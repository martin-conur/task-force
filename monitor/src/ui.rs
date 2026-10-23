//! Rendering. Every word on screen is a snapshot field or a fixed label: the
//! words for a status are a lookup of the collector's `status` value, and an
//! unknown value is shown as it came rather than guessed at.

use chrono::{DateTime, Local, Utc};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::app::{pm_needs_you, rows, worker_needs_you, App, OvRow, Row, View};
use crate::snapshot::{DoneItem, InFlight, NextItem, Repo};

/// How long a flash message stays in the footer.
const FLASH_SECS: i64 = 6;

fn dim() -> Style {
    Style::default().fg(Color::DarkGray)
}
fn bold() -> Style {
    Style::default().add_modifier(Modifier::BOLD)
}

pub fn draw(f: &mut Frame, app: &mut App, now: DateTime<Utc>) {
    let area = f.area();
    let [header, rule1, body, rule2, status, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(area);
    let w = area.width as usize;

    let (title, keys) = match (&app.view, app.detail.is_some()) {
        (View::Overview, _) => (
            Line::from(Span::styled(
                if app.needs_you {
                    " task-monitor · all repos · needs you"
                } else {
                    " task-monitor · all repos"
                },
                bold(),
            )),
            if app.needs_you {
                " ↑↓ move  ⏎ open repo  t jump to tab  ! every agent  a back  q quit"
            } else {
                " ↑↓ move  ⏎ open repo  t jump to tab  ! needs you  a back  q quit"
            },
        ),
        (View::Repo(_), detail) => (
            repo_title(app.current_repo()),
            if detail {
                " ↑↓ scroll  ⏎/esc close  o open PR/issue  t jump to tab  q quit"
            } else {
                " ↑↓ move  ⏎ expand  o open PR/issue  t jump to tab  a all repos  q quit"
            },
        ),
    };
    let fresh = freshness(app, now);
    f.render_widget(Paragraph::new(fit(title, fresh, w)), header);
    f.render_widget(Paragraph::new(rule(w)), rule1);
    f.render_widget(Paragraph::new(rule(w)), rule2);

    let status_line = match (&app.flash, &app.freshness.error) {
        (Some((at, msg)), _) if (now - *at).num_seconds() < FLASH_SECS => Line::from(Span::styled(
            format!(" {msg}"),
            Style::default().fg(Color::Yellow),
        )),
        (_, Some((_, why))) => Line::from(Span::styled(
            format!(" snapshot failed: {why}"),
            Style::default().fg(Color::Red),
        )),
        _ => Line::default(),
    };
    f.render_widget(Paragraph::new(truncate_line(status_line, w)), status);
    f.render_widget(Paragraph::new(Span::styled(keys, dim())), footer);

    if app.snapshot.is_none() {
        let msg = match &app.freshness.error {
            Some(_) => " no snapshot yet",
            None => " loading the first snapshot…",
        };
        f.render_widget(Paragraph::new(Span::styled(msg, dim())), body);
        return;
    }
    match (&app.view, app.detail) {
        (View::Overview, _) => overview(f, app, body),
        (View::Repo(name), detail) => match app.current_repo() {
            None => {
                let msg = format!(" {name} is not in the latest snapshot · a for all repos");
                f.render_widget(Paragraph::new(Span::styled(msg, dim())), body);
            }
            Some(_) if detail.is_some() => detail_view(f, app, body, now),
            Some(repo) => repo_view(f, repo, app.selected, body, now),
        },
    }
}

fn repo_title(repo: Option<&Repo>) -> Line<'static> {
    let Some(repo) = repo else {
        return Line::from(" task-monitor");
    };
    let mut spans = vec![Span::styled(
        format!(" {}", repo.name.as_deref().unwrap_or("?")),
        bold(),
    )];
    let pm = &repo.pm;
    let pm_text = match (&pm.alias_of, pm.state.as_ref(), &pm.agent) {
        (Some(primary), _, _) => format!("PM via {primary}"),
        (None, None, _) => "no PM".to_string(),
        (None, Some(_), agent) => format!(
            "PM {}",
            agent.as_deref().or(repo.agent.as_deref()).unwrap_or("")
        ),
    };
    spans.push(Span::raw(format!(" · {}", pm_text.trim_end())));
    if pm.unread > 0 {
        spans.push(Span::raw(" · "));
        spans.push(Span::styled(
            format!("✉ {} unread", pm.unread),
            Style::default().fg(Color::Yellow),
        ));
    }
    Line::from(spans)
}

/// The header's right side: the clock, then `live`, or what is stale and
/// for how long.
fn freshness(app: &App, now: DateTime<Utc>) -> Line<'static> {
    let clock = now.with_timezone(&Local).format("%H:%M").to_string();
    let (text, style) = if app.snapshot.is_none() {
        ("loading".to_string(), dim())
    } else if app.freshness.error.is_some() {
        let age = app
            .freshness
            .received_at
            .map(|t| ago(t, now))
            .unwrap_or_default();
        (format!("stale {age}"), Style::default().fg(Color::Red))
    } else if let Some(fetched) = forge_stale_since(app) {
        (
            format!(
                "forge {}",
                fetched
                    .map(|t| ago(t, now))
                    .unwrap_or_else(|| "stale".into())
            ),
            Style::default().fg(Color::Yellow),
        )
    } else {
        ("live".to_string(), Style::default().fg(Color::Green))
    };
    Line::from(vec![
        Span::raw(format!("{clock} · ")),
        Span::styled(text, style),
        Span::raw(" "),
    ])
}

/// The forge state on screen is older than this run, for the repos shown:
/// `Some(fetched_at)` when stale. A repo with no forge is never stale.
fn forge_stale_since(app: &App) -> Option<Option<DateTime<Utc>>> {
    let shown: Vec<&Repo> = match app.current_repo() {
        Some(r) => vec![r],
        None => app.repos().iter().collect(),
    };
    let stale: Vec<&Repo> = shown
        .into_iter()
        .filter(|r| r.forge.available && r.forge.stale)
        .collect();
    if stale.is_empty() {
        return None;
    }
    Some(
        stale
            .iter()
            .filter_map(|r| r.forge.fetched_at.as_deref().and_then(parse_time))
            .min(),
    )
}

fn overview(f: &mut Frame, app: &App, area: Rect) {
    let w = area.width as usize;
    let repos = app.repos();
    let name_w = repos
        .iter()
        .map(|r| r.name.as_deref().unwrap_or("?").width())
        .max()
        .unwrap_or(0);
    let mut lines = Vec::new();
    for (i, row) in app.overview_rows().into_iter().enumerate() {
        let selected = i == app.overview_selected;
        let repo = &repos[row.repo()];
        lines.push(match row {
            OvRow::Repo(_) => repo_line(repo, selected, name_w, w),
            OvRow::Pm(_) => pm_line(repo, selected, w),
            OvRow::Worker(_, j) => worker_line(repo, &repo.in_flight[j], selected, w),
            OvRow::Reviewer(_, j, k) => reviewer_line(repo, &repo.in_flight[j], k, selected, w),
        });
    }
    if lines.is_empty() {
        let msg = if app.needs_you && !repos.is_empty() {
            " nothing needs you · ! shows every agent"
        } else {
            " no repos: no radio session names one, and this is not a repo"
        };
        lines.push(Line::from(Span::styled(msg, dim())));
    }
    let offset = scroll_to(
        app.overview_selected,
        app.overview_selected + 1,
        area.height as usize,
    );
    f.render_widget(Paragraph::new(lines).scroll((offset as u16, 0)), area);
}

fn repo_line(repo: &Repo, selected: bool, name_w: usize, w: usize) -> Line<'static> {
    let (dot, dot_style) = if repo.attention.active {
        ("●", Style::default().fg(Color::Yellow))
    } else {
        ("○", dim())
    };
    let name = repo.name.as_deref().unwrap_or("?");
    let signals: Vec<&str> = repo
        .attention
        .signals
        .iter()
        .filter_map(|s| s.text.as_deref())
        .collect();
    let mut left = vec![
        Span::raw(if selected { "▸" } else { " " }),
        Span::styled(format!("{dot} "), dot_style),
        Span::styled(format!("{name:<name_w$}"), title_style(selected)),
        Span::raw("  "),
        Span::raw(signals.join(" · ")),
    ];
    if signals.is_empty() {
        left.pop();
    }
    let n = repo.in_flight.len();
    let mut right = vec![Span::raw(if n == 0 {
        "idle".to_string()
    } else {
        format!("{n} in flight")
    })];
    // Rows name their zellij session: `t` there switches the client (#287).
    if let Some(session) = repo_session(repo) {
        right.push(Span::styled(format!(" · zellij {session}"), dim()));
    }
    right.push(Span::raw(" "));
    fit(Line::from(left), Line::from(right), w)
}

/// Column widths of an agent row: label, agent, state icon, state words.
const LABEL_W: usize = 10;
const AGENT_W: usize = 7;
const ICON_W: usize = 2;
const STATE_W: usize = 15;

/// One agent row: `▸    PM       claude  ⏸  idle            ✉ 1 unread   ← you`.
/// Only the title is cut on a narrow terminal; `← you` always shows.
#[allow(clippy::too_many_arguments)]
fn agent_line(
    selected: bool,
    label: &str,
    agent: &str,
    state: Option<&str>,
    words: &str,
    words_style: Style,
    title: Span<'static>,
    you: bool,
    w: usize,
) -> Line<'static> {
    let icon_style = match state {
        Some("awaiting") => Style::default().fg(Color::Yellow),
        _ => dim(),
    };
    let left = Line::from(vec![
        Span::styled(if selected { "▸    " } else { "     " }, bold()),
        Span::styled(pad(label, LABEL_W), title_style(selected)),
        Span::raw(" "),
        Span::styled(pad(agent, AGENT_W), dim()),
        Span::raw(" "),
        Span::styled(pad(state_icon(state), ICON_W), icon_style),
        Span::raw(" "),
        Span::styled(pad(words, STATE_W), words_style),
        Span::raw(" "),
        title,
    ]);
    let right = if you {
        Line::from(vec![
            Span::styled(
                "← you",
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" "),
        ])
    } else {
        Line::default()
    };
    fit(left, right, w)
}

fn pm_line(repo: &Repo, selected: bool, w: usize) -> Line<'static> {
    let pm = &repo.pm;
    let agent = pm.agent.as_deref().or(repo.agent.as_deref()).unwrap_or("?");
    let words = match (&pm.alias_of, pm.state.as_deref()) {
        (Some(primary), _) => format!("via {primary}"),
        (None, None) => "no session".to_string(),
        (None, Some(state)) => state.to_string(),
    };
    // What the PM owes you, in the signals' own words.
    let owed: Vec<&str> = repo
        .attention
        .signals
        .iter()
        .filter(|s| {
            matches!(
                s.kind.as_deref(),
                Some("unread-inbox") | Some("review-waiting-merge")
            )
        })
        .filter_map(|s| s.text.as_deref())
        .collect();
    agent_line(
        selected,
        "PM",
        agent,
        pm.state.as_deref(),
        &words,
        dim(),
        Span::styled(owed.join(" · "), Style::default().fg(Color::Yellow)),
        pm_needs_you(repo),
        w,
    )
}

fn worker_line(repo: &Repo, item: &InFlight, selected: bool, w: usize) -> Line<'static> {
    let session = item.session.as_ref();
    let agent = session
        .and_then(|s| s.agent.as_deref())
        .or(repo.agent.as_deref())
        .unwrap_or("?");
    let you = worker_needs_you(repo, item);
    let (words, style) = if you {
        ("waiting on you", Style::default().fg(Color::Yellow))
    } else {
        (
            status_words(item.status.as_deref().unwrap_or("")),
            Style::default().fg(Color::Cyan),
        )
    };
    let label = item
        .label
        .as_deref()
        .or(item.slug.as_deref())
        .unwrap_or("?");
    agent_line(
        selected,
        label,
        agent,
        session.and_then(|s| s.state.as_deref()),
        words,
        style,
        Span::styled(
            item.title.clone().unwrap_or_default(),
            title_style(selected),
        ),
        you,
        w,
    )
}

fn reviewer_line(
    repo: &Repo,
    item: &InFlight,
    k: usize,
    selected: bool,
    w: usize,
) -> Line<'static> {
    let rev = &item.reviewers[k];
    let session = rev.session.as_ref();
    let agent = session
        .and_then(|s| s.agent.as_deref())
        .or(repo.agent.as_deref())
        .unwrap_or("?");
    let state = session.and_then(|s| s.state.as_deref());
    let words = match state {
        Some("busy") => "reviewing",
        Some(other) => other,
        None => "no session",
    };
    let pr = rev
        .pr
        .or_else(|| item.pr.as_ref().and_then(|p| p.number))
        .map(|n| format!("PR #{n}"))
        .unwrap_or_default();
    agent_line(
        selected,
        "  ↳ review",
        agent,
        state,
        words,
        dim(),
        Span::styled(pr, dim()),
        false,
        w,
    )
}

/// `s` cut or padded to `w` display columns.
fn pad(s: &str, w: usize) -> String {
    let mut out = if s.width() > w {
        ellipsize(s, w.saturating_sub(1))
    } else {
        s.to_string()
    };
    out.push_str(&" ".repeat(w.saturating_sub(out.width())));
    out
}

fn repo_session(repo: &Repo) -> Option<&str> {
    repo.pm.zellij_session.as_deref().or_else(|| {
        repo.in_flight
            .iter()
            .find_map(|i| i.session.as_ref()?.zellij_session.as_deref())
    })
}

fn repo_view(f: &mut Frame, repo: &Repo, selected: usize, area: Rect, now: DateTime<Utc>) {
    let w = area.width as usize;
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut sel_span = (0, 0);
    let mut idx = 0;
    // Append one selectable row, noting where the selected one landed.
    let mut push = |lines: &mut Vec<Line<'static>>, idx: &mut usize, row: Vec<Line<'static>>| {
        if *idx == selected {
            sel_span = (lines.len(), lines.len() + row.len());
        }
        *idx += 1;
        lines.extend(row);
    };

    lines.push(section(format!("IN FLIGHT ({})", repo.in_flight.len())));
    if repo.in_flight.is_empty() {
        lines.push(empty("nothing in flight"));
    }
    for item in &repo.in_flight {
        let row = in_flight_lines(item, idx == selected, w, now);
        push(&mut lines, &mut idx, row);
    }
    lines.push(Line::from(rule(w)));

    let source = match repo.next.source.as_deref() {
        Some("queue") => "  (PM queue)".to_string(),
        Some("tracker") => "  (tracker backlog)".to_string(),
        Some("none") | None => String::new(),
        Some(other) => format!("  ({other})"),
    };
    lines.push(section(format!("NEXT{source}")));
    if repo.next.items.is_empty() {
        lines.push(empty("nothing queued"));
    }
    for (i, item) in repo.next.items.iter().enumerate() {
        let row = next_lines(i + 1, item, idx == selected, w);
        push(&mut lines, &mut idx, row);
    }
    lines.push(Line::from(rule(w)));

    let window = repo
        .done
        .window_hours
        .map(|h| format!("  (last {h}h)"))
        .unwrap_or_default();
    lines.push(section(format!("DONE{window}")));
    if repo.done.items.is_empty() {
        lines.push(empty("nothing merged recently"));
    }
    for item in &repo.done.items {
        let row = done_lines(item, idx == selected, w, now);
        push(&mut lines, &mut idx, row);
    }
    debug_assert_eq!(idx, rows(repo).len());

    let offset = scroll_to(sel_span.0, sel_span.1, area.height as usize);
    f.render_widget(Paragraph::new(lines).scroll((offset as u16, 0)), area);
}

fn section(title: String) -> Line<'static> {
    Line::from(Span::styled(format!(" {title}"), bold()))
}

fn empty(text: &str) -> Line<'static> {
    Line::from(Span::styled(format!("   {text}"), dim()))
}

fn marker(selected: bool) -> Span<'static> {
    Span::styled(if selected { " ▸ " } else { "   " }, bold())
}

fn title_style(selected: bool) -> Style {
    if selected {
        bold()
    } else {
        Style::default()
    }
}

/// The words for a collector `status` (docs/task-monitor-schema.md).
pub fn status_words(status: &str) -> &str {
    match status {
        "implementing" => "implementing",
        "pr-open" => "open",
        "under-review" => "under review",
        "changes-requested" => "changes requested",
        "re-review" => "re-review",
        "waiting-merge" => "waiting merge",
        "merged" => "merged",
        "closed" => "closed",
        other => other,
    }
}

/// `▶` / `⏸` / `❓` for a session `STATE=`, or a dot with no session.
pub fn state_icon(state: Option<&str>) -> &'static str {
    match state {
        Some("busy") => "▶",
        Some("idle") => "⏸",
        Some("awaiting") => "❓",
        _ => "·",
    }
}

fn in_flight_lines(
    item: &InFlight,
    selected: bool,
    w: usize,
    now: DateTime<Utc>,
) -> Vec<Line<'static>> {
    let label = item
        .label
        .clone()
        .or_else(|| item.slug.clone())
        .unwrap_or_default();
    let title = item.title.clone().unwrap_or_default();
    let status = status_words(item.status.as_deref().unwrap_or("")).to_string();
    let status = match item.pr.as_ref().and_then(|p| p.number) {
        Some(n) if item.status.as_deref() == Some("pr-open") => format!("PR #{n} open"),
        Some(n) => format!("PR #{n} {status}"),
        None => status,
    };
    let status_style = match item.status.as_deref() {
        Some("changes-requested") => Style::default().fg(Color::Red),
        Some("waiting-merge") | Some("merged") => Style::default().fg(Color::Green),
        _ => Style::default().fg(Color::Cyan),
    };
    let line1 = fit(
        Line::from(vec![
            marker(selected),
            Span::styled(format!("{label:<6}"), bold()),
            Span::raw(" "),
            Span::styled(title, title_style(selected)),
        ]),
        Line::from(vec![Span::styled(status, status_style), Span::raw(" ")]),
        w,
    );
    let session = item.session.as_ref();
    let icon = state_icon(session.and_then(|s| s.state.as_deref()));
    let age = session
        .and_then(|s| s.last_heartbeat.as_deref())
        .and_then(parse_time)
        .map(|t| ago(t, now));
    let activity = match (session, age) {
        (None, _) => "· no session".to_string(),
        (Some(_), Some(age)) => format!("{icon} {age}"),
        (Some(_), None) => icon.to_string(),
    };
    let activity_style = match session.and_then(|s| s.state.as_deref()) {
        Some("awaiting") => Style::default().fg(Color::Yellow),
        _ => dim(),
    };
    let mut right = vec![];
    if !item.reviewers.is_empty() {
        right.push(Span::styled(
            format!("{} reviewing · ", item.reviewers.len()),
            dim(),
        ));
    }
    right.push(Span::styled(activity, activity_style));
    right.push(Span::raw(" "));
    let desc = item.description.clone().unwrap_or_default();
    let line2 = fit(
        Line::from(vec![
            Span::raw(" ".repeat(10)),
            Span::styled(first_line(&desc), dim()),
        ]),
        Line::from(right),
        w,
    );
    vec![line1, line2]
}

fn next_lines(n: usize, item: &NextItem, selected: bool, w: usize) -> Vec<Line<'static>> {
    let label = item
        .label
        .clone()
        .or_else(|| item.reference.clone())
        .unwrap_or_default();
    let right = match &item.note {
        Some(note) => Line::from(vec![
            Span::styled(format!("\"{note}\""), Style::default().fg(Color::Cyan)),
            Span::raw(" "),
        ]),
        None => Line::default(),
    };
    let mut out = vec![fit(
        Line::from(vec![
            marker(selected),
            Span::styled(format!("{n:<2} "), dim()),
            Span::styled(format!("{label:<6}"), bold()),
            Span::raw(" "),
            Span::styled(
                item.title.clone().unwrap_or_default(),
                title_style(selected),
            ),
        ]),
        right,
        w,
    )];
    if let Some(desc) = item.description.as_deref().filter(|d| !d.is_empty()) {
        out.push(truncate_line(
            Line::from(vec![
                Span::raw(" ".repeat(13)),
                Span::styled(first_line(desc), dim()),
            ]),
            w,
        ));
    }
    out
}

fn done_lines(item: &DoneItem, selected: bool, w: usize, now: DateTime<Utc>) -> Vec<Line<'static>> {
    let label = item
        .label
        .clone()
        .or_else(|| item.reference.clone())
        .unwrap_or_default();
    let mut meta = Vec::new();
    if let Some(n) = item.pr.as_ref().and_then(|p| p.number) {
        meta.push(format!("PR #{n}"));
    }
    if let Some(sha) = item.merge_sha.as_deref().filter(|s| !s.is_empty()) {
        meta.push(sha.chars().take(7).collect());
    }
    if let Some(t) = item.merged_at.as_deref().and_then(parse_time) {
        meta.push(format!("{} ago", ago(t, now)));
    }
    let mut out = vec![fit(
        Line::from(vec![
            marker(selected),
            Span::styled(format!("{label:<6}"), bold()),
            Span::raw(" "),
            Span::styled(
                item.title.clone().unwrap_or_default(),
                title_style(selected),
            ),
        ]),
        Line::from(vec![Span::styled(meta.join(" · "), dim()), Span::raw(" ")]),
        w,
    )];
    // The summary, wrapped to two lines: the account of what the solution was.
    let summary = item
        .description
        .as_deref()
        .or(item.summary.as_deref())
        .unwrap_or("");
    let indent = 10;
    let wrapped = wrap(summary, w.saturating_sub(indent + 1).max(10));
    for (i, l) in wrapped.iter().take(2).enumerate() {
        let text = if i == 1 && wrapped.len() > 2 {
            ellipsize(l, w.saturating_sub(indent + 2))
        } else {
            l.clone()
        };
        out.push(Line::from(vec![
            Span::raw(" ".repeat(indent)),
            Span::styled(text, dim()),
        ]));
    }
    out
}

/// The expanded item: its full text, scrollable. A done item shows the whole
/// PR body; the others show everything the snapshot has on them.
fn detail_view(f: &mut Frame, app: &mut App, area: Rect, now: DateTime<Utc>) {
    let (Some(repo), Some(row)) = (app.current_repo(), app.selected_row()) else {
        app.detail = None;
        return;
    };
    let w = area.width as usize;
    let mut head: Vec<Line> = Vec::new();
    let mut text;
    match row {
        Row::InFlight(i) => {
            let item = &repo.in_flight[i];
            head.extend(in_flight_lines(item, true, w, now).into_iter().take(1));
            let mut meta = vec![format!("branch {}", item.branch.as_deref().unwrap_or("?"))];
            if let Some(r) = item.session.as_ref().and_then(|s| s.role.as_deref()) {
                meta.push(r.to_string());
            }
            for r in &item.reviewers {
                meta.push(format!(
                    "{} {}",
                    r.role.as_deref().unwrap_or("reviewer"),
                    state_icon(r.session.as_ref().and_then(|s| s.state.as_deref()))
                ));
            }
            head.push(Line::from(Span::styled(
                format!("   {}", meta.join(" · ")),
                dim(),
            )));
            text = item.description.clone().unwrap_or_default();
        }
        Row::Next(i) => {
            let item = &repo.next.items[i];
            head.extend(next_lines(i + 1, item, true, w).into_iter().take(1));
            text = item.description.clone().unwrap_or_default();
        }
        Row::Done(i) => {
            let item = &repo.done.items[i];
            head.extend(done_lines(item, true, w, now).into_iter().take(1));
            text = item
                .body
                .clone()
                .or_else(|| item.summary.clone())
                .unwrap_or_default();
        }
    }
    if text.trim().is_empty() {
        text = "(no description)".into();
    }
    head.push(Line::default());

    let body_w = w.saturating_sub(4).max(10);
    let body: Vec<String> = text
        .lines()
        .flat_map(|l| wrap_indented(l, body_w))
        .collect();
    let visible = (area.height as usize).saturating_sub(head.len()).max(1);
    let max_scroll = body.len().saturating_sub(visible);
    let scroll = (app.detail.unwrap_or(0) as usize).min(max_scroll);
    app.detail = Some(scroll as u16);

    let [top, rest] =
        Layout::vertical([Constraint::Length(head.len() as u16), Constraint::Min(1)]).areas(area);
    f.render_widget(Paragraph::new(head), top);
    let lines: Vec<Line> = body
        .into_iter()
        .map(|l| Line::from(format!("   {l}")))
        .collect();
    f.render_widget(Paragraph::new(lines).scroll((scroll as u16, 0)), rest);
}

// ---- text helpers ------------------------------------------------------

pub fn parse_time(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|t| t.with_timezone(&Utc))
}

/// A compact age: `40s`, `14m`, `3h`, `2d`.
pub fn ago(t: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let s = (now - t).num_seconds().max(0);
    match s {
        0..=59 => format!("{s}s"),
        60..=3599 => format!("{}m", s / 60),
        3600..=86399 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86400),
    }
}

fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").to_string()
}

fn rule(w: usize) -> Span<'static> {
    Span::styled("─".repeat(w), dim())
}

fn line_width(line: &Line) -> usize {
    line.spans.iter().map(|s| s.content.width()).sum()
}

/// `left` padded so `right` ends at the edge. When both do not fit, `left`
/// is cut first: the status on the right is what the eye scans for.
pub fn fit(left: Line<'static>, right: Line<'static>, w: usize) -> Line<'static> {
    let rw = line_width(&right);
    let room = w.saturating_sub(rw + 1);
    let mut left = truncate_line(left, room);
    let pad = w.saturating_sub(line_width(&left) + rw);
    left.spans.push(Span::raw(" ".repeat(pad)));
    left.spans.extend(right.spans);
    truncate_line(left, w)
}

/// Cut a line to `w` columns, ending in `…` when anything was cut.
pub fn truncate_line(line: Line<'static>, w: usize) -> Line<'static> {
    if line_width(&line) <= w {
        return line;
    }
    let mut out = Vec::new();
    let mut used = 0;
    let budget = w.saturating_sub(1);
    for span in line.spans {
        let sw = span.content.width();
        if used + sw <= budget {
            used += sw;
            out.push(span);
            continue;
        }
        let mut cut = String::new();
        for c in span.content.chars() {
            let cw = c.width().unwrap_or(0);
            if used + cw > budget {
                break;
            }
            used += cw;
            cut.push(c);
        }
        out.push(Span::styled(cut, span.style));
        break;
    }
    if w > 0 {
        out.push(Span::raw("…"));
    }
    Line::from(out)
}

fn ellipsize(s: &str, w: usize) -> String {
    let mut out: String = String::new();
    let mut used = 0;
    for c in s.chars() {
        let cw = c.width().unwrap_or(0);
        if used + cw > w {
            break;
        }
        used += cw;
        out.push(c);
    }
    out.push('…');
    out
}

/// Greedy word wrap by display width; a word wider than the line is split.
pub fn wrap(text: &str, w: usize) -> Vec<String> {
    let w = w.max(1);
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut cur_w = 0;
    for word in text.split_whitespace() {
        let ww = word.width();
        if cur_w > 0 && cur_w + 1 + ww > w {
            out.push(std::mem::take(&mut cur));
            cur_w = 0;
        }
        if ww > w {
            for c in word.chars() {
                let cw = c.width().unwrap_or(0);
                if cur_w + cw > w {
                    out.push(std::mem::take(&mut cur));
                    cur_w = 0;
                }
                cur.push(c);
                cur_w += cw;
            }
            continue;
        }
        if cur_w > 0 {
            cur.push(' ');
            cur_w += 1;
        }
        cur.push_str(word);
        cur_w += ww;
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Wrap one line of a body, keeping its leading indent on every piece so a
/// nested list stays nested.
fn wrap_indented(line: &str, w: usize) -> Vec<String> {
    let rest = line.trim_start();
    if rest.is_empty() {
        return vec![String::new()];
    }
    let indent = &line[..line.len() - rest.len()];
    let iw = indent.width().min(w / 2);
    wrap(rest, w - iw)
        .into_iter()
        .map(|l| format!("{}{l}", " ".repeat(iw)))
        .collect()
}

/// The first line to show so `[start, end)` is on screen, scrolling as
/// little as possible from the top.
fn scroll_to(start: usize, end: usize, height: usize) -> usize {
    if end <= height {
        0
    } else {
        start.min(end.saturating_sub(height))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::{App, Key, OvRow};
    use crate::snapshot::parse;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::time::Instant;

    const MULTI: &str = include_str!("../tests/fixtures/multi.json");

    fn now() -> DateTime<Utc> {
        "2026-10-20T15:00:00Z".parse().unwrap()
    }

    fn app(json: &str, in_repo: bool) -> App {
        let mut app = App::new(in_repo);
        app.offer(
            Instant::now(),
            crate::refresh::Mode::Full,
            parse(json).unwrap(),
            now(),
        );
        app
    }

    fn render(app: &mut App, w: u16, h: u16) -> Vec<String> {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| draw(f, app, now())).unwrap();
        let buf = term.backend().buffer().clone();
        (0..h)
            .map(|y| {
                let mut s = String::new();
                let mut x = 0;
                while x < w {
                    let cell = &buf[(x, y)];
                    s.push_str(cell.symbol());
                    x += cell.symbol().width().max(1) as u16;
                }
                s.trim_end().to_string()
            })
            .collect()
    }

    fn screen(lines: &[String]) -> String {
        lines.join("\n")
    }

    fn line_with<'a>(lines: &'a [String], needle: &str) -> &'a str {
        lines
            .iter()
            .find(|l| l.contains(needle))
            .unwrap_or_else(|| panic!("no line contains {needle:?}:\n{}", screen(lines)))
    }

    #[test]
    fn repo_view_shows_the_three_sections() {
        let mut a = app(MULTI, true);
        let s = render(&mut a, 100, 30);
        let text = screen(&s);
        assert!(
            s[0].starts_with(" task-force · PM claude · ✉ 1 unread"),
            "{}",
            s[0]
        );
        assert!(s[0].ends_with("· live"), "{}", s[0]);
        for want in [
            "IN FLIGHT (2)",
            "NEXT  (PM queue)",
            "DONE  (last 24h)",
            "↑↓ move  ⏎ expand",
        ] {
            assert!(text.contains(want), "missing {want:?}:\n{text}");
        }
        let row = line_with(&s, "#267");
        assert!(
            row.starts_with(" ▸ #267"),
            "the first item is selected: {row}"
        );
        assert!(row.ends_with("PR #270 re-review"), "{row}");
        assert!(line_with(&s, "Teach the hook merge").ends_with("1 reviewing · ▶ 14m"));
        assert!(line_with(&s, "#262").ends_with("implementing"));
        assert!(line_with(&s, "A scratch-home probe").ends_with("❓ 3m"));
        assert!(line_with(&s, "#180").ends_with("\"after #267\""));
        assert!(line_with(&s, "#266").ends_with("PR #269 · 1415b86 · 2h ago"));
        assert!(text.contains("Both whitespace checks use a grep helper"));
    }

    /// A queued notion page (#306): the PM's title and the compact page id
    /// render, the page URL does not.
    #[test]
    fn a_titled_queue_row_renders_the_title_not_the_url() {
        let url = "https://app.notion.com/p/3fdd9a72260f81559d2fdfe4589b5b1c";
        let item: NextItem = serde_json::from_value(serde_json::json!({
            "ref": url, "label": "notion:…589b5b1c", "number": null,
            "title": "Arms schema", "description": null, "url": url,
            "note": "needs sign-off"
        }))
        .unwrap();
        let row: String = next_lines(1, &item, false, 100)[0]
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(row.contains("notion:…589b5b1c Arms schema"), "{row}");
        assert!(row.trim_end().ends_with("\"needs sign-off\""), "{row}");
        assert!(!row.contains("https://"), "{row}");
    }

    #[test]
    fn narrow_terminals_cut_the_title_not_the_status() {
        let mut a = app(MULTI, true);
        let s = render(&mut a, 60, 30);
        let row = line_with(&s, "#267");
        assert!(row.ends_with("PR #270 re-review"), "{row}");
        assert!(row.contains('…'), "{row}");
        assert!(s.iter().all(|l| l.width() <= 60));
    }

    #[test]
    fn the_selection_scrolls_into_view() {
        let mut a = app(MULTI, true);
        for _ in 0..10 {
            a.key(Key::Down, now());
        }
        let s = render(&mut a, 100, 12);
        assert!(line_with(&s, "#266").starts_with(" ▸ #266"));
    }

    #[test]
    fn enter_expands_a_done_item_to_its_full_scrollable_body() {
        let mut a = app(MULTI, true);
        for _ in 0..10 {
            a.key(Key::Down, now());
        }
        a.key(Key::Enter, now());
        let s = render(&mut a, 100, 17);
        let text = screen(&s);
        assert!(
            text.contains("Closes #266") && text.contains("line one of the body"),
            "{text}"
        );
        assert!(
            !text.contains("THE LAST LINE"),
            "the body is longer than the screen"
        );
        assert!(text.contains("↑↓ scroll"));
        for _ in 0..40 {
            a.key(Key::Down, now());
        }
        let text = screen(&render(&mut a, 100, 17));
        assert!(text.contains("THE LAST LINE OF THE BODY"), "{text}");
        assert!(
            a.detail.unwrap() < 40,
            "scrolling stops at the end of the body"
        );
    }

    #[test]
    fn overview_lights_repos_with_signals_and_names_their_session() {
        let mut a = app(MULTI, false);
        let s = render(&mut a, 120, 20);
        assert!(s[0].starts_with(" task-monitor · all repos"));
        let tf = line_with(&s, "task-force ");
        assert!(tf.starts_with("▸● task-force"), "{tf}");
        assert!(tf.contains("✉ 1 unread · 1 review waiting merge"), "{tf}");
        assert!(tf.ends_with("2 in flight · zellij task-force"), "{tf}");
        assert!(line_with(&s, "recommender-systems").contains("❓ rerank-sasrec-gate is asking"));
        assert!(line_with(&s, "recommender-systems").ends_with("zellij rec"));
        let other = line_with(&s, "other-repo");
        assert!(other.starts_with(" ○ other-repo"), "{other}");
        assert!(other.ends_with("idle · zellij other"), "{other}");
        // No PM session and no worker session: no zellij session to name.
        assert!(line_with(&s, "jira-repo").ends_with("1 in flight"));
        assert!(screen(&s).contains("! needs you"));
    }

    /// The overview's lines, from the first repo row on, cut at `w`.
    fn overview_lines(a: &mut App, w: u16) -> Vec<String> {
        render(a, w, 24)
            .into_iter()
            .skip(2)
            .take_while(|l| !l.starts_with('─'))
            .filter(|l| !l.is_empty())
            .collect()
    }

    #[test]
    fn overview_lists_every_agent_under_its_repo_and_marks_who_needs_you() {
        let mut a = app(MULTI, false);
        let s = overview_lines(&mut a, 120);
        let you = |l: &str| l.ends_with("← you");
        let rows: Vec<(&str, bool)> = s
            .iter()
            .map(|l| {
                (
                    l.split_whitespace()
                        .nth(if l.starts_with('▸') { 1 } else { 0 })
                        .unwrap_or(""),
                    you(l),
                )
            })
            .collect();
        assert_eq!(s.len(), 13, "{}", screen(&s));
        // The PM owes unread mail and a review: it, not the repo, is marked,
        // and the row says why.
        let pm = &s[1];
        assert!(pm.starts_with("     PM         claude  ⏸  idle"), "{pm}");
        assert!(
            pm.contains("✉ 1 unread · 1 review waiting merge") && you(pm),
            "{pm}"
        );
        assert!(!you(&s[0]), "the repo row is not the one marked: {}", s[0]);
        // A busy worker: agent, icon, status words and title, unmarked.
        let w = line_with(&s, "#267");
        assert!(
            w.starts_with("     #267       claude  ▶  re-review       kiro upgraded"),
            "{w}"
        );
        assert!(!you(w), "{w}");
        // Its reviewer nests under it.
        assert!(
            s[3].starts_with("       ↳ review claude  ▶  reviewing       PR #270"),
            "{}",
            s[3]
        );
        // The asking worker is marked, in this repo and the next.
        let asking = line_with(&s, "#262");
        assert!(
            asking.contains("❓ waiting on you  Launched tabs") && you(asking),
            "{asking}"
        );
        let rec = line_with(&s, "Gate the SASRec");
        assert!(
            rec.starts_with("     12         claude  ❓ waiting on you") && you(rec),
            "{rec}"
        );
        // A kiro PM beside a claude worker, and a repo with no sessions.
        assert!(
            s[6].starts_with("     PM         kiro    ▶  busy"),
            "{}",
            s[6]
        );
        assert!(!you(&s[6]), "{}", s[6]);
        assert!(
            s[9].starts_with("     PM         kiro    ·  no session"),
            "{}",
            s[9]
        );
        assert!(line_with(&s, "PROJ-42 ").starts_with("     PROJ-42    kiro    ·  implementing"));
        let marked: Vec<&str> = rows.iter().filter(|r| r.1).map(|r| r.0).collect();
        assert_eq!(marked, vec!["PM", "#262", "12"]);
    }

    #[test]
    fn bang_filters_the_overview_to_what_needs_you() {
        let mut a = app(MULTI, false);
        a.key(Key::Char('!'), now());
        let s = render(&mut a, 120, 24);
        assert!(
            s[0].starts_with(" task-monitor · all repos · needs you"),
            "{}",
            s[0]
        );
        assert!(screen(&s).contains("! every agent"));
        let s = overview_lines(&mut a, 120);
        assert_eq!(s.len(), 5, "{}", screen(&s));
        assert!(
            s[0].starts_with("▸● task-force"),
            "repo rows stay, for context"
        );
        assert!(s[1].contains("PM") && s[2].contains("#262") && s[4].contains("Gate the SASRec"));
        assert!(s[3].starts_with(" ● recommender-systems"));
        assert!(s[1..]
            .iter()
            .filter(|l| !l.contains('●'))
            .all(|l| l.ends_with("← you")));
        // Nothing needs you: say so instead of an empty screen.
        let mut snap = parse(MULTI).unwrap();
        for r in &mut snap.repos {
            r.attention.signals.clear();
        }
        a.offer(Instant::now(), crate::refresh::Mode::Local, snap, now());
        assert!(
            screen(&render(&mut a, 120, 24)).contains("nothing needs you · ! shows every agent")
        );
    }

    #[test]
    fn narrow_overviews_cut_titles_and_keep_the_mark() {
        let mut a = app(MULTI, false);
        let s = render(&mut a, 60, 24);
        assert!(s.iter().all(|l| l.width() <= 60), "{}", screen(&s));
        let asking = line_with(&s, "#262");
        assert!(
            asking.ends_with("← you") && asking.contains('…'),
            "{asking}"
        );
        assert!(line_with(&s, "#267").ends_with('…'));
    }

    #[test]
    fn a_failed_refresh_keeps_the_screen_and_marks_it_stale() {
        let mut a = app(MULTI, true);
        a.failed(
            Instant::now(),
            crate::refresh::Mode::Local,
            now(),
            "task-monitor-snapshot timed out after 20s".into(),
        );
        let s = render(&mut a, 100, 30);
        assert!(s[0].contains("stale 0s"), "{}", s[0]);
        assert!(
            screen(&s).contains("#267"),
            "the last good snapshot is still drawn"
        );
        assert!(screen(&s).contains("snapshot failed: task-monitor-snapshot timed out after 20s"));
    }

    #[test]
    fn a_stale_forge_is_marked_with_its_age() {
        let mut a = app(MULTI, true);
        a.key(Key::Char('a'), now());
        crate::app::tests::go_to(&mut a, OvRow::Repo(2));
        a.key(Key::Enter, now());
        let s = render(&mut a, 100, 20);
        assert!(s[0].starts_with(" jira-repo · no PM"), "{}", s[0]);
        assert!(s[0].ends_with("· forge 1h"), "{}", s[0]);
        assert!(line_with(&s, "PROJ-42").contains("PROJ-42 · kiro-config2"));
        line_with(&s, "· no session"); // panics when absent
        assert!(screen(&s).contains("nothing queued"));
    }

    #[test]
    fn before_the_first_snapshot_it_says_so() {
        let mut a = App::new(true);
        let s = render(&mut a, 80, 10);
        assert!(screen(&s).contains("loading the first snapshot"));
        a.failed(
            Instant::now(),
            crate::refresh::Mode::Local,
            now(),
            "boom".into(),
        );
        assert!(screen(&render(&mut a, 80, 10)).contains("snapshot failed: boom"));
    }

    #[test]
    fn renders_the_documented_example() {
        let mut a = app(
            include_str!("../../docs/task-monitor-schema.example.json"),
            true,
        );
        let text = screen(&render(&mut a, 120, 40));
        assert!(text.contains("#273"), "{text}");
        assert!(text.contains("NEXT  (tracker backlog)"));
    }

    #[test]
    fn a_flash_shows_then_expires() {
        let mut a = app(MULTI, true);
        a.flash(now(), "tab 4 is now 'other', not kiro-config");
        assert!(screen(&render(&mut a, 100, 30)).contains("tab 4 is now 'other'"));
        a.flash = Some((
            now() - chrono::Duration::seconds(FLASH_SECS + 1),
            "old".into(),
        ));
        assert!(!screen(&render(&mut a, 100, 30)).contains("old"));
    }

    #[test]
    fn wrap_and_age_helpers() {
        assert_eq!(wrap("aa bb cc", 5), vec!["aa bb", "cc"]);
        assert_eq!(wrap("abcdefgh", 3), vec!["abc", "def", "gh"]);
        assert_eq!(wrap_indented("  - aa bb", 6), vec!["  - aa", "  bb"]);
        assert_eq!(wrap_indented("   ", 6), vec![""]);
        let t = now();
        assert_eq!(ago(t - chrono::Duration::seconds(30), t), "30s");
        assert_eq!(ago(t - chrono::Duration::minutes(14), t), "14m");
        assert_eq!(ago(t - chrono::Duration::hours(26), t), "1d");
        assert_eq!(status_words("waiting-merge"), "waiting merge");
        assert_eq!(status_words("brand-new"), "brand-new");
    }
}
