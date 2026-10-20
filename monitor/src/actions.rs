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
/// `t` cannot cross zellij sessions (#272), so a tab in another session is
/// named rather than attempted.
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
        return Err(
            "not inside zellij: t jumps to tabs of the monitor's own zellij session".into(),
        );
    }
    let here = env("ZELLIJ_SESSION_NAME");
    if let (Some(there), Some(here)) = (session, here.as_deref()) {
        if there != here {
            return Err(format!(
                "{name} is in zellij session '{there}': switch to it with zellij's session manager"
            ));
        }
    }
    let Some(id) = tab_id.filter(|id| !id.is_empty()) else {
        return Err(format!("no tab id recorded for {name}"));
    };
    let Ok(id_num) = id.parse::<u64>() else {
        return Err(format!("tab id '{id}' for {name} is not a number"));
    };
    let listed = run("zellij", &["action", "list-tabs", "--json"])?;
    let tabs: Vec<Tab> = serde_json::from_str(&listed)
        .map_err(|_| "zellij list-tabs returned nothing parseable".to_string())?;
    match tabs.iter().find(|t| t.tab_id == Some(id_num)) {
        None => Err(format!("no tab has id {id} any more (zellij restarted?)")),
        Some(t) => {
            let at = t.name.as_deref().unwrap_or("");
            if !tab_name_is(at, name) {
                return Err(format!(
                    "tab id {id} is now '{at}', not {name}: the recorded id is stale"
                ));
            }
            run("zellij", &["action", "go-to-tab-by-id", id])?;
            Ok(format!("went to {at}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABS: &str = r#"[{"tab_id":0,"name":"⏸️ pm-task-force","position":0},
                           {"tab_id":4,"name":"▶️ kiro-config"},
                           {"tab_id":5,"name":"other-kiro-config"}]"#;

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
            Ok(if args.get(1) == Some(&"list-tabs") {
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
    fn does_not_cross_zellij_sessions() {
        let mut calls = vec![];
        let r = goto_tab(
            Some("0"),
            "pm-rec",
            Some("rec"),
            &env_in("task-force"),
            &mut fake(&mut calls),
        );
        assert!(r.unwrap_err().contains("zellij session 'rec'"));
        assert!(calls.is_empty());
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
