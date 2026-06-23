# SDK sync — `Sources/FeralNodeSDK/`

## Source of truth

The canonical home of `FeralNodeSDK` is **`ASOS/feral-nodes/ios-node-sdk/`**. The copy in this repo is a vendored snapshot used for local builds and CI until the SDK is extracted into its own dedicated Git repository (post-demo).

## Last sync

| Field | Value |
| --- | --- |
| Synced from | `ASOS/feral-nodes/ios-node-sdk/Sources/FeralNodeSDK/` |
| Source SHA | `04a0b94d824a5ad4d8a271403507e94e972c5f48` (PR #73 — HUP v1.3 phone-as-peer + reconnect + action_response) |
| Synced on | 2026-05-05 (Phase 2) |
| Sync direction | ASOS → this repo |
| SDK version | `0.2.0`, HUP version `1.3.0` |

## Sync history

| Date | Source SHA | Notes |
| --- | --- | --- |
| 2026-05-05 (initial) | `060c16e2` | v2026.5.14 baseline; SDK v0.1.0-scaffold, HUP v1.2.0 |
| 2026-05-05 (Phase 2) | `04a0b94d` | PR #73: phone-as-peer envelopes, reconnect, action_response, inbound stream, optional hupVersion. SDK v0.2.0, HUP v1.3.0 |

## Sync protocol

**ASOS is canonical for the SDK shape.** When the brain protocol changes, change `ASOS/feral-nodes/ios-node-sdk/` first, run its tests, open a PR. Once merged, run:

```bash
cd ~/Desktop/feral-companion-ios
rm -rf Sources/FeralNodeSDK
cp -R ~/Desktop/thoera-mac/ASOS/feral-nodes/ios-node-sdk/Sources/FeralNodeSDK \
      Sources/FeralNodeSDK
cd ~/Desktop/thoera-mac/ASOS && git rev-parse HEAD > /tmp/sdk-sha.txt
# Update SDK_SYNC.md → "Source SHA" with the value of /tmp/sdk-sha.txt
git add Sources/FeralNodeSDK docs/SDK_SYNC.md
git commit -m "chore(sdk): sync FeralNodeSDK from ASOS@<sha>"
```

**Never modify `Sources/FeralNodeSDK/` files in this repo directly.** All changes flow through ASOS first. The vendored copy is read-only.

## App-side SDK helpers in use

The companion app calls these `FeralNode` methods (sync them from ASOS when upgrading):

| Method | HUP frame | Used by |
| --- | --- | --- |
| `sendPeripheralBridgeRegister(bridgeId:platform:devices:expiresAt:)` | `peripheral_bridge_register` | `BrainClient` on connect — registers self-describing manifests from `PeripheralManifests.bridgeDevices()` so bridged glasses/wristband appear in the brain's fleet with zero brain-side per-device code. |

When syncing a new SDK drop, verify this helper (and any related payload types such as `AnyCodable`) are present in the vendored copy before building.

## Why we vendor instead of using SwiftPM

`ios-node-sdk` lives inside the ASOS monorepo as a sub-directory. SwiftPM does not support a sub-directory of a Git repo as a package source without restructuring ASOS. Two real options:

1. **Vendor the source** (current choice). Pros: zero ASOS restructuring, repo is self-contained. Cons: drift risk, manual sync.
2. **Extract `ios-node-sdk` to its own Git repo and consume via SwiftPM Git URL.** Pros: clean, no drift. Cons: orchestration overhead during the demo week.

Post-demo, we extract. For now, vendor + this `SDK_SYNC.md` discipline.

## Drift detection

CI on this repo runs a check that diffs `Sources/FeralNodeSDK/` against the recorded `Source SHA` in this file. If they're out of sync, the check warns. The check does NOT block — drift is sometimes intentional during active SDK development on the companion side.
