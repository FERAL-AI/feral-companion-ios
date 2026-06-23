# FERAL Companion (iOS)

Vendor-pluggable iOS companion app for the FERAL AI brain. Pairs with any FERAL brain over the HUP WebSocket protocol and exposes a uniform UI for chat, voice, and live health sensors regardless of which physical device the user has on their face or wrist.

> **Status:** active development. App builds, connects to brain, and exposes a Devices tab with brain-driven hardware fleet cards plus local adapter pairing. See `docs/PROGRESS.md`.

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

### Devices tab — two complementary views

The **Devices** tab (`DevicesView`) combines brain-driven fleet visibility with local phone-side pairing. They are additive; neither replaces the other.

| Layer | Source | Purpose |
| --- | --- | --- |
| **Hardware fleet** | Brain `GET /api/hardware/fleet` via `FleetStore` | Server-driven cards for every self-describing device the brain controls — robots, bridged glasses, wristbands, anything that registers a manifest. Rendered by `FleetSection`. |
| **Local adapters** | `DeviceStore` catalog | Phone-side BLE pairing and activation (W300 glasses audio, Veepoo scan/connect, HealthKit, iPhone built-ins). Unchanged by the fleet view. |

**`FleetStore`** (`App/Sources/State/FleetStore.swift`) polls `/api/hardware/fleet` on the connected brain every ~5 s while the Devices tab is open. It parses each device's capabilities and the last verification (honesty) state into `FleetDevice` / `FleetCapability` / `FleetVerification` models.

**`FleetSection`** (`App/Sources/Views/FleetSection.swift`) renders those models as cards entirely from the brain response — device name/type, capability list, safety badges (`SAFE` / `CONFIRM` / `APPROVAL` / `READ` / `IRREVERSIBLE`), and a live honesty strip (`verified ✓` / `verified ✗` / unverified). A brand-new device the brain learns about appears as a card automatically; no app code change required.

### Self-describing bridged peripherals

When the phone connects to a brain, **`BrainClient`** sends HUP self-description manifests for phone-bridged BLE peripherals via `FeralNode.sendPeripheralBridgeRegister(...)` (`peripheral_bridge_register`). The manifests live in **`PeripheralManifests`** (`App/Sources/State/PeripheralManifests.swift`) and cover:

- **Theora W300** glasses (`theora-w300`)
- **W610 Open** glasses (`w610-open`) — the "unknown device, zero code" proof; same declarative path, no brain-side per-device code
- **Veepoo** wristband (`veepoo-band`)

The brain builds LLM tools, safety policy, fleet cards, and closed-loop honesty checks from these manifests alone. Registration is best-effort — a failure never breaks chat/voice.

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
./scripts/bootstrap.sh   # always run after switching branches or adding Swift files
./scripts/check-vendor.sh  # optional: see which SDKs are present
open FeralCompanion.xcodeproj
```

`FeralCompanion.xcodeproj` is **gitignored** and regenerated from `project.yml`. Run `./scripts/bootstrap.sh` (or `xcodegen generate`) whenever you:

- switch branches, or
- **add new Swift files** under `App/Sources/` or `Sources/FeralNodeSDK/`

Without regenerating, Xcode fails with *"Cannot find \<Type\> in scope"* or *"Build input files cannot be found"* because the generated project does not yet list the new files.

`App/Sources/` and `Sources/FeralNodeSDK/` compile into the **same** `FeralCompanion` target (see `project.yml`). App code must **not** `import FeralNodeSDK` — types like `FeralNode` and `AnyCodable` are visible directly.

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
