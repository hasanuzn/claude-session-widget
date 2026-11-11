//! Settings, stored as JSON. Same file and field names as 1.x
//! (`%APPDATA%\ClaudeSessionWidget\settings.json`), so an existing install keeps its settings.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Settings {
    /// "auto" or a language code.
    pub language: String,
    /// "icon" | "card" | "last"
    pub open_mode: String,
    pub expanded: bool,
    pub topmost: bool,
    pub notify: bool,
    pub blink: bool,
    pub show_cli: bool,
    pub refresh_sec: u32,
    /// 30–100 (%), opacity while the mouse is not over the widget.
    pub opacity: u32,
    pub keep_min: u32,
    /// Window anchor (its bottom-right corner) in screen points; -1 = default corner.
    pub right: f64,
    pub bottom: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            language: "auto".into(),
            open_mode: "last".into(),
            expanded: false,
            topmost: true,
            notify: true,
            blink: true,
            show_cli: true,
            refresh_sec: 3,
            opacity: 100,
            keep_min: 30,
            right: -1.0,
            bottom: -1.0,
        }
    }
}

impl Settings {
    /// Loads the settings file (or the 1.x `ayarlar.json` the first time); defaults otherwise.
    pub fn load() -> Self {
        let Some(path) = path() else {
            return Self::default();
        };
        let text = std::fs::read_to_string(&path)
            .ok()
            .or_else(|| legacy_path().and_then(|p| std::fs::read_to_string(p).ok()));
        text.and_then(|t| serde_json::from_str::<Self>(t.trim_start_matches('\u{feff}')).ok())
            .map(Self::sanitized)
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(path) = path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(text) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, text);
        }
    }

    /// Whether the card is open when the widget starts.
    pub fn start_expanded(&self) -> bool {
        match self.open_mode.as_str() {
            "icon" => false,
            "card" => true,
            _ => self.expanded,
        }
    }

    fn sanitized(mut self) -> Self {
        self.opacity = self.opacity.clamp(30, 100);
        if ![2, 3, 5, 10].contains(&self.refresh_sec) {
            self.refresh_sec = 3;
        }
        if self.keep_min == 0 {
            self.keep_min = 30;
        }
        self
    }
}

fn path() -> Option<PathBuf> {
    config_dir().map(|d| d.join("ClaudeSessionWidget").join("settings.json"))
}

fn legacy_path() -> Option<PathBuf> {
    config_dir().map(|d| d.join("ClaudeOturumWidget").join("ayarlar.json"))
}

fn config_dir() -> Option<PathBuf> {
    if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_1x_file_format() {
        let json = "\u{feff}{ \"Language\": \"tr\", \"OpenMode\": \"card\", \"Expanded\": false, \"Topmost\": true,
            \"Notify\": false, \"Blink\": true, \"ShowCli\": true, \"RefreshSec\": 5, \"Opacity\": 80,
            \"KeepMin\": 60, \"Right\": 1916, \"Bottom\": 1028 }";
        let s: Settings = serde_json::from_str(json.trim_start_matches('\u{feff}')).unwrap();
        assert_eq!(s.language, "tr");
        assert!(!s.notify);
        assert_eq!((s.refresh_sec, s.opacity, s.keep_min), (5, 80, 60));
        assert_eq!(s.right, 1916.0);
        assert!(s.start_expanded());
    }

    #[test]
    fn missing_fields_take_defaults() {
        let s: Settings = serde_json::from_str("{\"Language\":\"en\"}").unwrap();
        assert_eq!(s.opacity, 100);
        assert!(s.topmost);
    }
}
