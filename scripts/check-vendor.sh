#!/usr/bin/env bash
# Report which Vendor/ SDK bundles are present on disk.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"

status() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    printf '  [present]  %s\n' "$label"
  else
    printf '  [absent]   %s\n' "$label"
  fi
}

echo "FERAL Companion — Vendor SDK status"
echo "Directory: $VENDOR"
echo
echo "Bundled (open source, committed):"
status "CocoaLumberjack.framework (BSD)" "$VENDOR/CocoaLumberjack.framework"
status "FMDB/ (MIT)" "$VENDOR/FMDB"
echo
echo "Optional (proprietary — contact Theora for access):"
status "JWBle.framework (Theora glasses / W300)" "$VENDOR/JWBle.framework"
status "RTKAudioConnectSDK.framework (Realtek audio)" "$VENDOR/RTKAudioConnectSDK.framework"
status "RTKLEFoundation.framework (Realtek BLE)" "$VENDOR/RTKLEFoundation.framework"
status "RTKOTASDK.framework (Realtek OTA)" "$VENDOR/RTKOTASDK.framework"
status "QCSDK.framework (W610 glasses)" "$VENDOR/QCSDK.framework"
status "VeepooBleSDK.framework (Veepoo wristband)" "$VENDOR/VeepooBleSDK.framework"
echo
if [[ -d "$VENDOR/JWBle.framework" ]]; then
  echo "Hardware: Theora glasses (W300) support is ENABLED for this build."
else
  echo "Hardware: Theora glasses features will report unavailable until JWBle.framework is installed."
fi
