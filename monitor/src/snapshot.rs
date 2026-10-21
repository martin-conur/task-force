//! The snapshot document, schema 1 (docs/task-monitor-schema.md).
//!
//! This is a reader of `task-monitor-snapshot --json` and nothing more. Every
//! field is optional and unknown fields are ignored, as the schema's
//! compatibility rule asks: version 1 may grow fields, and a snapshot missing
//! one must still render. Nothing here derives task-force state; it only
//! names what the collector already wrote.

use serde::{Deserialize, Deserializer};

pub const SCHEMA: u64 = 1;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    pub schema: Option<u64>,
    pub generated_at: Option<String>,
    pub mode: Option<String>,
    pub repos: Vec<Repo>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Repo {
    #[serde(deserialize_with = "scalar")]
    pub name: Option<String>,
    pub root: Option<String>,
    pub worktree_base: Option<String>,
    pub loadout: Option<String>,
    pub tracker: Option<String>,
    pub agent: Option<String>,
    pub pm: Pm,
    pub forge: Forge,
    pub in_flight: Vec<InFlight>,
    pub next: Next,
    pub done: Done,
    pub attention: Attention,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Pm {
    pub role: Option<String>,
    pub state: Option<String>,
    pub last_heartbeat: Option<String>,
    pub tab: Option<String>,
    #[serde(deserialize_with = "scalar")]
    pub tab_id: Option<String>,
    pub zellij_session: Option<String>,
    pub agent: Option<String>,
    pub alias_of: Option<String>,
    pub unread: u64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Forge {
    pub available: bool,
    pub fetched_at: Option<String>,
    pub stale: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Session {
    pub role: Option<String>,
    pub state: Option<String>,
    pub last_heartbeat: Option<String>,
    pub tab: Option<String>,
    #[serde(deserialize_with = "scalar")]
    pub tab_id: Option<String>,
    pub zellij_session: Option<String>,
    pub agent: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Pr {
    pub number: Option<u64>,
    pub url: Option<String>,
    pub title: Option<String>,
    pub state: Option<String>,
    pub is_draft: bool,
    pub head: Option<String>,
    pub summary: Option<String>,
    pub merged_at: Option<String>,
    pub merge_sha: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Reviewer {
    pub pr: Option<u64>,
    pub role: Option<String>,
    pub session: Option<Session>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct InFlight {
    pub slug: Option<String>,
    #[serde(rename = "ref", deserialize_with = "scalar")]
    pub reference: Option<String>,
    pub branch: Option<String>,
    pub worktree: Option<String>,
    pub label: Option<String>,
    pub number: Option<u64>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    pub pr: Option<Pr>,
    pub status: Option<String>,
    pub session: Option<Session>,
    #[serde(deserialize_with = "scalar")]
    pub tab_id: Option<String>,
    pub reviewers: Vec<Reviewer>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Next {
    pub source: Option<String>,
    pub items: Vec<NextItem>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct NextItem {
    #[serde(rename = "ref", deserialize_with = "scalar")]
    pub reference: Option<String>,
    pub label: Option<String>,
    pub number: Option<u64>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Done {
    pub window_hours: Option<u64>,
    pub min_items: Option<u64>,
    pub items: Vec<DoneItem>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DoneItem {
    #[serde(rename = "ref", deserialize_with = "scalar")]
    pub reference: Option<String>,
    pub label: Option<String>,
    pub number: Option<u64>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    pub summary: Option<String>,
    pub body: Option<String>,
    pub pr: Option<Pr>,
    pub merged_at: Option<String>,
    pub merge_sha: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Attention {
    pub active: bool,
    pub signals: Vec<Signal>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Signal {
    pub kind: Option<String>,
    pub text: Option<String>,
    /// `unread-inbox`: the PM's unread count.
    pub count: Option<u64>,
    /// `review-waiting-merge`: the PRs whose review waits on the PM.
    #[serde(deserialize_with = "numbers")]
    pub prs: Vec<u64>,
    /// `worker-awaiting`: the workers asking.
    pub workers: Vec<AwaitingWorker>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct AwaitingWorker {
    pub role: Option<String>,
    pub slug: Option<String>,
    pub last_heartbeat: Option<String>,
}

/// Accept a string, a number or null where the schema names a string. A ref
/// is `"266"` today; a collector that ever emits `266` must not blank the
/// screen over it.
fn scalar<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(match serde_json::Value::deserialize(d)? {
        serde_json::Value::String(s) => Some(s),
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        _ => None,
    })
}

/// A list of numbers, where an entry may come as a string (the collector
/// passes through a PR it could not read as a number). Others are dropped.
fn numbers<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u64>, D::Error> {
    Ok(match serde_json::Value::deserialize(d)? {
        serde_json::Value::Array(items) => items
            .iter()
            .filter_map(|v| match v {
                serde_json::Value::Number(n) => n.as_u64(),
                serde_json::Value::String(s) => s.parse().ok(),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    })
}

/// Parse a snapshot. Refuses a different schema version, because a reader
/// that guesses at a breaking change shows wrong data rather than none.
pub fn parse(text: &str) -> Result<Snapshot, String> {
    let snap: Snapshot =
        serde_json::from_str(text).map_err(|e| format!("bad snapshot JSON: {e}"))?;
    match snap.schema {
        Some(SCHEMA) => Ok(snap),
        Some(v) => Err(format!(
            "snapshot schema {v}, this task-monitor reads {SCHEMA}"
        )),
        None => Err("snapshot has no schema field".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_documented_example() {
        let snap = parse(include_str!("../../docs/task-monitor-schema.example.json")).unwrap();
        let repo = &snap.repos[0];
        assert_eq!(repo.name.as_deref(), Some("task-force"));
        assert_eq!(repo.pm.unread, 1);
        assert_eq!(repo.in_flight[0].slug.as_deref(), Some("monitor-snapshot"));
        assert_eq!(repo.in_flight[0].tab_id.as_deref(), Some("1"));
        assert!(repo.attention.active);
        assert_eq!(repo.done.items[0].pr.as_ref().unwrap().number, Some(269));
    }

    #[test]
    fn tolerates_missing_and_unknown_fields() {
        let snap = parse(r#"{"schema":1,"repos":[{"name":"x","future":{"a":1},"in_flight":[{"ref":42,"tab_id":3}]}]}"#).unwrap();
        let item = &snap.repos[0].in_flight[0];
        assert_eq!(item.reference.as_deref(), Some("42"));
        assert_eq!(item.tab_id.as_deref(), Some("3"));
        assert!(snap.repos[0].pm.role.is_none());
    }

    #[test]
    fn reads_each_signal_kinds_own_fields() {
        let snap = parse(
            r#"{"schema":1,"repos":[{"attention":{"active":true,"signals":[
                {"kind":"unread-inbox","count":2,"text":"✉ 2 unread"},
                {"kind":"review-waiting-merge","prs":[270,"271","x"]},
                {"kind":"worker-awaiting","workers":[{"role":"worker-r-a","slug":"a"}]}]}}]}"#,
        )
        .unwrap();
        let s = &snap.repos[0].attention.signals;
        assert_eq!(s[0].count, Some(2));
        assert_eq!(s[1].prs, vec![270, 271]);
        assert_eq!(s[2].workers[0].slug.as_deref(), Some("a"));
        assert!(s[0].workers.is_empty() && s[2].prs.is_empty());
    }

    #[test]
    fn refuses_another_schema_version() {
        assert!(parse(r#"{"schema":2,"repos":[]}"#)
            .unwrap_err()
            .contains("schema 2"));
        assert!(parse(r#"{"repos":[]}"#).is_err());
        assert!(parse("not json").is_err());
    }
}
