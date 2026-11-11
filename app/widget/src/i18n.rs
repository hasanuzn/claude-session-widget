//! UI strings. The language files are the same `src/lang/<code>.psd1` files 1.x uses
//! (`Key = 'text'` per line), embedded at build time. Adding a language = add a file
//! there and one line in `FILES`.

use std::collections::HashMap;

const FILES: &[(&str, &str)] = &[
    ("en", include_str!("../../../src/lang/en.psd1")),
    ("tr", include_str!("../../../src/lang/tr.psd1")),
];

pub struct Strings {
    current: HashMap<String, String>,
    english: HashMap<String, String>,
}

impl Strings {
    /// `preference` is "auto" or a language code.
    pub fn load(preference: &str) -> Self {
        let code = resolve(preference);
        let english = parse(file("en").unwrap_or(""));
        let current = if code == "en" {
            english.clone()
        } else {
            parse(file(&code).unwrap_or(""))
        };
        Self { current, english }
    }

    /// The text for `key`: current language, then English, then the key itself.
    pub fn t<'a>(&'a self, key: &'a str) -> &'a str {
        self.current
            .get(key)
            .or_else(|| self.english.get(key))
            .map(String::as_str)
            .unwrap_or(key)
    }

    /// `t(key)` with `{0}`, `{1}`… replaced.
    pub fn f(&self, key: &str, args: &[&str]) -> String {
        let mut s = self.t(key).to_string();
        for (i, a) in args.iter().enumerate() {
            s = s.replace(&format!("{{{i}}}"), a);
        }
        s
    }
}

/// (code, own name) of every bundled language, e.g. ("tr", "Türkçe").
pub fn available() -> Vec<(&'static str, String)> {
    FILES
        .iter()
        .map(|(code, text)| {
            (
                *code,
                parse(text)
                    .remove("_Name")
                    .unwrap_or_else(|| code.to_string()),
            )
        })
        .collect()
}

fn file(code: &str) -> Option<&'static str> {
    FILES.iter().find(|(c, _)| *c == code).map(|(_, t)| *t)
}

/// "auto" → the system UI language if bundled, else English.
pub fn resolve(preference: &str) -> String {
    if preference != "auto" && file(preference).is_some() {
        return preference.to_string();
    }
    let sys = system_language();
    if file(&sys).is_some() {
        sys
    } else {
        "en".into()
    }
}

#[cfg(windows)]
fn system_language() -> String {
    let lang = unsafe { windows_sys::Win32::Globalization::GetUserDefaultUILanguage() };
    match lang & 0x3ff {
        0x1f => "tr".into(),
        _ => "en".into(),
    }
}

#[cfg(not(windows))]
fn system_language() -> String {
    std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LANG"))
        .unwrap_or_default()
        .chars()
        .take(2)
        .collect::<String>()
        .to_lowercase()
}

/// Parses `Key = 'value'` / `Key = "value"` lines; `''` inside single quotes is a quote.
pub fn parse(text: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for raw in text.trim_start_matches('\u{feff}').lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line == "@{" || line == "}" {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim();
        let parsed =
            if let Some(inner) = value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')) {
                inner.replace("''", "'")
            } else if let Some(inner) = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')) {
                inner.replace("\"\"", "\"").replace("`'", "'")
            } else {
                continue;
            };
        if !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            map.insert(key.to_string(), parsed);
        }
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_languages_have_the_same_keys() {
        let en = parse(file("en").unwrap());
        assert!(en.len() > 50);
        for (code, _) in available() {
            let other = parse(file(code).unwrap());
            let mut missing: Vec<_> = en.keys().filter(|k| !other.contains_key(*k)).collect();
            missing.sort();
            assert!(missing.is_empty(), "{code} is missing {missing:?}");
        }
    }

    #[test]
    fn parses_quotes_and_escapes() {
        let m = parse("@{\n  A = 'it''s'\n  B = \"Widget'tan\"\n  # c = 'x'\n}");
        assert_eq!(m["A"], "it's");
        assert_eq!(m["B"], "Widget'tan");
        assert!(!m.contains_key("c"));
    }

    #[test]
    fn formats_placeholders() {
        let s = Strings::load("en");
        assert_eq!(s.f("NRunning", &["3"]), "3 running");
        assert_eq!(s.t("NoSuchKey"), "NoSuchKey");
    }
}
