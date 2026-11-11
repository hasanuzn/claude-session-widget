//! OS specifics. Windows is implemented here; macOS and Linux get no-op fallbacks
//! until phase 4.

pub use imp::*;

/// A window rectangle in physical pixels: left, top, right, bottom.
pub type PxRect = [i32; 4];

#[cfg(windows)]
mod imp {
    use super::PxRect;
    use std::ffi::c_void;
    use windows_sys::Win32::Foundation::{
        BOOL, ERROR_ALREADY_EXISTS, GetLastError, HWND, LPARAM, RECT, TRUE,
    };
    use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;
    use windows_sys::Win32::Graphics::Gdi::{
        CombineRgn, CreateEllipticRgn, CreateRoundRectRgn, DeleteObject, GetMonitorInfoW,
        MONITOR_DEFAULTTONEAREST, MONITOR_DEFAULTTOPRIMARY, MONITORINFO, MonitorFromPoint,
        MonitorFromWindow, RGN_OR, SetWindowRgn,
    };
    use windows_sys::Win32::System::Console::{ATTACH_PARENT_PROCESS, AttachConsole};
    use windows_sys::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SZ, RegCloseKey,
        RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
    };
    use windows_sys::Win32::System::Threading::{CreateMutexW, GetCurrentProcessId};
    use windows_sys::Win32::UI::HiDpi::{GetDpiForSystem, GetDpiForWindow};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON,
    };
    use windows_sys::Win32::UI::Shell::{
        NIF_INFO, NIIF_INFO, NIM_MODIFY, NOTIFYICONDATAW, Shell_NotifyIconW, ShellExecuteW,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GWL_EXSTYLE, GetSystemMetrics, GetWindowLongPtrW, GetWindowRect,
        GetWindowTextW, GetWindowThreadProcessId, HWND_NOTOPMOST, HWND_TOPMOST, LWA_ALPHA,
        SM_SWAPBUTTON, SW_HIDE, SW_SHOWNA, SW_SHOWNORMAL, SWP_FRAMECHANGED, SWP_NOACTIVATE,
        SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SetLayeredWindowAttributes, SetWindowLongPtrW,
        SetWindowPos, ShowWindow, WS_EX_APPWINDOW, WS_EX_LAYERED, WS_EX_TOOLWINDOW,
    };

    pub type Hwnd = isize;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    fn h(hwnd: Hwnd) -> HWND {
        hwnd as HWND
    }

    /// False if another copy is already running (named mutex, kept for the process lifetime).
    pub fn single_instance(name: &str) -> bool {
        let n = wide(name);
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, n.as_ptr()) };
        !handle.is_null() && unsafe { GetLastError() } != ERROR_ALREADY_EXISTS
    }

    /// Lets `--test` print to the console it was started from (the app has no console of its own).
    pub fn attach_console() {
        unsafe {
            AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }

    /// This process's top-level window with the given title.
    pub fn find_own_window(title: &str) -> Option<Hwnd> {
        struct Search {
            pid: u32,
            title: Vec<u16>,
            found: Hwnd,
        }
        unsafe extern "system" fn each(hwnd: HWND, lparam: LPARAM) -> BOOL {
            let s = unsafe { &mut *(lparam as *mut Search) };
            let mut pid = 0u32;
            unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
            if pid == s.pid {
                let mut buf = [0u16; 128];
                let n =
                    unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32) } as usize;
                if buf[..n] == s.title[..s.title.len() - 1] {
                    s.found = hwnd as Hwnd;
                    return 0;
                }
            }
            TRUE
        }
        let mut s = Search {
            pid: unsafe { GetCurrentProcessId() },
            title: wide(title),
            found: 0,
        };
        unsafe { EnumWindows(Some(each), &mut s as *mut Search as LPARAM) };
        (s.found != 0).then_some(s.found)
    }

    /// Keeps the window out of Alt+Tab and the taskbar, and makes whole-window opacity possible.
    pub fn make_tool_window(hwnd: Hwnd) {
        unsafe {
            let ex = GetWindowLongPtrW(h(hwnd), GWL_EXSTYLE);
            let new =
                (ex | (WS_EX_TOOLWINDOW | WS_EX_LAYERED) as isize) & !(WS_EX_APPWINDOW as isize);
            if new != ex {
                // The taskbar only re-reads the style when the window is shown again.
                ShowWindow(h(hwnd), SW_HIDE);
                SetWindowLongPtrW(h(hwnd), GWL_EXSTYLE, new);
                SetLayeredWindowAttributes(h(hwnd), 0, 255, LWA_ALPHA);
                SetWindowPos(
                    h(hwnd),
                    std::ptr::null_mut(),
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE,
                );
                ShowWindow(h(hwnd), SW_SHOWNA);
            }
        }
    }

    pub fn set_alpha(hwnd: Hwnd, alpha: u8) {
        unsafe {
            SetLayeredWindowAttributes(h(hwnd), 0, alpha, LWA_ALPHA);
        }
    }

    /// Lets mouse clicks pass through the window (used while it is "hidden": fully
    /// transparent but still alive, so the UI keeps tracking sessions).
    pub fn set_click_through(hwnd: Hwnd, on: bool) {
        use windows_sys::Win32::UI::WindowsAndMessaging::WS_EX_TRANSPARENT;
        unsafe {
            let ex = GetWindowLongPtrW(h(hwnd), GWL_EXSTYLE);
            let new = if on {
                ex | WS_EX_TRANSPARENT as isize
            } else {
                ex & !(WS_EX_TRANSPARENT as isize)
            };
            if new != ex {
                SetWindowLongPtrW(h(hwnd), GWL_EXSTYLE, new);
            }
        }
    }

    /// Windows 11 rounded corners (ignored on Windows 10).
    pub fn set_round_corners(hwnd: Hwnd, round: bool) {
        const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
        let pref: u32 = if round { 2 } else { 1 }; // DWMWCP_ROUND / DWMWCP_DONOTROUND
        unsafe {
            DwmSetWindowAttribute(
                h(hwnd),
                DWMWA_WINDOW_CORNER_PREFERENCE,
                &pref as *const u32 as *const c_void,
                4,
            );
        }
    }

    /// Clips the window to a rounded rectangle (size and corner radius in physical px).
    /// Used instead of the system's rounded corners, which come with a drop shadow.
    pub fn set_round_rect_region(hwnd: Hwnd, w: i32, hgt: i32, radius: i32) {
        unsafe {
            // The right and bottom edges are exclusive, hence the +1.
            let rgn = CreateRoundRectRgn(0, 0, w + 1, hgt + 1, radius * 2, radius * 2);
            // The system owns the region from here on.
            SetWindowRgn(h(hwnd), rgn, TRUE);
        }
    }

    /// Clips the window to circles (centre x, centre y, radius in physical px), or removes the clip.
    pub fn set_circle_region(hwnd: Hwnd, circles: Option<&[(f32, f32, f32)]>) {
        unsafe {
            let Some(circles) = circles else {
                SetWindowRgn(h(hwnd), std::ptr::null_mut(), TRUE);
                return;
            };
            let rgn = |&(x, y, r): &(f32, f32, f32)| {
                CreateEllipticRgn(
                    (x - r).floor() as i32,
                    (y - r).floor() as i32,
                    (x + r).ceil() as i32 + 1,
                    (y + r).ceil() as i32 + 1,
                )
            };
            let mut iter = circles.iter();
            let Some(first) = iter.next() else { return };
            let combined = rgn(first);
            for c in iter {
                let other = rgn(c);
                CombineRgn(combined, combined, other, RGN_OR);
                DeleteObject(other as _);
            }
            // The system owns the region from here on.
            SetWindowRgn(h(hwnd), combined, TRUE);
        }
    }

    pub fn window_rect(hwnd: Hwnd) -> Option<PxRect> {
        let mut r = RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        };
        (unsafe { GetWindowRect(h(hwnd), &mut r) } != 0)
            .then_some([r.left, r.top, r.right, r.bottom])
    }

    pub fn dpi_scale(hwnd: Hwnd) -> f32 {
        let dpi = unsafe { GetDpiForWindow(h(hwnd)) };
        if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 }
    }

    pub fn system_scale() -> f32 {
        let dpi = unsafe { GetDpiForSystem() };
        if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 }
    }

    fn work_area_of(monitor: *mut c_void) -> Option<PxRect> {
        let mut info: MONITORINFO = unsafe { std::mem::zeroed() };
        info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
        (unsafe { GetMonitorInfoW(monitor as _, &mut info) } != 0).then_some([
            info.rcWork.left,
            info.rcWork.top,
            info.rcWork.right,
            info.rcWork.bottom,
        ])
    }

    /// Work area (screen minus taskbar) of the monitor the window is on.
    pub fn work_area(hwnd: Hwnd) -> Option<PxRect> {
        work_area_of(unsafe { MonitorFromWindow(h(hwnd), MONITOR_DEFAULTTONEAREST) } as _)
    }

    /// Work area of the monitor nearest to a point (physical px). Points left of or above
    /// the primary monitor are negative, so any value is a real position.
    pub fn work_area_near(x: i32, y: i32) -> Option<PxRect> {
        let pt = windows_sys::Win32::Foundation::POINT { x, y };
        work_area_of(unsafe { MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST) } as _)
    }

    pub fn primary_work_area() -> Option<PxRect> {
        let pt = windows_sys::Win32::Foundation::POINT { x: 0, y: 0 };
        work_area_of(unsafe { MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY) } as _)
    }

    /// Whether the primary mouse button is held right now. The system's window-move loop
    /// swallows the button release, so the UI cannot learn it from its own input events.
    pub fn primary_button_down() -> Option<bool> {
        let vk = if unsafe { GetSystemMetrics(SM_SWAPBUTTON) } != 0 {
            VK_RBUTTON
        } else {
            VK_LBUTTON
        };
        Some(unsafe { GetAsyncKeyState(vk as i32) } as u16 & 0x8000 != 0)
    }

    pub fn move_window(hwnd: Hwnd, x: i32, y: i32) {
        unsafe {
            SetWindowPos(
                h(hwnd),
                std::ptr::null_mut(),
                x,
                y,
                0,
                0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }

    pub fn set_topmost(hwnd: Hwnd, on: bool) {
        let after = if on { HWND_TOPMOST } else { HWND_NOTOPMOST };
        unsafe {
            SetWindowPos(
                h(hwnd),
                after,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }

    /// Balloon notification from the tray icon. `tray_hwnd` / id 1 are those of the
    /// first (and only) icon created by the tray-icon crate.
    pub fn notify(tray_hwnd: Hwnd, title: &str, body: &str) {
        let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
        nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        nid.hWnd = h(tray_hwnd);
        nid.uID = 1;
        nid.uFlags = NIF_INFO;
        nid.dwInfoFlags = NIIF_INFO;
        copy_into(&mut nid.szInfoTitle, title);
        copy_into(&mut nid.szInfo, body);
        unsafe {
            Shell_NotifyIconW(NIM_MODIFY, &nid);
        }
    }

    fn copy_into(dst: &mut [u16], s: &str) {
        let w: Vec<u16> = s.encode_utf16().take(dst.len() - 1).collect();
        dst[..w.len()].copy_from_slice(&w);
        dst[w.len()] = 0;
    }

    pub fn open_url(url: &str) {
        let (op, u) = (wide("open"), wide(url));
        unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                op.as_ptr(),
                u.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                SW_SHOWNORMAL,
            );
        }
    }

    // --- Start with Windows: HKCU\...\Run value

    const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const RUN_VALUE: &str = "ClaudeSessionWidget";

    fn open_run(access: u32) -> Option<HKEY> {
        let mut key: HKEY = std::ptr::null_mut();
        let path = wide(RUN_KEY);
        (unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, access, &mut key) } == 0)
            .then_some(key)
    }

    pub fn startup_enabled() -> bool {
        let Some(key) = open_run(KEY_QUERY_VALUE) else {
            return false;
        };
        let name = wide(RUN_VALUE);
        let found = unsafe {
            RegQueryValueExW(
                key,
                name.as_ptr(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } == 0;
        unsafe { RegCloseKey(key) };
        found
    }

    pub fn set_startup(on: bool) {
        let Some(key) = open_run(KEY_SET_VALUE) else {
            return;
        };
        let name = wide(RUN_VALUE);
        unsafe {
            if on {
                if let Ok(exe) = std::env::current_exe() {
                    let value = wide(&format!("\"{}\"", exe.display()));
                    RegSetValueExW(
                        key,
                        name.as_ptr(),
                        0,
                        REG_SZ,
                        value.as_ptr() as *const u8,
                        (value.len() * 2) as u32,
                    );
                }
            } else {
                RegDeleteValueW(key, name.as_ptr());
            }
            RegCloseKey(key);
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::PxRect;
    pub type Hwnd = isize;
    pub fn single_instance(_: &str) -> bool {
        true
    }
    pub fn attach_console() {}
    pub fn find_own_window(_: &str) -> Option<Hwnd> {
        None
    }
    pub fn make_tool_window(_: Hwnd) {}
    pub fn set_alpha(_: Hwnd, _: u8) {}
    pub fn set_click_through(_: Hwnd, _: bool) {}
    pub fn set_round_corners(_: Hwnd, _: bool) {}
    pub fn set_round_rect_region(_: Hwnd, _: i32, _: i32, _: i32) {}
    pub fn set_circle_region(_: Hwnd, _: Option<&[(f32, f32, f32)]>) {}
    pub fn window_rect(_: Hwnd) -> Option<PxRect> {
        None
    }
    pub fn dpi_scale(_: Hwnd) -> f32 {
        1.0
    }
    pub fn system_scale() -> f32 {
        1.0
    }
    pub fn work_area(_: Hwnd) -> Option<PxRect> {
        None
    }
    pub fn work_area_near(_: i32, _: i32) -> Option<PxRect> {
        None
    }
    pub fn primary_work_area() -> Option<PxRect> {
        None
    }
    pub fn primary_button_down() -> Option<bool> {
        None
    }
    pub fn move_window(_: Hwnd, _: i32, _: i32) {}
    pub fn set_topmost(_: Hwnd, _: bool) {}
    pub fn notify(_: Hwnd, _: &str, _: &str) {}
    pub fn open_url(url: &str) {
        let opener = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        let _ = std::process::Command::new(opener).arg(url).spawn();
    }
    pub fn startup_enabled() -> bool {
        false
    }
    pub fn set_startup(_: bool) {}
}
