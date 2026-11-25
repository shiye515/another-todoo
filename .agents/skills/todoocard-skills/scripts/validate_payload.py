#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from quicklz_payload import T3_CONTROLLER_BYTES, inspect_payload, unwrap_payload


OLD_800_480_RAW = 800 * 480 // 2
NEW_528_792_RAW = T3_CONTROLLER_BYTES
NEW_528_792_QUICKLZ_STORED = 4 + (NEW_528_792_RAW // 64) * 67


def classify(path: Path, expected_raw: bytes | None) -> tuple[str, bool]:
    data = path.read_bytes()
    size = len(data)
    lines = [f"{path}: {size} bytes"]
    valid = False

    if size == OLD_800_480_RAW:
        lines.append("match: old 800x480 six-color direct bitmap payload")
        valid = True
    if size == NEW_528_792_RAW:
        lines.append("match: T3 528x792 raw six-color controller payload")
        if expected_raw is not None and data != expected_raw:
            lines.append("error: raw payload differs from --expected-raw")
            return "\n".join(lines), False
        valid = True

    if data[:4] == b"\x00\x00\x00\x00":
        try:
            info = inspect_payload(data)
            decoded = unwrap_payload(data)
            level_text = "/".join(str(level) for level in info.levels)
            lines.append(
                "match: T3 QuickLZ controller payload "
                f"(levels={level_text}; blocks={info.block_count}; "
                f"compressed={info.compressed_blocks}; stored={info.stored_blocks}; "
                f"decoded={info.decoded_bytes})"
            )
            if info.decoded_bytes != NEW_528_792_RAW:
                lines.append(
                    f"error: decoded size is {info.decoded_bytes}, expected {NEW_528_792_RAW}"
                )
                return "\n".join(lines), False
            if expected_raw is not None and decoded != expected_raw:
                lines.append("error: decoded payload differs from --expected-raw")
                return "\n".join(lines), False
            if size == NEW_528_792_QUICKLZ_STORED and info.levels == (1,):
                lines.append("compatibility: legacy 64-byte QuickLZ-stored stream")
            elif info.levels == (3,):
                lines.append("protocol: v157+ independent 2KB QuickLZ level-3 stream")
            valid = True
        except ValueError as error:
            if not valid:
                lines.append(f"error: invalid QuickLZ payload: {error}")
                return "\n".join(lines), False

    if not valid:
        lines.append("error: payload does not match a supported TodooCard format")
    return "\n".join(lines), valid


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate TodooCard image-transfer payload sizes and QuickLZ streams."
    )
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--expected-raw", type=Path)
    args = parser.parse_args()
    expected_raw = args.expected_raw.read_bytes() if args.expected_raw else None
    all_valid = True
    for index, path in enumerate(args.paths):
        if index:
            print()
        result, valid = classify(path, expected_raw)
        print(result)
        all_valid = all_valid and valid
    return 0 if all_valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
