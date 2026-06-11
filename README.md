# Digitization Toolkit

An open-source, modular digitization toolkit designed for low-cost, high-quality scanning using Raspberry Pi Compute Module 4 and 64MP ArduCam cameras. Built for use in low-resource environments and community archives.

## Goals

- Empower small institutions and communities to digitize archival materials.
- Provide an easy-to-use web interface for image capture, metadata entry, and export.
- Ensure long-term reproducibility through open standards (BagIt, CSV, TIFF).
- Prioritize modularity and hardware independence for future-proofing.

## Tech Stack

- **Hardware**: Raspberry Pi CM4 + CM4IO, Raspberry Pi 5 (dual camera embedded), 2x 64MP ArduCam autofocus cameras, 2 x Cannon EOS Rebel T7 (GPhoto compatible cameras)
- **Backend**: Python, FastAPI
- **Frontend**: Svelte
- **Database**: PostgreSQL

## Status

> Project currently in development. Kick-off: September 2025
> Alpha prototype planned for deployment at SBMAL in June 2026.

## Release History

See [CHANGELOG.md](CHANGELOG.md) for version history and release notes.

***

## Quick Start

### Development (any machine, no cameras)

```bash
# One-command startup (all services in Docker)
./scripts/start-dev.sh
```

Or manually:
```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up
```

### Production (Raspberry Pi with cameras)

```bash
# Build the frontend image first (requires internet — do this at home/office):
docker compose build

# Then take it offline and run:
./scripts/start.sh
```

Or manually:
```bash
# Start database and frontend
docker compose up -d

# Start backend with pixi
cd backend && pixi run dev
```

**Access (production):** [http://localhost:3000](http://localhost:3000) (frontend) | [http://localhost:8000/docs](http://localhost:8000/docs) (API)
**Access (dev):** [http://localhost:5173](http://localhost:5173) (frontend, Vite) | [http://localhost:8000/docs](http://localhost:8000/docs) (API)

**Note:** The native backend is required for camera access due to Raspberry Pi-specific libraries (libcamera, picamera2).

### 📦 Backend Dependency Management

The backend uses **pixi** for dependency management:

```bash
# First time setup
cd backend
pixi install
pixi run setup-camera-link  # Raspberry Pi only

# Start backend
pixi run dev
```

## Production Distribution (SD Card Imaging)

The toolkit is designed to ship as a pre-flashed SD card. The end user only needs to insert the card, power on the Pi, and the application starts automatically — no internet connection required.

### Building the golden SD card (requires internet, done once)

```bash
# 0. Install GIT
sudo apt update
sudo apt install git -y

# 0.1. Override dev ssh for submodules
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

```bash
# 1. Clone the repository onto a fresh Raspberry Pi OS installation
git clone --recurse-submodules https://github.com/UCSB-AMPLab/digitization-toolkit.git ~/dtk
cd ~/dtk

# 1.1. Install pixi as Python environment manager
curl -fsSL https://pixi.sh/install.sh | bash
source ~/.bashrc
# Verify pixi is installed and sourced
pixi --version

# 1.2. Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 1.3. Setup Raspberry pi cameras
# Select the configuration according with the cameras to be used
# For instance
[Raspberry Pi 5 IMX519 Camera Setup](https://ampl.clair.ucsb.edu/digitization-toolkit-software/developers/device_setup_pi5_imx519.html)

# 1.4. Create the .env file
cp .env.example .env
nano .env # edit the values

# 2. Run the one-time provisioning script (internet required here)
#    Builds Docker images, installs pixi env, applies DB migrations
sudo chmod +x ./scripts/setup.sh
sudo ./scripts/setup.sh

# 2.1 Install Wayland kiosk browser
sudo ./scripts/installkb.sh

# 3. Install and enable the systemd service (auto-start on boot)
sudo ./scripts/install-service.sh
sudo systemctl start dtk

# 3.1 Apply the docker group to the current shell session
#     (setup.sh added pi to the docker group, but it only takes effect
#     after a logout/login — newgrp activates it immediately for this session)
newgrp docker

# 4. Verify the app is running
curl http://localhost:8000/health   # → {"status":"ok"}
curl -I http://localhost:3000       # → HTTP 200
```

### Creating an SD card image

```bash
# On the Pi — shut down cleanly
sudo systemctl stop dtk
sudo poweroff

# On a host machine with the SD card inserted (replace sdX with your device)
sudo dd if=/dev/sdX of=dtk-$(date +%Y%m%d).img bs=4M status=progress
# Compress for storage/transfer
xz -T0 dtk-$(date +%Y%m%d).img
```

### Flashing for end users

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (or `dd`) to write the `.img` to a new SD card.  
The application starts automatically on boot — no configuration needed.

### What's self-contained after provisioning

| Component | Stored at | Requires internet after setup? |
|---|---|---|
| Frontend (SvelteKit) | Docker image in `/var/lib/docker/` | No |
| PostgreSQL | Docker image in `/var/lib/docker/` | No |
| Backend Python env | `backend/.pixi/` | No |
| camera libraries | `/usr/lib/python3/dist-packages/` | No (system OS) |
| Application data | `/var/lib/dtk/` | No |

## Setup

This repository uses **Git submodules** for the `frontend` and `backend` code.  
When cloning, make sure to fetch submodules as well:

```bash
# Clone with submodules
git clone --recurse-submodules git@github.com:UCSB-AMPLab/digitization-toolkit.git
```

If you already cloned without `--recurse-submodules`, you can initialize and update submodules manually:

```bash
git submodule update --init --recursive
```

To pull the latest changes for submodules after updates:

```bash
git submodule update --remote --merge
```

***

## Development Documentation

See the [wiki](https://github.com/UCSB-AMPLab/digitization-toolkit/wiki) for detailed developer guides and API references.

## License

MIT
