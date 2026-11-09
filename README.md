<div align="center">
  <img src="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" alt="REBOOT app icon" width="128" height="128">
  <h1>REBOOT</h1>
  <p><strong>Make room for the things that matter.</strong></p>
  <p>A privacy-first desktop app for understanding screen time and building healthier digital habits.</p>
  <p>
    <a href="README.ru.md">Русская версия</a>
    ·
    <a href="https://github.com/eeeeeeeert3103-create/reboot">GitHub</a>
  </p>
  <p>
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-Dart%20%5E3.13.7-02569B?logo=flutter&logoColor=white">
    <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%20%7C%20Windows-2D6A5B">
    <img alt="Privacy first" src="https://img.shields.io/badge/privacy-local--first-4B6B50">
  </p>
</div>

---

REBOOT helps you see how computer time is spent, set gentle limits, and make small, intentional changes. Your usage history stays on your device. Collection starts only after you opt in.

## What you can do

- **See your screen time:** review app usage by day, week, month, or a custom range.
- **Spot patterns:** explore the timeline, activity heatmap, weekly report, and locally generated insights.
- **Set personal goals:** create daily limits for selected apps and track your progress.
- **Make time to focus:** run focus sessions and keep a local streak.
- **Choose your look:** switch between built-in color themes.
- **Keep data close:** export or clear locally stored information in Privacy Center.
- **Ask for optional local help:** connect to Ollama on your own computer after giving separate consent. REBOOT only accepts loopback connections.

REBOOT is a digital-wellbeing tool. It does not measure dopamine, diagnose addiction, or provide medical advice.

## Privacy by design

- Usage collection is off until you explicitly consent.
- Usage history and preferences are stored locally on your device.
- The app itself is excluded from usage totals.
- Optional AI advice uses a local Ollama server and is disabled until separately enabled.
- You can inspect the in-app Privacy Center to review consent, export data, or clear local data.

The privacy notice in the app still has operator and contact placeholders. Complete and review those details against the exact release build before distributing the app.

## Platforms

| Platform | Usage collection | Notes |
| --- | --- | --- |
| macOS | Available | Background collection can be managed in Settings and Privacy Center. |
| Windows | Available | The app stays available from the system tray while running. |

The repository also contains Flutter platform scaffolding for other targets; live usage collection is currently focused on macOS and Windows.

## Build from source

Install Flutter with a Dart SDK that satisfies the constraint in `pubspec.yaml`, then run:

```sh
flutter pub get
```

Build for your desktop platform:

```sh
# macOS (run on macOS)
flutter build macos --release

# Windows (run on Windows)
flutter build windows --release
```

To launch during development:

```sh
flutter run -d macos
# or
flutter run -d windows
```

## Project layout

```text
lib/       Flutter UI, app logic, models, local storage, and themes
macos/     macOS runner and native usage collector
windows/   Windows runner and native usage collector
android/   Flutter Android platform project
ios/       Flutter iOS platform project
docs/      Product and platform integration notes
test/      Unit and widget tests
```

## Documentation

- [Product scenarios](docs/product-scenarios.md)
- [Usage collector contract](docs/collector-contract.md)
- [Desktop app shell contract](docs/app-shell-contract.md)
- [Data map](docs/data-map.md)
- [Release packaging notes](docs/release.md)

## Contributing

Issues and pull requests are welcome. Please describe the platform and steps to reproduce any bug. For privacy-sensitive changes, explain what data is read, where it is stored, and how consent is handled.

## License

No reuse license has been granted yet. Publishing this repository makes the source visible; it does not grant permission to redistribute or use it. Contact the project owner before reusing the code.
