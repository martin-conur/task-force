//! The two things task-monitor does outside its own screen: open a URL, and
//! go to a zellij tab. Both go through a runner so tests never touch a
//! browser or a live zellij.

use serde::Deserialize;

/// Run a program and return its stdout, or why it failed.
pub type Run<'a> = dyn FnMut(&str, &[&str]) -> Result<String, String> + 'a;
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
pub fn goto_tab(
    tab_id: Option<&str>,
    name: &str,
    session: Option<&str>,
    env: &Env,
    run: &mut Run,
) -> Result<String, String> {
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
        return Err(format!("no tab id recorded for {name}"));
    };
    let Ok(id_num) = id.parse::<u64>() else {
        return Err(format!("tab id '{id}' for {name} is not a number"));
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
        return Err(format!("no tab has id {id} any more (zellij restarted?)"));
    };
    let at = t.name.as_deref().unwrap_or("");
    if !tab_name_is(at, name) {
        return Err(format!(
            "tab id {id} is now '{at}', not {name}: the recorded id is stale"
        ));
    }
    let Some(there) = elsewhere else {
        run("zellij", &["action", "go-to-tab-by-id", id])?;
        return Ok(format!("went to {at}"));
    };
    let Some(pos) = t.position else {
        return Err(format!("zellij did not say where tab {id} is in '{there}'"));
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
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert!(r.unwrap_err().contains("is now 'other-kiro-config'"));
        assert!(!calls.iter().any(|c| c.contains("go-to-tab")), "{calls:?}");
        let r = goto_tab(
            Some("9"),
            "kiro-config",
            None,
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
            &env_in("task-force"),
            &mut failing,
        );
        assert!(r.unwrap_err().contains("did not answer"));
    }

    #[test]
    fn says_why_when_there_is_nothing_to_go_to() {
        let mut calls = vec![];
        let outside = |_: &str| None;
        assert!(
            goto_tab(Some("0"), "pm-x", None, &outside, &mut fake(&mut calls))
                .unwrap_err()
                .contains("not inside zellij")
        );
        assert!(
            goto_tab(None, "pm-x", None, &env_in("s"), &mut fake(&mut calls))
                .unwrap_err()
                .contains("no tab id")
        );
        assert!(
            goto_tab(Some("0"), "", None, &env_in("s"), &mut fake(&mut calls))
                .unwrap_err()
                .contains("no PM session")
        );
        assert!(calls.is_empty());
        let mut broken = |_: &str, _: &[&str]| Ok::<_, String>("garbage".to_string());
        assert!(goto_tab(Some("0"), "pm-x", None, &env_in("s"), &mut broken)
            .unwrap_err()
            .contains("parseable"));
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
