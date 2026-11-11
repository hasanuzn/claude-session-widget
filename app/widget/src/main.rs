//! Claude Session Widget 2.0: a small, light window that shows the Claude Code
//! sessions working right now and their progress.
//!
//! Usage:
//!   claude-session-widget                 run the widget
//!   claude-session-widget --test          print the sessions found, then exit
//!   claude-session-widget --demo [--view icon|card|settings] [--lang en|tr]
//!                                         fake sessions; saves nothing
//!   claude-session-widget --demo --screenshot out.png [--view …] [--lang …]
//!                                         render to a PNG without a window

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod feed;
mod i18n;
mod platform;
mod screenshot;
mod settings;
mod shell;
mod theme;
mod tray;
mod ui;

use settings::Settings;
use ui::{Page, Widget};

pub const TITLE: &str = "Claude Session Widget";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

struct Args {
    test: bool,
    demo: bool,
    view: Option<String>,
    lang: Option<String>,
    screenshot: Option<String>,
}

fn args() -> Args {
    let mut a = Args {
        test: false,
        demo: false,
        view: None,
        lang: None,
        screenshot: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--test" | "-Test" => a.test = true,
            "--demo" | "-Demo" => a.demo = true,
            "--view" => a.view = it.next(),
            "--lang" => a.lang = it.next(),
            "--screenshot" => a.screenshot = it.next(),
            _ => {}
        }
    }
    a
}

fn main() {
    let args = args();

    if args.test {
        platform::attach_console();
        let mut scanner = claude_session_core::Scanner::new(claude_session_core::Paths::detect());
        let list = scanner.scan(true);
        if list.is_empty() {
            println!("No sessions running right now.");
        }
        for s in &list {
            let p = &s.progress;
            println!(
                "{}  [{}]  {}/{}  ▸ {}  ⎿ {}{}",
                s.name,
                s.location,
                p.done(),
                p.total(),
                p.current(),
                p.activity,
                s.waiting
                    .as_ref()
                    .map(|w| format!("  ⏸ {w}"))
                    .unwrap_or_default()
            );
        }
        return;
    }

    let mut settings = if args.demo {
        Settings::default()
    } else {
        Settings::load()
    };
    if let Some(lang) = &args.lang {
        settings.language = lang.clone();
    }
    let mut widget = Widget::new(settings, false, VERSION);

    if args.demo {
        let (sessions, finished) = feed::demo();
        widget.set_sessions(sessions, claude_session_core::now_ms());
        widget.set_finished_demo(finished);
        widget.open_row("demo-1");
        match args.view.as_deref() {
            Some("icon") => widget.set_expanded(false),
            Some("settings") => {
                widget.set_expanded(true);
                widget.page = Page::Settings;
            }
            _ => widget.set_expanded(true),
        }
    }

    if let Some(out) = &args.screenshot {
        if let Err(e) = screenshot::render(&mut widget, std::path::Path::new(out), 2.0) {
            eprintln!("screenshot failed: {e}");
            std::process::exit(1);
        }
        return;
    }

    let instance = if args.demo {
        "Local\\ClaudeSessionWidget2Demo"
    } else {
        "Local\\ClaudeSessionWidget2"
    };
    if !platform::single_instance(instance) {
        return;
    }

    let size = widget.desired_size();
    let config = egui_software_backend::SoftwareBackendAppConfiguration::new()
        .inner_size(Some(size))
        .position(shell::initial_position(&widget.settings, size))
        .title(Some(TITLE.to_string()))
        .decorations(Some(false))
        .resizable(Some(false))
        .window_level(Some(if widget.settings.topmost {
            egui::WindowLevel::AlwaysOnTop
        } else {
            egui::WindowLevel::Normal
        }));
    let demo = args.demo;
    // The backend takes a factory (FnMut); it is called once.
    let mut widget = Some(widget);
    let _ = egui_software_backend::run_app_with_software_backend(config, move |ctx| {
        shell::Shell::new(ctx, widget.take().expect("app created once"), demo)
    });
}
