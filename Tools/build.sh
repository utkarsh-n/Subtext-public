#!/bin/zsh
# Builds Subtext from a copy of the tree OUTSIDE iCloud Drive.
#
# ~/Documents is synced by iCloud, and xcodebuild loads projects through NSFileCoordinator,
# which stalls whenever the iCloud file-coordination daemon is busy — builds then hang at the
# invocation line for ever. Copying to a plain folder and building there sidesteps it entirely.
#
#   Tools/build.sh sim            build for the booted iPhone 17 Pro simulator (default)
#   Tools/build.sh device         build + sign for a physical iPhone
#   Tools/build.sh sim install    also install (and relaunch) on the simulator
#   Tools/build.sh device install also install on the connected iPhone
#
# Environment: SUBTEXT_BUILD_ROOT overrides the copy location; XCODEBUILD_TIMEOUT (s, default 1500).
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${SUBTEXT_BUILD_ROOT:-${TMPDIR:-/tmp}/subtext-build}"
DEST="$ROOT/Subtext"
MODE="${1:-sim}"
ACTION="${2:-build}"
SIM_ID="9AC0979F-7162-42A7-A2BD-FB3CC1D6439D"
DEVICE_ID="47C11007-EC72-5611-98B6-FC3FC5CD65F2"
mkdir -p "$DEST"
rsync -a --delete \
  --exclude 'build/' --exclude 'build-*/' --exclude '*.xcodeproj' --exclude '.git' \
  --exclude 'Tools/synctest/out/' --exclude '.DS_Store' \
  "$SRC/" "$DEST/"
cd "$DEST"
xattr -cr . 2>/dev/null || true
xcodegen generate > /dev/null
LOG="$DEST/build-$MODE.log"
if [ "$MODE" = "device" ]; then
  timeout "${XCODEBUILD_TIMEOUT:-1500}" xcodebuild -project Subtext.xcodeproj -scheme Subtext \
    -destination 'generic/platform=iOS' -derivedDataPath build-device \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID build > "$LOG" 2>&1 || true
  APP="$DEST/build-device/Build/Products/Debug-iphoneos/Subtext.app"
else
  timeout "${XCODEBUILD_TIMEOUT:-1500}" xcodebuild -project Subtext.xcodeproj -scheme Subtext \
    -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath build build > "$LOG" 2>&1 || true
  APP="$DEST/build/Build/Products/Debug-iphonesimulator/Subtext.app"
fi
grep -E "error:" "$LOG" | grep -v "export " | head -20
if grep -q "\*\* BUILD SUCCEEDED" "$LOG"; then
  echo "BUILD SUCCEEDED ($MODE) → $APP"
else
  echo "BUILD FAILED ($MODE) — log: $LOG"; exit 1
fi
if [ "$ACTION" = "install" ]; then
  if [ "$MODE" = "device" ]; then
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | grep -iE "installed|error" | head -2
  else
    xcrun simctl install "$SIM_ID" "$APP"
    xcrun simctl launch --terminate-running-process "$SIM_ID" com.utkarsh.subtext "${@:3}"
  fi
fi
