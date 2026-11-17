# Changelog

All notable changes to the Rane SL4 macOS ARM Driver project are documented in this file.

## [1.4.0] — 2026-11-17

The SL 2 and SL 3 drivers' work (pepeleedj/Rane-SL2-Macos-ARM-Driver and Rane-SL3-Macos-ARM-Driver,
v1.4.0) ported to the SL 4, with the SL 4's protocol worked out from Rane's SL4 driver 2.0.1f1 and
firmware 1.02 (`docs/SL4-COMMANDS.md`). **Not yet tested on an SL 4**: everything builds, and nothing
has been run against a box. `docs/SL4-AUDIO-ENGINE.md` ("Still open") lists what to check first.

### Added
- **The SL 2 driver's low-latency engine** in `SL4Device.driver`: deep-scheduled late-write playback,
  a timeline that follows the box's clock, capture placed on the timeline with gaps filled, the early
  capture read (with the SL 3's fill template, as the SL 4's pad byte is not known to be 0), input
  health and the input safety offset setting (`sl4panel safety`), stream teardown on the USB queue,
  and a debug build (`make plugin DEBUG=1`) with test hooks (`sl4dbg`).
- **The device follows the box's sample rate** (48 or 96 kHz, chosen on the SL 4): read with `0x4A`
  at connect and in the settle check, followed through a configuration change when the box reports a
  change (`0x4B`). Only the box's rate is offered.
- **Thru on all four decks** (notes `0x5C`–`0x5F`), the state dump at connect, and the decks' routing
  kept across a replug mid-stream.
- **Settle check**: thru and the rate are checked again 2 s after the box is opened and 4 s after the
  Mac wakes.
- **The box's two USB ports**: which one this Mac is on and whether a computer is on the other (`0x45`,
  and the `0x46` / `0x49` reports), in the status, `sl4panel` and the control panel.
- **Boot mode**: a box in its firmware updater (bcdDevice `0x9900`) is left to the firmware tools and
  reported in the status.
- **Output volume and mute**, master and per channel (10), in the driver.
- **SL 4 Control Panel.app** (macOS 13+): thru for decks 1–4, level meters, output volume, the sample
  rate, the USB ports, the input safety offset, and the firmware version in red when older than 1.02.
- **Firmware tools** (`tools/firmware/`): `extract-sl4-firmware.py` (from Rane's `RaneSL4_2.0.1f1.pkg`
  or its SL4Api, validated as Rane's `IsValidFirmwareImage` does), `sl4flash` (Rane's update
  sequence), and `sl4dump` (read-only status, and the flash summary table of a box in its updater).
- **Tests:** `make hwtest` (the hardware tests in one run), `tools/latency/` (round-trip latency and
  glitch tests), `sl4apitest` (SL4Api as Serato DJ Pro 2.5.5 calls it).
- **`make package`**: the installer package and zip built from source, with no Rane binaries.
- **Docs:** `docs/SL4-AUDIO-ENGINE.md` (design, bug catalogue, what to check on hardware),
  `docs/SL4-COMMANDS.md` (the box's protocol, image format and update sequence, from Rane's binaries),
  `docs/usb-descriptors.txt`, `AGENTS.md`.

### Changed
- `SL4Api.framework` matches Rane's 2.0.1f1 export for export (handles, return codes, signatures,
  callbacks from the box's reports, the bridge packets between the two ports' computers).
- `sl4panel` works through the driver, so it works while the driver runs.
- Channel names: Deck 1–4 and Aux (the order is assumed; to check on a box).
- The box's interfaces are no longer offered to other drivers, and the driver takes the HID interface
  back if macOS's HID driver holds it.

### Removed
- 44.1 kHz and the `0x31` rate command (the SL 4 has neither).
- The `0x37` heartbeat: the SL 4's USB chip answers it alone, and Rane's driver never sends it.
- Rane's "SL 4 Audio Control Panel" System Settings pane from the installer (the app replaces it).

### Fixed
- 520-byte packets (13 frames, for 96 kHz) in place of 280.
- The firmware version from `0x01` (`0x10` and `0x04`, from other Rane boxes, are not SL 4 commands).

## [1.3.0] - 2026-11-10

- Ultra-low-latency audio engine, CoreAudio volume/mute controls and hot-plug reconnect (pepelee, with
  Ben XO), ported from the SL 2 and SL 3 drivers.
