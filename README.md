# ✻ Claude Session Widget

**English** · [Türkçe](#türkçe)

A small Windows desktop widget that shows the **Claude sessions running right now**, what each one
is **doing**, and how far along it is — without switching to the Claude app.

If you run Claude in several sessions at once (local, WSL or terminal), you can see at a glance
which one is working on what, how many steps are done, and which one just finished.

> This is a community project. It is not made by, or affiliated with, Anthropic.

## Features

- **Icon ↔ card:** a round ✻ icon sits in the bottom-right corner; click it to open the session card.
- **Accordion rows:** each session shows its title and progress bar; click a title to expand its
  location, step list (✓ done, ▸ current, ○ pending) and latest tool call (⎿).
- **Finished alert:** when a session finishes, the icon blinks green and a Windows notification appears.
- **Live indicator:** the ✻ spins while anything is running; the badge shows how many sessions are running.
- **Tray icon:** hide the widget and it keeps running in the system tray.
- **Settings window**, English and Turkish UI (follows the Windows display language by default).
- Draggable, remembers its position. Nothing ever leaves your computer.

## Install

### One line

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/hasanuzn/claude-session-widget/main/get.ps1 | iex
```

### Download and double-click

1. On this page choose **Code → Download ZIP** and extract it.
2. Double-click **`Install.cmd`**.

No administrator rights are needed. The installer:

- copies the files to `%LOCALAPPDATA%\ClaudeOturumWidget`,
- adds **Claude Session Widget**, **… - Settings** and **… - Uninstall** to the Start menu,
- makes it start with Windows (you can turn this off in Settings),
- adds it to **Settings → Apps → Installed apps**,
- starts the widget.

Options: `Install.cmd -NoStartup` (don't start with Windows), `Install.cmd -NoLaunch` (don't start now).

## Settings

Open them with the ⚙ button on the card, **Settings…** in the tray icon's menu, or the
**Claude Session Widget - Settings** Start menu shortcut. Changes apply immediately.

| Setting | What it does | Default |
|---|---|---|
| Start with Windows | Runs automatically when you sign in | On |
| Always on top | Keeps the widget above other windows | On |
| On start | Icon, card, or the last state | Last state |
| Language | Auto (Windows display language), English or Türkçe | Auto |
| Transparency | 100 / 90 / 80 / 70 / 60 % — fully opaque while the mouse is over it | 100% |
| Windows notification | Notify when a session finishes | On |
| Blink the icon | Blink green while a finished job is unseen | On |
| Show terminal sessions | Also list sessions started with the `claude` command | On |
| Refresh interval | 2 / 3 / 5 / 10 seconds | 3 s |
| Keep finished | How long finished jobs stay listed: 15 / 30 / 60 min | 30 min |

Settings are stored in `%APPDATA%\ClaudeOturumWidget\ayarlar.json`.

## How it works

The widget only **reads** local files. It changes nothing and never connects to the internet.

- **Which sessions are running:** the Claude desktop app's session records
  (`%LOCALAPPDATA%\Claude-Data\…\claude-code-sessions\*.json`). A session counts as running when
  its latest user message came after its last turn boundary.
- **Progress and current work:** the session transcript's task list (`update_plan` / `TodoWrite`)
  and latest tool call. WSL transcripts are read through `wsl.exe`.
- **Terminal sessions:** entries marked `busy` in `%USERPROFILE%\.claude\sessions\*.json`.

Sessions that don't keep a task list show no progress bar, only their latest activity.

## Requirements

- Windows 10 or 11 (Windows PowerShell 5.1 and .NET Framework are built in)
- The Claude desktop app (Code tab) or the Claude Code CLI
- `wsl.exe` for WSL sessions

## Uninstall

Use **Claude Session Widget - Uninstall** in the Start menu, **Installed apps**, or `Uninstall.cmd`
in the repository folder. To keep your settings: `Uninstall.cmd -KeepSettings`.

## Troubleshooting

- If the widget doesn't open, check the log: `%TEMP%\oturum-widget.log`
- To list the sessions it finds in the console:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeOturumWidget\oturum-widget.ps1" -Test
  ```

## License

[MIT](LICENSE)

---

## Türkçe

Claude masaüstü uygulamasında **şu anda çalışan oturumları**, her birinin **ne yaptığını** ve
**ilerlemesini** masaüstünde küçük, ayrı bir pencerede gösteren Windows widget'ı.

> Topluluk projesidir; Anthropic tarafından yapılmamıştır ve Anthropic ile bağlantılı değildir.

**Özellikler:** sağ altta ✻ simgesi, tıklayınca açılan kart; başlığına tıklayınca açılıp kapanan
oturum satırları (kapalıyken yalnızca başlık ve ilerleme çubuğu); biten işte yeşil yanıp sönme ve
Windows bildirimi; sistem tepsisi simgesi; ayarlar penceresi; İngilizce ve Türkçe arayüz (varsayılan
olarak Windows görüntü dilini izler).

**Kurulum:** PowerShell'e şunu yapıştırın:

```powershell
irm https://raw.githubusercontent.com/hasanuzn/claude-session-widget/main/get.ps1 | iex
```

ya da **Code → Download ZIP** ile indirip **`Install.cmd`** dosyasına çift tıklayın. Yönetici izni
gerekmez; Başlat menüsüne kısayollar ekler, Windows açılınca başlatır (Ayarlar'dan kapatılabilir) ve
"Yüklü uygulamalar" listesine ekler.

**Ayarlar:** karttaki ⚙ düğmesi, tepsi menüsündeki **Ayarlar…** ya da Başlat menüsündeki
**Claude Session Widget - Ayarlar**. Windows açılınca başlatma, her zaman üstte, açılış görünümü,
dil (Otomatik / English / Türkçe), şeffaflık (%100–%60, fare üzerindeyken tam opak), Windows bildirimi, yanıp sönme, terminal oturumları, yenileme
aralığı ve bitenlerin listede kalma süresi buradan değiştirilir.

**Kaldırma:** Başlat menüsünden **Claude Session Widget - Kaldır**, "Yüklü uygulamalar" listesi ya da
`Uninstall.cmd`. Ayarları korumak için: `Uninstall.cmd -KeepSettings`.

**Sorun giderme:** hata kaydı `%TEMP%\oturum-widget.log` dosyasındadır; bulunan oturumları görmek
için yukarıdaki `-Test` komutunu çalıştırın.
