//! Change detection: when to run the collector, and running it.
//!
//! Two kinds of run (#272). A *local* run (`--local`) reads disk only and
//! merges with the last full run's cache, so a filesystem event never waits
//! on GitHub. A *full* run also asks the forge, on a slow timer. Both run off
//! the UI thread; the screen keeps the last good snapshot while they do.

use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

use crate::snapshot::{self, Snapshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Local,
    Full,
}

impl Mode {
    /// A local run reads disk and is quick; a full run makes several `gh`
    /// calls per repo, and with `--all` that adds up.
    pub fn timeout(self) -> Duration {
        match self {
            Mode::Local => Duration::from_secs(20),
            Mode::Full => Duration::from_secs(180),
        }
    }
}

/// The trailing-edge debounce for filesystem events, and its cap: a steady
/// stream of events still refreshes at least this often.
pub const DEBOUNCE: Duration = Duration::from_millis(400);
pub const MAX_WAIT: Duration = Duration::from_secs(2);
pub const DEFAULT_POLL: Duration = Duration::from_secs(45);

/// Decides which runs to start. Pure, so its timing is testable: main feeds
/// it events and the clock, and starts whatever [`Scheduler::due`] returns.
#[derive(Debug)]
pub struct Scheduler {
    poll: Duration,
    first_event: Option<Instant>,
    last_event: Option<Instant>,
    running: [bool; 2],
    next_full: Instant,
}

impl Scheduler {
    /// Starts with both runs due: a local one for a quick first screen, a
    /// full one for the forge state.
    pub fn new(now: Instant, poll: Duration) -> Self {
        Scheduler {
            poll,
            first_event: Some(now),
            last_event: Some(now - DEBOUNCE),
            running: [false; 2],
            next_full: now,
        }
    }

    fn slot(mode: Mode) -> usize {
        mode as usize
    }

    pub fn fs_event(&mut self, now: Instant) {
        self.first_event.get_or_insert(now);
        self.last_event = Some(now);
    }

    pub fn due(&mut self, now: Instant) -> Vec<Mode> {
        let mut out = Vec::new();
        if let (Some(first), Some(last)) = (self.first_event, self.last_event) {
            let settled =
                now.duration_since(last) >= DEBOUNCE || now.duration_since(first) >= MAX_WAIT;
            // An event during a local run waits for it, then runs again:
            // the run in flight may have read the directory before the change.
            if settled && !self.running[Self::slot(Mode::Local)] {
                self.first_event = None;
                self.last_event = None;
                self.running[Self::slot(Mode::Local)] = true;
                out.push(Mode::Local);
            }
        }
        if !self.running[Self::slot(Mode::Full)] && now >= self.next_full {
            self.running[Self::slot(Mode::Full)] = true;
            out.push(Mode::Full);
        }
        out
    }

    pub fn finished(&mut self, mode: Mode, now: Instant) {
        self.running[Self::slot(mode)] = false;
        if mode == Mode::Full {
            self.next_full = now + self.poll;
        }
    }

    /// How long main may sleep before something could become due.
    pub fn next_wakeup(&self, now: Instant) -> Duration {
        let mut wake = if self.running[Self::slot(Mode::Full)] {
            Duration::MAX
        } else {
            self.next_full.saturating_duration_since(now)
        };
        if let (Some(first), Some(last)) = (self.first_event, self.last_event) {
            let at = (last + DEBOUNCE).min(first + MAX_WAIT);
            wake = wake.min(at.saturating_duration_since(now));
        }
        wake
    }
}

/// The collector command, `task-monitor-snapshot`.
#[derive(Debug, Clone)]
pub struct Collector {
    pub program: PathBuf,
    /// Arguments that go before the mode flags. Empty outside tests, which
    /// run their scripts as `/bin/sh <script>` (#283).
    pub lead: Vec<PathBuf>,
}

impl Collector {
    /// `$TASK_MONITOR_SNAPSHOT`, else the `bin/task-monitor-snapshot` of the
    /// checkout this binary was built in, else whichever is on PATH.
    pub fn locate() -> Self {
        if let Some(p) = std::env::var_os("TASK_MONITOR_SNAPSHOT").filter(|p| !p.is_empty()) {
            return Collector {
                program: p.into(),
                lead: Vec::new(),
            };
        }
        let sibling = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.canonicalize().ok())
            .and_then(|exe| {
                exe.ancestors()
                    .map(|a| a.join("bin/task-monitor-snapshot"))
                    .find(|p| p.is_file())
            });
        Collector {
            program: sibling.unwrap_or_else(|| "task-monitor-snapshot".into()),
            lead: Vec::new(),
        }
    }

    pub fn args(mode: Mode) -> Vec<&'static str> {
        let mut args = vec!["--json", "--all"];
        if mode == Mode::Local {
            args.push("--local");
        }
        args
    }

    /// Run once, killing the run at `timeout`. A failure says why in one
    /// line, for the footer.
    pub fn run(&self, mode: Mode, timeout: Duration) -> Result<Snapshot, String> {
        let name = self
            .program
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut child = Command::new(&self.program)
            .args(&self.lead)
            .args(Self::args(mode))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("cannot run {}: {e}", self.program.display()))?;
        // Drain both pipes on their own threads: a snapshot is far larger
        // than a pipe buffer, and a full stderr would stall the child too.
        let mut out = child.stdout.take().unwrap();
        let mut err = child.stderr.take().unwrap();
        let out_t = std::thread::spawn(move || {
            let mut s = String::new();
            out.read_to_string(&mut s).map(|_| s)
        });
        let err_t = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = err.read_to_string(&mut s);
            s
        });
        let deadline = Instant::now() + timeout;
        let status = loop {
            if let Some(st) = child.try_wait().map_err(|e| e.to_string())? {
                break st;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{name} timed out after {}s", timeout.as_secs()));
            }
            std::thread::sleep(Duration::from_millis(25));
        };
        let stdout = out_t
            .join()
            .map_err(|_| "reader panicked".to_string())?
            .map_err(|e| e.to_string())?;
        let stderr = err_t.join().unwrap_or_default();
        if !status.success() {
            let why = stderr
                .lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .unwrap_or("")
                .trim()
                .to_string();
            let code = status
                .code()
                .map(|c| format!("exit {c}"))
                .unwrap_or_else(|| "killed".into());
            return Err(if why.is_empty() {
                format!("{name} failed ({code})")
            } else {
                format!("{name} failed ({code}): {why}")
            });
        }
        snapshot::parse(&stdout)
    }
}

/// What the watcher watches, and the events that count.
///
/// - `<home>/radio`, recursively: sessions, mailboxes. Not its `log`, which
///   every radio call appends to and which carries nothing the other files
///   do not.
/// - `<home>/monitor`, recursively: the PM's queue, and the cache a full run
///   writes (so a full run's result reaches the next local run at once).
/// - each repo's worktree base, not recursively, for `.<slug>.info`
///   sidecars only: the worktrees under it are full of build output.
pub struct Targets {
    home: PathBuf,
    bases: HashSet<PathBuf>,
}

impl Targets {
    pub fn new(home: PathBuf) -> Self {
        Targets {
            home,
            bases: HashSet::new(),
        }
    }

    pub fn radio(&self) -> PathBuf {
        canon(self.home.join("radio"))
    }
    pub fn monitor(&self) -> PathBuf {
        canon(self.home.join("monitor"))
    }

    /// Learn the worktree bases a snapshot names. Returns the new ones.
    pub fn learn(&mut self, snap: &Snapshot) -> Vec<PathBuf> {
        let mut new = Vec::new();
        let named = snap.repos.iter().flat_map(|r| {
            r.worktree_base
                .iter()
                .map(PathBuf::from)
                .chain(r.in_flight.iter().filter_map(|i| {
                    Path::new(i.worktree.as_deref()?)
                        .parent()
                        .map(Path::to_path_buf)
                }))
        });
        for base in named.map(canon) {
            if self.bases.insert(base.clone()) {
                new.push(base);
            }
        }
        new
    }

    pub fn relevant(&self, path: &Path) -> bool {
        if let Ok(rest) = path.strip_prefix(self.radio()) {
            return rest != Path::new("log") && !rest.starts_with("log.");
        }
        if path.starts_with(self.monitor()) {
            return true;
        }
        let sidecar = path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with('.') && n.ends_with(".info"));
        sidecar && path.parent().is_some_and(|p| self.bases.contains(p))
    }
}

/// The path the kernel reports events under. FSEvents names the real path
/// (`/private/var/…` for `/var/…`), so a target reached through a symlink
/// must be compared in that form or its every event is filtered out. A path
/// that does not exist yet stays as given, and is learned again once it does.
fn canon(p: PathBuf) -> PathBuf {
    p.canonicalize().unwrap_or(p)
}

/// Keeps a filesystem watcher on [`Targets`], adding each target once it
/// exists. Events are forwarded through `notify`.
pub struct Watcher {
    inner: Option<notify::RecommendedWatcher>,
    watched: HashSet<PathBuf>,
    pub targets: std::sync::Arc<std::sync::Mutex<Targets>>,
}

impl Watcher {
    pub fn new(home: PathBuf, notify_tx: Sender<()>) -> Self {
        let targets = std::sync::Arc::new(std::sync::Mutex::new(Targets::new(home)));
        let t = targets.clone();
        let inner = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(ev) = res else { return };
            if matches!(ev.kind, notify::EventKind::Access(_)) {
                return;
            }
            let targets = t.lock().unwrap();
            if ev.paths.iter().any(|p| targets.relevant(p)) {
                let _ = notify_tx.send(());
            }
        })
        .ok();
        Watcher {
            inner,
            watched: HashSet::new(),
            targets,
        }
    }

    /// Whether filesystem events are available at all. Without them the
    /// slow poll still refreshes everything.
    pub fn available(&self) -> bool {
        self.inner.is_some()
    }

    /// Watch every target that exists and is not watched yet. Called after
    /// each snapshot, so a radio dir or worktree base that appears later is
    /// picked up.
    pub fn sync(&mut self, snap: Option<&Snapshot>) {
        use notify::{RecursiveMode, Watcher as _};
        let Some(inner) = self.inner.as_mut() else {
            return;
        };
        let wanted: Vec<(PathBuf, RecursiveMode)> = {
            let mut t = self.targets.lock().unwrap();
            if let Some(s) = snap {
                t.learn(s);
            }
            let mut w = vec![
                (t.radio(), RecursiveMode::Recursive),
                (t.monitor(), RecursiveMode::Recursive),
            ];
            w.extend(
                t.bases
                    .iter()
                    .cloned()
                    .map(|b| (b, RecursiveMode::NonRecursive)),
            );
            w
        };
        for (path, mode) in wanted {
            if !self.watched.contains(&path) && path.is_dir() && inner.watch(&path, mode).is_ok() {
                self.watched.insert(path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn starts_with_a_local_and_a_full_run() {
        let t0 = Instant::now();
        let mut s = Scheduler::new(t0, DEFAULT_POLL);
        assert_eq!(s.due(t0), vec![Mode::Local, Mode::Full]);
        assert_eq!(s.due(t0 + ms(10)), vec![]);
    }

    #[test]
    fn events_are_debounced_on_the_trailing_edge() {
        let t0 = Instant::now();
        let mut s = Scheduler::new(t0, DEFAULT_POLL);
        s.due(t0);
        s.finished(Mode::Local, t0);
        s.fs_event(t0 + ms(100));
        s.fs_event(t0 + ms(300));
        assert_eq!(
            s.due(t0 + ms(600)),
            vec![],
            "300ms after the last event is still inside the debounce"
        );
        assert_eq!(s.next_wakeup(t0 + ms(600)), ms(100));
        assert_eq!(s.due(t0 + ms(700)), vec![Mode::Local]);
    }

    #[test]
    fn a_steady_stream_of_events_still_refreshes() {
        let t0 = Instant::now();
        let mut s = Scheduler::new(t0, DEFAULT_POLL);
        s.due(t0);
        s.finished(Mode::Local, t0);
        let mut fired = false;
        for i in 1..=30 {
            let t = t0 + ms(i * 100);
            s.fs_event(t);
            fired |= s.due(t).contains(&Mode::Local);
        }
        assert!(fired, "MAX_WAIT caps the debounce");
    }

    #[test]
    fn an_event_during_a_local_run_reruns_after_it() {
        let t0 = Instant::now();
        let mut s = Scheduler::new(t0, DEFAULT_POLL);
        s.due(t0);
        s.fs_event(t0 + ms(10));
        assert_eq!(s.due(t0 + ms(1000)), vec![], "one local run at a time");
        s.finished(Mode::Local, t0 + ms(1100));
        assert_eq!(s.due(t0 + ms(1100)), vec![Mode::Local]);
    }

    #[test]
    fn the_full_run_repeats_on_the_poll_after_it_finishes() {
        let t0 = Instant::now();
        let poll = Duration::from_secs(45);
        let mut s = Scheduler::new(t0, poll);
        s.due(t0);
        s.finished(Mode::Local, t0);
        // A slow full run: the next one is timed from when it finished.
        let done = t0 + Duration::from_secs(30);
        assert_eq!(s.due(done), vec![]);
        s.finished(Mode::Full, done);
        assert_eq!(s.due(done + poll - ms(1)), vec![]);
        assert_eq!(s.due(done + poll), vec![Mode::Full]);
    }

    fn targets() -> Targets {
        let mut t = Targets::new("/h".into());
        let snap = snapshot::parse(include_str!("../tests/fixtures/multi.json")).unwrap();
        t.learn(&snap);
        t
    }

    #[test]
    fn only_state_files_and_sidecars_count_as_changes() {
        let t = targets();
        assert!(t.relevant(Path::new("/h/radio/sessions/pm-x.info")));
        assert!(t.relevant(Path::new("/h/radio/mailbox/pm-x/inbox/1.md")));
        assert!(t.relevant(Path::new("/h/monitor/task-force/queue")));
        assert!(!t.relevant(Path::new("/h/radio/log")));
        assert!(t.relevant(Path::new(
            "/home/you/src/task-force-worktrees/.home-env.info"
        )));
        assert!(t.relevant(Path::new(
            "/home/you/src/recommender-systems-worktrees/.new.info"
        )));
        assert!(!t.relevant(Path::new(
            "/home/you/src/task-force-worktrees/home-env/target/x.o"
        )));
        assert!(!t.relevant(Path::new("/home/you/src/task-force-worktrees/notes.txt")));
        assert!(!t.relevant(Path::new("/elsewhere/.x.info")));
    }

    #[test]
    fn targets_behind_a_symlink_match_the_real_paths_events_name() {
        let real = tmpdir("canon-real");
        std::fs::create_dir_all(real.join("radio/sessions")).unwrap();
        std::fs::create_dir_all(real.join("wt")).unwrap();
        let link = std::env::temp_dir().join(format!(
            "task-monitor-test-canon-link-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let mut t = Targets::new(link.clone());
        let mut snap = Snapshot::default();
        snap.repos.push(crate::snapshot::Repo {
            worktree_base: Some(link.join("wt").display().to_string()),
            ..Default::default()
        });
        t.learn(&snap);
        let real = real.canonicalize().unwrap();
        assert!(t.relevant(&real.join("radio/sessions/pm-x.info")));
        assert!(t.relevant(&real.join("wt/.slug.info")));
        std::fs::remove_file(&link).unwrap();
    }

    #[test]
    fn learns_each_worktree_base_once() {
        let mut t = targets();
        let snap = snapshot::parse(include_str!("../tests/fixtures/multi.json")).unwrap();
        assert!(t.learn(&snap).is_empty());
    }

    /// Run through `/bin/sh` rather than exec'd: on Linux, exec'ing a file
    /// just written fails with ETXTBSY while a parallel test's fork still
    /// holds its write fd (#283).
    fn script(dir: &Path, body: &str) -> Collector {
        let p = dir.join("snap");
        std::fs::write(&p, format!("{body}\n")).unwrap();
        Collector {
            program: "/bin/sh".into(),
            lead: vec![p],
        }
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("task-monitor-test-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn runs_the_collector_with_the_mode_flags() {
        let d = tmpdir("args");
        let c = script(
            &d,
            &format!(
                "echo \"$@\" > {}/args; echo '{{\"schema\":1,\"repos\":[]}}'",
                d.display()
            ),
        );
        c.run(Mode::Local, Duration::from_secs(5)).unwrap();
        assert_eq!(
            std::fs::read_to_string(d.join("args")).unwrap().trim(),
            "--json --all --local"
        );
        c.run(Mode::Full, Duration::from_secs(5)).unwrap();
        assert_eq!(
            std::fs::read_to_string(d.join("args")).unwrap().trim(),
            "--json --all"
        );
    }

    #[test]
    fn a_failing_collector_says_why() {
        let d = tmpdir("fail");
        let err = script(&d, "echo 'task-monitor-snapshot: not a repo' >&2; exit 3")
            .run(Mode::Local, Duration::from_secs(5))
            .unwrap_err();
        assert!(
            err.contains("exit 3") && err.contains("not a repo"),
            "{err}"
        );
        let err = script(&d, "echo '{'")
            .run(Mode::Local, Duration::from_secs(5))
            .unwrap_err();
        assert!(err.contains("bad snapshot JSON"), "{err}");
    }

    #[test]
    fn a_hung_collector_is_killed_at_the_timeout() {
        let d = tmpdir("hang");
        let t = Instant::now();
        let err = script(&d, "exec sleep 30")
            .run(Mode::Local, ms(300))
            .unwrap_err();
        assert!(err.contains("timed out"), "{err}");
        assert!(t.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_large_snapshot_does_not_deadlock_the_pipe() {
        let d = tmpdir("big");
        let pad = "x".repeat(1000);
        let body = format!(
            "printf '{{\"schema\":1,\"repos\":[],\"pad\":\"'; i=0; while [ $i -lt 400 ]; do printf '{pad}'; i=$((i+1)); done; printf '\"}}'"
        );
        script(&d, &body)
            .run(Mode::Full, Duration::from_secs(10))
            .unwrap();
    }
}
