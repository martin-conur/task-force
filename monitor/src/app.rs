//! Screen state and key handling. Pure: a key press changes the state and
//! may return an [`Action`] for main to carry out (open a URL, go to a tab),
//! so every key is testable without a terminal, a browser or zellij.

use std::time::Instant;

use chrono::{DateTime, Utc};

use crate::refresh::Mode;
use crate::snapshot::{Repo, Snapshot};

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
        let n_repos = self.repos().len();
        self.overview_selected = self.overview_selected.min(n_repos.saturating_sub(1));
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
        let n = self.repos().len();
        match key {
            Key::Up | Key::Char('k') => {
                self.overview_selected = self.overview_selected.saturating_sub(1)
            }
            Key::Down | Key::Char('j') => {
                self.overview_selected = (self.overview_selected + 1).min(n.saturating_sub(1))
            }
            Key::Enter => {
                if let Some(name) = self
                    .repos()
                    .get(self.overview_selected)
                    .and_then(|r| r.name.clone())
                {
                    self.enter_repo(name);
                }
            }
            Key::Char('a') | Key::Esc => {
                if let Some(name) = self.last_repo.clone() {
                    self.enter_repo(name);
                }
            }
            Key::Char('t') => {
                let repo = self.repos().get(self.overview_selected)?;
                return Some(pm_tab(repo).unwrap_or_else(|| {
                    // No PM session: say so rather than doing nothing.
                    Action::GotoTab {
                        tab_id: None,
                        name: String::new(),
                        session: None,
                    }
                }));
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
                if let Some(i) = self.last_repo.as_ref().and_then(|name| {
                    self.repos()
                        .iter()
                        .position(|r| r.name.as_ref() == Some(name))
                }) {
                    self.overview_selected = i;
                }
                self.view = View::Overview;
                self.detail = None;
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
                    Some(Row::InFlight(i)) => {
                        let item = &repo.in_flight[i];
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
                    // Queued and merged items have no worker; their tab is the PM's.
                    _ => pm_tab(repo).unwrap_or(Action::GotoTab {
                        tab_id: None,
                        name: String::new(),
                        session: None,
                    }),
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

fn pm_tab(repo: &Repo) -> Option<Action> {
    let role = repo.pm.role.clone()?;
    Some(Action::GotoTab {
        tab_id: repo.pm.tab_id.clone(),
        name: role,
        session: repo.pm.zellij_session.clone(),
    })
}

#[cfg(test)]
mod tests {
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

    #[test]
    fn enter_on_an_overview_row_opens_that_repo() {
        let mut app = app_with(MULTI, false);
        app.key(Key::Down, now());
        app.key(Key::Enter, now());
        assert_eq!(app.view, View::Repo("recommender-systems".into()));
        assert_eq!(app.selected, 0);
        // t on an overview row is the PM's tab.
        app.key(Key::Char('a'), now());
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
