#!/usr/bin/env bash
# scripts/bootstrap.sh — one-shot local-build entry point for FERAL
# Companion. Drops a contributor from `git clone` to a buildable Xcode
# project in a single command:
#
#   $ git clone https://github.com/FERAL-AI/feral-companion-ios.git
#   $ cd feral-companion-ios
#   $ ./scripts/bootstrap.sh
#   $ open FeralCompanion.xcodeproj
#
# The script is idempotent and safe to re-run after pulling new commits
# or dropping new vendor frameworks into Vendor/.
#
# Build modes (auto-detected):
#   stub  — Vendor/ is missing the proprietary JieLi/RTK frameworks;
#           the app builds against JWBleStubs.swift. Demo 2 only
#           (PhoneOnlyAdapter + HealthKitAdapter).
#   full  — All five vendor frameworks present; W300 BLE + Theora
#           wristband work. Demo 3 enabled.
#
# Flags:
#   --dry-run     report build mode + planned actions, do nothing
#   --force-stub  ignore Vendor/ contents and bootstrap in stub mode
#   --help        print this message

set -euo pipefail

# ---------------------------------------------------------------------
# Logging primitives
# ---------------------------------------------------------------------
_log()  { printf "\033[36m[bootstrap]\033[0m %s\n" "$*"; }
_warn() { printf "\033[33m[bootstrap]\033[0m %s\n" "$*" >&2; }
_die()  { printf "\033[31m[bootstrap]\033[0m %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------
DRY_RUN=false
FORCE_STUB=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --force-stub) FORCE_STUB=true ;;
        --help|-h)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            _warn "unknown flag: $arg (see --help)"
            exit 64
            ;;
    esac
done

# ---------------------------------------------------------------------
# Repo root
# ---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------
# Tool prerequisites
# ---------------------------------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        _log "xcodegen not found — installing via Homebrew"
        $DRY_RUN || brew install xcodegen
    else
        _die "xcodegen is not installed and Homebrew is unavailable. Install xcodegen manually: https://github.com/yonaskolb/XcodeGen#installing"
    fi
fi

# Xcode command-line tools are required for xcodebuild.
if ! xcode-select -p >/dev/null 2>&1; then
    _warn "Xcode command-line tools are not installed. Run: xcode-select --install"
fi

# ---------------------------------------------------------------------
# Vendor framework detection
# ---------------------------------------------------------------------
VENDOR_FRAMEWORKS=(
    "Vendor/JWBle.framework"
    "Vendor/CocoaLumberjack.framework"
    "Vendor/RTKAudioConnectSDK.framework"
    "Vendor/RTKLEFoundation.framework"
    "Vendor/RTKOTASDK.framework"
)

MISSING_FRAMEWORKS=()
for fw in "${VENDOR_FRAMEWORKS[@]}"; do
    if [[ ! -d "$REPO_ROOT/$fw" ]]; then
        MISSING_FRAMEWORKS+=("$fw")
    fi
done

if $FORCE_STUB; then
    BUILD_MODE="stub"
    _log "--force-stub: ignoring Vendor/ contents"
    # Force every framework into the "missing" list so the diagnostic
    # block below renders the full set.
    MISSING_FRAMEWORKS=("${VENDOR_FRAMEWORKS[@]}")
elif [[ ${#MISSING_FRAMEWORKS[@]} -eq 0 ]]; then
    BUILD_MODE="full"
else
    BUILD_MODE="stub"
fi

# ---------------------------------------------------------------------
# Vendor cache hint
# ---------------------------------------------------------------------
VENDOR_CACHE="${FERAL_VENDOR_CACHE:-$HOME/.feral/vendor-cache/companion-ios}"
if [[ "$BUILD_MODE" == "stub" && ! $FORCE_STUB && -d "$VENDOR_CACHE" ]]; then
    _log "vendor cache detected at $VENDOR_CACHE — populating Vendor/"
    mkdir -p "$REPO_ROOT/Vendor"
    for fw in "${VENDOR_FRAMEWORKS[@]}"; do
        src="$VENDOR_CACHE/$(basename "$fw")"
        if [[ -d "$src" ]]; then
            $DRY_RUN || rm -rf "$REPO_ROOT/$fw"
            $DRY_RUN || cp -R "$src" "$REPO_ROOT/$fw"
            _log "  copied $(basename "$fw")"
        fi
    done
    # Re-evaluate after copy.
    MISSING_FRAMEWORKS=()
    for fw in "${VENDOR_FRAMEWORKS[@]}"; do
        [[ -d "$REPO_ROOT/$fw" ]] || MISSING_FRAMEWORKS+=("$fw")
    done
    [[ ${#MISSING_FRAMEWORKS[@]} -eq 0 ]] && BUILD_MODE="full"
fi

# ---------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------
_log "build mode: $BUILD_MODE"
if [[ "$BUILD_MODE" == "stub" ]]; then
    _log "stub mode — the following frameworks are absent and the app"
    _log "will compile against JWBleStubs.swift (Demo 2 only):"
    for fw in "${MISSING_FRAMEWORKS[@]+"${MISSING_FRAMEWORKS[@]}"}"; do
        _log "  - $fw"
    done
    _log "for the full build (Demo 3 / W300 glasses) see docs/VENDOR_SETUP.md"
fi

if $DRY_RUN; then
    _log "--dry-run: stopping before xcodegen"
    exit 0
fi

# ---------------------------------------------------------------------
# xcodegen
# ---------------------------------------------------------------------
if [[ "$BUILD_MODE" == "full" ]]; then
    SPEC="project.vendor.yml"
else
    SPEC="project.yml"
fi

# DEVELOPMENT_TEAM is consumed by project.yml via ${DEVELOPMENT_TEAM}.
# If the contributor exported it, propagate; otherwise leave unset so
# Xcode's automatic signing UI handles team selection.
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    _log "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM (from environment)"
else
    _log "DEVELOPMENT_TEAM not set — configure signing in Xcode's Signing & Capabilities tab"
fi

_log "running xcodegen generate --spec $SPEC"
xcodegen generate --spec "$SPEC" --quiet

_log "done. Next:"
_log "  open FeralCompanion.xcodeproj"
if [[ "$BUILD_MODE" == "stub" ]]; then
    _log "  (Build & Run targets the iPhone simulator; the Devices tab"
    _log "  will show 'JWBle SDK not installed' for the glasses card.)"
fi
