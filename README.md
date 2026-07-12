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
# Start database and frontend behind Nginx (base compose + Pi overlay)
docker compose -f docker-compose.yml -f docker-compose.pi.yml up -d --pull never

# Start backend natively with pixi (production mode, no --reload)
cd backend && pixi run start
```

The Pi overlay (`docker-compose.pi.yml`) is required in production: it bind-mounts Postgres at `/var/lib/dtk/db/postgres` (instead of the base compose's `postgres_data` named volume) and adds the Nginx reverse proxy that puts frontend and backend behind one origin on port 80.

**Access (production):** [http://localhost](http://localhost) (Nginx, port 80 — proxies `/` to the frontend and `/api/` to the backend) | [http://localhost:8000/docs](http://localhost:8000/docs) (API, direct)
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
# 1. Clone the repository onto a fresh Raspberry Pi OS installation
git clone --recurse-submodules https://github.com/UCSB-AMPLab/digitization-toolkit-software.git ~/dtk
cd ~/dtk

# 2. Run the one-time provisioning script (internet required here)
#    Builds Docker images, installs pixi env, applies DB migrations
sudo ./scripts/setup.sh

# 3. Install and enable the systemd service (auto-start on boot)
sudo ./scripts/install-service.sh
sudo systemctl start dtk

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
git clone --recurse-submodules git@github.com:UCSB-AMPLab/digitization-toolkit-software.git
```

If you already cloned without `--recurse-submodules`, you can initialize and update submodules manually:

```bash
git submodule update --init --recursive
```

To bring the submodules to the exact versions this repo pins (after pulling the superproject):

```bash
git pull
git submodule update --init --recursive
```

Do not use `--remote` here: it moves the submodules to their branch tips instead of the tested commits the superproject records. `--remote` belongs only to the deliberate pointer bump — see the [Git workflow](https://github.com/UCSB-AMPLab/digitization-toolkit-software/wiki/Git-workflow) wiki.

***

## Development Documentation

See the [wiki](https://github.com/UCSB-AMPLab/digitization-toolkit-software/wiki) for detailed developer guides and API references.

## License

Copyright © 2025 UCSB – Archives, Memory & Preservation Lab.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See [LICENSE](LICENSE) for the full text.

Hardware CAD files and documentation are released under CC BY 4.0.
