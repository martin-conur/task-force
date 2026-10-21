//! The things task-monitor does outside its own screen: open a URL, go to a
//! zellij tab, and recreate a worker whose tab is gone. All go through a
//! runner so tests never touch a browser, a live zellij or a real worker.

use serde::Deserialize;

use crate::app::Recreate;

/// Run a program and return its stdout, or why it failed.
pub type Run<'a> = dyn FnMut(&str, &[&str]) -> Result<String, String> + 'a;
/// Run a program in a directory and return its stdout, or why it failed.
pub type RunIn<'a> = dyn FnMut(&str, &str, &[&str]) -> Result<String, String> + 'a;
/// Read an environment variable.
pub type Env<'a> = dyn Fn(&str) -> Option<String> + 'a;

pub fn system_run(prog: &str, args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new(prog)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("{prog}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "{prog} {} failed ({})",
            args.first().copied().unwrap_or(""),
            out.status
        ))
    }
}

/// Like [`system_run`], from directory `dir`, and a failure says what the
/// program said: task-recreate-worker explains its refusals on stderr, and
/// the status line is where they belong. The reason is its `Error: ` line,
/// since a warning can come first (kiro's), else its first line.
pub fn system_run_in(dir: &str, prog: &str, args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new(prog)
        .args(args)
        .current_dir(dir)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("{prog}: {e}"))?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let mut lines = stderr.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.clone().next();
    Err(lines
        .find_map(|l| l.strip_prefix("Error: "))
        .or(first)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{prog} failed ({})", out.status)))
}

pub fn system_env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

pub fn open_url(url: &str, run: &mut Run) -> Result<String, String> {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    run(opener, &[url]).map(|_| format!("opened {url}"))
}

#[derive(Deserialize)]
struct Tab {
    tab_id: Option<u64>,
    name: Option<String>,
    position: Option<u64>,
}

/// True when tab name `name` belongs to `slug`: the bare slug, or the slug
/// after a space-separated prefix (radio's `⏸️ ` / `▶️ ` / `❓︎ ` paint). The
/// same rule as `aw_tab_name_is_slug` in lib/zellij-tab.sh, which task-done
/// applies before it closes a tab (#260): keep the two in step.
pub fn tab_name_is(name: &str, slug: &str) -> bool {
    !slug.is_empty() && (name == slug || name.ends_with(&format!(" {slug}")))
}

/// Go to `name`'s tab by its recorded id, after checking that the tab at that
/// id is still `name`'s. A tab id is only valid for one zellij server's
/// lifetime, so after a restart it can belong to another worker's tab.
///
/// A tab in another zellij session is reached by switching this client to
/// that session (#287): its tabs are listed and the name checked the same
/// way, then `switch-session --tab-position` lands on the tab in one step.
/// `go-to-tab-by-id` is no use there: a session with no client attached has
/// no active tab, so the client would land wherever it attaches. The monitor
/// itself keeps running in its own session. Nothing switches until every
/// check has passed, and `switch-session` is never pointed at a session that
/// `list-tabs` did not answer for, because it creates a missing one.
///
/// For a `worker`'s tab, a tab that is gone says so and offers `R` (#291).
pub fn goto_tab(
    tab_id: Option<&str>,
    name: &str,
    session: Option<&str>,
    worker: bool,
    env: &Env,
    run: &mut Run,
) -> Result<String, String> {
    goto(tab_id, name, session, env, run).map_err(|miss| match miss {
        Miss::Gone(why) if worker => format!("tab gone · R to recreate ({why})"),
        Miss::Gone(why) | Miss::Other(why) => why,
    })
}

/// Why [`goto`] did not go: the tab is gone, or something else.
enum Miss {
    Gone(String),
    Other(String),
}

impl From<String> for Miss {
    fn from(why: String) -> Self {
        Miss::Other(why)
    }
}

impl From<&str> for Miss {
    fn from(why: &str) -> Self {
        Miss::Other(why.into())
    }
}

fn goto(
    tab_id: Option<&str>,
    name: &str,
    session: Option<&str>,
    env: &Env,
    run: &mut Run,
) -> Result<String, Miss> {
    if name.is_empty() {
        return Err("no PM session for this repo, so no tab to go to".into());
    }
    if env("ZELLIJ").is_none() {
        return Err("not inside zellij: t jumps to tabs from a zellij session".into());
    }
    let here = env("ZELLIJ_SESSION_NAME");
    let elsewhere = match (session, here.as_deref()) {
        (Some(there), Some(here)) if there != here => Some(there),
        _ => None,
    };
    let Some(id) = tab_id.filter(|id| !id.is_empty()) else {
        return Err(Miss::Gone(format!("no tab id recorded for {name}")));
    };
    let Ok(id_num) = id.parse::<u64>() else {
        return Err(format!("tab id '{id}' for {name} is not a number").into());
    };
    let listed = match elsewhere {
        None => run("zellij", &["action", "list-tabs", "--json"])?,
        Some(there) => run("zellij", &["-s", there, "action", "list-tabs", "--json"])
            .map_err(|_| format!("zellij session '{there}' did not answer: is it running?"))?,
    };
    // A session that is not running answers with a plain-text list, exit 0.
    let tabs: Vec<Tab> = serde_json::from_str(&listed).map_err(|_| match elsewhere {
        None => "zellij list-tabs returned nothing parseable".to_string(),
        Some(there) => format!("zellij session '{there}' is not running"),
    })?;
    let Some(t) = tabs.iter().find(|t| t.tab_id == Some(id_num)) else {
        return Err(Miss::Gone(format!(
            "no tab has id {id} any more (zellij restarted?)"
        )));
    };
    let at = t.name.as_deref().unwrap_or("");
    if !tab_name_is(at, name) {
        return Err(Miss::Gone(format!(
            "tab id {id} is now '{at}', not {name}: the recorded id is stale"
        )));
    }
    let Some(there) = elsewhere else {
        run("zellij", &["action", "go-to-tab-by-id", id])?;
        return Ok(format!("went to {at}"));
    };
    let Some(pos) = t.position else {
        return Err(format!("zellij did not say where tab {id} is in '{there}'").into());
    };
    // `--tab-position` counts from 1, where list-tabs' `position` counts from
    // 0. From the zellij v0.44.2 source: the attaching client's position goes
    // to `Screen::go_to_tab`, which calls
    // `switch_active_tab(tab_index.saturating_sub(1), ..)`, and that function
    // matches `t.position == new_tab_pos`, the field list-tabs reports.
    // https://github.com/zellij-org/zellij/blob/v0.44.2/zellij-server/src/screen.rs#L7347-L7348
    // https://github.com/zellij-org/zellij/blob/v0.44.2/zellij-server/src/screen.rs#L1955-L1957
    // A probe on throwaway sessions agreed: 1, 2 and 3 focused positions 0,
    // 1 and 2, and 0 also focused position 0.
    let pos = (pos + 1).to_string();
    run(
        "zellij",
        &["action", "switch-session", there, "--tab-position", &pos],
    )?;
    Ok(format!(
        "switched to session '{there}', tab {at} · the monitor is still in '{}'",
        here.as_deref().unwrap_or("its own session")
    ))
}

/// `R`: run `task-recreate-worker <slug> --session <session>` from the repo's
/// main checkout with its loadout, then go to the new tab the way `t` does
/// (#291). The command holds every rule (a live tab, a fresh heartbeat, a
/// missing worktree) and its refusal is the message. The monitor only
/// refuses what the command cannot see: no session to open the tab in, or
/// one that is not running, since this never creates a session.
pub fn recreate_worker(
    req: &Recreate,
    program: &str,
    env: &Env,
    run: &mut Run,
    run_in: &mut RunIn,
) -> Result<String, String> {
    let slug = req.slug.as_str();
    let repo = req.repo.as_str();
    let Some(session) = req.session.as_deref().filter(|s| !s.is_empty()) else {
        return Err(format!(
            "no zellij session recorded for {repo}: start its PM, then R again"
        ));
    };
    let Some(root) = req.root.as_deref().filter(|r| !r.is_empty()) else {
        return Err(format!("no main checkout recorded for {repo}"));
    };
    let tabs = session_tabs(session, run)?;
    let mut args = vec![slug, "--session", session];
    if let Some(l) = req.loadout.as_deref().filter(|l| !l.is_empty()) {
        args.extend(["--impl", l]);
    }
    run_in(root, program, &args)?;
    // The new tab's id, by its name, from the session it opened in. The
    // sidecar has it too, but only the next snapshot would carry it here.
    let tabs = session_tabs(session, run).unwrap_or(tabs);
    let Some(id) = tabs
        .iter()
        .find(|t| tab_name_is(t.name.as_deref().unwrap_or(""), slug))
        .and_then(|t| t.tab_id)
    else {
        return Ok(format!(
            "recreated {slug} in '{session}', but its tab is not listed yet: t once it shows"
        ));
    };
    let id = id.to_string();
    Ok(
        match goto_tab(Some(&id), slug, Some(session), true, env, run) {
            Ok(went) => format!("recreated {slug} · {went}"),
            Err(why) => format!("recreated {slug} in '{session}' · {why}"),
        },
    )
}

/// The tabs of a running zellij session, or why there are none. A session
/// that is not running answers `list-tabs` with plain text and exit 0.
fn session_tabs(session: &str, run: &mut Run) -> Result<Vec<Tab>, String> {
    let not_running = || format!("zellij session '{session}' is not running: R never creates one");
    let listed = run("zellij", &["-s", session, "action", "list-tabs", "--json"])
        .map_err(|_| not_running())?;
    serde_json::from_str(&listed).map_err(|_| not_running())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABS: &str = r#"[{"tab_id":0,"name":"⏸️ pm-task-force","position":0},
                           {"tab_id":4,"name":"▶️ kiro-config","position":2},
                           {"tab_id":5,"name":"other-kiro-config","position":1}]"#;

    fn env_in(session: &'static str) -> impl Fn(&str) -> Option<String> {
        move |k| match k {
            "ZELLIJ" => Some("0".into()),
            "ZELLIJ_SESSION_NAME" => Some(session.into()),
            _ => None,
        }
    }

    /// A zellij that lists TABS and records every call.
    fn fake(calls: &mut Vec<String>) -> impl FnMut(&str, &[&str]) -> Result<String, String> + '_ {
        move |prog, args| {
            calls.push(format!("{prog} {}", args.join(" ")));
            Ok(if args.contains(&"list-tabs") {
                TABS.into()
            } else {
                String::new()
            })
        }
    }

    #[test]
    fn goes_to_a_verified_tab() {
        let mut calls = vec![];
        let r = goto_tab(
            Some("4"),
            "kiro-config",
            Some("task-force"),
            false,
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert_eq!(r, Ok("went to ▶️ kiro-config".into()));
        assert_eq!(calls.last().unwrap(), "zellij action go-to-tab-by-id 4");
    }

    #[test]
    fn refuses_a_stale_id_now_held_by_another_tab() {
        let mut calls = vec![];
        let r = goto_tab(
            Some("5"),
            "kiro-config",
            None,
            false,
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert!(r.unwrap_err().contains("is now 'other-kiro-config'"));
        assert!(!calls.iter().any(|c| c.contains("go-to-tab")), "{calls:?}");
        let r = goto_tab(
            Some("9"),
            "kiro-config",
            None,
            false,
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert!(r.unwrap_err().contains("no tab has id 9"));
    }

    #[test]
    fn switches_to_a_verified_tab_in_another_session() {
        let mut calls = vec![];
        let r = goto_tab(
            Some("4"),
            "kiro-config",
            Some("rec"),
            false,
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert_eq!(
            r,
            Ok("switched to session 'rec', tab ▶️ kiro-config · the monitor is still in 'task-force'".into())
        );
        // The other session's tabs are listed, then one switch lands on the
        // tab by its 1-based position: no go-to-tab-by-id, no half-switch.
        assert_eq!(
            calls,
            vec![
                "zellij -s rec action list-tabs --json",
                "zellij action switch-session rec --tab-position 3",
            ]
        );
    }

    #[test]
    fn never_switches_session_when_a_check_fails() {
        // A stale id in the other session.
        let mut calls = vec![];
        let r = goto_tab(
            Some("5"),
            "kiro-config",
            Some("rec"),
            false,
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert!(r.unwrap_err().contains("is now 'other-kiro-config'"));
        assert_eq!(calls, vec!["zellij -s rec action list-tabs --json"]);
        // A session that is not running: zellij prints a plain-text list
        // and exits 0. switch-session would create the session, so it must
        // never be reached.
        let mut calls = vec![];
        let mut gone = |p: &str, a: &[&str]| {
            calls.push(format!("{p} {}", a.join(" ")));
            Ok::<_, String>(
                "Session 'rec' not found. The following sessions are active:\ntask-force".into(),
            )
        };
        let r = goto_tab(
            Some("4"),
            "kiro-config",
            Some("rec"),
            false,
            &env_in("task-force"),
            &mut gone,
        );
        assert_eq!(r, Err("zellij session 'rec' is not running".into()));
        assert_eq!(calls.len(), 1, "{calls:?}");
        // list-tabs failing outright.
        let mut failing = |_: &str, _: &[&str]| Err::<String, _>("zellij -s failed".to_string());
        let r = goto_tab(
            Some("4"),
            "kiro-config",
            Some("rec"),
            false,
            &env_in("task-force"),
            &mut failing,
        );
        assert!(r.unwrap_err().contains("did not answer"));
    }

    #[test]
    fn says_why_when_there_is_nothing_to_go_to() {
        let mut calls = vec![];
        let outside = |_: &str| None;
        assert!(goto_tab(
            Some("0"),
            "pm-x",
            None,
            false,
            &outside,
            &mut fake(&mut calls)
        )
        .unwrap_err()
        .contains("not inside zellij"));
        assert!(goto_tab(
            None,
            "pm-x",
            None,
            false,
            &env_in("s"),
            &mut fake(&mut calls)
        )
        .unwrap_err()
        .contains("no tab id"));
        assert!(goto_tab(
            Some("0"),
            "",
            None,
            false,
            &env_in("s"),
            &mut fake(&mut calls)
        )
        .unwrap_err()
        .contains("no PM session"));
        assert!(calls.is_empty());
        let mut broken = |_: &str, _: &[&str]| Ok::<_, String>("garbage".to_string());
        assert!(
            goto_tab(Some("0"), "pm-x", None, false, &env_in("s"), &mut broken)
                .unwrap_err()
                .contains("parseable")
        );
    }

    #[test]
    fn t_on_a_gone_worker_tab_offers_r() {
        let hint = |id: Option<&str>, worker: bool| {
            let mut calls = vec![];
            let r = goto_tab(
                id,
                "kiro-config",
                None,
                worker,
                &env_in("task-force"),
                &mut fake(&mut calls),
            );
            r.unwrap_err()
        };
        // No tab has the id, the id is another tab's, or none was recorded.
        assert_eq!(
            hint(Some("9"), true),
            "tab gone · R to recreate (no tab has id 9 any more (zellij restarted?))"
        );
        assert!(hint(Some("5"), true).starts_with("tab gone · R to recreate (tab id 5 is now"));
        assert!(hint(None, true).starts_with("tab gone · R to recreate (no tab id"));
        // The PM's and a reviewer's tabs are not R's to recreate.
        assert!(!hint(Some("9"), false).contains("R to recreate"));
        // A session that is not running is not a gone tab: R would refuse.
        let mut gone = |_: &str, _: &[&str]| Ok::<_, String>("Session 'rec' not found.".into());
        let r = goto_tab(
            Some("4"),
            "kiro-config",
            Some("rec"),
            true,
            &env_in("task-force"),
            &mut gone,
        );
        assert_eq!(r, Err("zellij session 'rec' is not running".into()));
    }

    fn req(session: Option<&str>) -> Recreate {
        Recreate {
            slug: "kiro-config".into(),
            repo: "recommender-systems".into(),
            root: Some("/src/rec".into()),
            loadout: Some("claude-local".into()),
            session: session.map(str::to_string),
        }
    }

    /// A task-recreate-worker that records where and how it ran, then
    /// answers with `answer`.
    fn recorder(
        ran: &mut Vec<String>,
        answer: Result<String, String>,
    ) -> impl FnMut(&str, &str, &[&str]) -> Result<String, String> + '_ {
        move |dir, prog, args| {
            ran.push(format!("{dir}: {prog} {}", args.join(" ")));
            answer.clone()
        }
    }

    #[test]
    fn r_runs_task_recreate_worker_in_the_repo_and_its_session_then_goes_there() {
        let (mut calls, mut ran) = (vec![], vec![]);
        let r = recreate_worker(
            &req(Some("rec")),
            "task-recreate-worker",
            &env_in("task-force"),
            &mut fake(&mut calls),
            &mut recorder(&mut ran, Ok("Recovered".into())),
        );
        // From the main checkout, with the loadout, into the repo's session.
        assert_eq!(
            ran,
            vec!["/src/rec: task-recreate-worker kiro-config --session rec --impl claude-local"]
        );
        // Checked running first, then the new tab found and reached the way
        // t reaches another session's tab.
        assert_eq!(
            calls,
            vec![
                "zellij -s rec action list-tabs --json",
                "zellij -s rec action list-tabs --json",
                "zellij -s rec action list-tabs --json",
                "zellij action switch-session rec --tab-position 3",
            ]
        );
        assert_eq!(
            r,
            Ok("recreated kiro-config · switched to session 'rec', tab ▶️ kiro-config · the monitor is still in 'task-force'".into())
        );
        // In the monitor's own session it is a plain go-to-tab.
        let (mut calls, mut ran) = (vec![], vec![]);
        let r = recreate_worker(
            &req(Some("rec")),
            "task-recreate-worker",
            &env_in("rec"),
            &mut fake(&mut calls),
            &mut recorder(&mut ran, Ok(String::new())),
        );
        assert_eq!(
            r,
            Ok("recreated kiro-config · went to ▶️ kiro-config".into())
        );
        assert_eq!(calls.last().unwrap(), "zellij action go-to-tab-by-id 4");
        // No loadout recorded: the command detects it.
        let (mut calls, mut ran) = (vec![], vec![]);
        let mut no_loadout = req(Some("rec"));
        no_loadout.loadout = None;
        let _ = recreate_worker(
            &no_loadout,
            "trw",
            &env_in("rec"),
            &mut fake(&mut calls),
            &mut recorder(&mut ran, Ok(String::new())),
        );
        assert_eq!(ran, vec!["/src/rec: trw kiro-config --session rec"]);
    }

    #[test]
    fn r_refuses_when_the_repo_session_is_not_running() {
        let (mut calls, mut ran) = (vec![], vec![]);
        let mut gone = |p: &str, a: &[&str]| {
            calls.push(format!("{p} {}", a.join(" ")));
            Ok::<_, String>("Session 'rec' not found. The following sessions are active:".into())
        };
        let r = recreate_worker(
            &req(Some("rec")),
            "task-recreate-worker",
            &env_in("task-force"),
            &mut gone,
            &mut recorder(&mut ran, Ok(String::new())),
        );
        assert_eq!(
            r,
            Err("zellij session 'rec' is not running: R never creates one".into())
        );
        assert!(ran.is_empty(), "{ran:?}");
        assert_eq!(calls, vec!["zellij -s rec action list-tabs --json"]);
        // No session recorded at all: nothing is asked, nothing runs.
        let (mut calls, mut ran) = (vec![], vec![]);
        let r = recreate_worker(
            &req(None),
            "task-recreate-worker",
            &env_in("task-force"),
            &mut fake(&mut calls),
            &mut recorder(&mut ran, Ok(String::new())),
        );
        assert!(r
            .unwrap_err()
            .contains("no zellij session recorded for recommender-systems"));
        assert!(calls.is_empty() && ran.is_empty());
    }

    #[test]
    fn r_shows_the_commands_refusal_and_goes_nowhere() {
        let (mut calls, mut ran) = (vec![], vec![]);
        let refusal =
            "worker-rec-kiro-config still looks live — refusing to open a second tab for one role.";
        let r = recreate_worker(
            &req(Some("rec")),
            "task-recreate-worker",
            &env_in("task-force"),
            &mut fake(&mut calls),
            &mut recorder(&mut ran, Err(refusal.into())),
        );
        assert_eq!(r, Err(refusal.into()));
        assert_eq!(calls, vec!["zellij -s rec action list-tabs --json"]);
    }

    #[test]
    fn r_says_so_when_the_new_tab_is_not_listed_yet() {
        let (mut calls, mut ran) = (vec![], vec![]);
        let mut empty = |p: &str, a: &[&str]| {
            calls.push(format!("{p} {}", a.join(" ")));
            Ok::<_, String>("[]".into())
        };
        let r = recreate_worker(
            &req(Some("rec")),
            "task-recreate-worker",
            &env_in("task-force"),
            &mut empty,
            &mut recorder(&mut ran, Ok(String::new())),
        );
        assert!(r.unwrap().contains("not listed yet"));
        assert!(
            !calls.iter().any(|c| c.contains("switch-session")),
            "{calls:?}"
        );
    }

    #[test]
    fn a_failing_command_reports_its_first_stderr_line() {
        let dir = std::env::temp_dir();
        let dir = dir.to_str().unwrap();
        let r = system_run_in(
            dir,
            "/bin/sh",
            &[
                "-c",
                "echo report; printf '\\nError: it refused\\n  because\\n' >&2; exit 1",
            ],
        );
        assert_eq!(r, Err("it refused".into()));
        // A warning before the Error: line does not hide it; with no Error:
        // line, the first line is the reason.
        let r = system_run_in(
            dir,
            "/bin/sh",
            &[
                "-c",
                "echo '⚠ V3 dialog ahead' >&2; echo 'Error: no worktree' >&2; exit 1",
            ],
        );
        assert_eq!(r, Err("no worktree".into()));
        let r = system_run_in(dir, "/bin/sh", &["-c", "echo 'plain' >&2; exit 1"]);
        assert_eq!(r, Err("plain".into()));
        let r = system_run_in(dir, "/bin/sh", &["-c", "pwd -P"]);
        let here = std::path::Path::new(dir).canonicalize().unwrap();
        assert_eq!(r.unwrap().trim(), here.to_str().unwrap(), "it runs in dir");
    }

    #[test]
    fn tab_name_rule_matches_task_done() {
        assert!(tab_name_is("kiro-config", "kiro-config"));
        assert!(tab_name_is("❓︎ kiro-config", "kiro-config"));
        assert!(!tab_name_is("other-kiro-config", "kiro-config"));
        assert!(!tab_name_is("kiro-config", ""));
    }

    #[test]
    fn opens_urls_with_the_platform_opener() {
        let mut calls = vec![];
        let mut run = |p: &str, a: &[&str]| {
            calls.push(format!("{p} {}", a.join(" ")));
            Ok(String::new())
        };
        assert!(open_url("https://x/1", &mut run).is_ok());
        let opener = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        assert_eq!(calls, vec![format!("{opener} https://x/1")]);
    }
}
