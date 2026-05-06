# Phase progress — FERAL companion iOS

Tracks the build of this app from scaffold to demo-ready.

| Phase | Description | Status |
| --- | --- | --- |
| 1 | Repo + Xcode scaffold + signing | in progress |
| 2 | `ios-node-sdk` upstream fixes | **done — PR #73** |
| 3 | App shell (TabView, BrainClient over FeralNode, deep links, pairing parser) | pending |
| 4 | `PhoneOnlyAdapter` + `HealthKitAdapter` (Demo 2 ready) | pending |
| 5 | Demo 2 ships | pending |
| 6 | `JWBleAdapter` (real BLE) | pending |
| 7 | Demo 3 ships | pending |
| 8 | Brain auth tightening (`phone_bearer` for `/v1/session` + REST) | pending |

## Day 1 (2026-05-05) — what landed

- Created private repo `FERAL-AI/feral-companion-ios`.
- Authored `project.yml` (xcodegen), Info.plist with permission strings + `feral://` URL scheme + bluetooth-central + audio background modes.
- Authored `FeralCompanion.entitlements` with HealthKit capability.
- Authored `LaunchScreen.storyboard`, `Assets.xcassets/AppIcon.appiconset`, `AccentColor`.
- Vendored `Sources/FeralNodeSDK/` from `ASOS@060c16e`.
- Wrote `FeralCompanionApp.swift`, `RootView.swift`, `AppEnvironment.swift`, `Stores.swift` (Phase-1 stubs).
- Documented SDK sync protocol in `docs/SDK_SYNC.md`.
- Documented progress in this file.

## Day-1 deliverable target

Phase 1 + 2: app builds, connects to brain, no UI yet. End-of-day status check:

- [x] `xcodegen generate` produces `FeralCompanion.xcodeproj` cleanly
- [x] `xcodebuild -scheme FeralCompanion -destination 'generic/platform=iOS Simulator' build` succeeds — `BUILD SUCCEEDED` 2026-05-05 18:14, re-verified 18:32 with the upgraded SDK
- [ ] App launches on iPhone simulator and shows the Phase-1 placeholder (deferred — Phase 3 wires real UI)
- [x] `ios-node-sdk` fixes (auto-reconnect, `hup_action_response`, inbound stream, voice helpers) opened as **ASOS PR #73**, all 30 SDK tests pass
- [x] SDK synced forward into this repo at `Sources/FeralNodeSDK/` from `ASOS@04a0b94d`

## Day-1 result

**Phase 1 + 2 complete.** End-of-day status: app builds clean against the upgraded SDK. The brain-talking surface (`FeralNode`) now has every helper the upcoming Phase 3 + 4 work needs:

- `connect()` with auto-reconnect (HUP_SPEC §2 backoff)
- `inboundFrames` AsyncStream for brain replies
- `sendChatRequest`, `startVoiceSession`, `interruptVoiceSession`, `sendAudioChunk`
- `sendActionResponse(actionId:success:result:error:)`
- `emit(eventType:data:)` + `emitVideoFrame` + `emitAudioFrame`

Tomorrow: Phase 3 (BrainClient wrapper around FeralNode + Pairing + TabView shell + delegate fan-out).

## Outstanding for Day 2+

- Phase 3 → Phase 7 work above.
- Apple Developer team setup for real-device deploy (`DEVELOPMENT_TEAM` Xcode setting).
