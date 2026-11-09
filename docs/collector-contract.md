# REBOOT collector contract (v1) — shared by macOS, Windows and Dart

Channel: `MethodChannel('reboot/collector')`, standard codec. Dart polls; there is no EventChannel.
All timestamps are UTC ISO-8601 strings with milliseconds, e.g. `2026-11-05T09:26:03.953Z`.

## Methods

| Method | Args | Returns |
|---|---|---|
| `getStatus` | — | status map |
| `requestPermission` | — | status map (no OS permission is needed on macOS/Windows; returns the current status) |
| `start` | `{ "userConsent": bool }` | `null`. If `userConsent != true` → `FlutterError("consent_required")`. If the platform cannot start (Windows: `SetTimer` failed) → `FlutterError("start_failed")` and status `failed`. Idempotent: start while collecting is a no-op. |
| `stop` | — | `null`. Closes the open foreground segment (emits `foregroundEnded` at now), stops all observers/timers. Idempotent. Buffered events stay drainable. |
| `drainEvents` | — | snapshot map. Returns every buffered event and clears the buffer. While collecting, first "checkpoints" the open segment: emits `foregroundEnded` at now and right away `foregroundStarted` for the same app with the same timestamp, so at most one poll interval of data can be lost on a crash. |

### Status map
```
{ "platform": "macOS" | "windows",
  "lifecycle": "unavailable" | "permissionRequired" | "ready" | "collecting" | "stopped" | "failed",
  "permissionGranted": bool,      // true on macOS/Windows (no OS permission needed for this data)
  "collecting": bool,             // true only when lifecycle == "collecting"
  "message": String,              // short Russian, user-facing, truthful
  "checkedAt": ISO }
```
`ready` = never started in this process; `stopped` = was started then stopped.

### Snapshot map
```
{ "platform": "macOS" | "windows", "capturedAt": ISO (now), "events": [event, ...] }
```
Every event timestamp must be <= capturedAt. Events are in chronological order, except that `idleStarted` may be earlier than events drained before it (see Idle).

### Event map
```
{ "type": "foregroundStarted" | "foregroundEnded" | "appLaunched" | "idleStarted" | "idleEnded" | "sessionLocked" | "sessionUnlocked",
  "timestamp": ISO,
  "appIdentifier": String?,   // macOS: bundleIdentifier (fallback: executable name). Windows: lowercased exe file name, e.g. "chrome.exe" (never a full path).
  "displayName": String?,     // macOS: localizedName. Windows: FileDescription from version info, fallback exe name without ".exe".
  "durationSeconds": int? }   // ONLY on foregroundEnded: active seconds of that segment, >= 0
```
Rules:
- `appIdentifier`/`displayName`, when present, must be non-empty strings. Omit the key instead of sending empty/null.
- `foregroundStarted`/`foregroundEnded`/`appLaunched` carry app fields; idle/lock events carry none.
- At most one open foreground segment. Every `foregroundStarted` is eventually followed by a matching `foregroundEnded` for the same app (switch, idle, lock, sleep, stop, checkpoint).
- Idle: poll every 5 s; idle when no user input for >= 120 s. On idle start emit `foregroundEnded` with timestamp = max(segment start, last input) and duration measured to it (may be 0), then `idleStarted` with the TRUE last-input time — even when that is earlier than the last drain/checkpoint (bounded only by the last lock/unlock/wake/start). Dart removes already stored active time between that moment and the end of idle. On input again: `idleEnded` (now) then `foregroundStarted` for the current frontmost app.
- Lock/unlock and system sleep/wake: lock or sleep → `foregroundEnded` (now) + `sessionLocked`; unlock or wake → `sessionUnlocked` + `foregroundStarted` (if not idle). Sleep is reported as `sessionLocked` (documented).
- `appLaunched`: macOS — `NSWorkspace.didLaunchApplicationNotification` for apps with regular activation policy. Windows — the first time a process id is seen as foreground in this collector run (documented as "first activation of a new process").
- While idle or locked, no foreground segment is open.
- Buffer cap 20 000 events; on overflow drop the oldest and keep going.
- Never collect window titles, URLs, document names, keystrokes, screenshots, or the content of any app. No network.

## What Dart does with it
Dart drains every 30 s and on app pause/close, turns `foregroundEnded` into sessions (`start = timestamp - durationSeconds`), merges contiguous checkpoint pieces, splits at local midnight, stores them locally, and records coverage (when the collector was actually running).
