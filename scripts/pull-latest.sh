#!/bin/sh
# Xcode Cmd-R pre-action (Colby, 2026-11-20: he built straight to his phone and
# didn't get the latest changes). Before every Run, get the latest main - and
# regenerate the Xcode project when files were added / removed or project.yml
# changed. Copied from LifeOS's ios/scripts/pull-latest.sh. Local Macs only.
# It never fails the build: offline / local edits = build what's here.
# Log: /tmp/lectures-pull.log
if [ -n "$CI" ] || [ -n "$CI_XCODE_CLOUD" ] || [ -n "$GITHUB_ACTIONS" ]; then exit 0; fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
{
  echo "== $(date) $REPO"
  cd "$REPO" || exit 0
  BEFORE=$(git rev-parse HEAD 2>/dev/null) || exit 0
  if ! git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 pull --ff-only --quiet; then
    echo "pull skipped (offline, local edits or another branch) - building what's here"
    exit 0
  fi
  AFTER=$(git rev-parse HEAD)
  if [ "$BEFORE" = "$AFTER" ]; then echo "up to date"; exit 0; fi
  echo "updated ${BEFORE%"${BEFORE#???????}"} -> ${AFTER%"${AFTER#???????}"}"
  if git diff --name-status "$BEFORE" "$AFTER" | grep -qE '^[ADR]|project\.yml'; then
    echo "files added / removed: regenerating the Xcode project (if this build fails, press Cmd-R again)"
    sh scripts/regenerate.sh
  fi
} >> /tmp/lectures-pull.log 2>&1
exit 0
