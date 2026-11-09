#!/usr/bin/env python3
"""Самотест verify_package.py и extract_notices.py на синтетических ZIP.

    python3 tools/release/test_verify_package.py -v

Только стандартная библиотека; всё создаётся во временной папке ($TMPDIR).
"""
from __future__ import annotations

import contextlib
import gzip
import io
import os
import plistlib
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_notices  # noqa: E402
import verify_package  # noqa: E402

DOCS = {
    "README.txt": "REBOOT readme\n",
    "VERSION.txt": "Version: 1.0.0\n",
    "PRIVACY_POLICY.md": "# Политика\nC:\\Users\\<имя>\\AppData\\Local\\REBOOT\\\n",
    "THIRD_PARTY_NOTICES.txt": "Apache License, risk-free, task-runner, desk-top\n",
}


def mac_files(prefix: str = "REBOOT-macOS-v1.0.0/") -> dict:
    plist = plistlib.dumps({
        "CFBundleExecutable": "reboot_app",
        "CFBundleIdentifier": "com.reboot.app.rebootApp",
    })
    files = {
        "REBOOT.app/Contents/Info.plist": plist,
        "REBOOT.app/Contents/MacOS/reboot_app": b"\xcf\xfa\xed\xfe\x00\x00binary",
        "REBOOT.app/Contents/_CodeSignature/CodeResources": b"<plist/>",
        "REBOOT.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/NOTICES.Z":
            gzip.compress(b"licenses"),
        "REBOOT.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/shaders/ink_sparkle.frag":
            b"\x00\x01shader",
    }
    files.update({k: v.encode() for k, v in DOCS.items()})
    return {prefix + k: v for k, v in files.items()}


def win_files(prefix: str = "REBOOT-Windows-v1.0.0/") -> dict:
    files = {
        "reboot_app.exe": b"MZ\x00\x00exe",
        "flutter_windows.dll": b"MZ\x00\x00dll",
        "msvcp140.dll": b"MZ\x00\x00",
        "vcruntime140.dll": b"MZ\x00\x00",
        "vcruntime140_1.dll": b"MZ\x00\x00",
        "data/app.so": b"\x7fELF\x00aot",
        "data/icudtl.dat": b"\x00icu",
        "data/flutter_assets/NOTICES.Z": gzip.compress(b"licenses"),
        "data/flutter_assets/AssetManifest.bin": b"\x00\x01",
    }
    files.update({k: v.encode() for k, v in DOCS.items()})
    return {prefix + k: v for k, v in files.items()}


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="reboot-verify-test-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def make_zip(self, files: dict, name: str = "pkg.zip", backslashes: bool = False) -> str:
        path = self.tmp / name
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
            for arc, data in files.items():
                if backslashes:
                    arc = arc.replace("/", "\\")
                zf.writestr(arc, data)
        return str(path)

    def assertHasError(self, report, needle: str) -> None:
        self.assertFalse(report.ok, f"ожидались ошибки, отчёт чистый")
        self.assertTrue(any(needle in e for e in report.errors),
                        f"нет ошибки с «{needle}» среди: {report.errors}")


class ValidPackages(Base):
    def test_macos_ok_with_top_folder(self):
        r = verify_package.verify(self.make_zip(mac_files()), "auto")
        self.assertEqual(r.platform, "macos")
        self.assertEqual(r.root_prefix, "REBOOT-macOS-v1.0.0/")
        self.assertTrue(r.ok, r.errors)

    def test_macos_ok_without_top_folder(self):
        r = verify_package.verify(self.make_zip(mac_files(prefix="")), "macos")
        self.assertTrue(r.ok, r.errors)

    def test_windows_ok(self):
        r = verify_package.verify(self.make_zip(win_files()), "windows")
        self.assertEqual(r.platform, "windows")
        self.assertTrue(r.ok, r.errors)

    def test_windows_backslash_names_normalized(self):
        r = verify_package.verify(self.make_zip(win_files(), backslashes=True), "auto")
        self.assertTrue(r.ok, r.errors)
        self.assertTrue(any("обратные слэши" in w for w in r.warnings))

    def test_sk_inside_words_is_not_flagged(self):
        # "risk-free", "task-runner" не должны считаться ключами sk-.
        r = verify_package.verify(self.make_zip(mac_files()), "macos")
        self.assertFalse(any("sk-" in e for e in r.errors), r.errors)


class Structure(Base):
    def test_missing_docs(self):
        files = mac_files()
        del files["REBOOT-macOS-v1.0.0/THIRD_PARTY_NOTICES.txt"]
        del files["REBOOT-macOS-v1.0.0/VERSION.txt"]
        r = verify_package.verify(self.make_zip(files), "macos")
        self.assertHasError(r, "THIRD_PARTY_NOTICES.txt")
        self.assertHasError(r, "VERSION.txt")

    def test_empty_doc(self):
        files = mac_files()
        files["REBOOT-macOS-v1.0.0/README.txt"] = b""
        self.assertHasError(verify_package.verify(self.make_zip(files), "macos"), "пустой документ")

    def test_macos_missing_binary_and_plist(self):
        files = {k: v for k, v in mac_files().items() if "/Contents/MacOS/" not in k and not k.endswith("Info.plist")}
        r = verify_package.verify(self.make_zip(files), "macos")
        self.assertHasError(r, "Info.plist")
        self.assertHasError(r, "Contents/MacOS")

    def test_macos_executable_mismatch(self):
        files = mac_files()
        files["REBOOT-macOS-v1.0.0/REBOOT.app/Contents/Info.plist"] = plistlib.dumps({"CFBundleExecutable": "other"})
        self.assertHasError(verify_package.verify(self.make_zip(files), "macos"), "CFBundleExecutable")

    def test_windows_missing_runtime(self):
        files = win_files()
        del files["REBOOT-Windows-v1.0.0/vcruntime140_1.dll"]
        del files["REBOOT-Windows-v1.0.0/data/app.so"]
        r = verify_package.verify(self.make_zip(files), "windows")
        self.assertHasError(r, "vcruntime140_1.dll")
        self.assertHasError(r, "data/app.so")

    def test_platform_mismatch(self):
        self.assertHasError(verify_package.verify(self.make_zip(win_files()), "macos"), "ожидалась платформа")

    def test_unknown_platform(self):
        self.assertHasError(verify_package.verify(self.make_zip({k: v.encode() for k, v in DOCS.items()}), "auto"),
                            "не удалось определить платформу")


class Forbidden(Base):
    def check(self, extra: dict, needle: str, base=None):
        files = (base or mac_files)()
        files.update(extra)
        self.assertHasError(verify_package.verify(self.make_zip(files), "auto"), needle)

    def test_source_files(self):
        for ext in (".dart", ".swift", ".cpp", ".kt", ".py", ".ps1", ".sh", ".yaml", ".lock", ".h"):
            with self.subTest(ext=ext):
                self.check({f"REBOOT-macOS-v1.0.0/REBOOT.app/Contents/Resources/x{ext}": b"x"}, "запрещённый тип")

    def test_debug_files_windows(self):
        for name in ("reboot_app.pdb", "reboot_app.ilk", "flutter_windows.dll.lib", "reboot_app.exp", "app.symbols"):
            with self.subTest(name=name):
                self.check({f"REBOOT-Windows-v1.0.0/{name}": b"x"}, "запрещённый тип", base=win_files)

    def test_secrets_files(self):
        for name in ("cert.p12", "signing.pfx", "id.pem", "dev.key", "a.mobileprovision", ".env", ".env.local"):
            with self.subTest(name=name):
                files = mac_files()
                files[f"REBOOT-macOS-v1.0.0/{name}"] = b"x"
                r = verify_package.verify(self.make_zip(files), "macos")
                self.assertFalse(r.ok, name)

    def test_dsym_and_xcode_dirs(self):
        self.check({"REBOOT-macOS-v1.0.0/reboot_app.app.dSYM/Contents/Info.plist": b"x"}, ".dsym")
        self.check({"REBOOT-macOS-v1.0.0/Runner.xcodeproj/project.pbxproj": b"x"}, "xcodeproj")
        self.check({"REBOOT-macOS-v1.0.0/Runner.xcworkspace/contents.xcworkspacedata": b"x"}, "xcworkspace")

    def test_service_dirs_any_level(self):
        for d in (".git", ".github", ".dart_tool", ".agents", ".codex"):
            with self.subTest(d=d):
                self.check({f"REBOOT-macOS-v1.0.0/REBOOT.app/Contents/{d}/config": b"x"}, "служебная папка")

    def test_repo_dirs_top_level(self):
        for d in ("test", "lib", "docs", "logs", "reports", "tasks", "backups"):
            with self.subTest(d=d):
                self.check({f"REBOOT-macOS-v1.0.0/{d}/file.txt": b"x"}, "папка разработки")

    def test_obfuscation_map(self):
        self.check({"REBOOT-macOS-v1.0.0/obfuscation-map.json": b"[]"}, "карта обфускации")

    def test_zip_slip(self):
        self.check({"../evil.txt": b"x"}, "небезопасный путь")


class Secrets(Base):
    def check_text(self, text: bytes, needle: str):
        files = mac_files()
        files["REBOOT-macOS-v1.0.0/REBOOT.app/Contents/Resources/config.json"] = text
        self.assertHasError(verify_package.verify(self.make_zip(files), "macos"), needle)

    def test_private_key(self):
        self.check_text(b"-----BEGIN RSA PRIVATE KEY-----\nMIIE...", "приватный ключ")
        self.check_text(b"-----BEGIN PRIVATE KEY-----\nMIIE...", "приватный ключ")

    def test_github_token(self):
        self.check_text(b'{"t":"ghp_' + b"a" * 36 + b'"}', "ghp_")

    def test_openai_key(self):
        self.check_text(b"key=sk-proj-" + b"A1" * 12, "sk-")

    def test_aws_key(self):
        self.check_text(b"AKIAIOSFODNN7EXAMPLE", "AKIA")

    def test_users_path(self):
        self.check_text(b"built at /Users/someone/REBOOT/lib/main.dart", "/Users/")

    def test_binary_users_path_is_warning_only(self):
        files = mac_files()
        files["REBOOT-macOS-v1.0.0/REBOOT.app/Contents/MacOS/reboot_app"] = b"\x00\x00/Users/someone/build\x00"
        r = verify_package.verify(self.make_zip(files), "macos")
        self.assertTrue(r.ok, r.errors)
        self.assertTrue(any("/Users/" in w for w in r.warnings))


class MacMetadata(Base):
    def test_appledouble_and_ds_store_are_warnings(self):
        files = mac_files()
        files["REBOOT-macOS-v1.0.0/._README.txt"] = b"\x00\x05\x16\x07xattr"
        files["REBOOT-macOS-v1.0.0/.DS_Store"] = b"\x00\x00\x00\x01Bud1"
        files["__MACOSX/REBOOT-macOS-v1.0.0/._REBOOT.app"] = b"\x00\x05\x16\x07"
        r = verify_package.verify(self.make_zip(files), "macos")
        self.assertTrue(r.ok, r.errors)
        self.assertGreaterEqual(sum("служебный файл macOS" in w for w in r.warnings), 3)


class WindowsBinaryPaths(Base):
    def test_pdb_path_in_exe_is_warning(self):
        files = win_files()
        files["REBOOT-Windows-v1.0.0/reboot_app.exe"] = b"MZ\x00RSDS\x00C:\\Users\\bob\\REBOOT\\reboot_app.pdb\x00"
        r = verify_package.verify(self.make_zip(files), "windows")
        self.assertTrue(r.ok, r.errors)
        self.assertTrue(any("C:\\Users\\" in w for w in r.warnings), r.warnings)

    def test_policy_placeholder_path_is_not_flagged(self):
        r = verify_package.verify(self.make_zip(win_files()), "windows")
        self.assertEqual(r.warnings, [])


class Integrity(Base):
    def test_corrupted_member(self):
        path = Path(self.make_zip(mac_files()))
        data = bytearray(path.read_bytes())
        # Портим данные первой записи (после локального заголовка), CRC не сойдётся.
        name_len = int.from_bytes(data[26:28], "little")
        extra_len = int.from_bytes(data[28:30], "little")
        start = 30 + name_len + extra_len
        data[start] ^= 0xFF
        data[start + 1] ^= 0xFF
        path.write_bytes(bytes(data))
        r = verify_package.verify(str(path), "macos")
        self.assertFalse(r.ok)

    def test_not_a_zip_exit_2(self):
        p = self.tmp / "bad.zip"
        p.write_bytes(b"not a zip at all")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verify_package.main([str(p)]), 2)

    def test_missing_file_exit_2(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verify_package.main([str(self.tmp / "nope.zip")]), 2)

    def test_exit_codes(self):
        good = self.make_zip(mac_files(), "good.zip")
        files = mac_files()
        files["REBOOT-macOS-v1.0.0/lib/main.dart"] = b"void main(){}"
        bad = self.make_zip(files, "bad.zip")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(verify_package.main([good]), 0)
            self.assertEqual(verify_package.main([bad]), 1)
            self.assertEqual(verify_package.main(["--json", good, bad]), 1)
        self.assertIn("[ERROR]", out.getvalue())


class Notices(Base):
    def test_gzip(self):
        self.assertEqual(extract_notices.detect_format(gzip.compress(b"x")), "gzip")
        self.assertEqual(extract_notices.decompress_notices(gzip.compress("Лицензия MIT".encode())), "Лицензия MIT")

    def test_zlib(self):
        self.assertEqual(extract_notices.detect_format(zlib.compress(b"x")), "zlib")
        self.assertEqual(extract_notices.decompress_notices(zlib.compress(b"Apache 2.0")), "Apache 2.0")

    def test_unknown_and_empty(self):
        with self.assertRaises(ValueError):
            extract_notices.decompress_notices(b"plain text")
        with self.assertRaises(ValueError):
            extract_notices.decompress_notices(gzip.compress(b"   "))

    def test_cli(self):
        src, dst = self.tmp / "NOTICES.Z", self.tmp / "out.txt"
        src.write_bytes(gzip.compress(b"BSD-3-Clause"))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(extract_notices.main(["x", str(src), str(dst)]), 0)
        self.assertIn("BSD-3-Clause", dst.read_text(encoding="utf-8"))
        src.write_bytes(b"garbage")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(extract_notices.main(["x", str(src), str(dst)]), 3)


if __name__ == "__main__":
    unittest.main()
