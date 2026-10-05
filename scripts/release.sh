#!/usr/bin/env bash
# Builds the app for the App Store and uploads it to TestFlight.
#
#   scripts/release.sh            # archive, sign, upload
#   scripts/release.sh --archive  # archive and sign only (no upload)
#
# Needs: Xcode signed in to the Apple account of team 36T6NXA5JU (Xcode →
# Settings → Accounts), an Apple Distribution certificate in the Keychain, and
# the app created in App Store Connect with the bundle id
# com.trinityenergie.energycourtage. ios/Config.xcconfig must point at the
# production project, or the app would ship on demo data -- checked below.
#
# Each upload gets a build number from the clock (yyyyMMddHHmm), so it is
# always higher than the last; the version shown to people is MARKETING_VERSION
# in ios/project.yml.
set -euo pipefail

cd "$(dirname "$0")/../ios"
TEAM="36T6NXA5JU"
BUILD="$(date +%Y%m%d%H%M)"
OUT="$HOME/Library/Developer/Xcode/Archives/TrinityEnergie"
ARCHIVE="$OUT/TrinityEnergie-$BUILD.xcarchive"
DD="$HOME/Library/Developer/Xcode/DerivedData/TrinityEnergie-release"
mkdir -p "$OUT"

grep -q '^SUPABASE_URL = https' Config.xcconfig && grep -q '^SUPABASE_ANON_KEY = ey' Config.xcconfig || {
  echo "ios/Config.xcconfig does not point at a Supabase project: the app would ship on demo data." >&2
  exit 1
}

XCODEGEN="$(command -v xcodegen || find .build/tools /Users/"$USER"/denis/ios/.build/tools -type f -name xcodegen -perm -u+x 2>/dev/null | head -1)"
"$XCODEGEN" generate --quiet

echo "==> Unit tests"
xcodebuild test -scheme EnergyCourtage -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$DD-tests" -quiet 2>&1 | grep -E "error:|Executed .* tests" | tail -2

echo "==> Archive $BUILD"
xcodebuild archive -project EnergyCourtage.xcodeproj -scheme EnergyCourtageApp \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath "$DD" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD" \
  -quiet
echo "    $ARCHIVE"

[ "${1:-}" = "--archive" ] && exit 0

echo "==> Upload to App Store Connect (TestFlight)"
PLIST="$(mktemp -d)/ExportOptions.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PL
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$PLIST" \
  -exportPath "$OUT/export-$BUILD" -allowProvisioningUpdates
echo "Uploaded build $BUILD. It appears in App Store Connect → TestFlight after processing (5-15 min)."
