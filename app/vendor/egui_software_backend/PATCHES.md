# Local patches

Vendored copy of [`egui_software_backend`](https://github.com/DGriffin91/egui_software_backend)
0.0.3 (MIT OR Apache-2.0, see the licence files). Examples, tests and dev-dependencies were left
out. Changes are marked `claude-session-widget patch` in `src/winit.rs`:

- **Timed repaints** (`egui::Context::request_repaint_after`): upstream redraws immediately,
  ignoring the delay, and then resets the event loop to `ControlFlow::Wait`, so a widget that asks
  for "repaint in 30 s" ends up repainting ~60 times a second. Now a request redraws only when it
  is due; later requests are remembered and the loop sleeps until then (`ControlFlow::WaitUntil`).

Remove this copy once upstream has an equivalent fix.
