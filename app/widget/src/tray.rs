//! Tray icon (menu bar icon on macOS) with its menu. Clicks and menu picks are sent
//! to the UI through a channel; `on_event` runs right away on the tray's thread (it
//! can show a hidden window, which would not run any UI code by itself).

use std::sync::mpsc::{Receiver, channel};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayCmd {
    /// Left click on the icon.
    Toggle,
    Show,
    Settings,
    Topmost,
    Quit,
}

pub struct Tray {
    icon: TrayIcon,
    topmost: CheckMenuItem,
    show: MenuItem,
    settings: MenuItem,
    quit: MenuItem,
    images: [Icon; 3],
    current: usize,
}

/// Which image the tray shows.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum TrayImage {
    Normal = 0,
    Done = 1,
    Dim = 2,
}

impl Tray {
    pub fn new(
        labels: TrayLabels,
        topmost: bool,
        on_event: impl Fn(TrayCmd) + Send + Sync + 'static,
    ) -> (Self, Receiver<TrayCmd>) {
        let (tx, rx) = channel();
        let show = MenuItem::new(&labels.show, true, None);
        let settings = MenuItem::new(&labels.settings, true, None);
        let top = CheckMenuItem::new(&labels.topmost, true, topmost, None);
        let quit = MenuItem::new(&labels.quit, true, None);
        let menu = Menu::new();
        let _ = menu.append_items(&[
            &show,
            &settings,
            &top,
            &PredefinedMenuItem::separator(),
            &quit,
        ]);
        let ids = (
            show.id().clone(),
            settings.id().clone(),
            top.id().clone(),
            quit.id().clone(),
        );

        let on_event = std::sync::Arc::new(on_event);
        let (tx_menu, on_menu) = (tx.clone(), on_event.clone());
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            let cmd = if e.id == ids.0 {
                TrayCmd::Show
            } else if e.id == ids.1 {
                TrayCmd::Settings
            } else if e.id == ids.2 {
                TrayCmd::Topmost
            } else if e.id == ids.3 {
                TrayCmd::Quit
            } else {
                return;
            };
            let _ = tx_menu.send(cmd);
            on_menu(cmd);
        }));
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = e
            {
                let _ = tx.send(TrayCmd::Toggle);
                on_event(TrayCmd::Toggle);
            }
        }));

        let images = icon_images();
        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_menu_on_left_click(false)
            .with_tooltip(&labels.tooltip)
            .with_icon(images[0].clone())
            .build()
            .expect("tray icon");
        (
            Self {
                icon,
                topmost: top,
                show,
                settings,
                quit,
                images,
                current: 0,
            },
            rx,
        )
    }

    pub fn set_image(&mut self, image: TrayImage) {
        let i = image as usize;
        if i != self.current {
            self.current = i;
            let _ = self.icon.set_icon(Some(self.images[i].clone()));
        }
    }

    pub fn set_tooltip(&self, text: &str) {
        // Windows limits tray tooltips to 127 characters.
        let t: String = text.chars().take(120).collect();
        let _ = self.icon.set_tooltip(Some(t));
    }

    pub fn set_topmost(&self, on: bool) {
        self.topmost.set_checked(on);
    }

    pub fn set_labels(&self, labels: &TrayLabels) {
        self.show.set_text(&labels.show);
        self.settings.set_text(&labels.settings);
        self.topmost.set_text(&labels.topmost);
        self.quit.set_text(&labels.quit);
    }

    #[cfg(windows)]
    pub fn hwnd(&self) -> isize {
        self.icon.window_handle() as isize
    }

    #[cfg(not(windows))]
    pub fn hwnd(&self) -> isize {
        0
    }
}

pub struct TrayLabels {
    pub show: String,
    pub settings: String,
    pub topmost: String,
    pub quit: String,
    pub tooltip: String,
}

/// Normal (orange), done (green) and dim images, decoded from the app's .ico (32 px frame).
fn icon_images() -> [Icon; 3] {
    let (rgba, w, h) = decode_ico_frame(
        include_bytes!("../../../src/assets/claude-session-widget.ico"),
        32,
    )
    .unwrap_or_else(|| ([0xD9, 0x77, 0x57, 0xFF].repeat(32 * 32), 32, 32));
    let recolor = |to: [u8; 3]| -> Vec<u8> {
        rgba.chunks(4)
            .flat_map(|p| {
                // Orange spokes (#D97757) get the new colour; the dark disc stays.
                let orange = p[0] > 0x90 && p[0] > p[2].saturating_add(40);
                if orange {
                    [to[0], to[1], to[2], p[3]]
                } else {
                    [p[0], p[1], p[2], p[3]]
                }
            })
            .collect()
    };
    [
        Icon::from_rgba(rgba.clone(), w, h).expect("icon"),
        Icon::from_rgba(recolor([0x7F, 0xB7, 0x7E]), w, h).expect("icon"),
        Icon::from_rgba(recolor([0x55, 0x54, 0x4F]), w, h).expect("icon"),
    ]
}

/// RGBA of the PNG frame with the given size from an .ico file (PNG frames only).
pub fn decode_ico_frame(ico: &[u8], size: u32) -> Option<(Vec<u8>, u32, u32)> {
    let count = u16::from_le_bytes([*ico.get(4)?, *ico.get(5)?]) as usize;
    for i in 0..count {
        let e = 6 + i * 16;
        let dim = *ico.get(e)? as u32;
        let dim = if dim == 0 { 256 } else { dim };
        if dim != size {
            continue;
        }
        let len = u32::from_le_bytes(ico.get(e + 8..e + 12)?.try_into().ok()?) as usize;
        let off = u32::from_le_bytes(ico.get(e + 12..e + 16)?.try_into().ok()?) as usize;
        let png = ico.get(off..off + len)?;
        let decoder = png::Decoder::new(png);
        let mut reader = decoder.read_info().ok()?;
        let mut buf = vec![0; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).ok()?;
        if info.color_type != png::ColorType::Rgba || info.bit_depth != png::BitDepth::Eight {
            return None;
        }
        buf.truncate(info.buffer_size());
        return Some((buf, info.width, info.height));
    }
    None
}
