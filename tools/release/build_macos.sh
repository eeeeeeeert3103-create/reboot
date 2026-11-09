#!/usr/bin/env bash
# REBOOT — Release-сборка и упаковка для macOS.
#
#   tools/release/build_macos.sh                 # сборка + упаковка в dist/
#   tools/release/build_macos.sh --skip-build --app path/to/reboot_app.app
#                                                # только упаковка готового .app
#   tools/release/build_macos.sh --dist /tmp/out # другой каталог результата
#
# Переменные окружения (все необязательные):
#   REBOOT_MACOS_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)" — подписать.
#   REBOOT_NOTARY_PROFILE        профиль `xcrun notarytool store-credentials` —
#                                отправить на notarization (только вместе с подписью).
#   REBOOT_SAVE_OBFUSCATION_MAP  1 — сохранить карту обфускации Dart в symbols.
#   REBOOT_SKIP_VERIFY           1 — не запускать verify_package.py в конце.
#
# Результат:
#   dist/REBOOT-macOS-v<version>.zip, dist/REBOOT-macOS-v<version>.zip.sha256
#   dist/symbols/macos-<version>+<build>/  (split-debug-info, dSYM) — НЕ для пользователей.
#
# Скрипт работает только на macOS (ditto, codesign). Совместим с bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log()  { printf '[build_macos] %s\n' "$*"; }
warn() { printf '[build_macos] ВНИМАНИЕ: %s\n' "$*" >&2; }
die()  { printf '[build_macos] ОШИБКА: %s\n' "$*" >&2; exit 1; }

SKIP_BUILD=0
APP_SRC=""
DIST="$ROOT/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --app)        shift; [ $# -gt 0 ] || die "--app требует путь"; APP_SRC="$1" ;;
    --dist)       shift; [ $# -gt 0 ] || die "--dist требует путь"; DIST="$1" ;;
    -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
    *)            die "неизвестный аргумент: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "скрипт запускается только на macOS"
for tool in ditto codesign python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "не найден инструмент: $tool"
done

# --- Версия из pubspec.yaml -------------------------------------------------
FULL_VERSION="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$ROOT/pubspec.yaml" | head -n 1)"
[ -n "$FULL_VERSION" ] || die "не удалось прочитать version из pubspec.yaml"
VERSION="${FULL_VERSION%%+*}"
case "$FULL_VERSION" in *+*) BUILD_NUMBER="${FULL_VERSION#*+}" ;; *) BUILD_NUMBER="0" ;; esac
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "неожиданный формат версии: $FULL_VERSION"
log "версия $VERSION (build $BUILD_NUMBER)"

mkdir -p "$DIST"
DIST="$(cd "$DIST" && pwd)"
PKG_NAME="REBOOT-macOS-v$VERSION"
SYMBOLS_DIR="$DIST/symbols/macos-$FULL_VERSION"
STAGE_ROOT="$DIST/staging/macos"
STAGE="$STAGE_ROOT/$PKG_NAME"
ZIP_PATH="$DIST/$PKG_NAME.zip"
mkdir -p "$SYMBOLS_DIR"

# --- Сборка -----------------------------------------------------------------
OBFUSCATED="да (--obfuscate --split-debug-info)"
if [ "$SKIP_BUILD" -eq 0 ]; then
  command -v flutter >/dev/null 2>&1 || die "flutter не найден в PATH"
  BUILD_ARGS=(build macos --release --obfuscate "--split-debug-info=$SYMBOLS_DIR")
  if [ "${REBOOT_SAVE_OBFUSCATION_MAP:-0}" = "1" ]; then
    BUILD_ARGS+=("--extra-gen-snapshot-options=--save-obfuscation-map=$SYMBOLS_DIR/obfuscation-map.json")
  fi
  log "flutter ${BUILD_ARGS[*]}"
  (cd "$ROOT" && flutter "${BUILD_ARGS[@]}")
  PRODUCTS="$ROOT/build/macos/Build/Products/Release"
  if [ -z "$APP_SRC" ]; then
    APP_SRC="$PRODUCTS/reboot_app.app"
  fi
else
  [ -n "$APP_SRC" ] || die "--skip-build требует --app <путь к .app>"
  OBFUSCATED="неизвестно (упакована готовая сборка, --skip-build)"
  warn "сборка пропущена: упаковывается готовый $APP_SRC"
fi

[ -d "$APP_SRC" ] || die "не найден .app: $APP_SRC"
[ -f "$APP_SRC/Contents/Info.plist" ] || die "в $APP_SRC нет Contents/Info.plist"
[ -d "$APP_SRC/Contents/MacOS" ] || die "в $APP_SRC нет Contents/MacOS"
APP_SRC="$(cd "$APP_SRC" && pwd)"
PRODUCTS_DIR="$(dirname "$APP_SRC")"

# --- dSYM -> symbols (не в пакет) ------------------------------------------
DSYM_COUNT=0
for dsym in "$PRODUCTS_DIR"/*.dSYM; do
  [ -d "$dsym" ] || continue
  mkdir -p "$SYMBOLS_DIR/dSYM"
  rm -rf "$SYMBOLS_DIR/dSYM/$(basename "$dsym")"
  ditto "$dsym" "$SYMBOLS_DIR/dSYM/$(basename "$dsym")"
  DSYM_COUNT=$((DSYM_COUNT + 1))
done
if [ "$DSYM_COUNT" -gt 0 ]; then
  log "dSYM скопированы в symbols: $DSYM_COUNT"
else
  log "dSYM рядом с .app не найдены (это не ошибка)"
fi

# --- Staging ----------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE"
APP_DST="$STAGE/REBOOT.app"
log "копирование $(basename "$APP_SRC") -> $APP_DST"
ditto "$APP_SRC" "$APP_DST"

# Вычищаем то, что не должно попасть к пользователю.
find "$APP_DST" \( -name '*.dSYM' -o -name '.DS_Store' -o -name '*.symbols' -o -name '*.map' \) -prune -exec rm -rf {} + 2>/dev/null || true

ENTITLEMENTS="$ROOT/macos/Runner/Release.entitlements"

# --- Strip главного исполняемого файла ------------------------------------
# Flutter/Xcode оставляют в Contents/MacOS/<exe> debug map (N_OSO) с абсолютными
# путями к объектным файлам (build/.../Intermediates.noindex), то есть с именем
# пользователя и структурой каталогов. dSYM уже сохранён выше, UUID при strip
# не меняется, поэтому символизация нативных сбоев сохраняется.
# Отключить: REBOOT_MACOS_STRIP=0.
STRIP_STATUS="нет"
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DST/Contents/Info.plist" 2>/dev/null || true)"
EXE_PATH="$APP_DST/Contents/MacOS/${EXE_NAME:-reboot_app}"
if [ "${REBOOT_MACOS_STRIP:-1}" = "1" ] && [ -f "$EXE_PATH" ] && file "$EXE_PATH" | grep -q 'Mach-O'; then
  log "strip -S -x $(basename "$EXE_PATH") (удаление debug map и локальных символов)"
  xcrun strip -S -x "$EXE_PATH"
  STRIP_STATUS="да (strip -S -x главного исполняемого файла)"
  if [ -z "${REBOOT_MACOS_SIGN_IDENTITY:-}" ]; then
    # strip ломает прежнюю подпись; без Developer ID восстанавливаем ad-hoc
    # (на Apple Silicon неподписанный arm64-код не запускается вовсе).
    [ -f "$ENTITLEMENTS" ] || die "нет $ENTITLEMENTS"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DST"
    codesign --verify --strict "$APP_DST"
    log "ad-hoc подпись восстановлена после strip (это НЕ подпись Developer ID)"
  fi
fi

# --- Подпись ----------------------------------------------------------------
SIGN_STATUS=""
if [ -n "${REBOOT_MACOS_SIGN_IDENTITY:-}" ]; then
  [ -f "$ENTITLEMENTS" ] || die "нет $ENTITLEMENTS"
  if ! security find-identity -v -p codesigning | grep -Fq "$REBOOT_MACOS_SIGN_IDENTITY"; then
    die "сертификат «$REBOOT_MACOS_SIGN_IDENTITY» не найден в связке ключей (security find-identity -v -p codesigning)"
  fi
  log "подпись Developer ID: $REBOOT_MACOS_SIGN_IDENTITY"
  codesign --deep --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$REBOOT_MACOS_SIGN_IDENTITY" "$APP_DST"
  codesign --verify --deep --strict --verbose=2 "$APP_DST"
  SIGN_STATUS="подписано Developer ID ($REBOOT_MACOS_SIGN_IDENTITY), hardened runtime"
else
  warn "REBOOT_MACOS_SIGN_IDENTITY не задана: приложение НЕ подписано Developer ID."
  warn "Gatekeeper покажет предупреждение; пользователю нужно снять карантин или открыть через контекстное меню."
  CURRENT_SIG="$( { codesign -dv "$APP_DST" 2>&1 || true; } | sed -n 's/^Signature=//p' | head -n 1)"
  SIGN_STATUS="не подписано Developer ID (текущая подпись: ${CURRENT_SIG:-нет})"
fi

# --- Notarization (заготовка) ----------------------------------------------
NOTARY_STATUS="не выполнялась"
if [ -n "${REBOOT_NOTARY_PROFILE:-}" ]; then
  [ -n "${REBOOT_MACOS_SIGN_IDENTITY:-}" ] || die "REBOOT_NOTARY_PROFILE задан, но нет подписи Developer ID: notarization невозможна"
  NOTARY_ZIP="$STAGE_ROOT/notarize-$PKG_NAME.zip"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_DST" "$NOTARY_ZIP"
  log "xcrun notarytool submit (профиль $REBOOT_NOTARY_PROFILE), ожидание результата..."
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$REBOOT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DST"
  xcrun stapler validate "$APP_DST"
  rm -f "$NOTARY_ZIP"
  NOTARY_STATUS="notarized, ticket stapled"
else
  log "REBOOT_NOTARY_PROFILE не задан: notarization пропущена"
fi

# --- Документы пакета -------------------------------------------------------
README_TEMPLATE="$SCRIPT_DIR/README-package.txt"
[ -f "$README_TEMPLATE" ] || die "нет $README_TEMPLATE"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD_NUMBER/g" "$README_TEMPLATE" > "$STAGE/README.txt"

[ -f "$ROOT/docs/privacy-policy.md" ] || die "нет docs/privacy-policy.md"
cp "$ROOT/docs/privacy-policy.md" "$STAGE/PRIVACY_POLICY.md"

NOTICES_Z="$(find "$APP_DST/Contents/Frameworks" -path '*flutter_assets/NOTICES.Z' -type f 2>/dev/null | head -n 1 || true)"
[ -n "$NOTICES_Z" ] || die "NOTICES.Z не найден во flutter_assets"
python3 "$SCRIPT_DIR/extract_notices.py" "$NOTICES_Z" "$STAGE/THIRD_PARTY_NOTICES.txt"

GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'неизвестно')"
GIT_DIRTY=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  GIT_DIRTY=" (рабочее дерево с незакоммиченными изменениями)"
fi
cat > "$STAGE/VERSION.txt" <<EOF
Product:        REBOOT
Platform:       macOS
Version:        $VERSION
Build:          $BUILD_NUMBER
Bundle ID:      com.reboot.app.rebootApp
Commit:         $GIT_COMMIT$GIT_DIRTY
Built (UTC):    $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Dart obfuscation: $OBFUSCATED
Native strip:   $STRIP_STATUS
Code signing:   $SIGN_STATUS
Notarization:   $NOTARY_STATUS
EOF

# --- ZIP + SHA-256 ----------------------------------------------------------
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
log "упаковка -> $ZIP_PATH"
# --norsrc/--noextattr/--noacl: не тащить в ZIP AppleDouble-файлы ._* с xattr
# (карантин, provenance, Finder-метки). Подпись бандла хранится в
# _CodeSignature и Mach-O и от xattr не зависит.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$STAGE" "$ZIP_PATH"
(cd "$DIST" && shasum -a 256 "$PKG_NAME.zip" > "$PKG_NAME.zip.sha256")
log "SHA-256: $(cut -d' ' -f1 "$ZIP_PATH.sha256")"

# --- Проверка пакета --------------------------------------------------------
if [ "${REBOOT_SKIP_VERIFY:-0}" != "1" ]; then
  python3 "$SCRIPT_DIR/verify_package.py" --platform macos "$ZIP_PATH"
fi

log "готово."
log "  пакет:   $ZIP_PATH"
log "  symbols: $SYMBOLS_DIR (хранить приватно, в пакет не входят)"
log "  подпись: $SIGN_STATUS"
