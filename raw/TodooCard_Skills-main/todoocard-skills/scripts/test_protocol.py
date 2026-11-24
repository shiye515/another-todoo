#!/usr/bin/env python3
"""Deterministic protocol checks for current and legacy TodooCard payloads."""

from __future__ import annotations

import hashlib
import unittest

from quicklz_payload import (
    T3_CONTROLLER_BYTES,
    build_level3_payload,
    inspect_payload,
    unwrap_payload,
)


class QuickLZPayloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = bytes(
            ((index * 17 + (index // 97) * 29) & 0xFF)
            for index in range(T3_CONTROLLER_BYTES)
        )

    def test_level3_payload_is_deterministic_and_round_trips(self) -> None:
        payload = build_level3_payload(self.raw)
        info = inspect_payload(payload)
        self.assertEqual(info.decoded_bytes, T3_CONTROLLER_BYTES)
        self.assertEqual(info.block_count, 103)
        self.assertEqual(info.levels, (3,))
        self.assertEqual(unwrap_payload(payload), self.raw)
        self.assertEqual(len(payload), 44304)
        self.assertEqual(
            hashlib.sha256(payload).hexdigest(),
            "31761fbb26551a0c498ca37522c6aa490e7ca558b47fb4d56af777af9de793cc",
        )

    def test_legacy_stored_payload_remains_readable(self) -> None:
        chunks = [
            b"\x74\x43\x40" + self.raw[offset : offset + 64]
            for offset in range(0, len(self.raw), 64)
        ]
        payload = b"\x00\x00\x00\x00" + b"".join(chunks)
        info = inspect_payload(payload)
        self.assertEqual(info.levels, (1,))
        self.assertEqual(info.stored_blocks, T3_CONTROLLER_BYTES // 64)
        self.assertEqual(unwrap_payload(payload), self.raw)

    def test_truncated_payload_is_rejected(self) -> None:
        payload = build_level3_payload(self.raw)
        with self.assertRaises(ValueError):
            inspect_payload(payload[:-1])

    def test_wrong_controller_size_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            build_level3_payload(self.raw[:-1])


if __name__ == "__main__":
    unittest.main()
