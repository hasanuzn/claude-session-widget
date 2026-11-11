//! Renders the widget to a PNG without opening a window (CPU renderer, transparent
//! background). Used for the README screenshots and to check the UI when no screen
//! is available.

use crate::theme;
use crate::ui::Widget;
use claude_session_core::now_ms;
use egui::{Context, Pos2, RawInput, Rect};
use egui_software_backend::{BufferMutRef, ColorFieldOrder, EguiSoftwareRender};
use std::path::Path;

pub fn render(widget: &mut Widget, out: &Path, scale: f32) -> Result<(), String> {
    let ctx = Context::default();
    let have_mdl2 = theme::install(&ctx);
    widget.glyphs = theme::glyphs(have_mdl2);
    ctx.set_pixels_per_point(scale);

    let now = now_ms();
    let mut renderer = EguiSoftwareRender::new(ColorFieldOrder::Rgba);
    let mut size = widget.desired_size();
    let mut pixels = Vec::new();
    // A few passes so the card settles on its measured height.
    for _ in 0..4 {
        size = widget.desired_size();
        let input = RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, size)),
            ..Default::default()
        };
        let output = ctx.run_ui(input, |ui| {
            widget.draw(ui, now);
        });
        let prims = ctx.tessellate(output.shapes, output.pixels_per_point);
        let (w, h) = (
            (size.x * scale).round() as usize,
            (size.y * scale).round() as usize,
        );
        pixels = vec![[0u8; 4]; w * h];
        let mut buf = BufferMutRef::new(&mut pixels, w, h);
        renderer.render(
            &mut buf,
            &prims,
            &output.textures_delta,
            output.pixels_per_point,
        );
    }
    let (w, h) = (
        (size.x * scale).round() as u32,
        (size.y * scale).round() as u32,
    );
    write_png(out, w, h, &pixels)
}

fn write_png(path: &Path, w: u32, h: u32, pixels: &[[u8; 4]]) -> Result<(), String> {
    // The renderer writes premultiplied alpha; PNG wants straight alpha.
    let mut data = Vec::with_capacity(pixels.len() * 4);
    for p in pixels {
        let a = p[3] as u32;
        if a == 0 {
            data.extend_from_slice(&[0, 0, 0, 0]);
        } else {
            let un = |c: u8| ((c as u32 * 255 + a / 2) / a).min(255) as u8;
            data.extend_from_slice(&[un(p[0]), un(p[1]), un(p[2]), p[3]]);
        }
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(&data).map_err(|e| e.to_string())
}
