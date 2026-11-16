#!/bin/sh
# Local TestFlight upload of Lectures from Colby's Mac (2026-11-16; never
# GitHub Actions any more). One command: latest main -> regenerate the project
# -> archive (Release, automatic signing with the Xcode account) -> upload.
#   sh ~/lectures/scripts/testflight.sh        (alias: lectures-tf)
# Only when Colby says "build" (PROJECT_NOTES > Next Build Queue).
# Needs: Xcode signed in to the Apple developer account (Xcode > Settings >
# Accounts) and one device registered on the team (his iPhone already is).
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "→ Getting the latest main"
git pull --ff-only --quiet || echo "  (pull skipped - building what's here)"

# Team ID: shared with LifeOS's lifeos-tf (~/.lifeos-team-id); else from the
# Mac's distribution certificate; else asked once.
TEAM_FILE="$HOME/.lifeos-team-id"
TEAM="${LECTURES_TEAM_ID:-}"
if [ -z "$TEAM" ] && [ -f "$TEAM_FILE" ]; then TEAM=$(tr -d '[:space:]' < "$TEAM_FILE"); fi
if [ -z "$TEAM" ]; then
  TEAM=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*Apple Distribution: .*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -1)
fi
if [ -z "$TEAM" ]; then
  printf "Apple Team ID (10 characters, developer.apple.com > Account > Membership details): "
  read -r TEAM
fi
if [ "${#TEAM}" -ne 10 ]; then echo "✗ \"$TEAM\" isn't a 10-character Team ID"; exit 1; fi
echo "$TEAM" > "$TEAM_FILE"

# Build number: one above the last upload from this Mac (starts above 34, the
# last GitHub build). Xcode also bumps it past anything TestFlight already has
# (manageAppVersionAndBuildNumber), so it never collides.
NUM_FILE="$HOME/.lectures-build-number"
LAST=$(cat "$NUM_FILE" 2>/dev/null || echo 34)
NEXT=$((LAST + 1))

echo "→ Generating the Xcode project"
LECTURES_TEAM_ID="$TEAM" sh scripts/regenerate.sh >/dev/null

OUT="$HOME/Library/Developer/Lectures-TestFlight/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "→ Archiving build $NEXT (a few minutes)"
if ! xcodebuild archive -project Lectures.xcodeproj -scheme Lectures -configuration Release \
    -destination generic/platform=iOS -archivePath "$OUT/Lectures.xcarchive" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$NEXT" \
    > "$OUT/archive.log" 2>&1; then
  if grep -q "no devices from which to generate a provisioning profile" "$OUT/archive.log"; then
    echo "✗ Apple needs one registered device on your team first (one time):"
    echo "  plug your iPhone into the Mac, unlock it, tap Trust, then open"
    echo "  Xcode > Window > Devices and Simulators until it shows the iPhone. Then run lectures-tf again."
    exit 1
  fi
  grep -E "error:|warning: .*signing|No profiles|requires a provisioning" "$OUT/archive.log" | head -20
  tail -15 "$OUT/archive.log"
  echo "✗ Archive failed - full log: $OUT/archive.log"
  exit 1
fi

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><true/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

echo "→ Uploading to TestFlight"
if ! xcodebuild -exportArchive -archivePath "$OUT/Lectures.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates > "$OUT/upload.log" 2>&1; then
  grep -iE "error|failed" "$OUT/upload.log" | head -20
  echo "✗ Upload failed - full log: $OUT/upload.log"
  exit 1
fi

GOT=$(/usr/libexec/PlistBuddy -c Print "$OUT/export/DistributionSummary.plist" 2>/dev/null | sed -n 's/.*buildNumber = \([0-9]*\).*/\1/p' | head -1)
GOT=${GOT:-$NEXT}
echo "$GOT" > "$NUM_FILE"
echo "✓ Uploaded Lectures build $GOT - it shows in TestFlight after Apple's processing (usually 5-15 min)."
