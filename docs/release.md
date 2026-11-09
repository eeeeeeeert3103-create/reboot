# Релизные сборки REBOOT: сборка, защита кода, подпись, проверка пакета

Документ описывает, как собрать пакеты REBOOT для пользователей macOS и Windows,
что именно защищает код и что не защищает, где лежат отладочные символы и как
проверить пакет перед публикацией.

Все инструменты лежат в `tools/release/`:

| Файл | Назначение |
|---|---|
| `build_macos.sh` | Release-сборка macOS, strip, подпись (опционально), notarization (опционально), ZIP, SHA-256 |
| `build_windows.ps1` | Release-сборка Windows, VC++ runtime, Authenticode (опционально), ZIP, SHA-256 |
| `verify_package.py` | Проверка готового ZIP (только stdlib Python) |
| `test_verify_package.py` | Самотест верификатора на синтетических ZIP |
| `extract_notices.py` | Распаковка `NOTICES.Z` из flutter_assets в `THIRD_PARTY_NOTICES.txt` |
| `README-package.txt` | Пользовательский README пакета (общий для macOS и Windows) |
| `ci/release.yml` | Шаблон GitHub Actions (не активен, см. ниже) |

Версия берётся из `pubspec.yaml` (`version: 1.0.0+1` → пакет `v1.0.0`, сборка `1`).

---

## 1. Быстрый старт

### macOS

```bash
tools/release/build_macos.sh
# результат:
#   dist/REBOOT-macOS-v1.0.0.zip
#   dist/REBOOT-macOS-v1.0.0.zip.sha256
#   dist/symbols/macos-1.0.0+1/        <- приватно, не публиковать
```

Только упаковать уже собранный `.app` (без `flutter build`):

```bash
tools/release/build_macos.sh --skip-build --app build/macos/Build/Products/Release/reboot_app.app
```

Параметры: `--dist <каталог>` — куда класть результат (по умолчанию `dist/` в корне репозитория).

Переменные окружения:

| Переменная | Что делает |
|---|---|
| `REBOOT_MACOS_SIGN_IDENTITY` | Имя сертификата `Developer ID Application: … (TEAMID)`. Если не задана — пакет **не подписан Developer ID** (скрипт так и пишет) |
| `REBOOT_NOTARY_PROFILE` | Профиль `xcrun notarytool store-credentials`. Только вместе с подписью |
| `REBOOT_MACOS_STRIP` | `0` — не делать strip главного исполняемого файла (по умолчанию `1`) |
| `REBOOT_SAVE_OBFUSCATION_MAP` | `1` — сохранить карту обфускации Dart в symbols |
| `REBOOT_SKIP_VERIFY` | `1` — не запускать `verify_package.py` в конце |

### Windows (на Windows-машине или в CI)

```powershell
pwsh tools\release\build_windows.ps1
# результат:
#   dist\REBOOT-Windows-v1.0.0.zip
#   dist\REBOOT-Windows-v1.0.0.zip.sha256
#   dist\symbols\windows-1.0.0+1\      <- приватно, не публиковать
```

Параметры: `-SkipBuild -ReleaseDir <путь>` — упаковать готовую сборку; `-Dist <каталог>`; `-Arch x64|arm64` (по умолчанию `x64`).

Переменные окружения:

| Переменная | Что делает |
|---|---|
| `REBOOT_WIN_CERT_PATH` + `REBOOT_WIN_CERT_PASSWORD` | Подпись Authenticode из `.pfx` |
| `REBOOT_WIN_CERT_THUMBPRINT` | Альтернатива: SHA1-отпечаток сертификата в хранилище Windows |
| `REBOOT_WIN_TIMESTAMP_URL` | RFC 3161 timestamp-сервер (по умолчанию `http://timestamp.digicert.com`) |
| `REBOOT_SAVE_OBFUSCATION_MAP`, `REBOOT_SKIP_VERIFY` | Как на macOS |

Скрипт сохранён в UTF-8 с BOM, чтобы Windows PowerShell 5.1 правильно читал кириллицу. При редактировании сохраняйте BOM.

> **Важно.** `flutter build` перезаписывает общий каталог `build/`. Не запускайте релизную сборку, пока кто-то ещё работает со сборками в этом рабочем дереве.

---

## 2. Что делают скрипты

### macOS (`build_macos.sh`)

1. `flutter build macos --release --obfuscate --split-debug-info=dist/symbols/macos-<version>+<build>`.
2. Копирует все `*.dSYM` рядом с `.app` в `dist/symbols/…/dSYM/`. В пакет они не попадают.
3. Копирует `reboot_app.app` в staging как `REBOOT.app` (`ditto`), удаляет `.DS_Store`, `*.dSYM`, `*.symbols`, `*.map`.
4. **Strip главного исполняемого файла** (`xcrun strip -S -x Contents/MacOS/reboot_app`). Без этого шага в бинаре остаётся debug map (N_OSO) с абсолютными путями к объектным файлам `build/macos/Build/Intermediates.noindex/…`, то есть с **именем пользователя** машины сборки. Это проверено на текущей Release-сборке: 30 вхождений `/Users/<имя>/REBOOT/…` до strip, 0 после, размер 455 КБ → 304 КБ. UUID бинаря не меняется, поэтому сохранённый dSYM подходит для символизации. strip ломает прежнюю подпись, поэтому без Developer ID скрипт восстанавливает **ad-hoc**-подпись (`codesign --sign -` с `Release.entitlements`). Ad-hoc-подпись — не подпись разработчика: Gatekeeper её не принимает, но без неё arm64-код на Apple Silicon вообще не запустится.
5. Подпись Developer ID, если задана `REBOOT_MACOS_SIGN_IDENTITY` (раздел 5).
6. Notarization, если задан `REBOOT_NOTARY_PROFILE` (раздел 5).
7. Кладёт рядом с `REBOOT.app`: `README.txt` (из `README-package.txt`, подставляется версия), `VERSION.txt` (версия, сборка, коммит, дата, статус обфускации, strip, подписи и notarization), `PRIVACY_POLICY.md` (копия `docs/privacy-policy.md`), `THIRD_PARTY_NOTICES.txt` (из `NOTICES.Z`).
8. `ditto -c -k --norsrc --noextattr --noacl --keepParent` → `dist/REBOOT-macOS-v<version>.zip`. Флаги `--norsrc --noextattr --noacl` нужны, чтобы в архив не попали AppleDouble-файлы `._*` с расширенными атрибутами (карантин, provenance, метки Finder). Без них `ditto` добавлял в ZIP по файлу `._*` на каждый файл и каталог.
9. `shasum -a 256` → `.zip.sha256`, затем `verify_package.py`.

### Windows (`build_windows.ps1`)

1. `flutter build windows --release --obfuscate --split-debug-info=dist\symbols\windows-<version>+<build>`.
2. Staging из `build\windows\x64\runner\Release` (или `-ReleaseDir`).
3. `*.pdb` копируются в `dist\symbols\…\pdb\`, затем из staging удаляются `*.pdb`, `*.lib`, `*.exp`, `*.ilk`.
4. Копирует `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` из `System32` (из 32-битного процесса — через `Sysnative`). Если файла нет — ошибка с подсказкой установить VC++ Redistributable 2015–2022. Проверяется архитектура PE (x64 = `0x8664`, arm64 = `0xAA64`), чтобы случайно не положить 32-битные DLL.
5. Authenticode через `signtool`, если заданы сертификат или отпечаток (раздел 6). Подписываются только наши `*.exe`/`*.dll`; runtime-DLL Microsoft уже подписаны Microsoft.
6. README (CRLF, UTF-8 с BOM), VERSION, PRIVACY_POLICY, THIRD_PARTY_NOTICES (через `extract_notices.py`, а без Python — через .NET `GZipStream`/`DeflateStream`).
7. `Compress-Archive` → `dist\REBOOT-Windows-v<version>.zip`, `Get-FileHash` → `.zip.sha256` (формат `shasum`: `<hash>  <имя>`), затем `verify_package.py`.

Примечание: Windows PowerShell 5.1 в `Compress-Archive` пишет пути с обратными слэшами. Распаковка в Проводнике работает, `verify_package.py` нормализует пути и выдаёт предупреждение. В CI используется `pwsh` 7, где этой проблемы нет.

### Про `NOTICES.Z`

Несмотря на расширение `.Z`, это не формат `compress(1)`. В текущей сборке (Flutter 3.47.9) это **gzip**-поток (сигнатура `1f 8b`) — это проверено на `build/macos/.../flutter_assets/NOTICES.Z`. Простой `zlib.decompress(data)` на нём падает с `incorrect header check`. `extract_notices.py` определяет формат по сигнатуре (gzip или zlib), распаковывает с нужным `wbits`, строго проверяет UTF-8 и непустоту. Реальный файл: 98 КБ → 1,3 млн символов лицензий.

---

## 3. Что защищает обфускация, а что нет (честно)

**Абсолютной защиты нет.** Всё, что выполняется на компьютере пользователя, можно исследовать. Меры ниже повышают стоимость анализа, но не делают его невозможным.

| Что | Состояние в пакете |
|---|---|
| Dart-код | Скомпилирован AOT в машинный код (`App.framework/App` на macOS, `data/app.so` на Windows). Исходников `.dart` в пакете нет |
| Имена Dart-символов (классы, методы, поля) | `--obfuscate` заменяет их бессмысленными идентификаторами |
| Строковые литералы Dart (тексты UI, ключи JSON, имена файлов, сообщения) | **Остаются читаемыми** (`strings` их покажет). Обфускация их не трогает |
| Ресурсы (`flutter_assets`: шрифты, картинки, `AssetManifest`, `NOTICES.Z`, шейдеры) | **Остаются как есть**, их можно извлечь |
| Имена platform channels и методов (`MethodChannel('…')`) | Это строки — читаемы |
| Нативный код (Swift на macOS, C++ на Windows) | Скомпилирован. На macOS главный исполняемый файл проходит strip (нет debug map и локальных символов). Имена Objective-C/Swift-классов, видимые в рантайме, остаются |
| Отладочная информация | Вынесена в `dist/symbols/` (Dart `*.symbols`, dSYM, PDB) и в пакет не входит |
| Секреты | В коде их быть не должно (правило AGENTS.md). Обфускация **не** защищает секреты: любая строка в бинаре извлекается за минуты |

Вывод: не храните в приложении ничего, что нельзя показать пользователю: ключи API, токены, «скрытые» URL.

---

## 4. Symbols: где лежат и как использовать

```
dist/symbols/
├── macos-1.0.0+1/
│   ├── app.darwin-arm64.symbols     # Dart split-debug-info (имена зависят от архитектуры)
│   ├── app.darwin-x86_64.symbols
│   ├── obfuscation-map.json         # только при REBOOT_SAVE_OBFUSCATION_MAP=1
│   └── dSYM/
│       ├── reboot_app.app.dSYM
│       ├── App.framework.dSYM
│       └── FlutterMacOS.framework.dSYM
└── windows-1.0.0+1/
    ├── app.windows-x64.symbols
    └── pdb/*.pdb
```

Точные имена `*.symbols` зависят от версии Flutter и архитектуры — смотрите в каталоге после сборки.

Правила:

- **Symbols не публиковать** и не класть в пакет. Они раскрывают структуру кода.
- Храните их приватно для **каждой** выпущенной версии: стек сбоя можно расшифровать только символами той же сборки. Удобно положить их в приватное хранилище с именем версии и коммита (`VERSION.txt` в пакете содержит коммит).
- `dist/` сейчас **не** указан в `.gitignore`. Рекомендуется добавить строку `/dist/`, чтобы пакеты и symbols случайно не попали в коммит.

Расшифровка Dart-стека из обфусцированной сборки:

```bash
# stack.txt — стек из лога/отчёта пользователя
flutter symbolize -i stack.txt -d dist/symbols/macos-1.0.0+1/app.darwin-arm64.symbols
flutter symbolize -i stack.txt -d dist/symbols/windows-1.0.0+1/app.windows-x64.symbols
```

Сообщения ошибок вида `Instance of 'a3'` (имена классов в тексте исключений) `flutter symbolize` не переводит. Для них нужна карта обфускации (`REBOOT_SAVE_OBFUSCATION_MAP=1` → `obfuscation-map.json`, JSON-массив пар «исходное имя, обфусцированное имя»).

Нативные сбои:

- macOS: `atos -o dist/symbols/.../dSYM/reboot_app.app.dSYM/Contents/Resources/DWARF/reboot_app -arch arm64 -l <load address> <адреса>` или открыть `.ips`-отчёт в Xcode/Console с dSYM рядом. Совпадение проверяйте через `dwarfdump --uuid` (UUID бинаря и dSYM совпадают и после strip — проверено).
- Windows: открыть дамп в WinDbg/Visual Studio с путём к `dist\symbols\…\pdb`.

---

## 5. macOS: подпись Developer ID и notarization

Сейчас сертификатов нет (`security find-identity -v -p codesigning` → 0 identities), поэтому пакеты **не подписаны Developer ID**. Скрипт пишет это явно, а в `VERSION.txt` фиксируется `Code signing: не подписано Developer ID (текущая подпись: adhoc)`. Пользователь видит предупреждение Gatekeeper; инструкция для него — в `README.txt` (контекстное меню «Открыть» / «Всё равно открыть» в настройках / `xattr -dr com.apple.quarantine`).

Когда появится сертификат:

```bash
export REBOOT_MACOS_SIGN_IDENTITY="Developer ID Application: <Имя> (<TEAMID>)"
# один раз сохранить учётные данные notarytool в связку ключей:
xcrun notarytool store-credentials reboot-notary --apple-id <id> --team-id <TEAMID> --password <app-specific password>
export REBOOT_NOTARY_PROFILE=reboot-notary
tools/release/build_macos.sh
```

Что делает скрипт:

- проверяет, что сертификат есть в связке ключей, иначе останавливается;
- `codesign --deep --force --options runtime --timestamp --entitlements macos/Runner/Release.entitlements --sign "$REBOOT_MACOS_SIGN_IDENTITY" REBOOT.app`, затем `codesign --verify --deep --strict`;
- при `REBOOT_NOTARY_PROFILE`: ZIP приложения → `xcrun notarytool submit --keychain-profile … --wait` → `xcrun stapler staple` → `stapler validate`, затем итоговый ZIP пакета. Notarization без подписи скрипт не запускает.

Ограничения:

- Apple не рекомендует `--deep` для подписи: entitlements приложения (`app-sandbox`, `files.user-selected.read-write`) применяются и к вложенным фреймворкам. Для текущего состава (`App.framework`, `FlutterMacOS.framework`) это работает, но при первой настоящей подписи стоит перейти на подпись «изнутри наружу»: фреймворки без entitlements, затем `REBOOT.app` с entitlements.
- Hardened runtime (`--options runtime`) обязателен для notarization. Приложение с ним не проверялось, так как подписи нет. Перед выпуском запустите подписанную сборку и пройдите основные сценарии (коллектор, экспорт через диалог сохранения).
- Notarization требует членства в Apple Developer Program.

## 6. Windows: Authenticode

Без сертификата файлы **не подписаны**: SmartScreen покажет «Система Windows защитила ваш компьютер», пользователь нажимает «Подробнее» → «Выполнить в любом случае» (описано в README).

С сертификатом:

```powershell
$env:REBOOT_WIN_CERT_PATH = "C:\secure\reboot.pfx"
$env:REBOOT_WIN_CERT_PASSWORD = "<пароль>"
# или: $env:REBOOT_WIN_CERT_THUMBPRINT = "<SHA1>"
pwsh tools\release\build_windows.ps1
```

Скрипт ищет `signtool.exe` в PATH или в Windows SDK, подписывает `signtool sign /fd SHA256 /tr <timestamp> /td SHA256` все свои `*.exe`/`*.dll` и проверяет их `signtool verify /pa /all`. Timestamp нужен, чтобы подпись оставалась действительной после истечения срока сертификата.

Замечания:

- Пароль передаётся `signtool` в командной строке (`/p`) и виден другим процессам этой машины. На общих машинах лучше импортировать сертификат в хранилище и использовать `REBOOT_WIN_CERT_THUMBPRINT`, а в CI — эфемерный раннер (как в шаблоне).
- Подпись не убирает предупреждение SmartScreen сразу: репутация файла или издателя накапливается со временем.
- В PE-файлах MSVC обычно сохраняет абсолютный путь к PDB (CodeView), например `C:\Users\<имя>\…\reboot_app.pdb`. `verify_package.py` выдаёт на это предупреждение. Чтобы путь не попадал в exe, можно добавить линкеру `/PDBALTPATH:%_PDB%` в `windows/CMakeLists.txt`. В рамках этой задачи это **не сделано** (код приложения не менялся) и на Windows не проверялось.

---

## 7. Проверка пакета

```bash
python3 tools/release/verify_package.py dist/REBOOT-macOS-v1.0.0.zip
python3 tools/release/verify_package.py --platform windows dist/REBOOT-Windows-v1.0.0.zip
python3 tools/release/verify_package.py --json dist/*.zip
python3 tools/release/test_verify_package.py -v      # самотест, 37 тестов
```

Что проверяется:

1. Целостность (`zipfile.testzip`), отсутствие абсолютных путей и `..` (zip slip).
2. Нет исходников и служебных файлов: `.dart .swift .cpp .cc .h .hpp .m .mm .kt .java .py .ps1 .sh .yaml .yml .lock .iml .pbxproj .pdb .ilk .exp .lib .map .symbols .pem .p12 .pfx .key .mobileprovision`, `.env*`, карты обфускации, каталоги `*.xcodeproj *.xcworkspace *.dSYM`, а также `.git .github .dart_tool .agents .codex` на любом уровне.
3. В корне пакета нет папок `test/ lib/ docs/ logs/ reports/ tasks/ backups/` (`PRIVACY_POLICY.md` лежит в корне как файл).
4. В текстовых файлах нет `BEGIN … PRIVATE KEY`, `ghp_…`, `github_pat_…`, `sk-…` (как отдельный токен: «risk-free» не считается), `AKIA…`, `/Users/…`. Текст определяется по содержимому (нет NUL, валидный UTF-8). В бинарных файлах приватные ключи и пути `/Users/…` / `C:\Users\…` дают предупреждение (`WARN`), а не ошибку.
5. macOS: `REBOOT.app/Contents/Info.plist`, исполняемый файл из `CFBundleExecutable` в `Contents/MacOS/`; предупреждение, если нет `_CodeSignature` или bundle ID отличается от `com.reboot.app.rebootApp`.
   Windows: `reboot_app.exe`, `flutter_windows.dll`, `data/app.so`, `data/icudtl.dat`, `data/flutter_assets/`, три runtime-DLL.
6. Непустые `README.txt`, `VERSION.txt`, `PRIVACY_POLICY.md`, `THIRD_PARTY_NOTICES.txt` в корне пакета.
7. `.DS_Store`, `._*`, `__MACOSX/` — предупреждение.

Коды выхода: `0` — нарушений нет, `1` — есть нарушения, `2` — файл не найден или это не ZIP.

---

## 8. Состав ZIP

macOS (`REBOOT-macOS-v1.0.0.zip`):

```
REBOOT-macOS-v1.0.0/
├── REBOOT.app/
│   └── Contents/
│       ├── Info.plist
│       ├── MacOS/reboot_app                 # Swift runner, после strip
│       ├── Frameworks/App.framework         # Dart AOT (обфусцирован) + flutter_assets
│       ├── Frameworks/FlutterMacOS.framework
│       ├── Resources/
│       └── _CodeSignature/
├── README.txt
├── VERSION.txt
├── PRIVACY_POLICY.md
└── THIRD_PARTY_NOTICES.txt
```

Windows (`REBOOT-Windows-v1.0.0.zip`):

```
REBOOT-Windows-v1.0.0/
├── reboot_app.exe
├── flutter_windows.dll
├── msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll
├── data/
│   ├── app.so                # Dart AOT (обфусцирован)
│   ├── icudtl.dat
│   └── flutter_assets/
├── README.txt
├── VERSION.txt
├── PRIVACY_POLICY.md
└── THIRD_PARTY_NOTICES.txt
```

`PRIVACY_POLICY.md` сейчас — **черновик** с пометками `[НЕ УКАЗАНО: …]` (см. сам документ). До публичного выпуска его нужно заполнить и пройти юридическую проверку. README пакета предупреждает об этом пользователя.

---

## 9. CI (шаблон)

`tools/release/ci/release.yml` — шаблон workflow с jobs `macos-latest` и `windows-latest`. Каждый job:

1. ставит Flutter 3.47.9 (`subosito/flutter-action`), выполняет `flutter pub get`;
2. при наличии секретов импортирует сертификат во временную связку ключей или раскодирует `.pfx` во временный каталог раннера;
3. вызывает `build_macos.sh` / `build_windows.ps1`;
4. отдельно запускает `verify_package.py`;
5. загружает **два разных artifact**: пакет (`retention-days: 30`) и symbols (`reboot-*-symbols-<sha>`, `retention-days: 7`);
6. удаляет связку ключей или сертификат.

Шаблон не активен. Чтобы включить, скопируйте его в `.github/workflows/release.yml` **приватного** репозитория. Artifacts приватного репозитория видны только участникам с доступом. Symbols из CI нужно сразу перенести в постоянное приватное хранилище: через 7 дней они удаляются.

---

## 10. Приватность репозитория

- **Основной репозиторий с исходниками должен быть private.** В нём лежат исходники, архитектура коллектора, внутренние документы (`docs/`, `tasks/`, `reports/`, `logs/`, `.agents`, `.codex`) и инструменты разработки (`tools/orchestrator.py`).
- Если нужен публичный канал распространения, заведите **отдельный публичный репозиторий только для бинарников**: GitHub Releases с ZIP, `.sha256` и короткой страницей описания. Без исходников, без symbols, без CI-секретов.
- Публичный репозиторий собирает пакеты не сам: ZIP собираются в приватном репозитории (или локально), проходят `verify_package.py` и вручную загружаются в Releases.
- Секреты подписи хранятся только в GitHub Secrets приватного репозитория или в связке ключей / хранилище сертификатов машины сборки. Никогда — в репозитории.
- Перед загрузкой сверяйте SHA-256 из `.sha256` с файлом и публикуйте хеш рядом со ссылкой.

---

## 11. Что проверено и что нет

Проверено (5 ноября 2026, macOS, без запуска `flutter build`):

- `bash -n tools/release/build_macos.sh`.
- `test_verify_package.py`: 37 тестов, все проходят.
- `build_macos.sh --skip-build` на синтетическом `.app` во временной папке и на **копии** существующей Release-сборки `build/macos/Build/Products/Release/reboot_app.app` (оригинал не изменяется): dSYM ушли в symbols, strip убрал пути `/Users/…`, ad-hoc-подпись после strip валидна (`codesign --verify --deep --strict`), entitlements сохранены, UUID бинаря совпадает с dSYM, `verify_package.py` → 0 ошибок, `shasum -c` проходит.
- Ветки ошибок: неизвестный сертификат, notarization без подписи, `--skip-build` без `--app`.
- `NOTICES.Z` из реальной сборки распаковывается (gzip).
- `ci/release.yml` синтаксически корректный YAML.

Не проверено:

- `flutter build macos/windows --release --obfuscate` через скрипты: сборки не запускались, потому что каталогом `build/` пользуются другие.
- Подпись Developer ID, notarization и Authenticode: сертификатов нет.
- Запуск упакованного приложения после strip и повторной ad-hoc-подписи.
- `build_windows.ps1`: PowerShell на машине нет. Проверены только BOM и баланс скобок; на Windows скрипт не запускался.
- Шаблон CI в GitHub Actions не запускался.
