---
name: todoocard-skills
description: Pair, probe, prepare, validate, and explicitly send photos to compatible TodooCard/T3 528x792 six-color BLE e-paper cards from macOS. Use when a user asks to pair a Mac with a current secure TodooCard, transfer JPG, PNG, or HEIC images, inspect nearby compatible BLE cards, or diagnose pairing, encrypted GATT access, image orientation, and color rendering.
---

# TodooCard Skills

Use this skill only on macOS with `swiftc`, Bluetooth permission, and physical
proximity to the device. Image preparation additionally requires `python3` and
`/usr/bin/sips`. This is a local BLE workflow; it makes no network calls.

## Secure pairing contract

Current secure T3 firmware advertises manufacturer `0x5053`, screen type
`0x134C`, encrypted-GATT capability bit `0x01`, and physical-pairing-window bit
`0x02`. Treat firmware `0x8C+` with bit `0x01` as secure. Current firmware is
v167 (`raw=0xA7`). Its pairing flow is:

- Hold the rear button for 5 seconds until the front light fast-flashes on
  v152 (`raw=0x98`) and newer. Older secure firmware requires 10 seconds.
- Detect bit `0x02`; it remains open for at most 60 seconds.
- Connect only the exact CoreBluetooth UUID and read encrypted Battery Level
  `180F/2A19` to create and verify the macOS system bond.
- Pairing succeeds only after encrypted access succeeds. An ordinary BLE
  connection is not proof of pairing.
- Retry only `CBErrorDomain` code `15` (encryption timeout), at most twice
  after the first attempt with 0.75-second and 1.5-second backoff. Report all
  other errors immediately.
- Pair separately from probing or sending. The firmware rejects pairing when
  the physical window is closed and rejects an old bonded central while a new
  device is pairing.

## Safety-first workflow

1. Build and list nearby devices without writing:

   ```bash
   scripts/prepare_and_send.sh --list
   ```

2. Ask the user to select the exact UUID. If the list reports `secure=yes` and
   the Mac is not already paired, request confirmation before changing the
   macOS system bond. Then start the pairing waiter and tell the user to hold
   the rear button for 5 seconds on current firmware:

   ```bash
   scripts/prepare_and_send.sh --pair --device-id UUID
   ```

   The command waits for `pairing=open`; it must not connect while the bit is
   closed. If macOS shows a pairing prompt, ask the user to accept it.

3. Probe the exact UUID after pairing. This verifies manufacturer `0x5053`,
   screen `0x134C`, the existing encrypted bond, and FEF1/FEF2 access without
   changing the display. On v165 (`raw=0xA5`) and newer it also reads retained
   image-ACK diagnostics when available:

   ```bash
   scripts/prepare_and_send.sh --probe --device-id UUID
   ```

4. Prepare and validate the image first. This does not contact a device:

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic
   ```

5. State the exact target UUID and request confirmation immediately before the irreversible display update. Only after confirmation, send:

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic --device-id UUID --send
   ```

The script normalizes images to PNG, uses six-color Floyd-Steinberg dithering,
creates current and legacy T3 payloads, decodes them back to the exact
controller bitmap, and validates them before Bluetooth transfer. For
TodooCard/T3 528x792 (`0x134C`), it always uses the bottom-layer
`todoocard-correct` panel calibration.

## Firmware-aware transfer contract

Select the transfer method from the verified manufacturer-data firmware byte;
do not guess from the device name:

- v157 (`raw=0x9D`) and newer: prefer independent 2 KB QuickLZ 1.5 level-3
  blocks. If that compressed stream would be no smaller on the wire, use the
  raw controller bitmap. Pad only a compressed stream to the negotiated BLE
  payload-block size before reporting its length.
- Before v157: use the legacy independent 64-byte QuickLZ stored stream.
- v157 and newer: send at most one 32-block application window, drain the BLE
  queue with a response write at the window boundary when supported, then wait
  up to 5 seconds for the device's durable external-Flash checkpoint. Continue
  from the exact block index returned by the device; a lower index is a repair,
  not a new transfer.
- If a checkpoint times out, re-send only the previous window-end block to
  solicit retained progress. Allow at most 16 repair/probe requests. Never
  blindly replay the entire payload inside the same session.
- v159 (`raw=0x9F`) and newer retain an ACK until the BLE TX queue accepts it;
  do not interpret a delayed ACK as success or failure before the timeout.
- Capability bit `0x10` means Turbo Link is available. Capability bit `0x08`
  means OTA-only recovery mode: refuse image transfer and direct the user to
  approved firmware repair.
- v166 (`raw=0xA6`) and newer have a 10-second valid-progress lease and may
  disconnect or reboot to restore advertising after a stalled or finished
  transfer. A disconnect is not transfer success: require the actual
  `0x05 0x08` refresh acknowledgement.
- v167 (`raw=0xA7`) adds OTA window acknowledgements; its image-transfer
  contract remains the verified v157+ contract above.

Interpret image ACK failures precisely:

- `0x01`: malformed or out-of-order packet. Stop; do not keep replaying data.
- `0x09`: external Flash write failure. Stop and report the hardware-side I/O
  failure.
- `0x0A`: external Flash readback verification failure. Stop and report the
  verification failure.
- On v165+, read characteristic
  `D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1003` from service
  `D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1001` before exiting when possible. Report
  session flags, generated/accepted/rejected notification counts, requested
  block, previous status, notify result, and last received block. If the link
  is already gone, tell the user to reconnect with `--probe` for the retained
  diagnostics.

## Canonical display orientation

Treat an upright source image as the correct user-facing orientation. Always
use the bottom-layer `todoocard-correct` calibration for TodooCard/T3 528x792
(`0x134C`) payloads. Its current implementation performs the proven panel
compensation internally; callers must not rotate, mirror, reproduce, or
override that implementation. Reject every other T3 orientation and do not
expose `--screen-orientation` as a user option.

For an individual source image that is sideways, add the optional source-image
correction below. The canonical bottom-layer panel calibration still runs
afterward:

```bash
--rotate-right-90
```

The screen controller transform is already handled internally; do not add a
second controller rotation.

## Guardrails

- Require an exact device UUID for probe or send. Do not select a device by name alone.
- Require an exact device UUID for pairing. Never connect merely because a
  name, RSSI, or service resembles TodooCard.
- Pair only through `--pair`, only after the user authorizes creating a system
  bond, and only after the target advertises `pairing=open`.
- Refuse `--probe` and `--send` while the new-device pairing window is open.
  Use `--pair` for a genuinely new Mac, or wait for normal advertising to
  resume before accessing an existing bond.
- Treat encrypted Battery Level access as the pairing proof. Do not claim
  success from `didConnect`, service discovery, or a system prompt alone.
- Keep `--send` opt-in. A successful transfer permanently changes the screen until another image is sent.
- Always use `todoocard-correct` for TodooCard/T3 528x792 (`0x134C`) controller
  packing. Accept upright source images and refuse raw orientation overrides.
- Do not send arbitrary `.bin` or `.protocol.qlz` files. Always generate and validate them with the bundled converter.
- Refuse image transfer while OTA recovery capability bit `0x08` is set.
- Honor durable checkpoint resume indices; never restart from block zero merely
  because an ACK was delayed or requested repair.
- Treat local images and generated payloads as private. The script keeps transient copies under `/tmp`; do not upload them or log their paths externally.
- The input-size limit is 100 MB and 50 megapixels. Refuse larger inputs rather than exhausting memory.
- If the final device acknowledgement is absent, report failure; do not claim the display refreshed.
