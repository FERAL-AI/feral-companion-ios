# Vendor framework setup

FERAL Companion supports two build modes. **Stub mode** (the default
for any fresh `git clone`) compiles against no-op stand-ins for the
JieLi W300 glasses + Theora wristband BLE stack and runs every
non-glasses surface. **Full mode** links against the proprietary
JieLi / Realtek frameworks and unlocks the W300 hardware path.

This document covers the access flow for full mode. If you do not
need W300 support, stop here — `./scripts/bootstrap.sh` from the
repo root already produces a runnable simulator build.

## What's in the bundle

| Framework | Source | License | Required for |
|---|---|---|---|
| `JWBle.framework` | JieLi SDK | NDA | All W300 BLE + Theora |
| `RTKAudioConnectSDK.framework` | Realtek | NDA | W300 audio |
| `RTKLEFoundation.framework` | Realtek | NDA | W300 BLE transport |
| `RTKOTASDK.framework` | Realtek | NDA | W300 OTA firmware |
| `CocoaLumberjack.framework` | BSD-3 | Permissive | Vendor demo parity |

The four NDA frameworks cannot be redistributed through the public
GitHub repository. They are not under FERAL's copyright and the
vendor licenses forbid third-party hosting.

## Access flow

1. Email `hardware@feral.ai` from your work address. The team will
   verify your partnership status and forward the JieLi NDA.
2. Sign and return the NDA. Provide the GitHub username you will use
   to push changes to `feral-companion-ios`.
3. You receive a **one-time signed URL** for a tarball containing all
   five frameworks at the binary version this repo is calibrated
   against. The URL expires after 24 hours.
4. Extract the tarball into the FERAL vendor cache:

   ```bash
   mkdir -p ~/.feral/vendor-cache/companion-ios
   tar -xzf companion-vendor-<sha>.tar.gz -C ~/.feral/vendor-cache/companion-ios
   ```

5. From the repo root, run the bootstrap script. It auto-detects the
   cache, copies the five frameworks into `Vendor/`, picks
   `project.vendor.yml`, and regenerates the Xcode project:

   ```bash
   ./scripts/bootstrap.sh
   open FeralCompanion.xcodeproj
   ```

## Verifying the drop

After `./scripts/bootstrap.sh` reports `build mode: full`, confirm:

```bash
ls Vendor/*.framework | sort
# Vendor/CocoaLumberjack.framework
# Vendor/JWBle.framework
# Vendor/RTKAudioConnectSDK.framework
# Vendor/RTKLEFoundation.framework
# Vendor/RTKOTASDK.framework
```

The generated Xcode project's "Frameworks, Libraries, and Embedded
Content" pane for the `FeralCompanion` target lists the same five
binaries with **Embed & Sign** enabled.

## Updating to a new vendor version

1. JieLi releases a new SDK version → FERAL hardware team validates
   it against a W300 reference unit and publishes a new signed URL.
2. Replace the contents of `~/.feral/vendor-cache/companion-ios/`.
3. Re-run `./scripts/bootstrap.sh`. The script overwrites
   `Vendor/*.framework` from the cache before running xcodegen.
4. Run the full test suite on a real W300 device. The vendor demo
   has a long history of SDK quirks; the comments at the top of
   `App/Sources/Adapters/W300SensorManager.swift` enumerate the
   ones we have already paid for.

## Why the indirection

The vendor cache layer (`~/.feral/vendor-cache/companion-ios/`)
exists so contributors with multiple checkouts of the repo only
download the binaries once. Re-running `./scripts/bootstrap.sh`
across worktrees is cheap.

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `bootstrap.sh` reports `stub` despite cache present | cache directory not at `$FERAL_VENDOR_CACHE` (default `~/.feral/vendor-cache/companion-ios`) | Set `FERAL_VENDOR_CACHE` or extract into the default path |
| Xcode reports `Could not find module 'JWBle'` | xcodegen ran against `project.yml` instead of `project.vendor.yml` | Re-run `./scripts/bootstrap.sh` (it picks the spec automatically) or run `xcodegen generate --spec project.vendor.yml` |
| `unrecognized selector -[FMDatabase getTableSchema:]` at SDK init | `FMDatabaseAdditions.m` did not link | Confirm `Sources/ThirdParty/FMDB/FMDatabaseAdditions.m` is in the target's Compile Sources and bootstrap reported `build mode: full` |
| App signing fails with team mismatch | `DEVELOPMENT_TEAM` env still set to a prior contributor's team ID | `unset DEVELOPMENT_TEAM` or set it to your own; re-run bootstrap |
