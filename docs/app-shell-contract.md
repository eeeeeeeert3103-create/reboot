# REBOOT app shell contract (v1) — background mode, menu bar / tray, autostart

Channel: `MethodChannel('reboot/app')`, standard codec, both directions.
Shared by macOS (Swift, `macos/Runner`) and Windows (C++, `windows/runner`). Dart side: `lib/services/app_shell.dart`.

## Dart → native

| Method | Args | Returns |
|---|---|---|
| `getAppState` | — | state map |
| `setBackgroundMode` | `{ "enabled": bool }` | state map. Enabled: closing the main window hides it and the app keeps running (menu bar / tray item visible). Disabled: closing the window quits the app as before. Native keeps the value in memory only; Dart persists it and sends it on every start. Default before Dart calls: disabled. |
| `setLaunchAtLogin` | `{ "enabled": bool }` | state map. macOS 13+: `SMAppService.mainApp.register()/unregister()`. Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value name `REBOOT`, data `"<full exe path>" --background`. Errors → `FlutterError("launch_at_login_failed", message)`. |
| `updateStatus` | `{ "title": String, "lines": [String], "collecting": bool, "progress": double? }` | `null`. `title`: short text for the macOS menu bar button next to the icon (e.g. `2:15`), may be empty. `lines`: 2–4 read-only lines shown at the top of the menu (e.g. `Сегодня: 2 ч 15 мин`, `Цель: 6 ч · 37%`, `Сбор идёт`). Windows: tray tooltip = `REBOOT — ` + first line (≤127 chars), menu shows the lines as disabled items. `collecting` toggles the menu item text below. |
| `showWindow` | — | `null`. Shows and focuses the main window (macOS: activation policy `.regular`, `NSApp.activate`). |
| `hideWindow` | — | `null`. Hides the main window (only meaningful when background mode is on). |
| `quit` | — | `null`. Terminates the process now. Dart calls this after it has saved data. |

### State map
```
{ "backgroundMode": bool,
  "windowVisible": bool,
  "launchAtLogin": bool,                 // currently registered
  "launchAtLoginStatus": "enabled" | "disabled" | "requiresApproval" | "notSupported" | "error",
  "launchAtLoginMessage": String,        // short Russian, truthful (e.g. "Нужно разрешить в Системных настройках → Объекты входа")
  "startedInBackground": bool,           // Windows: launched with --background; macOS: false
  "trayAvailable": bool }
```

## Native → Dart (`invokeMethod` on the same channel)

| Method | Args | Meaning |
|---|---|---|
| `trayAction` | `{ "action": "open" \| "toggleCollection" \| "quit" }` | User picked a menu bar / tray item. For `quit` native must NOT terminate by itself: Dart saves and calls `quit`. Safety net: if Dart has not called `quit` within 4 s, terminate anyway. |
| `windowVisibilityChanged` | `{ "visible": bool }` | Window was hidden (close button in background mode) or shown again. |

## Menu bar / tray menu (both platforms, Russian)
1. Status lines from `updateStatus` (disabled items).
2. separator
3. `Открыть REBOOT` → show window + `trayAction open`.
4. `Остановить сбор` / `Возобновить сбор` (depends on last `collecting`) → `trayAction toggleCollection`.
5. separator
6. `Завершить REBOOT` → `trayAction quit` (+ 4 s safety net).

macOS: `NSStatusItem` with a template SF Symbol (e.g. `bolt.fill`) so it follows light/dark menu bar. Visible only while background mode is on. When the window is hidden in background mode switch to `.accessory` (no Dock icon); back to `.regular` when shown. While background mode is on, call `ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "REBOOT собирает статистику")` so App Nap does not stall the collector timers; end it when background mode is turned off. Window close button in background mode: `windowShouldClose` → `orderOut` + return false. Cmd+Q / Dock "Quit" still quits (goes through Flutter's exit request, which Dart answers after saving).

Windows: `Shell_NotifyIconW` with the app icon (`IDI_APP_ICON` from `resource.h`), callback message on the main HWND, right-click and left-click open the menu (`TrackPopupMenu`, `SetForegroundWindow` first). Handle `TaskbarCreated` (re-add icon after Explorer restarts). Intercept `WM_CLOSE` BEFORE `flutter_controller_->HandleTopLevelWindowProc` when background mode is on: `ShowWindow(SW_HIDE)` and return 0. Launched with `--background`: create the window hidden (still create the engine) and show the tray icon. Remove the icon on exit (`NIM_DELETE`).

Never: hidden processes without an icon, keyloggers, screenshots, network.

## v1.1 additions — app limits and Windows tray

### Dart → native (same `reboot/app` channel)

| Method | Args | Returns |
|---|---|---|
| `getFrontmostApp` | — | `{ "appIdentifier": String, "displayName": String }` of the current foreground app (same identifiers as the collector: macOS bundle ID, Windows lowercased exe name), or `null` when none / REBOOT itself is frontmost. |
| `limitApp` | `{ "appIdentifier": String }` | `{ "applied": bool, "message": String }`. Soft limit: only if that app is frontmost right now. macOS: `NSRunningApplication.hide()` (never terminate, never force). Windows: `ShowWindow(foregroundHwnd, SW_MINIMIZE)` for the foreground window of that process (UWP: the frame window). Then bring the REBOOT window to front (same as `showWindow`). Never kills processes, never blocks launching. |

### Windows tray
The tray icon is always shown while REBOOT runs (not only in background mode), and on Windows background mode is always on: closing the window hides it to the tray. `setBackgroundMode(false)` is accepted but keeps the icon; only "Завершить REBOOT" ends the process.

### macOS
Local AI (Ollama on `127.0.0.1:11434`) needs `com.apple.security.network.client` in both entitlements. The app connects only to loopback; Dart enforces this.
