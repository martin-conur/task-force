//! Screen state and key handling. Pure: a key press changes the state and
//! may return an [`Action`] for main to carry out (open a URL, go to a tab),
//! so every key is testable without a terminal, a browser or zellij.

use std::time::Instant;

use chrono::{DateTime, Utc};

use crate::refresh::Mode;
use crate::snapshot::{InFlight, Repo, Snapshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Up,
    Down,
    PageUp,
    PageDown,
    Enter,
    Esc,
    Char(char),
    Quit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Quit,
    Open(String),
    /// Go to a zellij tab, once it is verified to still be `name`'s.
    GotoTab {
        tab_id: Option<String>,
        name: String,
        session: Option<String>,
    },
}

/// What [`App::offer`] did with a snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Offer {
    /// A newer one is on screen.
    Rejected,
    Taken,
    /// Taken, but its disk state is older than what it replaced: run a
    /// local refresh to bring that back.
    TakenNeedsLocal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum View {
    /// One repo, by its snapshot `name`.
    Repo(String),
    Overview,
}

/// A selectable row of the repo view, by index into its section.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Row {
    InFlight(usize),
    Next(usize),
    Done(usize),
}

pub fn rows(repo: &Repo) -> Vec<Row> {
    (0..repo.in_flight.len())
        .map(Row::InFlight)
        .chain((0..repo.next.items.len()).map(Row::Next))
        .chain((0..repo.done.items.len()).map(Row::Done))
        .collect()
}

/// A row of the overview: a repo, then its agents under it. Indices are
/// into `repos`, a repo's `in_flight` and an item's `reviewers`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OvRow {
    Repo(usize),
    Pm(usize),
    Worker(usize, usize),
    Reviewer(usize, usize, usize),
}

impl OvRow {
    pub fn repo(self) -> usize {
        match self {
            OvRow::Repo(r) | OvRow::Pm(r) | OvRow::Worker(r, _) | OvRow::Reviewer(r, _, _) => r,
        }
    }
}

fn has_signal(repo: &Repo, kind: &str) -> bool {
    repo.attention
        .signals
        .iter()
        .any(|s| s.kind.as_deref() == Some(kind))
}

/// The PM is the agent behind unread mail and a review waiting on merge.
pub fn pm_needs_you(repo: &Repo) -> bool {
    has_signal(repo, "unread-inbox") || has_signal(repo, "review-waiting-merge")
}

/// A worker needs you when the `worker-awaiting` signal names it. The
/// signal, not the session's `STATE=`, decides: it has already dropped an
/// `awaiting` a crashed tab left behind.
pub fn worker_needs_you(repo: &Repo, item: &InFlight) -> bool {
    let role = item.session.as_ref().and_then(|s| s.role.as_deref());
    repo.attention
        .signals
        .iter()
        .filter(|s| s.kind.as_deref() == Some("worker-awaiting"))
        .flat_map(|s| &s.workers)
        .any(|w| {
            (w.role.is_some() && w.role.as_deref() == role)
                || (w.slug.is_some() && w.slug == item.slug)
        })
}

/// Every overview row, in screen order. `needs_you` keeps only the agents
/// that need you, under their repo's row, and drops repos with none.
pub fn overview_rows(repos: &[Repo], needs_you: bool) -> Vec<OvRow> {
    let mut out = Vec::new();
    for (r, repo) in repos.iter().enumerate() {
        let mut agents = Vec::new();
        if !needs_you || pm_needs_you(repo) {
            agents.push(OvRow::Pm(r));
        }
        for (i, item) in repo.in_flight.iter().enumerate() {
            if !needs_you || worker_needs_you(repo, item) {
                agents.push(OvRow::Worker(r, i));
            }
            if !needs_you {
                agents.extend((0..item.reviewers.len()).map(|k| OvRow::Reviewer(r, i, k)));
            }
        }
        if needs_you && agents.is_empty() {
            continue;
        }
        out.push(OvRow::Repo(r));
        out.extend(agents);
    }
    out
}

/// What the screen shows for freshness. The snapshot itself is never dropped
/// for a failure: the last good one stays up, marked stale.
#[derive(Debug, Clone, Default)]
pub struct Freshness {
    /// When the snapshot on screen was received.
    pub received_at: Option<DateTime<Utc>>,
    /// The latest attempt failed or timed out, and why.
    pub error: Option<(DateTime<Utc>, String)>,
}

pub struct App {
    pub snapshot: Option<Snapshot>,
    /// When the collector run behind `snapshot` started, and its kind. See
    /// [`App::superseded`] for which results replace it.
    pub snapshot_started: Option<Instant>,
    snapshot_mode: Option<Mode>,
    pub freshness: Freshness,
    pub view: View,
    /// The repo view's last repo, so `a` toggles back to it.
    pub last_repo: Option<String>,
    pub selected: usize,
    /// Selection identity, kept across refreshes that reorder the lists.
    selected_key: Option<String>,
    pub overview_selected: usize,
    /// Overview selection identity, as `selected_key` is the repo view's.
    overview_key: Option<String>,
    /// `!`: the overview shows only the agents that need you.
    pub needs_you: bool,
    /// The expanded item's scroll offset, when one is expanded.
    pub detail: Option<u16>,
    pub flash: Option<(DateTime<Utc>, String)>,
}

impl App {
    /// `in_repo`: started inside a repo, so open on its view (the current
    /// repo is the snapshot's first). Otherwise open on the overview.
    pub fn new(in_repo: bool) -> Self {
        App {
            snapshot: None,
            snapshot_started: None,
            snapshot_mode: None,
            freshness: Freshness::default(),
            view: if in_repo {
                View::Repo(String::new())
            } else {
                View::Overview
            },
            last_repo: None,
            selected: 0,
            selected_key: None,
            overview_selected: 0,
            overview_key: None,
            needs_you: false,
            detail: None,
            flash: None,
        }
    }

    /// Whether the outcome of a `mode` run that started at `started` is
    /// older news than the snapshot on screen. A run that started later
    /// wins, except that a full run is never superseded by a local one: a
    /// local run cannot ask the forge, so its PR state is only the cache
    /// the full run is about to refresh. With heartbeats rewriting session
    /// files all the time, a local run landing mid-full-run is the normal
    /// case, and a plain start-time rule would drop every full result.
    fn superseded(&self, started: Instant, mode: Mode) -> bool {
        let Some(shown) = self.snapshot_started else {
            return false;
        };
        shown > started && !(mode == Mode::Full && self.snapshot_mode == Some(Mode::Local))
    }

    /// Take a run's snapshot unless it is superseded.
    pub fn offer(
        &mut self,
        started: Instant,
        mode: Mode,
        snap: Snapshot,
        now: DateTime<Utc>,
    ) -> Offer {
        if self.superseded(started, mode) {
            return Offer::Rejected;
        }
        // A full run older than the local data it replaces read disk before
        // that local run did: right for the forge, behind on disk.
        let behind = self.snapshot_started.is_some_and(|shown| shown > started);
        self.snapshot = Some(snap);
        self.snapshot_started = Some(started);
        self.snapshot_mode = Some(mode);
        self.freshness.received_at = Some(now);
        self.freshness.error = None;
        // The empty name means "the current repo", fixed on the first snapshot.
        if self.view == View::Repo(String::new()) {
            let first = self.repos().first().and_then(|r| r.name.clone());
            self.view = first.map(View::Repo).unwrap_or(View::Overview);
        }
        self.reselect();
        if behind {
            Offer::TakenNeedsLocal
        } else {
            Offer::Taken
        }
    }

    /// Mark the screen stale for a failed run, unless the screen already
    /// shows something newer than that run could have.
    pub fn failed(&mut self, started: Instant, mode: Mode, now: DateTime<Utc>, why: String) {
        if !self.superseded(started, mode) {
            self.freshness.error = Some((now, why));
        }
    }

    pub fn repos(&self) -> &[Repo] {
        self.snapshot
            .as_ref()
            .map(|s| s.repos.as_slice())
            .unwrap_or(&[])
    }

    pub fn current_repo(&self) -> Option<&Repo> {
        match &self.view {
            View::Repo(name) => self
                .repos()
                .iter()
                .find(|r| r.name.as_deref() == Some(name)),
            View::Overview => None,
        }
    }

    pub fn overview_rows(&self) -> Vec<OvRow> {
        overview_rows(self.repos(), self.needs_you)
    }

    pub fn selected_overview_row(&self) -> Option<OvRow> {
        self.overview_rows().get(self.overview_selected).copied()
    }

    fn overview_row_key(&self, row: OvRow) -> String {
        let repos = self.repos();
        let name = repos[row.repo()].name.as_deref().unwrap_or("");
        let slug = |i: usize| repos[row.repo()].in_flight[i].slug.as_deref().unwrap_or("");
        match row {
            OvRow::Repo(_) => format!("r:{name}"),
            OvRow::Pm(_) => format!("p:{name}"),
            OvRow::Worker(_, i) => format!("w:{name}:{}", slug(i)),
            OvRow::Reviewer(_, i, k) => format!(
                "v:{name}:{}:{}",
                slug(i),
                repos[row.repo()].in_flight[i].reviewers[k]
                    .role
                    .as_deref()
                    .unwrap_or("")
            ),
        }
    }

    fn remember_overview_selection(&mut self) {
        self.overview_key = self
            .selected_overview_row()
            .map(|row| self.overview_row_key(row));
    }

    /// Select the overview row `key` names, if it is on screen.
    fn select_overview(&mut self, key: &str) -> bool {
        let rows = self.overview_rows();
        match rows
            .iter()
            .position(|&row| self.overview_row_key(row) == key)
        {
            Some(i) => {
                self.overview_selected = i;
                self.overview_key = Some(key.to_string());
                true
            }
            None => false,
        }
    }

    pub fn selected_row(&self) -> Option<Row> {
        self.current_repo()
            .and_then(|r| rows(r).get(self.selected).copied())
    }

    fn row_key(repo: &Repo, row: Row) -> String {
        match row {
            Row::InFlight(i) => format!("f:{}", repo.in_flight[i].slug.as_deref().unwrap_or("")),
            Row::Next(i) => format!(
                "n:{}",
                repo.next.items[i].reference.as_deref().unwrap_or("")
            ),
            Row::Done(i) => format!(
                "d:{}",
                repo.done.items[i]
                    .pr
                    .as_ref()
                    .and_then(|p| p.number)
                    .unwrap_or(0)
            ),
        }
    }

    fn remember_selection(&mut self) {
        self.selected_key = self
            .current_repo()
            .and_then(|r| rows(r).get(self.selected).map(|&row| Self::row_key(r, row)));
    }

    /// After a refresh, follow the selected item to its new position, or
    /// stay at the same index when it is gone.
    fn reselect(&mut self) {
        if !self
            .overview_key
            .clone()
            .is_some_and(|k| self.select_overview(&k))
        {
            let n = self.overview_rows().len();
            self.overview_selected = self.overview_selected.min(n.saturating_sub(1));
            self.remember_overview_selection();
        }
        let Some(repo) = self.current_repo() else {
            return;
        };
        let rs = rows(repo);
        if let Some(key) = &self.selected_key {
            if let Some(i) = rs.iter().position(|&row| &Self::row_key(repo, row) == key) {
                self.selected = i;
                return;
            }
        }
        self.selected = self.selected.min(rs.len().saturating_sub(1));
        if rs.is_empty() {
            self.detail = None;
        }
        self.remember_selection();
    }

    pub fn flash(&mut self, now: DateTime<Utc>, msg: impl Into<String>) {
        self.flash = Some((now, msg.into()));
    }

    pub fn key(&mut self, key: Key, now: DateTime<Utc>) -> Option<Action> {
        if key == Key::Quit || key == Key::Char('q') {
            return Some(Action::Quit);
        }
        if let Some(scroll) = self.detail {
            return self.detail_key(key, scroll, now);
        }
        match self.view {
            View::Overview => self.overview_key(key, now),
            View::Repo(_) => self.repo_key(key, now),
        }
    }

    fn detail_key(&mut self, key: Key, scroll: u16, now: DateTime<Utc>) -> Option<Action> {
        match key {
            Key::Up | Key::Char('k') => self.detail = Some(scroll.saturating_sub(1)),
            Key::Down | Key::Char('j') => self.detail = Some(scroll.saturating_add(1)),
            Key::PageUp => self.detail = Some(scroll.saturating_sub(10)),
            Key::PageDown | Key::Char(' ') => self.detail = Some(scroll.saturating_add(10)),
            Key::Enter | Key::Esc => self.detail = None,
            Key::Char('o') | Key::Char('t') => return self.repo_key(key, now),
            Key::Char('a') => {
                self.detail = None;
                return self.repo_key(key, now);
            }
            _ => {}
        }
        None
    }

    fn overview_key(&mut self, key: Key, now: DateTime<Utc>) -> Option<Action> {
        let n = self.overview_rows().len();
        match key {
            Key::Up | Key::Char('k') => {
                self.overview_selected = self.overview_selected.saturating_sub(1);
                self.remember_overview_selection();
            }
            Key::Down | Key::Char('j') => {
                self.overview_selected = (self.overview_selected + 1).min(n.saturating_sub(1));
                self.remember_overview_selection();
            }
            Key::Enter => {
                let row = self.selected_overview_row()?;
                let repo = &self.repos()[row.repo()];
                let name = repo.name.clone()?;
                // An agent row opens its repo on that agent's item.
                let item = match row {
                    OvRow::Worker(_, i) | OvRow::Reviewer(_, i, _) => Some(i),
                    _ => None,
                };
                let key = item.map(|i| Self::row_key(repo, Row::InFlight(i)));
                self.enter_repo(name);
                if let (Some(key), Some(i)) = (key, item) {
                    self.selected = i;
                    self.selected_key = Some(key);
                    self.reselect();
                }
            }
            Key::Char('a') | Key::Esc => {
                if let Some(name) = self.last_repo.clone() {
                    self.enter_repo(name);
                }
            }
            Key::Char('!') => {
                // Stay on the same row when it is still shown, else on its
                // repo, else at the top.
                let row = self.overview_key.clone();
                let repo = self
                    .selected_overview_row()
                    .and_then(|r| self.repos()[r.repo()].name.clone())
                    .map(|name| format!("r:{name}"));
                self.needs_you = !self.needs_you;
                let kept = row.is_some_and(|k| self.select_overview(&k))
                    || repo.is_some_and(|k| self.select_overview(&k));
                if !kept {
                    self.overview_selected = 0;
                    self.remember_overview_selection();
                }
            }
            Key::Char('t') => {
                let row = self.selected_overview_row()?;
                let repo = &self.repos()[row.repo()];
                return Some(match row {
                    OvRow::Repo(_) | OvRow::Pm(_) => pm_tab(repo).unwrap_or_else(no_pm),
                    OvRow::Worker(_, i) => worker_tab(&repo.in_flight[i]),
                    OvRow::Reviewer(_, i, k) => {
                        let item = &repo.in_flight[i];
                        let rev = &item.reviewers[k];
                        let session = rev.session.as_ref();
                        let pr = rev.pr.or_else(|| item.pr.as_ref().and_then(|p| p.number));
                        Action::GotoTab {
                            tab_id: session.and_then(|s| s.tab_id.clone()),
                            // task-reviewer's tab slug.
                            name: pr.map(|n| format!("review-pr{n}")).unwrap_or_default(),
                            session: session.and_then(|s| s.zellij_session.clone()),
                        }
                    }
                });
            }
            Key::Char('o') => self.flash(now, "o opens an item's PR or issue: ⏎ into a repo first"),
            _ => {}
        }
        None
    }

    fn enter_repo(&mut self, name: String) {
        if self.last_repo.as_ref() != Some(&name) {
            self.selected = 0;
            self.selected_key = None;
        }
        self.view = View::Repo(name);
        self.detail = None;
        self.reselect();
    }

    fn repo_key(&mut self, key: Key, now: DateTime<Utc>) -> Option<Action> {
        let n = self.current_repo().map(|r| rows(r).len()).unwrap_or(0);
        match key {
            Key::Up | Key::Char('k') => {
                self.selected = self.selected.saturating_sub(1);
                self.remember_selection();
            }
            Key::Down | Key::Char('j') => {
                self.selected = (self.selected + 1).min(n.saturating_sub(1));
                self.remember_selection();
            }
            Key::Enter => {
                if self.selected_row().is_some() {
                    self.detail = Some(0);
                }
            }
            Key::Char('a') => {
                if let View::Repo(name) = &self.view {
                    self.last_repo = Some(name.clone());
                }
                self.view = View::Overview;
                self.detail = None;
                if let Some(name) = self.last_repo.clone() {
                    self.select_overview(&format!("r:{name}"));
                }
            }
            Key::Char('o') => {
                let url = self.selected_url();
                match url {
                    Some(u) => return Some(Action::Open(u)),
                    None => self.flash(now, "this item has no URL"),
                }
            }
            Key::Char('t') => {
                let (repo, row) = (self.current_repo()?, self.selected_row());
                return Some(match row {
                    Some(Row::InFlight(i)) => worker_tab(&repo.in_flight[i]),
                    // Queued and merged items have no worker; their tab is the PM's.
                    _ => pm_tab(repo).unwrap_or_else(no_pm),
                });
            }
            _ => {}
        }
        None
    }

    /// What `o` opens: an in-flight item's PR once it has one, else the item.
    pub fn selected_url(&self) -> Option<String> {
        let repo = self.current_repo()?;
        match self.selected_row()? {
            Row::InFlight(i) => {
                let item = &repo.in_flight[i];
                item.pr
                    .as_ref()
                    .and_then(|p| p.url.clone())
                    .or_else(|| item.url.clone())
            }
            Row::Next(i) => repo.next.items[i].url.clone(),
            Row::Done(i) => {
                let item = &repo.done.items[i];
                item.url
                    .clone()
                    .or_else(|| item.pr.as_ref().and_then(|p| p.url.clone()))
            }
        }
    }
}

fn worker_tab(item: &InFlight) -> Action {
    let session = item.session.as_ref();
    Action::GotoTab {
        // The sidecar's id first, as task-done reads it.
        tab_id: item
            .tab_id
            .clone()
            .or_else(|| session.and_then(|s| s.tab_id.clone())),
        name: item.slug.clone().unwrap_or_default(),
        session: session.and_then(|s| s.zellij_session.clone()),
    }
}

/// No PM session: say so rather than doing nothing.
fn no_pm() -> Action {
    Action::GotoTab {
        tab_id: None,
        name: String::new(),
        session: None,
    }
}

fn pm_tab(repo: &Repo) -> Option<Action> {
    let role = repo.pm.role.clone()?;
    Some(Action::GotoTab {
        tab_id: repo.pm.tab_id.clone(),
        name: role,
        session: repo.pm.zellij_session.clone(),
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::snapshot::parse;

    fn now() -> DateTime<Utc> {
        "2026-10-20T15:00:00Z".parse().unwrap()
    }

    fn app_with(json: &str, in_repo: bool) -> App {
        let mut app = App::new(in_repo);
        app.offer(Instant::now(), Mode::Full, parse(json).unwrap(), now());
        app
    }

    pub(crate) const MULTI: &str = include_str!("../tests/fixtures/multi.json");

    #[test]
    fn opens_on_the_current_repo_inside_one_and_on_the_overview_outside() {
        assert_eq!(app_with(MULTI, true).view, View::Repo("task-force".into()));
        assert_eq!(app_with(MULTI, false).view, View::Overview);
    }

    #[test]
    fn arrows_move_across_sections_and_stop_at_the_ends() {
        let mut app = app_with(MULTI, true);
        let total = rows(app.current_repo().unwrap()).len();
        app.key(Key::Up, now());
        assert_eq!(app.selected, 0);
        for _ in 0..total + 3 {
            app.key(Key::Down, now());
        }
        assert_eq!(app.selected, total - 1);
        assert!(matches!(app.selected_row(), Some(Row::Done(_))));
    }

    #[test]
    fn enter_expands_and_scrolls_then_esc_collapses() {
        let mut app = app_with(MULTI, true);
        app.key(Key::Enter, now());
        assert_eq!(app.detail, Some(0));
        app.key(Key::Down, now());
        app.key(Key::PageDown, now());
        assert_eq!(app.detail, Some(11));
        assert_eq!(
            app.selected, 0,
            "scrolling the body does not move the selection"
        );
        app.key(Key::Esc, now());
        assert_eq!(app.detail, None);
    }

    #[test]
    fn o_opens_the_pr_once_there_is_one_else_the_issue() {
        let mut app = app_with(MULTI, true);
        assert_eq!(
            app.key(Key::Char('o'), now()),
            Some(Action::Open(
                "https://github.com/o/task-force/pull/270".into()
            ))
        );
        app.key(Key::Down, now());
        assert_eq!(
            app.key(Key::Char('o'), now()),
            Some(Action::Open(
                "https://github.com/o/task-force/issues/262".into()
            ))
        );
    }

    #[test]
    fn o_without_a_url_flashes_instead_of_acting() {
        let mut app = app_with(MULTI, true);
        app.view = View::Repo("jira-repo".into());
        app.selected = 0;
        assert_eq!(app.key(Key::Char('o'), now()), None);
        assert!(app.flash.as_ref().unwrap().1.contains("no URL"));
    }

    #[test]
    fn t_targets_the_worker_tab_by_sidecar_id_and_slug() {
        let mut app = app_with(MULTI, true);
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("4".into()),
                name: "kiro-config".into(),
                session: Some("task-force".into())
            })
        );
        // A worker with no sidecar id falls back to its session's.
        app.key(Key::Down, now());
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("7".into()),
                name: "home-env".into(),
                session: Some("task-force".into())
            })
        );
    }

    #[test]
    fn t_on_a_queued_or_done_item_targets_the_pm_tab() {
        let mut app = app_with(MULTI, true);
        app.selected = rows(app.current_repo().unwrap()).len() - 1;
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("0".into()),
                name: "pm-task-force".into(),
                session: Some("task-force".into())
            })
        );
    }

    #[test]
    fn a_toggles_the_overview_and_back_to_the_same_repo() {
        let mut app = app_with(MULTI, true);
        app.key(Key::Down, now());
        app.key(Key::Char('a'), now());
        assert_eq!(app.view, View::Overview);
        assert_eq!(app.overview_selected, 0);
        app.key(Key::Char('a'), now());
        assert_eq!(app.view, View::Repo("task-force".into()));
        assert_eq!(app.selected, 1, "the selection survives the round trip");
    }

    /// Select an overview row, by moving to it as the user would.
    pub(crate) fn go_to(app: &mut App, row: OvRow) {
        let i = app
            .overview_rows()
            .iter()
            .position(|&r| r == row)
            .unwrap_or_else(|| panic!("{row:?} is not on screen"));
        while app.overview_selected > i {
            app.key(Key::Up, now());
        }
        while app.overview_selected < i {
            app.key(Key::Down, now());
        }
    }

    #[test]
    fn enter_on_an_overview_row_opens_that_repo() {
        let mut app = app_with(MULTI, false);
        go_to(&mut app, OvRow::Repo(1));
        app.key(Key::Enter, now());
        assert_eq!(app.view, View::Repo("recommender-systems".into()));
        assert_eq!(app.selected, 0);
        // t on a repo row is the PM's tab.
        app.key(Key::Char('a'), now());
        assert_eq!(app.selected_overview_row(), Some(OvRow::Repo(1)));
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("2".into()),
                name: "pm-recommender-systems".into(),
                session: Some("rec".into())
            })
        );
    }

    #[test]
    fn the_overview_lists_each_repos_agents_under_it() {
        let app = app_with(MULTI, false);
        use OvRow::*;
        assert_eq!(
            app.overview_rows(),
            vec![
                Repo(0),
                Pm(0),
                Worker(0, 0),
                Reviewer(0, 0, 0),
                Worker(0, 1),
                Repo(1),
                Pm(1),
                Worker(1, 0),
                Repo(2),
                Pm(2),
                Worker(2, 0),
                Repo(3),
                Pm(3),
            ]
        );
    }

    #[test]
    fn the_agent_behind_each_signal_is_the_one_that_needs_you() {
        let app = app_with(MULTI, false);
        let repos = app.repos();
        // Unread mail and a review waiting merge: the PM.
        assert!(pm_needs_you(&repos[0]));
        // An awaiting worker: that worker, and not the PM or its siblings.
        assert!(!pm_needs_you(&repos[1]));
        assert!(worker_needs_you(&repos[1], &repos[1].in_flight[0]));
        assert!(worker_needs_you(&repos[0], &repos[0].in_flight[1]));
        assert!(!worker_needs_you(&repos[0], &repos[0].in_flight[0]));
        assert!(!pm_needs_you(&repos[2]) && !pm_needs_you(&repos[3]));
        // Each PM signal marks it on its own.
        for kind in ["unread-inbox", "review-waiting-merge"] {
            let mut repo = repos[0].clone();
            repo.attention
                .signals
                .retain(|s| s.kind.as_deref() == Some(kind));
            assert!(pm_needs_you(&repo), "{kind}");
        }
    }

    #[test]
    fn the_signal_not_the_session_state_marks_a_worker() {
        // `awaiting` with no signal is what a crashed tab leaves behind.
        let mut snap = parse(MULTI).unwrap();
        snap.repos[0]
            .attention
            .signals
            .retain(|s| s.kind.as_deref() != Some("worker-awaiting"));
        assert!(!worker_needs_you(
            &snap.repos[0],
            &snap.repos[0].in_flight[1]
        ));
        // By role alone, or by slug alone, the signal still finds it.
        let rec = &mut snap.repos[1];
        rec.attention.signals[0].workers[0].slug = None;
        assert!(worker_needs_you(rec, &rec.in_flight[0]));
        rec.attention.signals[0].workers[0].slug = Some("rerank-sasrec-gate".into());
        let rec = &mut snap.repos[1];
        rec.attention.signals[0].workers[0].role = None;
        assert!(worker_needs_you(rec, &rec.in_flight[0]));
        rec.attention.signals[0].workers[0].slug = Some("someone-else".into());
        assert!(!worker_needs_you(rec, &rec.in_flight[0]));
    }

    #[test]
    fn bang_keeps_only_what_needs_you_under_its_repo_and_toggles_back() {
        let mut app = app_with(MULTI, false);
        go_to(&mut app, OvRow::Worker(1, 0));
        app.key(Key::Char('!'), now());
        assert!(app.needs_you);
        use OvRow::*;
        assert_eq!(
            app.overview_rows(),
            vec![Repo(0), Pm(0), Worker(0, 1), Repo(1), Worker(1, 0)]
        );
        assert_eq!(
            app.selected_overview_row(),
            Some(Worker(1, 0)),
            "the selected agent stays selected"
        );
        app.key(Key::Char('!'), now());
        assert!(!app.needs_you);
        assert_eq!(app.selected_overview_row(), Some(Worker(1, 0)));
        // An agent the filter hides falls back to its repo's row.
        go_to(&mut app, Reviewer(0, 0, 0));
        app.key(Key::Char('!'), now());
        assert_eq!(app.selected_overview_row(), Some(Repo(0)));
        // A repo with nothing for you is dropped altogether.
        app.key(Key::Char('!'), now());
        go_to(&mut app, Pm(3));
        app.key(Key::Char('!'), now());
        assert_eq!(app.selected_overview_row(), Some(Repo(0)));
    }

    #[test]
    fn t_on_an_agent_row_targets_that_agents_tab() {
        let mut app = app_with(MULTI, false);
        let pm = Some(Action::GotoTab {
            tab_id: Some("0".into()),
            name: "pm-task-force".into(),
            session: Some("task-force".into()),
        });
        assert_eq!(app.key(Key::Char('t'), now()), pm, "the repo row: its PM");
        go_to(&mut app, OvRow::Pm(0));
        assert_eq!(app.key(Key::Char('t'), now()), pm);
        // A worker: the sidecar's id and the slug, as in the repo view.
        go_to(&mut app, OvRow::Worker(0, 0));
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("4".into()),
                name: "kiro-config".into(),
                session: Some("task-force".into())
            })
        );
        // A reviewer: its session's id and task-reviewer's tab slug.
        go_to(&mut app, OvRow::Reviewer(0, 0, 0));
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("8".into()),
                name: "review-pr270".into(),
                session: Some("task-force".into())
            })
        );
        // Another repo's worker names its own zellij session.
        go_to(&mut app, OvRow::Worker(1, 0));
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: Some("3".into()),
                name: "rerank-sasrec-gate".into(),
                session: Some("rec".into())
            })
        );
        // No session at all: an empty target, which goto_tab explains.
        go_to(&mut app, OvRow::Pm(2));
        assert_eq!(
            app.key(Key::Char('t'), now()),
            Some(Action::GotoTab {
                tab_id: None,
                name: "pm-jira-repo".into(),
                session: None
            })
        );
    }

    #[test]
    fn enter_on_an_agent_row_opens_its_repo_on_that_item() {
        let mut app = app_with(MULTI, false);
        go_to(&mut app, OvRow::Worker(0, 1));
        app.key(Key::Enter, now());
        assert_eq!(app.view, View::Repo("task-force".into()));
        assert_eq!(app.selected_row(), Some(Row::InFlight(1)));
        app.key(Key::Char('a'), now());
        go_to(&mut app, OvRow::Reviewer(0, 0, 0));
        app.key(Key::Enter, now());
        assert_eq!(app.selected_row(), Some(Row::InFlight(0)));
        // The PM row opens the repo at the top.
        app.key(Key::Char('a'), now());
        go_to(&mut app, OvRow::Pm(1));
        app.key(Key::Enter, now());
        assert_eq!(app.view, View::Repo("recommender-systems".into()));
        assert_eq!(app.selected, 0);
    }

    #[test]
    fn a_refresh_keeps_the_selected_agent_when_repos_reorder() {
        let mut app = app_with(MULTI, false);
        go_to(&mut app, OvRow::Worker(1, 0));
        let mut snap = parse(MULTI).unwrap();
        snap.repos.reverse();
        app.offer(Instant::now(), Mode::Local, snap, now());
        assert_eq!(app.selected_overview_row(), Some(OvRow::Worker(2, 0)));
    }

    #[test]
    fn q_quits_from_every_screen() {
        let mut app = app_with(MULTI, true);
        assert_eq!(app.key(Key::Char('q'), now()), Some(Action::Quit));
        app.key(Key::Enter, now());
        assert_eq!(app.key(Key::Char('q'), now()), Some(Action::Quit));
        app.key(Key::Char('a'), now());
        assert_eq!(app.key(Key::Quit, now()), Some(Action::Quit));
    }

    #[test]
    fn a_refresh_keeps_the_selected_item_when_the_list_reorders() {
        let mut app = app_with(MULTI, true);
        app.key(Key::Down, now()); // home-env
        let mut snap = parse(MULTI).unwrap();
        snap.repos[0].in_flight.reverse();
        app.offer(Instant::now(), Mode::Local, snap, now());
        let repo = app.current_repo().unwrap();
        let Some(Row::InFlight(i)) = app.selected_row() else {
            panic!()
        };
        assert_eq!(repo.in_flight[i].slug.as_deref(), Some("home-env"));
    }

    fn empty() -> Snapshot {
        parse(r#"{"schema":1,"repos":[]}"#).unwrap()
    }

    #[test]
    fn a_run_that_started_earlier_never_replaces_a_later_one_of_its_kind() {
        let early = Instant::now();
        let late = early + std::time::Duration::from_millis(5);
        for mode in [Mode::Local, Mode::Full] {
            let mut app = App::new(true);
            assert_eq!(
                app.offer(late, mode, parse(MULTI).unwrap(), now()),
                Offer::Taken
            );
            assert_eq!(app.offer(early, mode, empty(), now()), Offer::Rejected);
            assert_eq!(app.repos().len(), 4);
        }
        // Nor does an older local run replace a newer full one.
        let mut app = App::new(true);
        app.offer(late, Mode::Full, parse(MULTI).unwrap(), now());
        assert_eq!(
            app.offer(early, Mode::Local, empty(), now()),
            Offer::Rejected
        );
    }

    #[test]
    fn a_local_run_landing_during_a_full_one_does_not_drop_the_full_result() {
        let full_start = Instant::now();
        let local_start = full_start + std::time::Duration::from_secs(5);
        let mut app = App::new(true);
        // The local run started after the full one and finished first.
        assert_eq!(
            app.offer(local_start, Mode::Local, empty(), now()),
            Offer::Taken
        );
        let mut full = parse(MULTI).unwrap();
        full.mode = Some("full".into());
        assert_eq!(
            app.offer(full_start, Mode::Full, full, now()),
            Offer::TakenNeedsLocal
        );
        assert_eq!(app.snapshot.as_ref().unwrap().mode.as_deref(), Some("full"));
        // The rerun it asks for starts later still, and replaces it.
        let rerun = local_start + std::time::Duration::from_secs(1);
        assert_eq!(
            app.offer(rerun, Mode::Local, parse(MULTI).unwrap(), now()),
            Offer::Taken
        );
    }

    #[test]
    fn a_failure_older_than_the_screen_does_not_mark_it_stale() {
        let early = Instant::now();
        let late = early + std::time::Duration::from_millis(5);
        let mut app = App::new(true);
        app.offer(late, Mode::Local, parse(MULTI).unwrap(), now());
        app.failed(early, Mode::Local, now(), "old local run timed out".into());
        assert!(app.freshness.error.is_none());
        app.failed(
            late + std::time::Duration::from_millis(1),
            Mode::Local,
            now(),
            "new".into(),
        );
        assert!(app.freshness.error.is_some());
        // A full run's failure still counts against local data: the forge
        // state on screen is what failed to refresh.
        let mut app = App::new(true);
        app.offer(late, Mode::Local, parse(MULTI).unwrap(), now());
        app.failed(early, Mode::Full, now(), "gh timed out".into());
        assert!(app.freshness.error.is_some());
    }

    #[test]
    fn a_failure_keeps_the_last_good_snapshot() {
        let mut app = app_with(MULTI, true);
        app.failed(Instant::now(), Mode::Full, now(), "timed out".into());
        assert_eq!(app.repos().len(), 4);
        assert!(app.freshness.error.is_some());
        app.offer(Instant::now(), Mode::Local, parse(MULTI).unwrap(), now());
        assert!(app.freshness.error.is_none());
    }
}
