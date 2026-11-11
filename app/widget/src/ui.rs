//! The widget's UI, independent of the window: the bubble, the card with accordion
//! session rows, the finished list and the settings page. It never touches the OS;
//! it returns [`Action`]s for the shell (window, tray, settings file) to carry out.

use crate::i18n::{self, Strings};
use crate::settings::Settings;
use crate::theme::*;
use claude_session_core::model::FINISHING;
use claude_session_core::{Location, Session, StepStatus};
use egui::{
    Align, Align2, Color32, CornerRadius, Label, Layout, Rect, Response, RichText, Sense, Stroke,
    StrokeKind, Ui, UiBuilder, Vec2, pos2, vec2,
};
use std::collections::{HashMap, HashSet};

pub const CARD_WIDTH: f32 = 380.0;
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
    /// Window mode: the OS rounds the corners; screenshots draw their own frame.
    pub window_mode: bool,
    pub version: &'static str,
    open_rows: HashSet<String>,
    prev: Option<HashMap<String, String>>,
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
            window_mode: true,
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

    /// New scan result. Sessions that disappeared are finished.
    pub fn set_sessions(&mut self, list: Vec<Session>, now_ms: f64) -> Vec<Action> {
        let mut actions = Vec::new();
        let current: HashMap<String, String> = list
            .iter()
            .map(|s| (s.id.clone(), s.name.clone()))
            .collect();
        if let Some(prev) = &self.prev {
            let ended: Vec<(String, String)> = prev
                .iter()
                .filter(|(id, _)| !current.contains_key(*id))
                .map(|(a, b)| (a.clone(), b.clone()))
                .collect();
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
        let n = self.sessions.len();
        let (glyph_color, ring) = if self.unseen > 0 && self.settings.blink {
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
        let badge = if self.unseen > 0 {
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
        if self.window_mode {
            p.rect_filled(full, CornerRadius::ZERO, BG);
            p.rect_stroke(
                full,
                CornerRadius::same(8),
                Stroke::new(1.0_f32, LINE),
                StrokeKind::Inside,
            );
        } else {
            p.rect_filled(full, CornerRadius::same(12), BG);
            p.rect_stroke(
                full,
                CornerRadius::same(12),
                Stroke::new(1.0_f32, LINE),
                StrokeKind::Inside,
            );
        }

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
        // Drag the window by the header (buttons keep their clicks).
        let drag = ui.interact(
            row.response.rect,
            ui.id().with("header-drag"),
            Sense::drag(),
        );
        if drag.drag_started() {
            actions.push(Action::StartDrag);
        }
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
        let n = self.sessions.len();
        let mut sub = if n > 0 {
            s.f("NRunning", &[&n.to_string()])
        } else {
            s.t("NoWork").to_string()
        };
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
        for i in 0..self.sessions.len() {
            if i > 0 {
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
