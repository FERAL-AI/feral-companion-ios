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

```bash
brew install xcodegen
./scripts/bootstrap.sh   # always run after switching branches
./scripts/check-vendor.sh  # optional: see which SDKs are present
open FeralCompanion.xcodeproj
```

`FeralCompanion.xcodeproj` is **gitignored** and regenerated from `project.yml`. If Xcode reports *"Build input files cannot be found"* for Swift files that are not on disk, your local `.xcodeproj` is stale — run `./scripts/bootstrap.sh` and rebuild.

To build for a real iPhone you need an Apple Developer team configured in Xcode signing.

## Vendor SDKs

The `Vendor/` directory holds third-party binaries the app links against.

### Bundled (open source — committed in-repo)

| Component | License | Purpose |
| --- | --- | --- |
| `Vendor/CocoaLumberjack.framework` | BSD | Logging dependency of the JWBle glasses SDK (linked when JWBle is present) |
| `Vendor/FMDB/` | MIT | SQLite helpers; `FMDatabaseAdditions` compiled when JWBle is present |

These are small, redistributable, and committed so operators with JWBle SDK access have the companion deps ready. A fresh clone **without** JWBle does not link them.

### Proprietary (optional — not redistributable)

The following SDKs are **not** committed. There are no written redistribution rights for them. The app **builds and runs without them**; corresponding hardware features show as *unavailable* in the Devices tab.

| SDK | Hardware | Drop path |
| --- | --- | --- |
| `JWBle.framework` (+ Realtek RTK*) | Theora W300 health glasses | `Vendor/JWBle.framework`, `Vendor/RTK*.framework` |
| `QCSDK.framework` | W610 open glasses | `Vendor/QCSDK.framework` |
| `VeepooBleSDK.framework` | Veepoo wristband | `Vendor/VeepooBleSDK.framework` |

To enable hardware features, **contact Theora** for SDK access, copy the `.framework` bundles into `Vendor/`, then regenerate the Xcode project:

```bash
./scripts/check-vendor.sh   # verify bundles are detected
./scripts/bootstrap.sh      # links frameworks when present
```

`scripts/generate-vendor-yml.sh` (called by bootstrap) adds proprietary framework links to the build **only when the bundles exist on disk**. Swift code uses `#if canImport(JWBle)` (and similar) so the app target compiles cleanly either way.

## SDK sync

This repo vendors `Sources/FeralNodeSDK/` from `ASOS/feral-nodes/ios-node-sdk/`. See `docs/SDK_SYNC.md` for the sync protocol (the SDK remains canonical in ASOS until extracted).

## Demos this app supports

- **Demo 2 — Ambient.** `PhoneOnlyAdapter` + `HealthKitAdapter`. No external hardware.
- **Demo 3 — Glasses vitals.** Adds `JWBleAdapter` for JieLi W300. Same UI; vitals come from glasses instead of phone.

See `docs/DEMOS.md` for the demo flows.
