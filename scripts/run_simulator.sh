#!/usr/bin/env bash
# Builds the app and launches it in the iOS Simulator.
#
#   scripts/run_simulator.sh            # demo data, no backend needed
#   scripts/run_simulator.sh --admin    # same, as Pierre-Louis
#   scripts/run_simulator.sh --live     # against SUPABASE_URL / SUPABASE_ANON_KEY
#
# Requires Xcode and xcodegen (brew install xcodegen).
set -euo pipefail

DEVICE="${DEVICE:-iPhone 15}"
BUNDLE_ID="com.trinityenergie.energycourtage"
MODE="demo"
EXTRA_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --admin) EXTRA_ARGS+=("-admin") ;;
    --live)  MODE="live" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

cd "$(dirname "$0")/.."
(cd ios && xcodegen generate)

if [ "$MODE" = "live" ] && [ -z "${SUPABASE_URL:-}" ]; then
  echo "--live needs SUPABASE_URL and SUPABASE_ANON_KEY in the environment." >&2
  exit 1
fi

echo "==> Building"
xcodebuild build \
  -project ios/EnergyCourtage.xcodeproj \
  -scheme EnergyCourtageApp \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath ios/.build \
  CODE_SIGNING_ALLOWED=NO \
  SUPABASE_URL="${SUPABASE_URL:-}" \
  SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
  | (command -v xcpretty >/dev/null && xcpretty || cat)

APP="ios/.build/Build/Products/Debug-iphonesimulator/EnergyCourtageApp.app"

echo "==> Booting $DEVICE"
# `boot` fails if it is already booted, which is not an error here.
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$DEVICE" -b

echo "==> Installing"
xcrun simctl install booted "$APP"

echo "==> Launching"
if [ "$MODE" = "demo" ]; then
  xcrun simctl launch booted "$BUNDLE_ID" -demo "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
else
  xcrun simctl launch booted "$BUNDLE_ID"
fi
