#!/bin/bash
# Wayland Kiosk Launcher - starts Chromium in fullscreen using Cage

echo "╔════════════════════════════════════════╗"
echo "║   Starting Wayland Kiosk Mode          ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "To exit: Press Ctrl+Alt+F2, then run 'pkill cage'"
echo ""

# Through nginx on port 80, like every other browser: the page and its /api
# calls then share one origin. The frontend container on :3000 has no /api.
KIOSK_URL="http://localhost"

# curl -f also waits out the 502 nginx answers while the frontend container
# is still starting.
echo -n "Waiting for the app at $KIOSK_URL..."
until curl -sSf "$KIOSK_URL" >/dev/null 2>&1; do
  echo -n "."
  sleep 0.2
done
echo " ✓ Ready!"

echo ""
echo "Launching Chromium kiosk..."
echo ""

# Chromium's profile lock (SingletonLock, a symlink to <hostname>-<pid>, with
# SingletonCookie and SingletonSocket) names the host it was taken on. After
# the unit is renamed (scripts/provision-hostname.sh), a lock left by the
# kiosk that cage ended names the old hostname, and Chromium refuses a
# profile locked by "another computer". This script starts the session's
# only Chromium, so a lock here is stale, unless a Chromium of this user is
# still running (one that has not finished exiting): its lock is then left
# alone. The profile is passed as --user-data-dir below, so the files removed
# are those of the profile Chromium opens.
PROFILE_DIR="$HOME/.config/chromium"
if pgrep -u "$(id -u)" -x 'chromium|chromium-browse' >/dev/null 2>&1; then
  echo "A Chromium of this user is still running; its profile lock is left in place."
else
  rm -f "$PROFILE_DIR/SingletonLock" "$PROFILE_DIR/SingletonCookie" "$PROFILE_DIR/SingletonSocket"
fi

# Cage automatically makes the app fullscreen
exec cage -- chromium-browser \
  --user-data-dir="$PROFILE_DIR" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --password-store=basic \
  --overscroll-history-navigation=0 \
  --check-for-update-interval=31536000 \
  --no-first-run \
  --disable-sync \
  --disable-background-networking \
  --disable-default-apps \
  --disable-extensions \
  "$KIOSK_URL"
