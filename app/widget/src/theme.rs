//! Colours (same as 1.x), fonts and egui style.

use egui::{Color32, FontData, FontDefinitions, FontFamily, FontId};

pub const BG: Color32 = Color32::from_rgb(0x26, 0x26, 0x24);
pub const BG2: Color32 = Color32::from_rgb(0x30, 0x30, 0x2E);
pub const LINE: Color32 = Color32::from_rgb(0x3D, 0x3D, 0x3A);
pub const TEXT: Color32 = Color32::from_rgb(0xF0, 0xEE, 0xE6);
pub const TEXT2: Color32 = Color32::from_rgb(0xC2, 0xC0, 0xB6);
pub const MUTED: Color32 = Color32::from_rgb(0x8F, 0x8D, 0x86);
pub const ACCENT: Color32 = Color32::from_rgb(0xD9, 0x77, 0x57);
pub const GREEN: Color32 = Color32::from_rgb(0x7F, 0xB7, 0x7E);
pub const DIM: Color32 = Color32::from_rgb(0x55, 0x54, 0x4F);
pub const INK: Color32 = Color32::from_rgb(0x1F, 0x1E, 0x1D);

const SEMIBOLD: &str = "semibold";
const ICONS: &str = "icons";
const MONO: &str = "mono";

pub fn regular(size: f32) -> FontId {
    FontId::new(size, FontFamily::Proportional)
}

pub fn semibold(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(SEMIBOLD.into()))
}

pub fn mono(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(MONO.into()))
}

/// Segoe MDL2 Assets glyphs on Windows (the same icons as 1.x).
pub fn icons(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(ICONS.into()))
}

/// Icon glyphs: MDL2 code points on Windows, plain symbols elsewhere.
pub struct Glyphs {
    pub settings: &'static str,
    pub pin: &'static str,
    pub minimize: &'static str,
    pub close: &'static str,
    pub back: &'static str,
    pub chevron_right: &'static str,
    pub chevron_down: &'static str,
}

pub fn glyphs(have_mdl2: bool) -> Glyphs {
    if have_mdl2 {
        Glyphs {
            settings: "\u{E713}",
            pin: "\u{E718}",
            minimize: "\u{E921}",
            close: "\u{E8BB}",
            back: "\u{E72B}",
            chevron_right: "\u{E76C}",
            chevron_down: "\u{E70D}",
        }
    } else {
        Glyphs {
            settings: "⚙",
            pin: "⊤",
            minimize: "—",
            close: "✕",
            back: "‹",
            chevron_right: "⏵",
            chevron_down: "⏷",
        }
    }
}

/// Installs fonts and style. Returns whether the MDL2 icon font was found.
#[allow(unused_assignments, unused_mut)]
pub fn install(ctx: &egui::Context) -> bool {
    let mut fonts = FontDefinitions::default();
    let mut proportional: Vec<String> = Vec::new();
    let mut semibold_list: Vec<String> = Vec::new();
    let mut have_icons = false;

    let mut mono_list: Vec<String> = Vec::new();
    #[cfg(windows)]
    {
        let dir = std::env::var_os("WINDIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_default()
            .join("Fonts");
        let mut load = |name: &str, files: &[&str]| -> bool {
            for file in files {
                if let Ok(bytes) = std::fs::read(dir.join(file)) {
                    fonts
                        .font_data
                        .insert(name.to_string(), FontData::from_owned(bytes).into());
                    return true;
                }
            }
            false
        };
        if load("segoe", &["segoeui.ttf"]) {
            proportional.push("segoe".into());
        }
        if load("segoe-semibold", &["seguisb.ttf"]) {
            semibold_list.push("segoe-semibold".into());
        }
        if load("segoe-symbol", &["seguisym.ttf"]) {
            proportional.push("segoe-symbol".into());
            semibold_list.push("segoe-symbol".into());
        }
        have_icons = load("mdl2", &["segmdl2.ttf"]);
        if load("cascadia", &["CascadiaMono.ttf", "consola.ttf"]) {
            mono_list.push("cascadia".into());
        }
    }

    // Built-in fonts stay as fallbacks everywhere.
    let defaults = fonts
        .families
        .get(&FontFamily::Proportional)
        .cloned()
        .unwrap_or_default();
    let mono_defaults = fonts
        .families
        .get(&FontFamily::Monospace)
        .cloned()
        .unwrap_or_default();
    let mut prop = proportional.clone();
    prop.extend(defaults.iter().cloned());
    fonts
        .families
        .insert(FontFamily::Proportional, prop.clone());
    let mut semi = semibold_list;
    semi.extend(prop.iter().cloned());
    fonts
        .families
        .insert(FontFamily::Name(SEMIBOLD.into()), semi);
    let icon_family = if have_icons {
        vec!["mdl2".to_string()]
    } else {
        prop.clone()
    };
    fonts
        .families
        .insert(FontFamily::Name(ICONS.into()), icon_family);
    mono_list.extend(mono_defaults);
    mono_list.extend(prop);
    fonts
        .families
        .insert(FontFamily::Name(MONO.into()), mono_list);
    ctx.set_fonts(fonts);

    ctx.all_styles_mut(|s| {
        s.visuals = egui::Visuals::dark();
        s.visuals.panel_fill = Color32::TRANSPARENT;
        s.visuals.window_fill = BG;
        s.visuals.override_text_color = Some(TEXT);
        s.visuals.widgets.noninteractive.bg_stroke.color = LINE;
        s.spacing.item_spacing = egui::vec2(6.0, 4.0);
        s.spacing.scroll.bar_width = 6.0;
        s.interaction.selectable_labels = false;
    });
    have_icons
}
