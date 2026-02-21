#!/bin/bash
# Wayland Kiosk Launcher - starts Chromium in fullscreen using Cage

echo "╔════════════════════════════════════════╗"
echo "║   Starting Wayland Kiosk Mode          ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "To exit: Press Ctrl+Alt+F2, then run 'pkill cage'"
echo ""

# Wait for frontend to be ready
echo -n "Waiting for frontend at http://localhost:3000..."
until curl -sSf http://localhost:3000 >/dev/null 2>&1; do
  echo -n "."
  sleep 1
done
echo " ✓ Ready!"

echo ""
echo "Launching Chromium kiosk..."
echo ""

# Launch Cage with Chromium in kiosk mode
# Cage automatically makes the app fullscreen
exec cage -- chromium-browser \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --overscroll-history-navigation=0 \
  --check-for-update-interval=31536000 \
  http://localhost:3000
