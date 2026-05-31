#!/usr/bin/env bash
# Regenerate FeralCompanion.xcodeproj from project.yml.
# Run after every branch switch — the .xcodeproj is gitignored and can
# retain references to Swift files that no longer exist on disk.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Install xcodegen: brew install xcodegen" >&2
  exit 1
fi
bash "$ROOT/scripts/generate-vendor-yml.sh"
xcodegen generate
echo "OK: $ROOT/FeralCompanion.xcodeproj"
