//! Claude Session Widget 2.0 — phase 0 spike.
//!
//! A borderless, always-on-top egui window drawn on the CPU (egui_software_backend +
//! softbuffer, no GPU driver loaded) plus a tray icon, with fixed demo data.
//! Measured on Windows 11: ~27 MB working set, 0 % CPU when idle, 3.9 MB binary.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use egui::{
    Align, Color32, CornerRadius, FontId, Layout, Margin, RichText, Sense, Stroke, Vec2,
    ViewportCommand,
};
use std::sync::mpsc;
use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{MouseButton, TrayIcon, TrayIconBuilder, TrayIconEvent};

// Colours shared with 1.x
const BG: Color32 = Color32::from_rgb(0x26, 0x26, 0x24);
const BG2: Color32 = Color32::from_rgb(0x30, 0x30, 0x2E);
const LINE: Color32 = Color32::from_rgb(0x3D, 0x3D, 0x3A);
const TEXT: Color32 = Color32::from_rgb(0xF0, 0xEE, 0xE6);
const TEXT2: Color32 = Color32::from_rgb(0xC2, 0xC0, 0xB6);
const MUTED: Color32 = Color32::from_rgb(0x8F, 0x8D, 0x86);
const ACCENT: Color32 = Color32::from_rgb(0xD9, 0x77, 0x57);
const GREEN: Color32 = Color32::from_rgb(0x7F, 0xB7, 0x7E);

const CARD_SIZE: Vec2 = Vec2::new(380.0, 420.0);
const BUBBLE_SIZE: Vec2 = Vec2::new(64.0, 64.0);
const EDGE_GAP: f32 = 12.0;

#[derive(Clone, Copy, PartialEq)]
enum Status {
    Done,
    Current,
    Pending,
}

struct Session {
    name: &'static str,
    place: &'static str,
    minutes: u32,
    steps: Vec<(&'static str, Status)>,
    activity: &'static str,
    open: bool,
}

impl Session {
    fn done(&self) -> usize {
        self.steps.iter().filter(|s| s.1 == Status::Done).count()
    }
}

enum UiEvent {
    ToggleCard,
    Quit,
}

struct Widget {
    sessions: Vec<Session>,
    expanded: bool,
    placed: bool,
    events: mpsc::Receiver<UiEvent>,
    _tray: TrayIcon,
}

impl Widget {
    fn new(ctx: egui::Context) -> Self {
        style(&ctx);

        // Tray icon and menu. Their callbacks run on other threads: forward to the
        // UI through a channel and wake egui, which otherwise sleeps.
        let (tx, rx) = mpsc::channel();
        let show = MenuItem::new("Show / hide", true, None);
        let quit = MenuItem::new("Quit", true, None);
        let menu = Menu::new();
        menu.append(&show).ok();
        menu.append(&quit).ok();
        let (show_id, quit_id) = (show.id().clone(), quit.id().clone());

        let tx_menu = tx.clone();
        let ctx_menu = ctx.clone();
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            let ev = if e.id == quit_id {
                Some(UiEvent::Quit)
            } else if e.id == show_id {
                Some(UiEvent::ToggleCard)
            } else {
                None
            };
            if let Some(ev) = ev {
                tx_menu.send(ev).ok();
                ctx_menu.request_repaint();
            }
        }));
        let ctx_tray = ctx.clone();
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            if let TrayIconEvent::Click { button: MouseButton::Left, .. } = e {
                tx.send(UiEvent::ToggleCard).ok();
                ctx_tray.request_repaint();
            }
        }));

        let tray = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_menu_on_left_click(false)
            .with_tooltip("Claude Session Widget")
            .with_icon(tray_icon_image())
            .build()
            .expect("tray icon");

        Self {
            sessions: demo_sessions(),
            expanded: true,
            placed: false,
            events: rx,
            _tray: tray,
        }
    }

    fn set_expanded(&mut self, ctx: &egui::Context, expanded: bool) {
        self.expanded = expanded;
        let size = if expanded { CARD_SIZE } else { BUBBLE_SIZE };
        ctx.send_viewport_cmd(ViewportCommand::InnerSize(size));
        self.placed = false; // re-anchor bottom-right after the resize
    }

    /// Keeps the window's bottom-right corner above the taskbar.
    fn place(&mut self, ctx: &egui::Context) {
        if self.placed {
            return;
        }
        let monitor = ctx.input(|i| i.viewport().monitor_size);
        if let Some(m) = monitor {
            let size = if self.expanded { CARD_SIZE } else { BUBBLE_SIZE };
            let pos = egui::pos2(m.x - size.x - EDGE_GAP, m.y - size.y - EDGE_GAP - 48.0);
            ctx.send_viewport_cmd(ViewportCommand::OuterPosition(pos));
            self.placed = true;
        }
    }

    fn card(&mut self, ui: &mut egui::Ui) {
        let ctx = ui.ctx().clone();
        egui::Frame::new()
            .fill(BG)
            .stroke(Stroke::new(1.0, LINE))
            .corner_radius(CornerRadius::same(12))
            .inner_margin(Margin::symmetric(14, 10))
            .show(ui, |ui| {
                ui.set_min_size(ui.available_size());

                // Header: drag to move, buttons on the right
                let header = ui.horizontal(|ui| {
                    ui.label(RichText::new("✻").color(ACCENT).size(18.0));
                    ui.vertical(|ui| {
                        ui.label(RichText::new("Active sessions").color(TEXT).strong().size(13.0));
                        let running = self.sessions.len();
                        ui.label(RichText::new(format!("{running} running")).color(MUTED).size(11.0));
                    });
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui.add(egui::Button::new(RichText::new("—").color(MUTED)).frame(false)).clicked() {
                            self.set_expanded(&ctx, false);
                        }
                    });
                });
                let drag = ui.interact(header.response.rect, ui.id().with("drag"), Sense::drag());
                if drag.drag_started() {
                    ctx.send_viewport_cmd(ViewportCommand::StartDrag);
                }

                ui.add_space(6.0);
                ui.painter().hline(ui.max_rect().x_range(), ui.cursor().top(), Stroke::new(1.0, LINE));
                ui.add_space(8.0);

                egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                    for (i, s) in self.sessions.iter_mut().enumerate() {
                        if i > 0 {
                            ui.add_space(4.0);
                            ui.painter().hline(ui.max_rect().x_range(), ui.cursor().top(), Stroke::new(1.0, BG2));
                            ui.add_space(6.0);
                        }
                        session_row(ui, s);
                    }
                });
            });
    }

    fn bubble(&mut self, ui: &mut egui::Ui) {
        let rect = ui.max_rect().shrink(4.0);
        let resp = ui.allocate_rect(rect, Sense::click_and_drag());
        let p = ui.painter();
        p.circle(rect.center(), rect.width() / 2.0, BG, Stroke::new(1.5, LINE));
        p.text(rect.center(), egui::Align2::CENTER_CENTER, "✻", FontId::proportional(26.0), ACCENT);
        let n = self.sessions.len();
        let badge = rect.right_top() + egui::vec2(-8.0, 8.0);
        p.circle_filled(badge, 9.0, ACCENT);
        p.text(badge, egui::Align2::CENTER_CENTER, n.to_string(), FontId::proportional(11.0), BG);
        if resp.drag_started() {
            ui.ctx().send_viewport_cmd(ViewportCommand::StartDrag);
        } else if resp.clicked() {
            let ctx = ui.ctx().clone();
            self.set_expanded(&ctx, true);
        }
    }
}

impl egui_software_backend::App for Widget {
    fn ui(&mut self, ui: &mut egui::Ui, _backend: &mut egui_software_backend::SoftwareBackend) {
        let ctx = ui.ctx().clone();
        while let Ok(ev) = self.events.try_recv() {
            match ev {
                UiEvent::ToggleCard => {
                    let open = !self.expanded;
                    self.set_expanded(&ctx, open);
                }
                UiEvent::Quit => ctx.send_viewport_cmd(ViewportCommand::Close),
            }
        }
        self.place(&ctx);
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(BG))
            .show_inside(ui, |ui| {
                if self.expanded { self.card(ui); } else { self.bubble(ui); }
            });
    }
}

fn session_row(ui: &mut egui::Ui, s: &mut Session) {
    let total = s.steps.len();
    let done = s.done();

    // Title row (click to expand / collapse)
    let title = ui.horizontal(|ui| {
        ui.label(RichText::new(if s.open { "⏷" } else { "⏵" }).color(MUTED).size(10.0));
        ui.label(RichText::new(s.name).color(TEXT).strong().size(13.0));
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.label(RichText::new(format!("{} min", s.minutes)).color(MUTED).size(11.0));
        });
    });
    if ui.interact(title.response.rect, ui.id().with(s.name), Sense::click()).clicked() {
        s.open = !s.open;
    }

    // Progress bar
    ui.horizontal(|ui| {
        ui.add_space(16.0);
        let frac = if total > 0 { done as f32 / total as f32 } else { 0.0 };
        let width = ui.available_width() - 70.0;
        ui.add(
            egui::ProgressBar::new(frac)
                .desired_width(width)
                .desired_height(5.0)
                .fill(ACCENT)
                .corner_radius(CornerRadius::same(3)),
        );
        let label = if total > 0 { format!("{done}/{total}  {}%", (frac * 100.0).round()) } else { "—".into() };
        ui.label(RichText::new(label).color(TEXT2).size(11.0));
    });

    if !s.open {
        return;
    }
    ui.indent(s.name, |ui| {
        ui.label(RichText::new(s.place).color(MUTED).size(11.0));
        for (text, status) in &s.steps {
            let (mark, mc, tc) = match status {
                Status::Done => ("✓", GREEN, TEXT2),
                Status::Current => ("▸", ACCENT, TEXT),
                Status::Pending => ("○", MUTED, MUTED),
            };
            ui.horizontal(|ui| {
                ui.label(RichText::new(mark).color(mc).size(12.0));
                ui.label(RichText::new(*text).color(tc).size(12.0));
            });
        }
        ui.label(RichText::new(format!("⎿  {}", s.activity)).color(MUTED).monospace().size(11.0));
    });
}

fn style(ctx: &egui::Context) {
    ctx.all_styles_mut(|s| {
        s.visuals.panel_fill = Color32::TRANSPARENT;
        s.visuals.window_fill = BG;
        s.visuals.extreme_bg_color = LINE; // progress-bar track
        s.visuals.override_text_color = Some(TEXT);
        s.spacing.item_spacing = egui::vec2(6.0, 4.0);
    });
}

/// 32×32 RGBA tray image: dark disc with an orange dot (the real icon comes in phase 2).
fn tray_icon_image() -> tray_icon::Icon {
    let n = 32u32;
    let mut rgba = Vec::with_capacity((n * n * 4) as usize);
    for y in 0..n {
        for x in 0..n {
            let (dx, dy) = (x as f32 - 15.5, y as f32 - 15.5);
            let d = (dx * dx + dy * dy).sqrt();
            let px = if d < 6.0 {
                [0xD9, 0x77, 0x57, 0xFF]
            } else if d < 15.5 {
                [0x26, 0x26, 0x24, 0xFF]
            } else {
                [0, 0, 0, 0]
            };
            rgba.extend_from_slice(&px);
        }
    }
    tray_icon::Icon::from_rgba(rgba, n, n).expect("tray image")
}

fn demo_sessions() -> Vec<Session> {
    use Status::*;
    vec![
        Session {
            name: "Refactor auth module",
            place: "Local · acme-web",
            minutes: 7,
            steps: vec![
                ("Read the current auth flow", Done),
                ("Extract token helpers", Done),
                ("Update login handler", Done),
                ("Run the test suite", Current),
                ("Summarize the changes", Pending),
            ],
            activity: "Bash · Run unit tests",
            open: true,
        },
        Session {
            name: "Write API docs",
            place: "WSL · Ubuntu · acme-api",
            minutes: 3,
            steps: vec![("Collect endpoints", Done), ("Draft reference", Current), ("Examples", Pending), ("Review", Pending)],
            activity: "Read · src/routes/users.ts",
            open: false,
        },
        Session {
            name: "Fix flaky CI job",
            place: "Terminal · acme-ci",
            minutes: 1,
            steps: vec![],
            activity: "Grep · retry",
            open: false,
        },
    ]
}

fn main() {
    let settings = egui_software_backend::SoftwareBackendAppConfiguration::new()
        .inner_size(Some(CARD_SIZE))
        .title(Some(String::from("Claude Session Widget")))
        .decorations(Some(false))
        .window_level(Some(egui::WindowLevel::AlwaysOnTop));
    egui_software_backend::run_app_with_software_backend(settings, Widget::new).expect("run");
}
