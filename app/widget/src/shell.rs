//! Runs the [`Widget`] in a real window: scan results, tray, window shape/size/
//! position/opacity, settings file, notifications. Repaints only when something
//! changes (new scan result, input, blink tick, the minute labels).

use crate::feed::{self, FeedControl};
use crate::platform::{self, Hwnd};
use crate::settings::Settings;
use crate::tray::{Tray, TrayCmd, TrayImage, TrayLabels};
use crate::ui::{Action, BUBBLE_BADGE, BUBBLE_DISC, CARD_RADIUS, Page, Widget};
use crate::{TITLE, theme};
use claude_session_core::{Session, now_ms};
use egui::{Context, Vec2, ViewportCommand};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU32, Ordering};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

const BLINK: Duration = Duration::from_millis(550);

pub struct Shell {
    w: Widget,
    demo: bool,
    feed: Option<Receiver<Vec<Session>>>,
    control: FeedControl,
    tray: Option<Tray>,
    tray_rx: Option<Receiver<TrayCmd>>,
    hwnd: Arc<AtomicIsize>,
    prepared: bool,
    requested_size: Option<Vec2>,
    /// Expanded, scale (%) and size (px) the window region was made for.
    applied_shape: Option<(bool, i32, i32, i32)>,
    applied_topmost: Option<bool>,
    applied_alpha: Option<u8>,
    applied_hidden: Option<bool>,
    dragging: bool,
    next_blink: Instant,
}

impl Shell {
    pub fn new(ctx: Context, mut w: Widget, demo: bool) -> Self {
        let have_mdl2 = theme::install(&ctx);
        w.glyphs = theme::glyphs(have_mdl2);
        w.startup_enabled = platform::startup_enabled();
        let control = FeedControl {
            include_terminal: Arc::new(AtomicBool::new(w.settings.show_cli)),
            refresh_sec: Arc::new(AtomicU32::new(w.settings.refresh_sec)),
        };
        let feed = (!demo).then(|| {
            let c = ctx.clone();
            feed::start(control.clone(), move || c.request_repaint())
        });
        let hwnd = Arc::new(AtomicIsize::new(0));
        let c = ctx.clone();
        let (tray, rx) = Tray::new(labels(&w), w.settings.topmost, move |_| c.request_repaint());
        Self {
            w,
            demo,
            feed,
            control,
            tray: Some(tray),
            tray_rx: Some(rx),
            hwnd,
            prepared: false,
            requested_size: None,
            applied_shape: None,
            applied_topmost: None,
            applied_alpha: None,
            applied_hidden: None,
            dragging: false,
            next_blink: Instant::now(),
        }
    }

    fn hwnd(&self) -> Option<Hwnd> {
        let h = self.hwnd.load(Ordering::Relaxed);
        (h != 0).then_some(h)
    }

    fn prepare(&mut self) {
        if self.prepared {
            return;
        }
        if let Some(h) = platform::find_own_window(TITLE) {
            self.hwnd.store(h, Ordering::Relaxed);
            platform::make_tool_window(h);
            self.prepared = true;
        }
    }

    fn save(&self) {
        if !self.demo {
            self.w.settings.save();
        }
    }

    fn handle(&mut self, action: Action, ctx: &Context) {
        match action {
            Action::StartDrag => {
                self.dragging = true;
                ctx.send_viewport_cmd(ViewportCommand::StartDrag);
            }
            Action::Hide => self.w.visible = false,
            Action::Quit => {
                self.save();
                ctx.send_viewport_cmd(ViewportCommand::Close);
            }
            Action::SaveSettings => self.save(),
            Action::LanguageChanged => {
                if let Some(t) = &self.tray {
                    t.set_labels(&labels(&self.w));
                }
            }
            Action::Topmost(on) => {
                if let Some(t) = &self.tray {
                    t.set_topmost(on);
                }
            }
            Action::Startup(on) => {
                if !self.demo {
                    platform::set_startup(on);
                }
            }
            Action::FeedChanged => {
                self.control
                    .include_terminal
                    .store(self.w.settings.show_cli, Ordering::Relaxed);
                self.control
                    .refresh_sec
                    .store(self.w.settings.refresh_sec, Ordering::Relaxed);
            }
            Action::OpenUrl(url) => platform::open_url(&url),
            Action::Notify { title, body } => {
                if let Some(t) = &self.tray {
                    platform::notify(t.hwnd(), &title, &body);
                }
            }
        }
    }

    fn tray_cmd(&mut self, cmd: TrayCmd, ctx: &Context) {
        match cmd {
            TrayCmd::Toggle => {
                if !self.w.visible {
                    self.w.visible = true;
                    self.w.set_expanded(true);
                } else {
                    let open = !self.w.expanded;
                    self.w.set_expanded(open);
                }
                self.save();
            }
            TrayCmd::Show => {
                self.w.visible = true;
                self.w.set_expanded(true);
            }
            TrayCmd::Settings => {
                self.w.visible = true;
                self.w.set_expanded(true);
                self.w.page = Page::Settings;
            }
            TrayCmd::Topmost => {
                self.w.settings.topmost = !self.w.settings.topmost;
                if let Some(t) = &self.tray {
                    t.set_topmost(self.w.settings.topmost);
                }
                self.save();
            }
            TrayCmd::Quit => self.handle(Action::Quit, ctx),
        }
    }

    /// Applies size, shape, position, opacity and z-order to the OS window.
    fn sync_window(&mut self, ctx: &Context) {
        let want = self.w.desired_size();
        if self.requested_size != Some(want) {
            ctx.send_viewport_cmd(ViewportCommand::InnerSize(want));
            self.requested_size = Some(want);
        }
        let Some(h) = self.hwnd() else { return };
        let Some(r) = platform::window_rect(h) else {
            return;
        };
        let scale = platform::dpi_scale(h);
        let (w, hgt) = (r[2] - r[0], r[3] - r[1]);
        let size_ok = (w - (want.x * scale).round() as i32).abs() <= 2
            && (hgt - (want.y * scale).round() as i32).abs() <= 2;

        // Shape: rounded card, or the bubble's circles.
        // Corners are cut with a window region, not the system's rounded corners: those come
        // with a drop shadow that looks out of place around a small floating widget.
        let shape = (self.w.expanded, (scale * 100.0) as i32, w, hgt);
        if size_ok && self.applied_shape != Some(shape) {
            if self.w.expanded {
                platform::set_round_corners(h, false);
                platform::set_round_rect_region(h, w, hgt, (CARD_RADIUS * scale).round() as i32);
            } else {
                let s = |(x, y, rad): (f32, f32, f32)| (x * scale, y * scale, rad * scale + 1.0);
                platform::set_circle_region(h, Some(&[s(BUBBLE_DISC), s(BUBBLE_BADGE)]));
                platform::set_round_corners(h, false);
            }
            self.applied_shape = Some(shape);
        }

        // Position: keep the bottom-right corner on the saved anchor.
        // The anchor is stored in points at the system scale (one space for all monitors,
        // as in 1.x), not at the window's own monitor scale.
        let sys = platform::system_scale() as f64;
        if self.dragging {
            let down = platform::primary_button_down()
                .unwrap_or_else(|| ctx.input(|i| i.pointer.any_down()));
            if down {
                // The system's move loop does not wake the UI when it ends; check again soon.
                ctx.request_repaint_after(Duration::from_millis(100));
            } else {
                self.dragging = false;
                self.w.settings.right = r[2] as f64 / sys;
                self.w.settings.bottom = r[3] as f64 / sys;
                self.save();
            }
        } else if size_ok {
            let target = match self.w.settings.anchor() {
                Some((right, bottom)) => {
                    let (ax, ay) = ((right * sys).round() as i32, (bottom * sys).round() as i32);
                    platform::work_area_near(ax - 1, ay - 1).map(|area| (ax, ay, area))
                }
                None => platform::work_area(h).map(|area| {
                    let m = (4.0 * scale).round() as i32;
                    (area[2] - m, area[3] - m, area)
                }),
            };
            if let Some((ax, ay, area)) = target {
                let x = (ax - w).clamp(area[0], (area[2] - w).max(area[0]));
                let y = (ay - hgt).clamp(area[1], (area[3] - hgt).max(area[1]));
                if (x - r[0]).abs() > 1 || (y - r[1]).abs() > 1 {
                    platform::move_window(h, x, y);
                }
            }
        }

        // Opacity: fully transparent and click-through while hidden; opaque under the mouse.
        let hovered = ctx.input(|i| i.pointer.hover_pos().is_some());
        let alpha = if !self.w.visible {
            0
        } else if hovered || self.dragging {
            255
        } else {
            (self.w.settings.opacity.clamp(30, 100) * 255 / 100) as u8
        };
        if self.applied_alpha != Some(alpha) {
            platform::set_alpha(h, alpha);
            self.applied_alpha = Some(alpha);
        }
        let hidden = !self.w.visible;
        if self.applied_hidden != Some(hidden) {
            platform::set_click_through(h, hidden);
            self.applied_hidden = Some(hidden);
        }
        if self.applied_topmost != Some(self.w.settings.topmost) {
            platform::set_topmost(h, self.w.settings.topmost);
            self.applied_topmost = Some(self.w.settings.topmost);
        }
    }
}

impl egui_software_backend::App for Shell {
    fn ui(&mut self, ui: &mut egui::Ui, _backend: &mut egui_software_backend::SoftwareBackend) {
        let ctx = ui.ctx().clone();
        let now = now_ms();
        self.prepare();

        let mut actions = Vec::new();
        if let Some(rx) = &self.feed {
            while let Ok(list) = rx.try_recv() {
                actions.extend(self.w.set_sessions(list, now));
            }
        }
        let cmds: Vec<TrayCmd> = self
            .tray_rx
            .as_ref()
            .map(|rx| rx.try_iter().collect())
            .unwrap_or_default();
        for cmd in cmds {
            self.tray_cmd(cmd, &ctx);
        }

        // Blink while a finished job is unseen (and the card is not showing it).
        let blinking =
            self.w.unseen > 0 && self.w.settings.blink && !(self.w.expanded && self.w.visible);
        if blinking {
            let t = Instant::now();
            if t >= self.next_blink {
                self.w.blink_on = !self.w.blink_on;
                self.next_blink = t + BLINK;
            }
            ctx.request_repaint_after(self.next_blink.saturating_duration_since(t));
        } else {
            self.w.blink_on = false;
        }

        actions.extend(self.w.draw(ui, now));
        for a in actions {
            self.handle(a, &ctx);
        }
        self.sync_window(&ctx);

        if let Some(t) = &mut self.tray {
            let image = if self.w.unseen > 0 && self.w.settings.blink {
                if self.w.blink_on {
                    TrayImage::Done
                } else {
                    TrayImage::Dim
                }
            } else if self.w.unseen > 0 {
                TrayImage::Done
            } else {
                TrayImage::Normal
            };
            t.set_image(image);
            t.set_tooltip(&format!("Claude: {}", self.w.subtitle()));
        }

        // Keep the "x min" labels current, without polling when nothing is listed.
        if self.w.expanded
            && self.w.visible
            && (!self.w.sessions.is_empty() || !self.w.finished.is_empty())
        {
            ctx.request_repaint_after(Duration::from_secs(30));
        }
    }
}

fn labels(w: &Widget) -> TrayLabels {
    let s = &w.strings;
    TrayLabels {
        show: s.t("Show").into(),
        settings: s.t("SettingsMenu").into(),
        topmost: s.t("Topmost").into(),
        quit: s.t("Exit").into(),
        tooltip: s.t("AppTitle").into(),
    }
}

/// Where to create the window (points), so it does not jump on the first frame.
pub fn initial_position(settings: &Settings, size: Vec2) -> Option<egui::Pos2> {
    let scale = platform::system_scale();
    let (ax, ay) = match settings.anchor() {
        Some((right, bottom)) => (right as f32 * scale, bottom as f32 * scale),
        None => {
            let area = platform::primary_work_area()?;
            (area[2] as f32 - 4.0 * scale, area[3] as f32 - 4.0 * scale)
        }
    };
    Some(egui::pos2(
        (ax - size.x * scale) / scale,
        (ay - size.y * scale) / scale,
    ))
}
