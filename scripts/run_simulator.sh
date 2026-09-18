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

# A missing bundle here means the build produced a library and no app, which
# is what happens when the package is built instead of the app target. Say so
# rather than failing three commands later with something cryptic.
if [ ! -d "$APP" ]; then
  echo "No app bundle at $APP" >&2
  echo "Products that were built:" >&2
  find ios/.build/Build/Products -maxdepth 2 -name '*.app' -o -maxdepth 2 -name '*.framework' 2>/dev/null >&2 || true
  exit 1
fi

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

# simctl returns before the app is on screen, and the Simulator window can
# stay behind the terminal.
open -a Simulator
echo
echo "If the Simulator window is empty, bring it to the front (Cmd-Tab)."
echo "App: $BUNDLE_ID  Device: $DEVICE"
