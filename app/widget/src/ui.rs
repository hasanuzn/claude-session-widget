//! The widget's UI, independent of the window: the bubble, the card with accordion
//! session rows, the finished list and the settings page. It never touches the OS;
//! it returns [`Action`]s for the shell (window, tray, settings file) to carry out.

use crate::i18n::{self, Strings};
use crate::settings::Settings;
use crate::theme::*;
use claude_session_core::model::FINISHING;
use claude_session_core::{Location, Session, StepStatus, Waiting};
use egui::{
    Align, Align2, Color32, CornerRadius, Label, Layout, Rect, Response, RichText, Sense, Stroke,
    StrokeKind, Ui, UiBuilder, Vec2, pos2, vec2,
};
use std::collections::{HashMap, HashSet};

pub const CARD_WIDTH: f32 = 380.0;
/// Corner radius of the card, in points.
pub const CARD_RADIUS: f32 = 10.0;
const MAX_CARD_HEIGHT: f32 = 600.0;
const MIN_CARD_HEIGHT: f32 = 120.0;

/// Bubble window: a disc with the badge overlapping its top-right edge.
pub const BUBBLE_SIZE: f32 = 64.0;
pub const BUBBLE_DISC: (f32, f32, f32) = (32.0, 34.0, 27.0); // centre x, centre y, radius
pub const BUBBLE_BADGE: (f32, f32, f32) = (52.0, 12.0, 10.5); // centre x, centre y, radius

pub const REPO_URL: &str = "https://github.com/hasanuzn/claude-session-widget";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Page {
    Sessions,
    Settings,
}

#[derive(Clone, Debug)]
pub struct Finished {
    pub id: String,
    pub name: String,
    pub at_ms: f64,
}

/// Something the shell has to do.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    StartDrag,
    Hide,
    Quit,
    SaveSettings,
    LanguageChanged,
    Topmost(bool),
    Startup(bool),
    FeedChanged,
    OpenUrl(String),
    Notify { title: String, body: String },
}

pub struct Widget {
    pub settings: Settings,
    pub strings: Strings,
    pub glyphs: Glyphs,
    pub sessions: Vec<Session>,
    pub finished: Vec<Finished>,
    pub unseen: usize,
    pub expanded: bool,
    pub page: Page,
    /// The window is shown (not hidden to the tray).
    pub visible: bool,
    pub startup_enabled: bool,
    pub blink_on: bool,
    pub version: &'static str,
    open_rows: HashSet<String>,
    /// Last scan: id -> (name, waiting).
    prev: Option<HashMap<String, (String, bool)>>,
    card_height: f32,
}

impl Widget {
    pub fn new(settings: Settings, have_mdl2: bool, version: &'static str) -> Self {
        let strings = Strings::load(&settings.language);
        let expanded = settings.start_expanded();
        Self {
            settings,
            strings,
            glyphs: glyphs(have_mdl2),
            sessions: Vec::new(),
            finished: Vec::new(),
            unseen: 0,
            expanded,
            page: Page::Sessions,
            visible: true,
            startup_enabled: false,
            blink_on: false,
            version,
            open_rows: HashSet::new(),
            prev: None,
            card_height: 220.0,
        }
    }

    pub fn open_row(&mut self, id: &str) {
        self.open_rows.insert(id.to_string());
    }

    /// Size the window should have (points).
    pub fn desired_size(&self) -> Vec2 {
        if self.expanded {
            vec2(CARD_WIDTH, self.card_height)
        } else {
            Vec2::splat(BUBBLE_SIZE)
        }
    }

    pub fn set_expanded(&mut self, expanded: bool) {
        self.expanded = expanded;
        if expanded {
            self.unseen = 0;
            self.blink_on = false;
        } else {
            self.page = Page::Sessions;
        }
        if self.settings.expanded != expanded {
            self.settings.expanded = expanded;
        }
    }

    /// New scan result. Working sessions that disappeared are finished; sessions that
    /// start waiting for the person raise a notification. A waiting session that drops
    /// out (its question got too old, or it was archived) is not "finished".
    pub fn set_sessions(&mut self, list: Vec<Session>, now_ms: f64) -> Vec<Action> {
        let mut actions = Vec::new();
        let current: HashMap<String, (String, bool)> = list
            .iter()
            .map(|s| (s.id.clone(), (s.name.clone(), s.waiting.is_some())))
            .collect();
        if let Some(prev) = &self.prev {
            let ended: Vec<(String, String)> = prev
                .iter()
                .filter(|(id, (_, was_waiting))| !was_waiting && !current.contains_key(*id))
                .map(|(id, (name, _))| (id.clone(), name.clone()))
                .collect();
            let new_waiting: Vec<&str> = list
                .iter()
                .filter(|s| s.waiting.is_some() && prev.get(&s.id).is_none_or(|(_, w)| !w))
                .map(|s| s.name.as_str())
                .collect();
            if !new_waiting.is_empty() && self.settings.notify {
                let body = if new_waiting.len() == 1 {
                    new_waiting[0].to_string()
                } else {
                    self.strings
                        .f("WaitMany", &[&new_waiting.len().to_string()])
                };
                actions.push(Action::Notify {
                    title: self.strings.t("WaitTitle").to_string(),
                    body,
                });
            }
            for (id, name) in &ended {
                self.finished.retain(|f| &f.id != id);
                self.finished.insert(
                    0,
                    Finished {
                        id: id.clone(),
                        name: name.clone(),
                        at_ms: now_ms,
                    },
                );
            }
            if !ended.is_empty() {
                if !(self.expanded && self.visible) {
                    self.unseen += ended.len();
                }
                if self.settings.notify {
                    let body = if ended.len() == 1 {
                        ended[0].1.clone()
                    } else {
                        self.strings.f("DoneMany", &[&ended.len().to_string()])
                    };
                    actions.push(Action::Notify {
                        title: self.strings.t("DoneTitle").to_string(),
                        body,
                    });
                }
            }
        }
        self.finished.retain(|f| !current.contains_key(&f.id));
        self.prev = Some(current);
        self.sessions = list;
        actions
    }

    /// Sessions that are working (not waiting for the person).
    pub fn working(&self) -> usize {
        self.sessions.iter().filter(|s| s.waiting.is_none()).count()
    }

    /// Sessions waiting for the person.
    pub fn waiting(&self) -> usize {
        self.sessions.len() - self.working()
    }

    pub fn set_finished_demo(&mut self, items: Vec<(String, f64)>) {
        self.finished = items
            .into_iter()
            .map(|(name, at_ms)| Finished {
                id: name.clone(),
                name,
                at_ms,
            })
            .collect();
    }

    /// Draws the whole window content. `now_ms` drives the "x min" labels.
    pub fn draw(&mut self, ui: &mut Ui, now_ms: f64) -> Vec<Action> {
        let keep = self.settings.keep_min as f64 * 60_000.0;
        self.finished.retain(|f| now_ms - f.at_ms <= keep);
        let mut actions = Vec::new();
        if self.expanded {
            self.card(ui, now_ms, &mut actions);
        } else {
            self.bubble(ui, &mut actions);
        }
        actions
    }

    // ------------------------------------------------------------------ bubble

    fn bubble(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) {
        let origin = ui.max_rect().min;
        let at = |x: f32, y: f32| origin + vec2(x, y);
        let (dx, dy, dr) = BUBBLE_DISC;
        let disc = Rect::from_center_size(at(dx, dy), Vec2::splat(dr * 2.0));
        let resp = ui.interact(
            ui.max_rect(),
            ui.id().with("bubble"),
            Sense::click_and_drag(),
        );
        let p = ui.painter();
        let n = self.working();
        let waiting = self.waiting();
        // Waiting for the person comes first: it is the one thing that needs them.
        let (glyph_color, ring) = if waiting > 0 {
            (BLUE, BLUE)
        } else if self.unseen > 0 && self.settings.blink {
            if self.blink_on {
                (GREEN, GREEN)
            } else {
                (DIM, LINE)
            }
        } else if self.unseen > 0 {
            (GREEN, LINE)
        } else if n > 0 {
            (ACCENT, LINE)
        } else {
            (DIM, LINE)
        };
        p.circle(disc.center(), dr, BG, Stroke::new(1.5_f32, ring));
        p.text(
            disc.center() + vec2(0.0, -1.0),
            Align2::CENTER_CENTER,
            "✻",
            semibold(27.0),
            glyph_color,
        );
        let badge = if waiting > 0 {
            Some((waiting.to_string(), BLUE))
        } else if self.unseen > 0 {
            Some((format!("✓{}", self.unseen), GREEN))
        } else if n > 0 {
            Some((n.to_string(), ACCENT))
        } else {
            None
        };
        if let Some((text, fill)) = badge {
            let (bx, by, br) = BUBBLE_BADGE;
            p.circle(at(bx, by), br, fill, Stroke::new(2.0_f32, BG));
            p.text(at(bx, by), Align2::CENTER_CENTER, text, semibold(10.5), INK);
        }
        if resp.drag_started() {
            actions.push(Action::StartDrag);
        } else if resp.clicked() {
            self.set_expanded(true);
            actions.push(Action::SaveSettings);
        }
        resp.on_hover_text(self.strings.t("AppTitle"));
    }

    // -------------------------------------------------------------------- card

    fn card(&mut self, ui: &mut Ui, now_ms: f64, actions: &mut Vec<Action>) {
        let full = ui.max_rect();
        let p = ui.painter().clone();
        // In a window the shell cuts the same corners with a window region.
        let corner = CornerRadius::same(CARD_RADIUS as u8);
        p.rect_filled(full, corner, BG);
        p.rect_stroke(full, corner, Stroke::new(1.0_f32, LINE), StrokeKind::Inside);

        let inner = full.shrink2(vec2(14.0, 10.0));
        let mut child = ui.new_child(
            UiBuilder::new()
                .max_rect(inner)
                .layout(Layout::top_down(Align::Min)),
        );
        let header_bottom = self.header(&mut child, actions);
        let sep_y = header_bottom + 8.0;
        p.hline(full.x_range(), sep_y, Stroke::new(1.0_f32, LINE));
        child.add_space(17.0);

        let available = MAX_CARD_HEIGHT - (sep_y - full.top()) - 14.0;
        let out = egui::ScrollArea::vertical()
            .max_height(available)
            .auto_shrink([false, true])
            .show(&mut child, |ui| match self.page {
                Page::Sessions => self.sessions_page(ui, now_ms),
                Page::Settings => self.settings_page(ui, actions),
            });
        let content = out.content_size.y.min(available);
        let wanted = ((sep_y - full.top()) + 9.0 + content + 12.0)
            .clamp(MIN_CARD_HEIGHT, MAX_CARD_HEIGHT)
            .round();
        if (wanted - self.card_height).abs() > 0.5 {
            self.card_height = wanted;
            ui.ctx().request_repaint();
        }
    }

    /// Returns the header's bottom y.
    fn header(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) -> f32 {
        let s = &self.strings;
        let g = &self.glyphs;
        let mut back = false;
        let mut to_settings = false;
        let mut minimize = false;
        let mut pin = false;
        let mut hide = false;
        // Drag the window by the header. Registered before the buttons so they sit on top.
        // It senses clicks too, so a drag starts only once the mouse moves: a drag-only
        // area would start the window move on the press and swallow the buttons' clicks.
        let header_rect = Rect::from_min_size(ui.cursor().min, vec2(ui.available_width(), 34.0));
        let drag = ui.interact(
            header_rect,
            ui.id().with("header-drag"),
            Sense::click_and_drag(),
        );
        if drag.drag_started() {
            actions.push(Action::StartDrag);
        }
        let row = ui.horizontal(|ui| {
            ui.set_height(34.0);
            if self.page == Page::Settings {
                back = icon_button(ui, g.back, s.t("Close"), false).clicked();
                ui.label(
                    RichText::new(s.t("SettingsTitle"))
                        .font(semibold(14.0))
                        .color(TEXT),
                );
            } else {
                ui.label(RichText::new("✻").font(semibold(19.0)).color(ACCENT));
                ui.add_space(4.0);
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 1.0;
                    ui.label(
                        RichText::new(s.t("Header"))
                            .font(semibold(13.0))
                            .color(TEXT),
                    );
                    ui.add(
                        Label::new(
                            RichText::new(self.subtitle())
                                .font(regular(11.0))
                                .color(MUTED),
                        )
                        .truncate(),
                    );
                });
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.spacing_mut().item_spacing.x = 2.0;
                hide = icon_button(ui, g.close, s.t("TipHide"), false).clicked();
                if self.page == Page::Sessions {
                    minimize = icon_button(ui, g.minimize, s.t("TipMin"), false).clicked();
                    pin = icon_button(ui, g.pin, s.t("TipPin"), self.settings.topmost).clicked();
                    to_settings = icon_button(ui, g.settings, s.t("TipSettings"), false).clicked();
                }
            });
        });
        if back {
            self.page = Page::Sessions;
        }
        if to_settings {
            self.page = Page::Settings;
        }
        if minimize {
            self.set_expanded(false);
            actions.push(Action::SaveSettings);
        }
        if pin {
            self.settings.topmost = !self.settings.topmost;
            actions.push(Action::Topmost(self.settings.topmost));
            actions.push(Action::SaveSettings);
        }
        if hide {
            actions.push(Action::Hide);
        }
        row.response.rect.bottom()
    }

    pub fn subtitle(&self) -> String {
        let s = &self.strings;
        let (n, waiting) = (self.working(), self.waiting());
        let mut sub = if n > 0 {
            s.f("NRunning", &[&n.to_string()])
        } else if waiting > 0 {
            String::new()
        } else {
            s.t("NoWork").to_string()
        };
        if waiting > 0 {
            if !sub.is_empty() {
                sub.push_str(" · ");
            }
            sub.push_str(&s.f("NWaiting", &[&waiting.to_string()]));
        }
        if !self.finished.is_empty() {
            sub.push_str(" · ");
            sub.push_str(&s.f("NFinished", &[&self.finished.len().to_string()]));
        }
        sub
    }

    // ------------------------------------------------------------ sessions page

    fn sessions_page(&mut self, ui: &mut Ui, now_ms: f64) {
        ui.set_width(ui.available_width());
        if self.sessions.is_empty() && self.finished.is_empty() {
            ui.add_space(14.0);
            ui.vertical_centered(|ui| {
                ui.label(
                    RichText::new(self.strings.t("NoSessions"))
                        .font(regular(12.0))
                        .color(MUTED),
                )
            });
            ui.add_space(10.0);
            return;
        }
        let (waiting, working): (Vec<usize>, Vec<usize>) =
            (0..self.sessions.len()).partition(|&i| self.sessions[i].waiting.is_some());
        if !waiting.is_empty() {
            ui.label(
                RichText::new(self.strings.t("Waiting"))
                    .font(semibold(10.0))
                    .color(BLUE),
            );
            ui.add_space(4.0);
            for (k, &i) in waiting.iter().enumerate() {
                if k > 0 {
                    ui.add_space(4.0);
                    separator(ui, 0.6);
                    ui.add_space(4.0);
                }
                self.waiting_row(ui, i, now_ms);
            }
            if !working.is_empty() {
                ui.add_space(8.0);
                separator(ui, 1.0);
                ui.add_space(8.0);
            }
        }
        for (k, &i) in working.iter().enumerate() {
            if k > 0 {
                ui.add_space(4.0);
                separator(ui, 0.6);
                ui.add_space(4.0);
            }
            self.session_row(ui, i, now_ms);
        }
        if !self.finished.is_empty() {
            ui.add_space(12.0);
            let mut clear = false;
            ui.horizontal(|ui| {
                ui.label(
                    RichText::new(self.strings.t("Finished"))
                        .font(semibold(10.0))
                        .color(MUTED),
                );
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    clear = text_button(ui, self.strings.t("Clear")).clicked();
                });
            });
            for f in &self.finished {
                ui.horizontal(|ui| {
                    ui.label(RichText::new("✓").font(regular(12.0)).color(GREEN));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let ago = self
                            .strings
                            .f("Ago", &[&elapsed(&self.strings, now_ms - f.at_ms)]);
                        ui.label(RichText::new(ago).font(regular(11.0)).color(MUTED));
                        ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                            ui.add(
                                Label::new(RichText::new(&f.name).font(regular(12.0)).color(TEXT2))
                                    .truncate(),
                            );
                        });
                    });
                });
            }
            if clear {
                self.finished.clear();
            }
        }
    }

    /// A session waiting for the person: its name, and the question it asked or what
    /// kind of answer it needs.
    fn waiting_row(&self, ui: &mut Ui, index: usize, now_ms: f64) {
        let s = &self.sessions[index];
        let strings = &self.strings;
        let detail = match &s.waiting {
            Some(Waiting::Question(q)) => q.clone(),
            Some(Waiting::Prompt(reason)) => strings
                .t(match reason.as_str() {
                    "permission prompt" | "sandbox request" => "WaitPermission",
                    "input needed" | "worker request" | "goal proposal" => "WaitInput",
                    "dialog open" => "WaitDialog",
                    _ => "WaitOther",
                })
                .to_string(),
            None => return,
        };
        ui.horizontal(|ui| {
            ui.add_sized(
                [12.0, 18.0],
                Label::new(RichText::new("●").font(regular(9.0)).color(BLUE)),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.label(
                    RichText::new(elapsed(strings, now_ms - s.since_ms))
                        .font(regular(11.0))
                        .color(MUTED),
                );
                ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                    ui.add(
                        Label::new(RichText::new(&s.name).font(semibold(13.0)).color(TEXT))
                            .truncate(),
                    );
                });
            });
        });
        ui.horizontal(|ui| {
            ui.add_space(18.0);
            ui.add(Label::new(RichText::new(detail).font(regular(12.0)).color(TEXT2)).truncate());
        });
    }

    fn session_row(&mut self, ui: &mut Ui, index: usize, now_ms: f64) {
        let s = &self.sessions[index];
        let open = self.open_rows.contains(&s.id);
        let strings = &self.strings;
        let total = s.progress.total();
        let done = s.progress.done();

        // Title row + bar form one clickable header.
        let header = ui.scope(|ui| {
            ui.horizontal(|ui| {
                let chevron = if open {
                    self.glyphs.chevron_down
                } else {
                    self.glyphs.chevron_right
                };
                ui.add_sized(
                    [12.0, 18.0],
                    Label::new(RichText::new(chevron).font(icons(9.0)).color(MUTED)),
                );
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    ui.label(
                        RichText::new(elapsed(strings, now_ms - s.since_ms))
                            .font(regular(11.0))
                            .color(MUTED),
                    );
                    ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                        ui.add(
                            Label::new(RichText::new(&s.name).font(semibold(13.0)).color(TEXT))
                                .truncate(),
                        );
                    });
                });
            });
            ui.horizontal(|ui| {
                ui.add_space(18.0);
                let label = match (done * 100 + total / 2).checked_div(total) {
                    Some(pct) => format!(
                        "{done}/{total}  {}",
                        strings.f("Percent", &[&pct.to_string()])
                    ),
                    None => "—".to_string(),
                };
                let label_galley = ui
                    .painter()
                    .layout_no_wrap(label.clone(), regular(11.0), TEXT2);
                let bar_w = (ui.available_width() - label_galley.size().x - 10.0).max(40.0);
                let (rect, _) = ui.allocate_exact_size(vec2(bar_w, 14.0), Sense::hover());
                let track = Rect::from_center_size(rect.center(), vec2(rect.width(), 5.0));
                ui.painter().rect_filled(track, CornerRadius::same(3), LINE);
                if total > 0 && done > 0 {
                    let mut fill = track;
                    fill.set_width(track.width() * done as f32 / total as f32);
                    ui.painter()
                        .rect_filled(fill, CornerRadius::same(3), ACCENT);
                }
                ui.add_space(4.0);
                ui.label(RichText::new(label).font(regular(11.0)).color(TEXT2));
            });
        });
        let id = s.id.clone();
        let rect = header.response.rect.expand2(vec2(4.0, 2.0));
        let click = ui.interact(rect, ui.id().with(("row", &id)), Sense::click());
        if click.hovered() {
            ui.painter()
                .rect_filled(rect, CornerRadius::same(6), BG2.gamma_multiply(0.6));
        }
        if click.clicked() {
            if open {
                self.open_rows.remove(&id);
            } else {
                self.open_rows.insert(id.clone());
            }
        }
        if !open {
            return;
        }

        let s = &self.sessions[index];
        let strings = &self.strings;
        ui.indent(("details", &id), |ui| {
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.add_space(2.0);
            let place = match &s.location {
                Location::Local => strings.t("Local").to_string(),
                Location::Terminal => strings.t("Terminal").to_string(),
                other => other.to_string(),
            };
            let leaf = claude_session_core::text::leaf_name(&s.cwd);
            ui.label(
                RichText::new(format!("{place} · {leaf}"))
                    .font(regular(11.0))
                    .color(MUTED),
            );
            ui.add_space(4.0);
            for step in &s.progress.steps {
                let (mark, mark_color, text_color) = match step.status {
                    StepStatus::Completed => ("✓", GREEN, TEXT2),
                    StepStatus::InProgress => ("▸", ACCENT, TEXT),
                    StepStatus::Pending => ("○", DIM, MUTED),
                };
                ui.horizontal(|ui| {
                    ui.add_sized(
                        [14.0, 16.0],
                        Label::new(RichText::new(mark).font(regular(12.0)).color(mark_color)),
                    );
                    ui.add(
                        Label::new(
                            RichText::new(&step.text)
                                .font(regular(12.0))
                                .color(text_color),
                        )
                        .truncate(),
                    );
                });
            }
            let activity = if s.progress.activity == FINISHING {
                strings.t("Finishing").to_string()
            } else if s.progress.activity.is_empty() {
                strings.t("Working").to_string()
            } else {
                s.progress.activity.clone()
            };
            ui.add_space(4.0);
            ui.add(
                Label::new(
                    RichText::new(format!("⎿  {activity}"))
                        .font(mono(11.0))
                        .color(MUTED),
                )
                .truncate(),
            );
            ui.add_space(2.0);
        });
    }

    // ------------------------------------------------------------ settings page

    fn settings_page(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) {
        ui.set_width(ui.available_width());
        let mut changed = false;

        section(ui, self.strings.t("General"));
        let mut startup = self.startup_enabled;
        if toggle_row(ui, &self.strings, "Startup", "StartupD", &mut startup) {
            self.startup_enabled = startup;
            actions.push(Action::Startup(startup));
        }
        if toggle_row(
            ui,
            &self.strings,
            "Topmost",
            "TopmostD",
            &mut self.settings.topmost,
        ) {
            actions.push(Action::Topmost(self.settings.topmost));
            changed = true;
        }
        let open_opts = [
            ("icon", self.strings.t("OIcon")),
            ("card", self.strings.t("OCard")),
            ("last", self.strings.t("OLast")),
        ];
        let open_opts: Vec<(String, String)> = open_opts
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect();
        changed |= pill_row(
            ui,
            &self.strings,
            "OpenMode",
            "OpenModeD",
            &open_opts,
            &mut self.settings.open_mode,
        );

        let mut langs = vec![("auto".to_string(), self.strings.t("LAuto").to_string())];
        langs.extend(
            i18n::available()
                .into_iter()
                .map(|(c, n)| (c.to_string(), n)),
        );
        if pill_row(
            ui,
            &self.strings,
            "Language",
            "LanguageD",
            &langs,
            &mut self.settings.language,
        ) {
            self.strings = Strings::load(&self.settings.language);
            actions.push(Action::LanguageChanged);
            changed = true;
        }
        let opacity: Vec<(String, String)> = [100, 90, 80, 70, 60]
            .iter()
            .map(|v| (v.to_string(), format!("{v}%")))
            .collect();
        let mut op = self.settings.opacity.to_string();
        if pill_row(ui, &self.strings, "Opacity", "OpacityD", &opacity, &mut op) {
            self.settings.opacity = op.parse().unwrap_or(100);
            changed = true;
        }

        section(ui, self.strings.t("Notifications"));
        changed |= toggle_row(
            ui,
            &self.strings,
            "Notify",
            "NotifyD",
            &mut self.settings.notify,
        );
        changed |= toggle_row(
            ui,
            &self.strings,
            "Blink",
            "BlinkD",
            &mut self.settings.blink,
        );

        section(ui, self.strings.t("Data"));
        if toggle_row(
            ui,
            &self.strings,
            "Cli",
            "CliD",
            &mut self.settings.show_cli,
        ) {
            actions.push(Action::FeedChanged);
            changed = true;
        }
        let sec = self.strings.t("Sec").to_string();
        let refresh: Vec<(String, String)> = [2, 3, 5, 10]
            .iter()
            .map(|v| (v.to_string(), format!("{v} {sec}")))
            .collect();
        let mut r = self.settings.refresh_sec.to_string();
        if pill_row(ui, &self.strings, "Refresh", "RefreshD", &refresh, &mut r) {
            self.settings.refresh_sec = r.parse().unwrap_or(3);
            actions.push(Action::FeedChanged);
            changed = true;
        }
        let (min, hr) = (
            self.strings.t("Min").to_string(),
            self.strings.t("Hr").to_string(),
        );
        let keep = vec![
            ("15".to_string(), format!("15 {min}")),
            ("30".to_string(), format!("30 {min}")),
            ("60".to_string(), format!("1 {hr}")),
        ];
        let mut k = self.settings.keep_min.to_string();
        if pill_row(ui, &self.strings, "Keep", "KeepD", &keep, &mut k) {
            self.settings.keep_min = k.parse().unwrap_or(30);
            changed = true;
        }

        ui.add_space(10.0);
        separator(ui, 1.0);
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            ui.label(
                RichText::new(self.strings.f("Version", &[self.version]))
                    .font(regular(11.0))
                    .color(MUTED),
            );
            if ui
                .add(
                    Label::new(RichText::new("GitHub").font(regular(11.0)).color(ACCENT))
                        .sense(Sense::click()),
                )
                .clicked()
            {
                actions.push(Action::OpenUrl(REPO_URL.to_string()));
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if text_button(ui, self.strings.t("Quit")).clicked() {
                    actions.push(Action::Quit);
                }
            });
        });
        if changed {
            actions.push(Action::SaveSettings);
        }
    }
}

// ----------------------------------------------------------------- helpers

pub fn elapsed(s: &Strings, ms: f64) -> String {
    let secs = (ms / 1000.0).round().max(0.0) as u64;
    if secs < 60 {
        return format!("{secs} {}", s.t("Sec"));
    }
    let m = secs / 60;
    if m < 60 {
        return format!("{m} {}", s.t("Min"));
    }
    format!("{} {} {} {}", m / 60, s.t("Hr"), m % 60, s.t("Min"))
}

fn separator(ui: &mut Ui, alpha: f32) {
    let rect = ui.available_rect_before_wrap();
    let y = ui.cursor().top();
    ui.painter().hline(
        rect.x_range(),
        y,
        Stroke::new(1.0_f32, LINE.gamma_multiply(alpha)),
    );
    ui.add_space(1.0);
}

fn section(ui: &mut Ui, title: &str) {
    ui.add_space(10.0);
    ui.label(RichText::new(title).font(semibold(10.0)).color(MUTED));
    ui.add_space(2.0);
}

fn icon_button(ui: &mut Ui, glyph: &str, tip: &str, active: bool) -> Response {
    let (rect, resp) = ui.allocate_exact_size(vec2(26.0, 26.0), Sense::click());
    let color = if active {
        ACCENT
    } else if resp.hovered() {
        TEXT
    } else {
        MUTED
    };
    if resp.hovered() {
        ui.painter().rect_filled(rect, CornerRadius::same(6), BG2);
    }
    ui.painter().text(
        rect.center(),
        Align2::CENTER_CENTER,
        glyph,
        icons(11.0),
        color,
    );
    resp.on_hover_text(tip)
}

fn text_button(ui: &mut Ui, text: &str) -> Response {
    let galley = ui
        .painter()
        .layout_no_wrap(text.to_string(), regular(11.0), MUTED);
    let (rect, resp) = ui.allocate_exact_size(galley.size() + vec2(16.0, 8.0), Sense::click());
    if resp.hovered() {
        ui.painter().rect_filled(rect, CornerRadius::same(5), BG2);
    }
    let color = if resp.hovered() { TEXT } else { MUTED };
    ui.painter().text(
        rect.center(),
        Align2::CENTER_CENTER,
        text,
        regular(11.0),
        color,
    );
    resp
}

/// Toggle switch; returns true when clicked (and flips `on`).
fn toggle(ui: &mut Ui, on: &mut bool) -> bool {
    let (rect, resp) = ui.allocate_exact_size(vec2(36.0, 20.0), Sense::click());
    if resp.clicked() {
        *on = !*on;
    }
    let p = ui.painter();
    p.rect_filled(
        rect,
        CornerRadius::same(10),
        if *on { ACCENT } else { LINE },
    );
    let x = if *on {
        rect.right() - 10.0
    } else {
        rect.left() + 10.0
    };
    p.circle_filled(
        pos2(x, rect.center().y),
        7.0,
        if *on { Color32::WHITE } else { TEXT2 },
    );
    resp.clicked()
}

fn pill(ui: &mut Ui, text: &str, selected: bool) -> Response {
    let galley = ui
        .painter()
        .layout_no_wrap(text.to_string(), regular(11.0), TEXT2);
    let (rect, resp) = ui.allocate_exact_size(galley.size() + vec2(20.0, 9.0), Sense::click());
    let (fill, stroke, color) = if selected {
        (ACCENT, ACCENT, INK)
    } else if resp.hovered() {
        (BG2, MUTED, TEXT2)
    } else {
        (BG2, LINE, TEXT2)
    };
    let p = ui.painter();
    p.rect_filled(rect, CornerRadius::same(6), fill);
    p.rect_stroke(
        rect,
        CornerRadius::same(6),
        Stroke::new(1.0_f32, stroke),
        StrokeKind::Inside,
    );
    p.text(
        rect.center(),
        Align2::CENTER_CENTER,
        text,
        regular(11.0),
        color,
    );
    resp
}

fn labels(ui: &mut Ui, s: &Strings, title: &str, desc: &str) {
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing.y = 1.0;
        ui.label(RichText::new(s.t(title)).font(regular(12.5)).color(TEXT));
        ui.add(Label::new(RichText::new(s.t(desc)).font(regular(11.0)).color(MUTED)).wrap());
    });
}

fn toggle_row(ui: &mut Ui, s: &Strings, title: &str, desc: &str, value: &mut bool) -> bool {
    let mut clicked = false;
    ui.add_space(6.0);
    ui.horizontal(|ui| {
        let w = ui.available_width();
        ui.allocate_ui_with_layout(vec2(w - 48.0, 0.0), Layout::top_down(Align::Min), |ui| {
            labels(ui, s, title, desc)
        });
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            clicked = toggle(ui, value)
        });
    });
    clicked
}

/// Title, description, then a line of pills. Returns true when the value changed.
fn pill_row(
    ui: &mut Ui,
    s: &Strings,
    title: &str,
    desc: &str,
    options: &[(String, String)],
    value: &mut String,
) -> bool {
    let mut changed = false;
    ui.add_space(6.0);
    labels(ui, s, title, desc);
    ui.add_space(4.0);
    ui.horizontal_wrapped(|ui| {
        ui.spacing_mut().item_spacing = vec2(5.0, 5.0);
        for (key, text) in options {
            if pill(ui, text, value == key).clicked() && value != key {
                *value = key.clone();
                changed = true;
            }
        }
    });
    changed
}

#[cfg(test)]
mod tests {
    use super::*;
    use egui::{Context, Event, Modifiers, PointerButton, Pos2, RawInput};

    fn card() -> (Context, Widget) {
        let ctx = Context::default();
        let have_mdl2 = install(&ctx);
        let mut w = Widget::new(Settings::default(), have_mdl2, "test");
        w.set_expanded(true);
        (ctx, w)
    }

    /// Runs one frame per event list and collects the actions.
    fn frames(ctx: &Context, w: &mut Widget, frames: Vec<Vec<Event>>) -> Vec<Action> {
        let mut actions = Vec::new();
        for events in frames {
            let input = RawInput {
                screen_rect: Some(Rect::from_min_size(Pos2::ZERO, w.desired_size())),
                events,
                ..Default::default()
            };
            let _ = ctx.run_ui(input, |ui| actions.extend(w.draw(ui, 0.0)));
        }
        actions
    }

    fn button(pos: Pos2, pressed: bool) -> Event {
        Event::PointerButton {
            pos,
            button: PointerButton::Primary,
            pressed,
            modifiers: Modifiers::default(),
        }
    }

    fn session(id: &str, waiting: Option<Waiting>) -> Session {
        Session {
            id: id.into(),
            name: format!("name-{id}"),
            cwd: String::new(),
            location: Location::Local,
            since_ms: 0.0,
            progress: Default::default(),
            waiting,
        }
    }

    #[test]
    fn waiting_sessions_notify_and_never_count_as_finished() {
        let (_, mut w) = card();
        let ask = || Some(Waiting::Question("Merge?".into()));
        assert!(w.set_sessions(vec![session("a", None)], 0.0).is_empty());

        // a stops to ask a question: a notification, and it is not finished.
        let acts = w.set_sessions(vec![session("a", ask())], 1.0);
        assert!(
            matches!(&acts[..], [Action::Notify { title, body }]
                if title == w.strings.t("WaitTitle") && body == "name-a"),
            "{acts:?}"
        );
        assert!(w.finished.is_empty());
        assert_eq!((w.working(), w.waiting()), (0, 1));

        // Still waiting: no second notification.
        assert!(w.set_sessions(vec![session("a", ask())], 2.0).is_empty());

        // The question drops out (too old): not reported as finished.
        assert!(w.set_sessions(vec![], 3.0).is_empty());
        assert!(w.finished.is_empty());

        // A working session that ends is finished, as before.
        w.set_sessions(vec![session("b", None)], 4.0);
        w.set_sessions(vec![], 5.0);
        assert_eq!(w.finished.len(), 1);
        assert_eq!(w.finished[0].id, "b");
    }

    #[test]
    fn header_buttons_get_their_clicks() {
        let (ctx, mut w) = card();
        // The close button: right edge of the header (card padding 14, button 26 wide).
        let at = pos2(CARD_WIDTH - 14.0 - 13.0, 10.0 + 17.0);
        let actions = frames(
            &ctx,
            &mut w,
            vec![
                vec![],
                vec![Event::PointerMoved(at)],
                vec![button(at, true)],
                vec![button(at, false)],
            ],
        );
        assert!(actions.contains(&Action::Hide), "{actions:?}");
        assert!(!actions.contains(&Action::StartDrag), "{actions:?}");
    }

    #[test]
    fn header_title_drags_the_window() {
        let (ctx, mut w) = card();
        let at = pos2(120.0, 27.0);
        let actions = frames(
            &ctx,
            &mut w,
            vec![
                vec![],
                vec![Event::PointerMoved(at)],
                vec![button(at, true)],
                vec![Event::PointerMoved(at + vec2(20.0, 10.0))],
            ],
        );
        assert!(actions.contains(&Action::StartDrag), "{actions:?}");
    }
}
