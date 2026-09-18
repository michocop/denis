#!/usr/bin/env bash
# Builds the app and launches it in the iOS Simulator.
#
#   scripts/run_simulator.sh            # demo data, no backend needed
#   scripts/run_simulator.sh --admin    # same, as Pierre-Louis
#   scripts/run_simulator.sh --live     # against SUPABASE_URL / SUPABASE_ANON_KEY
#
# Requires Xcode and xcodegen (brew install xcodegen).
set -euo pipefail

# Left empty on purpose: a hardcoded name like "iPhone 15" only exists on the
# machine it was written on. Set DEVICE="iPhone 17 Pro" to force one.
DEVICE="${DEVICE:-}"
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

cd "$(dirname "$0")/.."

# XcodeGen turns project.yml into the .xcodeproj that hosts the package. It is
# usually installed with Homebrew, but not everyone has Homebrew, and telling
# someone to go and get a package manager before they can look at their own app
# is a poor trade -- so fetch a local copy instead.
ensure_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN="xcodegen"
    return
  fi

  local dir="ios/.build/tools"
  local found
  found="$(find "$dir" -type f -name xcodegen -perm -u+x 2>/dev/null | head -1 || true)"

  if [ -z "$found" ]; then
    echo "==> XcodeGen not found; downloading a local copy into $dir"
    mkdir -p "$dir"
    curl -fsSL -o "$dir/xcodegen.zip" \
      https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip \
      || { echo "Could not download XcodeGen. Install it with: brew install xcodegen" >&2; exit 1; }
    unzip -q -o "$dir/xcodegen.zip" -d "$dir"
    # Gatekeeper quarantines anything downloaded, which makes the binary refuse
    # to run with a dialog rather than an error.
    xattr -dr com.apple.quarantine "$dir" 2>/dev/null || true
    found="$(find "$dir" -type f -name xcodegen -perm -u+x 2>/dev/null | head -1 || true)"
  fi

  [ -n "$found" ] || { echo "XcodeGen download did not contain a binary." >&2; exit 1; }
  XCODEGEN="$(cd "$(dirname "$found")" && pwd)/$(basename "$found")"
}

ensure_xcodegen

# project.yml names Config.xcconfig, and XcodeGen refuses to generate if it is
# missing. The example is empty, which is the right default: no project
# configured means the app runs on demo data.
if [ ! -f ios/Config.xcconfig ]; then
  cp ios/Config.example.xcconfig ios/Config.xcconfig
  echo "==> Created ios/Config.xcconfig from the example (demo data until filled in)"
fi

echo "==> Generating the Xcode project"
(cd ios && "$XCODEGEN" generate)

if [ "$MODE" = "live" ] && [ -z "${SUPABASE_URL:-}" ]; then
  echo "--live needs SUPABASE_URL and SUPABASE_ANON_KEY in the environment." >&2
  exit 1
fi

# Resolve a real simulator on THIS machine and address it by UDID, which
# cannot be ambiguous the way a name can.
pick_device() {
  local json
  json="$(xcrun simctl list devices available -j)" || {
    echo "Could not list simulators. Is Xcode installed and its license accepted?" >&2
    echo "Try: sudo xcodebuild -license accept" >&2
    exit 1
  }

  UDID="$(printf '%s' "$json" | DEVICE_NAME="$DEVICE" python3 -c '
import json, os, re, sys

wanted = os.environ.get("DEVICE_NAME", "").strip()
runtimes = json.load(sys.stdin)["devices"]

def ios_version(runtime):
    digits = re.findall(r"\d+", runtime.split(".")[-1])
    return tuple(int(d) for d in digits) or (0,)

def model_rank(name):
    numbers = re.findall(r"\d+", name)
    return (int(numbers[0]) if numbers else 0, "Pro" in name, "Max" in name)

candidates = []
for runtime, devices in runtimes.items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if wanted:
            if device["name"] == wanted:
                candidates.append((ios_version(runtime), (0,), device))
        elif "iPhone" in device["name"]:
            candidates.append((ios_version(runtime), model_rank(device["name"]), device))

if not candidates:
    sys.exit(0)
candidates.sort(key=lambda item: (item[0], item[1]))
print(candidates[-1][2]["udid"], candidates[-1][2]["name"], sep="\t")
')"

  if [ -z "$UDID" ]; then
    echo "No available iPhone simulator found." >&2
    echo "Installed simulators:" >&2
    xcrun simctl list devices available >&2
    echo >&2
    echo "Install one in Xcode: Settings > Components." >&2
    exit 1
  fi

  DEVICE_NAME="$(printf '%s' "$UDID" | cut -f2)"
  UDID="$(printf '%s' "$UDID" | cut -f1)"
  echo "==> Using $DEVICE_NAME ($UDID)"
}

pick_device

echo "==> Building"
xcodebuild build \
  -project ios/EnergyCourtage.xcodeproj \
  -scheme EnergyCourtageApp \
  -sdk iphonesimulator \
  -destination "id=$UDID" \
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

echo "==> Booting $DEVICE_NAME"
# `boot` fails if it is already booted, which is not an error here.
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b

echo "==> Installing"
xcrun simctl install "$UDID" "$APP"

echo "==> Launching"
if [ "$MODE" = "demo" ]; then
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
else
  xcrun simctl launch "$UDID" "$BUNDLE_ID"
fi

# simctl returns before the app is on screen, and the Simulator window can
# stay behind the terminal.
open -a Simulator
echo
echo "If the Simulator window is empty, bring it to the front (Cmd-Tab)."
echo "App: $BUNDLE_ID  Device: $DEVICE_NAME"
