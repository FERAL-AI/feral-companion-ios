# FERAL Companion (iOS)

Vendor-pluggable iOS companion app for the FERAL AI brain. Pairs with any FERAL brain over the HUP WebSocket protocol and exposes a uniform UI for chat, voice, and live health sensors regardless of which physical device the user has on their face or wrist.

> **Status:** scaffold (2026-05-05). Day 1 — Phase 1 + 2 complete: app builds, connects to brain, no UI yet. See `docs/PROGRESS.md`.

## Why this exists

`feral-nodes/ios-app/` in the ASOS monorepo had structural drift from the canonical HUP SDK and 12+ protocol-level bugs. Rather than fix it in place, we restart cleanly on top of `FeralNodeSDK` (the same SDK from `feral-nodes/ios-node-sdk/`) and adopt the **`VendorAdapter` plugin pattern** as the architectural primitive.

The result: a phone app that supports any current and future hardware via a single 30-line adapter file per device.

## Architecture

```
[Phone microphone]                         ┐
[Phone camera]                             │
[Apple HealthKit]                          │
[JieLi W300 health glasses (BLE)]          ├──► VendorAdapter (each plug)
[Veepoo wristband (BLE)]                   │            │
[Brilliant Frame (BLE)]                    │            │ node.emit("heart_rate", …)
[Ray-Ban Meta (companion bridge)]          │            │ node.emit("audio_frame", …)
[any future device with an iOS SDK]        ┘            │ node.emit("video_frame", …)
                                                        ▼
                                                  HUP device_event
                                                        │
                                                        ▼
                                            FERAL Brain (FastAPI)
```

The brain is device-agnostic. Adapters are device-specific. The app shell is both.

## Adapter status

| Adapter | Status | Hardware needed | First demo |
| --- | --- | --- | --- |
| `PhoneOnlyAdapter` | Planned (Phase 4) | None | Demo 2 |
| `HealthKitAdapter` | Planned (Phase 4) | iPhone | Demo 2 |
| `JWBleAdapter` | Planned (Phase 6) | JieLi W300 + JWBle frameworks | Demo 3 |
| `VeepooAdapter` | Stub | Veepoo wristband + VPBle frameworks | post-demo |
| `QCSDKAdapter` | Stub | W610 glasses + QCSDK | post-demo |
| `BrilliantAdapter` | Future | Brilliant Frame + Frame iOS SDK | post-demo |

## Build

A fresh clone builds in **stub mode** — no NDA frameworks, no signing
team, just the simulator-runnable Demo 2 surface (chat, Context tab,
Settings, Devices summary, onboarding wizard, HealthKit + microphone).

```bash
git clone https://github.com/FERAL-AI/feral-companion-ios.git
cd feral-companion-ios
./scripts/bootstrap.sh
open FeralCompanion.xcodeproj
```

`./scripts/bootstrap.sh` is idempotent: it installs `xcodegen` via
Homebrew if needed, detects whether the JieLi/Realtek frameworks are
present in `Vendor/` (or in `~/.feral/vendor-cache/companion-ios/`),
selects the appropriate build mode, and regenerates the Xcode
project.

### Build modes

| Mode | Vendor drop required | Hardware | What works |
|---|---|---|---|
| **Stub** (default) | No | iPhone simulator | Demo 2 — chat, Context tab, Settings, Devices summary, onboarding, HealthKit, microphone, QR pair |
| **Full** | Yes (NDA) | iPhone + JieLi W300 | Demo 3 — everything in stub mode + W300 BLE glasses + Theora wristband |

Stub mode satisfies the call-site signatures with no-op
implementations in [`App/Sources/Adapters/JWBleStubs.swift`](App/Sources/Adapters/JWBleStubs.swift)
gated behind `#if !canImport(JWBle)`. The real wired adapters in
[`App/Sources/Adapters/JWBleAdapterWired.swift`](App/Sources/Adapters/JWBleAdapterWired.swift),
[`App/Sources/Adapters/JWBleSession.swift`](App/Sources/Adapters/JWBleSession.swift),
[`App/Sources/Adapters/W300SensorManager.swift`](App/Sources/Adapters/W300SensorManager.swift),
and [`App/Sources/Views/BLEScanView.swift`](App/Sources/Views/BLEScanView.swift)
gate themselves behind `#if canImport(JWBle)` so the two
implementations never collide.

### Full-mode access

See [`docs/VENDOR_SETUP.md`](docs/VENDOR_SETUP.md) for the JieLi NDA
flow, vendor cache layout, and update procedure.

### Code signing

`project.yml` reads `DEVELOPMENT_TEAM` from the environment, so every
contributor signs with their own Apple Developer team without
editing the spec:

```bash
export DEVELOPMENT_TEAM=ABCDE12345     # optional — your team ID
./scripts/bootstrap.sh
```

If you leave it unset, Xcode's "Signing & Capabilities" tab will
prompt for a team on first build.

### Manual flow (no bootstrap)

```bash
brew install xcodegen

# Stub mode — no vendor frameworks required:
xcodegen generate

# Full mode — requires all five Vendor/*.framework present:
xcodegen generate --spec project.vendor.yml

open FeralCompanion.xcodeproj
```

## SDK sync

This repo vendors `Sources/FeralNodeSDK/` from `ASOS/feral-nodes/ios-node-sdk/`. See `docs/SDK_SYNC.md` for the sync protocol (the SDK remains canonical in ASOS until extracted).

## Third-party sources

[`Sources/ThirdParty/FMDB/`](Sources/ThirdParty/FMDB/) holds the
public-domain FMDB headers + the `FMDatabaseAdditions` category that
the JieLi vendor demo requires. The category is wrapped in
`#if __has_include(<JWBle/JWBle.h>)` so the file compiles to empty in
stub mode and links against the FMDatabase symbol shipped inside
`JWBle.framework` when the vendor drop is present.

## Demos this app supports

- **Demo 2 — Ambient.** `PhoneOnlyAdapter` + `HealthKitAdapter`. No external hardware.
- **Demo 3 — Glasses vitals.** Adds `JWBleAdapter` for JieLi W300. Same UI; vitals come from glasses instead of phone.

See `docs/DEMOS.md` for the demo flows.
