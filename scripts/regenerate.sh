#!/bin/sh
# Regenerate Lectures.xcodeproj on Colby's Mac (2026-11-16). The Xcode project
# isn't committed - XcodeGen builds it from project.yml. The Apple Team ID
# comes from ~/.lifeos-team-id (the same file LifeOS's lifeos-tf saves), so
# signing is set up without picking the team in Xcode.
#   sh ~/lectures/scripts/regenerate.sh        (alias: lectures)
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -z "${LECTURES_TEAM_ID:-}" ] && [ -f "$HOME/.lifeos-team-id" ]; then
  LECTURES_TEAM_ID="$(tr -d '[:space:]' < "$HOME/.lifeos-team-id")"
fi
export LECTURES_TEAM_ID="${LECTURES_TEAM_ID:-}"
[ -n "$LECTURES_TEAM_ID" ] || echo "  (no ~/.lifeos-team-id yet - run lifeos-tf or lectures-tf once, or pick the team in Xcode)"

if command -v xcodegen >/dev/null 2>&1; then
  XG=xcodegen
elif command -v brew >/dev/null 2>&1 && brew install xcodegen >/dev/null 2>&1; then
  XG=xcodegen
else
  curl -sSL -o /tmp/xcodegen.zip "https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip"
  rm -rf /tmp/xcodegen && unzip -oq /tmp/xcodegen.zip -d /tmp/xcodegen
  XG=/tmp/xcodegen/xcodegen/bin/xcodegen
fi

"$XG" generate --quiet
echo "Generated $REPO/Lectures.xcodeproj${LECTURES_TEAM_ID:+ (team $LECTURES_TEAM_ID)}"
