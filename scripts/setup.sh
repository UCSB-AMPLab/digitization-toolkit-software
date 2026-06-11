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
# 0. Ensure .env exists (compose + alembic must read the same credentials)
# ---------------------------------------------------------------------------
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo "→ Creating .env from .env.example..."
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    chown "$DTK_USER:$DTK_USER" "$PROJECT_ROOT/.env"
    echo "  .env created  ✓"
    echo "  IMPORTANT: Edit $PROJECT_ROOT/.env to set a real SECRET_KEY and"
    echo "  DATABASE_PASSWORD before going into production."
    echo ""
else
    echo "→ .env already exists — skipping copy."
    echo ""
fi

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
# Postgres data dir must remain root-owned so the postgres container can
# chown it to uid 999 (postgres) during first-time initdb.
chown -R "$DTK_USER:$DTK_USER" /var/lib/dtk/mounts /var/log/dtk 2>/dev/null || true
echo "  /var/lib/dtk  ✓"
echo "  /var/log/dtk  ✓"
echo ""

# ---------------------------------------------------------------------------
# 2a. Docker group membership (no sudo needed for docker after first login)
# ---------------------------------------------------------------------------
echo "→ Adding $DTK_USER to docker group..."
usermod -aG docker "$DTK_USER"
echo "  $DTK_USER added to docker group  ✓"
echo "  (Log out and back in after setup for this to take effect)"
echo ""

# ---------------------------------------------------------------------------
# 2b. Sudoers rule for storage mounting (no polkit/D-Bus needed)
# ---------------------------------------------------------------------------
echo "→ Configuring storage mount permissions..."
cat > /etc/sudoers.d/dtk-storage << 'EOF'
# Digitization Toolkit — allow backend user to mount/unmount removable storage
# without a password. Required because the backend runs without a login session
# and polkit cannot perform interactive authentication in that context.
Defaults:pi !requiretty
pi ALL=(root) NOPASSWD: /usr/bin/mount, /usr/bin/umount, /bin/mount, /bin/umount, /usr/bin/mkdir, /bin/mkdir, /usr/bin/chown, /bin/chown
EOF
chmod 0440 /etc/sudoers.d/dtk-storage
echo "  /etc/sudoers.d/dtk-storage  ✓"
echo ""

# ---------------------------------------------------------------------------
# 3. Docker images
# ---------------------------------------------------------------------------
echo "→ Pulling base images and building services..."
$COMPOSE pull db nginx
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
echo "→ Installing system camera packages (picamera2 / libcamera)..."
# python3-picamera2 and python3-libcamera are Raspberry Pi OS system packages.
# On non-Pi hardware these will simply not be found in apt and the install
# will fail gracefully — that is expected and OK.
if apt-get install -y python3-picamera2 python3-libcamera 2>/dev/null; then
    echo "  python3-picamera2  ✓"
    echo "→ Linking system camera libraries into pixi environment..."
    run_as_user "$PIXI_BIN" run setup-camera-link
    echo ""
else
    echo "  Skipping camera link (picamera2 not available — OK on non-Pi hardware)"
    echo ""
fi

# ---------------------------------------------------------------------------
# 6. Installing packages and binaries for cameras
# ---------------------------------------------------------------------------

# gPhoto2
if apt-get install -y gphoto2; then
    echo "  gphoto2  ✓"
    echo ""
else
    echo "  gphoto2 not available in apt — skipping."
    echo ""
fi

# ---------------------------------------------------------------------------
# 7. Database initialisation & migrations
# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"
echo "→ Starting database for migration..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
# First-time initdb on a Pi SD card can take 2-3 minutes; wait up to 3 min.
for i in $(seq 1 90); do
    if $COMPOSE exec -T db pg_isready -U "${DATABASE_USER:-user}" -d "${DATABASE_NAME:-digitization_toolkit}" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 90 ]; then
        echo "✗ Database did not become ready after 180s."
        echo "  Check logs: docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml logs db"
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
