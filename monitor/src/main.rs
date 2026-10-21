//! task-monitor: a real-time terminal view of what is in flight, next and
//! done in each repo task-force runs in, and which repo needs you (#272).
//!
//! It owns the screen, the keys and change detection, and nothing else.
//! Every value shown comes from `task-monitor-snapshot --json`
//! (docs/task-monitor-schema.md); this binary holds no task-force logic.

mod actions;
mod app;
mod refresh;
mod snapshot;
mod ui;

use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use chrono::Utc;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};

use app::{Action, App, Key, Offer};
use refresh::{Collector, Mode, Scheduler, Watcher};

const USAGE: &str = "\
Usage: task-monitor [--all] [--poll SECS]

A real-time view of task-force work: the repo view (in flight, next, done) and
the all-repos overview, which lists each repo's PM, workers and reviewers under
its attention light and marks the agent that needs you with `← you`.

  --all         open on the all-repos overview (the default outside a repo)
  --poll SECS   how often to ask the forge for PR and CI state (30-600, default 45)
  -h, --help    this help
  -V, --version the version

Keys: ↑↓ move  ⏎ expand / enter repo  o open PR/issue  t jump to tab
      ! overview: only what needs you  a all repos  q quit

t on an agent in another zellij session switches this client to that session
and tab; task-monitor keeps running in its own session, so come back through
zellij's session manager.

Local changes (radio mail, worker state, worktree sidecars) refresh at once
from disk; forge state refreshes every --poll seconds. The data comes from
task-monitor-snapshot ($TASK_MONITOR_SNAPSHOT overrides which one).
";

struct Args {
    all: bool,
    poll: Duration,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        all: false,
        poll: refresh::DEFAULT_POLL,
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--all" => args.all = true,
            "--poll" => {
                let v = it.next().ok_or("--poll needs a number of seconds")?;
                let secs: u64 = v
                    .parse()
                    .map_err(|_| format!("--poll: '{v}' is not a number of seconds"))?;
                if !(30..=600).contains(&secs) {
                    return Err(format!("--poll: {secs}s is outside 30-600"));
                }
                args.poll = Duration::from_secs(secs);
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "-V" | "--version" => {
                println!("task-monitor {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(args)
}

fn in_repo() -> bool {
    std::process::Command::new("git")
        .args(["rev-parse", "--is-inside-work-tree"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn radio_home() -> PathBuf {
    match std::env::var_os("TASK_FORCE_HOME").filter(|v| !v.is_empty()) {
        Some(h) => h.into(),
        None => PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".task-force"),
    }
}

enum Msg {
    Key(Key),
    Redraw,
    Fs,
    Ran {
        mode: Mode,
        started: Instant,
        result: Result<snapshot::Snapshot, String>,
    },
}

fn to_key(ev: event::KeyEvent) -> Option<Key> {
    if ev.kind != KeyEventKind::Press {
        return None;
    }
    Some(match ev.code {
        KeyCode::Char('c') if ev.modifiers.contains(KeyModifiers::CONTROL) => Key::Quit,
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        KeyCode::Enter => Key::Enter,
        KeyCode::Esc => Key::Esc,
        KeyCode::Char(c) => Key::Char(c),
        _ => return None,
    })
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("task-monitor: {e}\n\n{USAGE}");
            std::process::exit(2);
        }
    };
    let collector = Collector::locate();
    let mut app = App::new(!args.all && in_repo());

    let (tx, rx) = mpsc::channel::<Msg>();
    let (fs_tx, fs_rx) = mpsc::channel::<()>();
    let mut watcher = Watcher::new(radio_home(), fs_tx);
    watcher.sync(None);
    if !watcher.available() {
        app.flash(
            Utc::now(),
            "no filesystem events here: refreshing on the poll only",
        );
    }
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            while fs_rx.recv().is_ok() {
                if tx.send(Msg::Fs).is_err() {
                    break;
                }
            }
        });
    }
    {
        let tx = tx.clone();
        std::thread::spawn(move || loop {
            let msg = match event::read() {
                Ok(Event::Key(k)) => match to_key(k) {
                    Some(k) => Msg::Key(k),
                    None => continue,
                },
                Ok(Event::Resize(..)) => Msg::Redraw,
                Ok(_) => continue,
                Err(_) => break,
            };
            if tx.send(msg).is_err() {
                break;
            }
        });
    }

    let mut terminal = ratatui::init();
    let mut sched = Scheduler::new(Instant::now(), args.poll);
    loop {
        let now = Instant::now();
        for mode in sched.due(now) {
            let (tx, c) = (tx.clone(), collector.clone());
            std::thread::spawn(move || {
                let started = Instant::now();
                let result = c.run(mode, mode.timeout());
                let _ = tx.send(Msg::Ran {
                    mode,
                    started,
                    result,
                });
            });
        }
        if terminal
            .draw(|f| ui::draw(f, &mut app, Utc::now()))
            .is_err()
        {
            break;
        }
        // Wake at least once a second, so the clock and the ages move.
        let wait = sched
            .next_wakeup(Instant::now())
            .min(Duration::from_secs(1));
        let msg = match rx.recv_timeout(wait) {
            Ok(m) => m,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        match msg {
            Msg::Redraw => {}
            Msg::Fs => sched.fs_event(Instant::now()),
            Msg::Ran {
                mode,
                started,
                result,
            } => {
                sched.finished(mode, Instant::now());
                match result {
                    Ok(snap) => match app.offer(started, mode, snap, Utc::now()) {
                        Offer::Rejected => {}
                        taken => {
                            watcher.sync(app.snapshot.as_ref());
                            if taken == Offer::TakenNeedsLocal {
                                sched.fs_event(Instant::now());
                            }
                        }
                    },
                    Err(why) => app.failed(started, mode, Utc::now(), why),
                }
            }
            Msg::Key(k) => match app.key(k, Utc::now()) {
                None => {}
                Some(Action::Quit) => break,
                Some(Action::Open(url)) => {
                    let r = actions::open_url(&url, &mut actions::system_run);
                    app.flash(Utc::now(), r.unwrap_or_else(|e| e));
                }
                Some(Action::GotoTab {
                    tab_id,
                    name,
                    session,
                }) => {
                    let r = actions::goto_tab(
                        tab_id.as_deref(),
                        &name,
                        session.as_deref(),
                        &actions::system_env,
                        &mut actions::system_run,
                    );
                    app.flash(Utc::now(), r.unwrap_or_else(|e| e));
                }
            },
        }
    }
    ratatui::restore();
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::crossterm::event::{KeyEvent, KeyEventState};

    fn press(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent {
            code,
            modifiers,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
        }
    }

    #[test]
    fn ctrl_c_quits_and_a_bare_c_is_just_a_key() {
        assert_eq!(
            to_key(press(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Some(Key::Quit)
        );
        assert_eq!(
            to_key(press(KeyCode::Char('c'), KeyModifiers::NONE)),
            Some(Key::Char('c'))
        );
        assert_eq!(
            to_key(press(KeyCode::Enter, KeyModifiers::NONE)),
            Some(Key::Enter)
        );
        let release = KeyEvent {
            kind: KeyEventKind::Release,
            ..press(KeyCode::Char('q'), KeyModifiers::NONE)
        };
        assert_eq!(
            to_key(release),
            None,
            "only presses count, or every key acts twice"
        );
    }
}
