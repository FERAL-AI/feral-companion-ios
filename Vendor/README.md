# Vendor frameworks

This directory is the drop-in target for the five proprietary
frameworks that the JieLi W300 glasses + Theora wristband paths
depend on. Everything in here is **gitignored** by design; the public
repository must not redistribute the JieLi and Realtek SDKs.

```
Vendor/
├── JWBle.framework/               (JieLi — NDA)
├── RTKAudioConnectSDK.framework/  (Realtek — NDA)
├── RTKLEFoundation.framework/     (Realtek — NDA)
├── RTKOTASDK.framework/           (Realtek — NDA)
└── CocoaLumberjack.framework/     (BSD-3 — bundled by vendor demo)
```

## How a fresh clone behaves

* If **none** of the five frameworks are present, `xcodegen generate`
  produces a stub-mode project — `JWBleStubs.swift` provides no-op
  implementations of `JWBleSession`, `JWBleAdapterWired`, and
  `BLEScanView`. The build is green, the app launches, and every
  surface except the W300 BLE glasses works (Demo 2).
* If **all five** are present, `./scripts/bootstrap.sh` selects
  `project.vendor.yml` (which `include`s `project.yml` and layers the
  vendor framework deps on top), and the app builds against the real
  JieLi SDK (Demo 3).

A partial drop (e.g. only `JWBle.framework`) is rejected: bootstrap
keeps the project in stub mode and lists the missing frameworks.

## How to obtain the frameworks

See [`docs/VENDOR_SETUP.md`](../docs/VENDOR_SETUP.md) for the access
flow. In short:

1. Sign the JieLi NDA via your FERAL hardware partnerships contact.
2. Receive a one-time signed URL for the four-framework bundle.
3. Extract into `~/.feral/vendor-cache/companion-ios/`, then run
   `./scripts/bootstrap.sh` from the repo root. The script copies
   from the cache into `Vendor/`, sets `FERAL_HAS_VENDOR=true`, and
   regenerates the Xcode project.

## CocoaLumberjack

CocoaLumberjack is BSD-3 licensed and would be redistributable, but
the JieLi vendor demo links against a specific binary build with
SDK quirks; ship the same binary that ships with the JieLi bundle
to avoid runtime mismatches.
