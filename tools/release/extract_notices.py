#!/usr/bin/env python3
"""Распаковка NOTICES.Z (лицензии сторонних компонентов Flutter) в текст.

Flutter кладёт в flutter_assets файл NOTICES.Z. Несмотря на суффикс .Z, это
НЕ формат compress(1): на практике (Flutter 3.x) это gzip-поток (сигнатура
1f 8b); в старых версиях встречался zlib-поток (сигнатура 78 xx). Скрипт
проверяет сигнатуру, распаковывает через zlib.decompress с подходящим wbits
и проверяет, что результат — непустой UTF-8 текст.

Только стандартная библиотека.

Использование:
    python3 extract_notices.py <NOTICES.Z> <THIRD_PARTY_NOTICES.txt>
Код выхода: 0 — успех, 2 — неверные аргументы, 3 — неизвестный формат/ошибка.
"""
from __future__ import annotations

import sys
import zlib
from pathlib import Path

HEADER = (
    "THIRD-PARTY NOTICES / ЛИЦЕНЗИИ СТОРОННИХ КОМПОНЕНТОВ\n"
    "Сформировано из NOTICES.Z сборки Flutter (flutter_assets).\n"
    "=====================================================================\n\n"
)


def detect_format(data: bytes) -> str:
    if len(data) < 2:
        return "empty"
    if data[0] == 0x1F and data[1] == 0x8B:
        return "gzip"
    # zlib: CMF=0x78 (deflate, окно 32K), (CMF*256+FLG) % 31 == 0
    if data[0] & 0x0F == 8 and ((data[0] << 8) | data[1]) % 31 == 0:
        return "zlib"
    return "unknown"


def decompress_notices(data: bytes) -> str:
    fmt = detect_format(data)
    if fmt == "gzip":
        raw = zlib.decompress(data, 16 + zlib.MAX_WBITS)
    elif fmt == "zlib":
        raw = zlib.decompress(data, zlib.MAX_WBITS)
    else:
        raise ValueError(f"неизвестный формат NOTICES.Z (сигнатура {data[:2].hex() or 'пусто'})")
    text = raw.decode("utf-8")  # строгая проверка UTF-8
    if not text.strip():
        raise ValueError("распакованный NOTICES пуст")
    if "\x00" in text:
        raise ValueError("распакованный NOTICES содержит NUL — это не текст")
    return text


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = Path(argv[1]), Path(argv[2])
    try:
        data = src.read_bytes()
        fmt = detect_format(data)
        text = decompress_notices(data)
    except (OSError, ValueError, zlib.error, UnicodeDecodeError) as exc:
        print(f"[extract_notices] ОШИБКА: {src}: {exc}", file=sys.stderr)
        return 3
    dst.write_text(HEADER + text, encoding="utf-8", newline="\n")
    print(f"[extract_notices] {src.name}: формат {fmt}, {len(data)} -> {len(text)} символов -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
