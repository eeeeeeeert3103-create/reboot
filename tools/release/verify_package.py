#!/usr/bin/env python3
"""Проверка релизного ZIP-пакета REBOOT перед публикацией.

Только стандартная библиотека Python 3.8+.

    python3 tools/release/verify_package.py dist/REBOOT-macOS-v1.0.0.zip
    python3 tools/release/verify_package.py --platform windows dist/REBOOT-Windows-v1.0.0.zip
    python3 tools/release/verify_package.py --json dist/*.zip

Что проверяется:
  1. целостность ZIP (zipfile.testzip) и безопасность путей (нет абсолютных путей и "..");
  2. нет исходников, служебных и отладочных файлов (.dart, .pdb, .dSYM, .git, ключи и т. п.);
  3. нет папок разработки (test/, lib/, docs/, logs/, tasks/ ... в корне пакета);
  4. в текстовых файлах нет подозрительных строк (приватные ключи, токены, путь /Users/);
  5. структура приложения для macOS или Windows;
  6. есть README.txt, VERSION.txt, PRIVACY_POLICY.md, THIRD_PARTY_NOTICES.txt.

Коды выхода: 0 — нарушений нет; 1 — есть нарушения; 2 — ошибка запуска (нет файла, не ZIP).
Предупреждения (WARN) на код выхода не влияют.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import PurePosixPath
from typing import Dict, List, Optional

# --- Правила ----------------------------------------------------------------

FORBIDDEN_EXTENSIONS = (
    ".dart", ".swift", ".cpp", ".cc", ".h", ".hpp", ".m", ".mm", ".kt", ".java",
    ".py", ".ps1", ".sh", ".yaml", ".yml", ".lock", ".iml",
    ".pbxproj", ".pdb", ".ilk", ".exp", ".lib", ".map", ".symbols",
    ".pem", ".p12", ".pfx", ".key", ".mobileprovision",
)

# Каталоги-«пакеты» и служебные папки: запрещены на любом уровне вложенности.
FORBIDDEN_DIR_SUFFIXES = (".xcodeproj", ".xcworkspace", ".dsym")
FORBIDDEN_ANY_LEVEL_DIRS = {".git", ".github", ".dart_tool", ".agents", ".codex"}

# Папки репозитория: запрещены в корне пакета (внутри flutter_assets/packages
# могут легально встречаться похожие имена у сторонних пакетов).
FORBIDDEN_TOP_LEVEL_DIRS = {"test", "lib", "docs", "logs", "reports", "tasks", "backups"}

REQUIRED_DOCS = ("README.txt", "VERSION.txt", "PRIVACY_POLICY.md", "THIRD_PARTY_NOTICES.txt")

WINDOWS_REQUIRED = (
    "reboot_app.exe",
    "flutter_windows.dll",
    "data/app.so",
    "data/icudtl.dat",
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
)

MAC_APP = "REBOOT.app"

SUSPICIOUS_PATTERNS = (
    ("приватный ключ", re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("GitHub-токен ghp_", re.compile(rb"ghp_[A-Za-z0-9]{20,}")),
    ("GitHub-токен github_pat_", re.compile(rb"github_pat_[A-Za-z0-9_]{20,}")),
    ("API-ключ sk-", re.compile(rb"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{16,}")),
    ("AWS access key AKIA", re.compile(rb"AKIA[0-9A-Z]{16}")),
    ("локальный путь /Users/", re.compile(rb"/Users/[^\s/\"'<>]+")),
)
# В бинарных файлах ищем только самое опасное, и только как предупреждение
# (например, пути сборки в debug map Mach-O или путь к PDB в PE).
BINARY_WARN_PATTERNS = (
    SUSPICIOUS_PATTERNS[0],
    SUSPICIOUS_PATTERNS[5],
    ("локальный путь C:\\Users\\", re.compile(rb"[A-Za-z]:\\Users\\[^\\<>\x00\s]+")),
)

MAX_TEXT_SCAN_BYTES = 32 * 1024 * 1024


@dataclass
class Report:
    path: str
    platform: Optional[str] = None
    root_prefix: str = ""
    entries: int = 0
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


# --- Вспомогательные функции -----------------------------------------------

def normalize(name: str) -> str:
    return name.replace("\\", "/")


def detect_root_prefix(names: List[str]) -> str:
    """Если всё лежит в одной верхней папке (REBOOT-macOS-v1.0.0/...), вернуть её."""
    names = [n for n in names if n and not n.startswith("__MACOSX/")]
    tops = {n.split("/", 1)[0] for n in names}
    if len(tops) != 1:
        return ""
    top = next(iter(tops))
    if top == MAC_APP or top.lower().endswith(".app"):
        return ""
    if all(n == top or n == top + "/" or n.startswith(top + "/") for n in names):
        has_children = any(n.startswith(top + "/") and len(n) > len(top) + 1 for n in names)
        if has_children:
            return top + "/"
    return ""


def looks_like_text(data: bytes) -> bool:
    head = data[:8192]
    if not head:
        return False
    if b"\x00" in head:
        return False
    try:
        head.decode("utf-8")
        return True
    except UnicodeDecodeError as exc:
        # Обрезанный многобайтовый символ в конце блока — всё ещё текст.
        return exc.start >= len(head) - 4


def is_symlink(info: zipfile.ZipInfo) -> bool:
    return info.create_system == 3 and ((info.external_attr >> 16) & 0o170000) == 0o120000


def detect_platform(rel_names: set) -> Optional[str]:
    if any(n == MAC_APP + "/" or n.startswith(MAC_APP + "/") for n in rel_names):
        return "macos"
    if "reboot_app.exe" in rel_names:
        return "windows"
    return None


# --- Проверки ---------------------------------------------------------------

def check_forbidden(rel: str, is_dir: bool, report: Report) -> None:
    parts = [p for p in rel.split("/") if p]
    if not parts:
        return
    lower_parts = [p.lower() for p in parts]

    if lower_parts[0] in FORBIDDEN_TOP_LEVEL_DIRS and (len(parts) > 1 or is_dir):
        report.error(f"папка разработки в корне пакета: {rel}")
        return

    for comp in lower_parts[:-1] if not is_dir else lower_parts:
        if comp in FORBIDDEN_ANY_LEVEL_DIRS:
            report.error(f"служебная папка {comp}: {rel}")
            return
        if comp.endswith(FORBIDDEN_DIR_SUFFIXES):
            report.error(f"служебный/отладочный каталог {comp}: {rel}")
            return

    if is_dir:
        return
    name = lower_parts[-1]
    if name in FORBIDDEN_ANY_LEVEL_DIRS:
        report.error(f"служебный файл {name}: {rel}")
    elif name == ".env" or name.startswith(".env."):
        report.error(f"файл окружения: {rel}")
    elif name.endswith(FORBIDDEN_EXTENSIONS):
        report.error(f"запрещённый тип файла ({PurePosixPath(name).suffix}): {rel}")
    elif "obfuscation-map" in name or name.endswith(".map.json"):
        report.error(f"карта обфускации в пакете: {rel}")
    elif name == ".ds_store" or name.startswith("._") or "__macosx" in lower_parts:
        report.warn(f"служебный файл macOS (метаданные Finder/xattr): {rel}")


def scan_content(rel: str, data: bytes, report: Report) -> None:
    if looks_like_text(data):
        for label, rx in SUSPICIOUS_PATTERNS:
            m = rx.search(data[:MAX_TEXT_SCAN_BYTES])
            if m:
                snippet = m.group(0)[:40].decode("utf-8", "replace")
                report.error(f"подозрительная строка ({label}) в {rel}: «{snippet}…»")
    else:
        for label, rx in BINARY_WARN_PATTERNS:
            m = rx.search(data)
            if m:
                snippet = m.group(0)[:60].decode("utf-8", "replace")
                report.warn(f"в бинарном файле {rel} найдено ({label}): «{snippet}»")


def check_macos(zf: zipfile.ZipFile, rel_to_name: Dict[str, str], report: Report) -> None:
    plist_rel = f"{MAC_APP}/Contents/Info.plist"
    macos_dir = f"{MAC_APP}/Contents/MacOS/"
    if plist_rel not in rel_to_name:
        report.error(f"нет {plist_rel}")
    binaries = [r for r in rel_to_name if r.startswith(macos_dir) and not r.endswith("/") and r != macos_dir]
    if not binaries:
        report.error(f"нет исполняемого файла в {macos_dir}")
    if plist_rel in rel_to_name:
        try:
            info = plistlib.loads(zf.read(rel_to_name[plist_rel]))
        except Exception as exc:  # noqa: BLE001 — любая ошибка разбора = нарушение
            report.error(f"Info.plist не читается: {exc}")
            return
        exe = info.get("CFBundleExecutable")
        if exe and f"{macos_dir}{exe}" not in rel_to_name:
            report.error(f"CFBundleExecutable={exe}, но {macos_dir}{exe} нет в пакете")
        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id and bundle_id != "com.reboot.app.rebootApp":
            report.warn(f"неожиданный CFBundleIdentifier: {bundle_id}")
    if not any(r.endswith("/_CodeSignature/CodeResources") and r.startswith(f"{MAC_APP}/Contents/") for r in rel_to_name):
        report.warn("у REBOOT.app нет _CodeSignature: бандл не подписан даже ad-hoc")


def check_windows(rel_to_name: Dict[str, str], report: Report) -> None:
    lower = {r.lower(): r for r in rel_to_name}
    for req in WINDOWS_REQUIRED:
        if req.lower() not in lower:
            report.error(f"нет обязательного файла Windows: {req}")
    if not any(r.lower().startswith("data/flutter_assets/") for r in rel_to_name):
        report.error("нет data/flutter_assets/")


def verify(path: str, platform: str = "auto") -> Report:
    report = Report(path=path)
    try:
        zf = zipfile.ZipFile(path)
    except FileNotFoundError:
        report.error("файл не найден")
        return report
    except zipfile.BadZipFile as exc:
        report.error(f"не ZIP или повреждён: {exc}")
        return report

    with zf:
        try:
            bad = zf.testzip()
        except Exception as exc:  # noqa: BLE001
            bad = f"<ошибка чтения: {exc}>"
        if bad is not None:
            report.error(f"повреждённая запись (testzip): {bad}")

        infos = zf.infolist()
        report.entries = len(infos)
        if not infos:
            report.error("архив пуст")
            return report

        if any("\\" in i.filename for i in infos):
            report.warn("в именах записей есть обратные слэши (старый Compress-Archive?); проверено после нормализации")

        names = [normalize(i.filename) for i in infos]
        prefix = detect_root_prefix(names)
        report.root_prefix = prefix

        rel_to_name: Dict[str, str] = {}
        for info, name in zip(infos, names):
            if name.startswith("/") or re.match(r"^[A-Za-z]:", name) or ".." in name.split("/"):
                report.error(f"небезопасный путь в архиве: {info.filename}")
                continue
            rel = name[len(prefix):] if prefix and name.startswith(prefix) else name
            if not rel:
                continue
            rel_to_name[rel] = info.filename
            is_dir = info.is_dir() or rel.endswith("/")
            check_forbidden(rel.rstrip("/") if is_dir else rel, is_dir, report)
            if is_dir or is_symlink(info):
                continue
            try:
                data = zf.read(info.filename)
            except Exception as exc:  # noqa: BLE001
                report.error(f"не удалось прочитать {rel}: {exc}")
                continue
            scan_content(rel, data, report)

        # Добавляем неявные каталоги (zip может не содержать записей для папок).
        rel_set = set(rel_to_name)
        for rel in list(rel_to_name):
            parts = rel.rstrip("/").split("/")
            for i in range(1, len(parts)):
                rel_set.add("/".join(parts[:i]) + "/")

        detected = detect_platform(rel_set)
        if platform == "auto":
            platform = detected or ""
            if not platform:
                report.error("не удалось определить платформу: нет ни REBOOT.app, ни reboot_app.exe")
        elif detected and detected != platform:
            report.error(f"ожидалась платформа {platform}, а в пакете похоже {detected}")
        report.platform = platform or None

        if platform == "macos":
            check_macos(zf, rel_to_name, report)
        elif platform == "windows":
            check_windows(rel_to_name, report)

        for doc in REQUIRED_DOCS:
            if doc not in rel_to_name:
                report.error(f"нет обязательного документа в корне пакета: {doc}")
            elif zf.getinfo(rel_to_name[doc]).file_size == 0:
                report.error(f"пустой документ: {doc}")

    return report


def print_report(r: Report) -> None:
    status = "OK" if r.ok else "НАРУШЕНИЯ"
    print(f"=== {r.path}")
    print(f"    платформа: {r.platform or '?'}; записей: {r.entries}; корень: {r.root_prefix or '(корень архива)'}")
    for e in r.errors:
        print(f"    [ERROR] {e}")
    for w in r.warnings:
        print(f"    [WARN]  {w}")
    print(f"    итог: {status} (ошибок: {len(r.errors)}, предупреждений: {len(r.warnings)})")


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Проверка релизного ZIP REBOOT")
    ap.add_argument("zips", nargs="+", help="пути к ZIP-пакетам")
    ap.add_argument("--platform", choices=("auto", "macos", "windows"), default="auto")
    ap.add_argument("--json", action="store_true", help="вывести отчёт в JSON")
    args = ap.parse_args(argv)

    reports = [verify(p, args.platform) for p in args.zips]
    if args.json:
        print(json.dumps([{**r.__dict__, "ok": r.ok} for r in reports], ensure_ascii=False, indent=2))
    else:
        for r in reports:
            print_report(r)

    if any(r.errors == ["файл не найден"] or (r.errors and r.errors[0].startswith("не ZIP")) for r in reports):
        return 2
    return 0 if all(r.ok for r in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
