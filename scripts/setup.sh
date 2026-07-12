#!/bin/bash
# One-time provisioning script for Digitization Toolkit
#
# Run this ONCE on the Pi while connected to the internet.
# After completion the SD card can be imaged for offline distribution.
#
# What it does:
#   1. Stops any running services for a clean slate
#   2. Creates required system directories
#   3. Builds Docker images (frontend multi-stage, pulls postgres:16-alpine)
#   4. Installs backend pixi environment (conda-forge packages)
#   5. Links system camera libraries (picamera2 / libcamera)
#   6. Starts the DB, applies Alembic migrations, then stops it
#
# Usage: sudo ./scripts/setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Resolve the real (non-root) user so pixi runs under the correct home dir
if [ -n "$SUDO_USER" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(whoami)"
fi
DTK_USER_HOME=$(eval echo "~$DTK_USER")
PIXI_BIN="$DTK_USER_HOME/.pixi/bin/pixi"

if [ ! -x "$PIXI_BIN" ]; then
    echo "✗ pixi not found at $PIXI_BIN"
    echo "  Install pixi as $DTK_USER first:"
    echo "    curl -fsSL https://pixi.sh/install.sh | bash"
    exit 1
fi

# Run a command as DTK_USER, preserving the pixi bin in PATH
run_as_user() {
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" PATH="$DTK_USER_HOME/.pixi/bin:$PATH" "$@"
}

COMPOSE="docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml"

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — Initial Setup"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Stop any running services
# ---------------------------------------------------------------------------
echo "→ Stopping any running services..."
$COMPOSE down 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# 2. System directories
# ---------------------------------------------------------------------------
echo "→ Creating system directories..."
mkdir -p /var/lib/dtk/db/postgres
mkdir -p /var/lib/dtk/mounts
mkdir -p /var/log/dtk
chown -R "$DTK_USER:$DTK_USER" /var/lib/dtk /var/log/dtk 2>/dev/null || true
echo "  /var/lib/dtk  ✓"
echo "  /var/log/dtk  ✓"
echo ""

# ---------------------------------------------------------------------------
# 2b. Scoped privileged helper + sudoers rule (no polkit/D-Bus needed)
# ---------------------------------------------------------------------------
echo "→ Configuring storage mount permissions..."
"$SCRIPT_DIR/install-system-helper.sh"
echo ""

# ---------------------------------------------------------------------------
# 3. Docker images
# ---------------------------------------------------------------------------
echo "→ Pulling base images and building services..."
$COMPOSE pull db
$COMPOSE build frontend
echo ""

# ---------------------------------------------------------------------------
# 4. Pixi backend environment
# ---------------------------------------------------------------------------
echo "→ Installing backend dependencies (pixi)..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" install
echo ""

# ---------------------------------------------------------------------------
# 5. Camera system library link (Raspberry Pi only)
# ---------------------------------------------------------------------------
if python3 -c "import picamera2" 2>/dev/null || [ -d /usr/lib/python3/dist-packages/picamera2 ]; then
    echo "→ Linking system camera libraries..."
    run_as_user "$PIXI_BIN" run setup-camera-link
    echo ""
else
    echo "→ Skipping camera link (picamera2 not found — OK on non-Pi hardware)"
    echo ""
fi

# ---------------------------------------------------------------------------
# 6. Installing packages and binaries for cameras
# ---------------------------------------------------------------------------

# gPhoto2
if sudo apt install -y gphoto2; then
    echo "gPhoto2 package installed"
    echo ""
else
    echo "gPhoto2 package not available in apt package manager."
    echo ""
fi

# ---------------------------------------------------------------------------
# 6b. System clock hardening (survive power cuts without an RTC)
# ---------------------------------------------------------------------------
# Without a battery-backed clock the Pi resumes at the last saved tick after a
# power cut, which scrambles capture timestamps. fake-hwclock persists the time
# across reboots; chrony corrects it via NTP whenever the unit is online (such
# as now, during setup).
echo "→ Installing clock services (fake-hwclock, chrony)..."
if sudo apt install -y fake-hwclock chrony; then
    systemctl enable fake-hwclock 2>/dev/null || true
    systemctl enable chrony 2>/dev/null || true
    # Seed the saved clock now, while the time is correct
    fake-hwclock save 2>/dev/null || true
    echo "  fake-hwclock + chrony  ✓"
else
    echo "  clock services not available in apt — skipping"
fi
echo ""
# Pi 5 hardware RTC (optional, done manually): fit a cell on the RTC header and
# enable trickle charge by adding 'dtparam=rtc_bbat_vchg=3000000' to
# /boot/firmware/config.txt, then 'sudo hwclock -w'.

# ---------------------------------------------------------------------------
# 6c. Host firewall (venue-LAN hardening)
# ---------------------------------------------------------------------------
# Only nginx (port 80), SSH, mDNS, and Tailscale remain reachable from the
# LAN; the native backend on 8000 stays reachable from the Docker bridge only.
bash "$SCRIPT_DIR/setup-firewall.sh"
echo ""

# ---------------------------------------------------------------------------
# 6d. Journald size cap (NEH-101)
# ---------------------------------------------------------------------------
# This is an SD-card appliance: the journal lives on the root partition, and an
# unbounded journal (or a crash-looping unit spamming logs) could fill it and
# brick the device. Cap persistent journald usage at 100M via a drop-in.
echo "→ Capping journald size (SD-card appliance)..."
mkdir -p /etc/systemd/journald.conf.d
tee /etc/systemd/journald.conf.d/dtk.conf >/dev/null <<'EOF'
# Digitization Toolkit — SD-card appliance.
# Logs must never fill the root partition, so cap journald's on-disk usage.
[Journal]
SystemMaxUse=100M
EOF
if systemctl restart systemd-journald 2>/dev/null; then
    echo "  journald SystemMaxUse=100M  ✓"
else
    echo "  ⚠ journald restart failed — the 100M cap takes effect on next reboot"
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Database initialisation & migrations
# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"
echo "→ Starting database for migration..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "${DATABASE_USER:-user}" -d "${DATABASE_NAME:-digitization_toolkit}" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s."
        echo "  Check logs: docker compose logs db"
        $COMPOSE down
        exit 1
    fi
    sleep 2
done

echo "→ Applying database migrations..."
# DATABASE_HOST=localhost is already in .env; alembic reaches the DB
# container via the exposed 5432 port on the host.
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" run db-upgrade
echo ""

echo "→ Stopping database..."
cd "$PROJECT_ROOT"
$COMPOSE down
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Setup complete!"
echo "=========================================="
echo ""
echo "The Pi is now ready for offline operation."
echo ""
echo "Next steps:"
echo "  sudo ./scripts/install-service.sh   # Enable auto-start on boot"
echo ""
echo "Or start manually:"
echo "  ./scripts/start.sh"
echo ""
echo "To distribute this setup, power off and image the SD card:"
echo "  sudo poweroff"
