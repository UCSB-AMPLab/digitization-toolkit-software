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

# Cage automatically makes the app fullscreen
exec cage -- chromium-browser \
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
