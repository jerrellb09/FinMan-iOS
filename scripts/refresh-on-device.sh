#!/bin/zsh
# Rebuilds FinMan (ios-standalone branch) and reinstalls it on your iPhone so the free
# Apple ID's 7-day signing never lapses. Reinstalling keeps the app's data.
#
#   refresh-on-device.sh             build + install now
#   refresh-on-device.sh --install   copy to ~/bin and schedule it (Sun + Wed, 7 PM) with launchd
#   refresh-on-device.sh --uninstall remove the schedule
#
# Log: ~/Library/Logs/finman-ios-refresh.log
set -euo pipefail

REPO="$HOME/repos/FinManApp"
BRANCH="ios-standalone"
TEAM_ID="QUXAAFMP4V"                 # Jerrell Boone (Personal Team)
DEVICE_UDID="${DEVICE_UDID:-}"       # empty = first paired physical iPhone
WORK="$HOME/Library/Developer/FinManRefresh"
SRC="$WORK/source"                   # dedicated git worktree, unaffected by branch switches in $REPO
LOG="$HOME/Library/Logs/finman-ios-refresh.log"
LABEL="com.jerrell.finman-ios-refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALLED="$HOME/bin/refresh-finman-ios.sh"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

notify() { osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" >/dev/null 2>&1 || true; }

case "${1:-}" in
  --install)
    mkdir -p "${INSTALLED:h}" "${PLIST:h}"
    cp "$0" "$INSTALLED" && chmod +x "$INSTALLED"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$INSTALLED</string></array>
  <!-- Twice a week so one failed run never lets the 7-day signature expire.
       If the Mac is asleep at that time, launchd runs the job when it wakes. -->
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>19</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>19</integer><key>Minute</key><integer>0</integer></dict>
  </array>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/finman-ios-refresh-launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/finman-ios-refresh-launchd.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Scheduled $LABEL (Sundays and Wednesdays at 7 PM). Script: $INSTALLED"
    echo "Run it now with: launchctl kickstart -k gui/$(id -u)/$LABEL"
    exit 0 ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed the schedule. (Script left at $INSTALLED.)"
    exit 0 ;;
esac

mkdir -p "$WORK" "${LOG:h}"
exec > >(tee -a "$LOG") 2>&1
echo "=== Refresh started: $(date) ==="

fail() {
  echo "ERROR: $1"
  notify "FinMan refresh failed" "$1"
  echo "=== Refresh FAILED: $(date) ==="
  exit 1
}

# 1. Latest local commit on the branch, in a worktree of its own.
if [[ ! -e "$SRC/.git" ]]; then
  git -C "$REPO" worktree add --detach "$SRC" "$BRANCH" || fail "Couldn't create the build worktree."
fi
git -C "$SRC" checkout --quiet --force --detach "$BRANCH" || fail "Couldn't check out $BRANCH."
echo "Building $BRANCH @ $(git -C "$SRC" rev-parse --short HEAD)"

# 2. Find the iPhone (must be paired with this Mac: cable, or 'Connect via network').
if [[ -z "$DEVICE_UDID" ]]; then
  xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null 2>&1 || true
  DEVICE_UDID=$(/usr/bin/python3 - "$WORK/devices.json" <<'PY' || true
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and hw.get("udid"):
        print(hw["udid"])
        break
PY
)
fi
[[ -n "$DEVICE_UDID" ]] || fail "No paired iPhone found. Connect and unlock it, then run the refresh again."
echo "Device: $DEVICE_UDID"

# 3. Build and sign (automatic signing renews the free provisioning profile).
if ! xcodebuild \
  -project "$SRC/ios/FinManApp.xcodeproj" \
  -scheme FinManApp \
  -configuration Debug \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$WORK/DerivedData" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build > "$WORK/build.log" 2>&1; then
  grep -E "error:" "$WORK/build.log" | sort -u | head -5
  fail "Build or signing failed (see log). Open Xcode and check Settings > Accounts."
fi
echo "Build succeeded."
APP="$WORK/DerivedData/Build/Products/Debug-iphoneos/FinManApp.app"
[[ -d "$APP" ]] || fail "Build finished but FinManApp.app wasn't found."

# 4. Install over the existing app (keeps your data). Retry in case the phone is locked or asleep.
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"; then
    expires=$(date -v+7d "+%a %b %-d")
    notify "FinMan refreshed ✅" "Installed on your iPhone. Good until about $expires."
    echo "=== Refresh completed: $(date) (valid until ~$expires) ==="
    exit 0
  fi
  echo "Install attempt $attempt failed; retrying in 2 minutes…"
  sleep 120
done
fail "Couldn't install on the iPhone. Unlock it and keep it near the Mac, then run the refresh again."
