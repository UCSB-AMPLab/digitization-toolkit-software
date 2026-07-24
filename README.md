# Captua

**Captua** is the software of the **Digitization Toolkit**, an integrated toolkit of hardware, software, and documentation that allows lower-resourced institutions, collectives, and communities to digitize their archival collections at low cost.

The project builds on a decade of community-based digitization work in the Global South. The DIY book-scanning equipment that made that work possible — cheap digital cameras and single-board computers — has become increasingly obsolete or unavailable; the Digitization Toolkit replaces it with sustainable, up-to-date technologies. Captua runs a Raspberry Pi–based capture station driving paired cameras (ArduCam modules or gPhoto2-compatible DSLRs) through a web interface, in Spanish and English, for image capture, metadata entry, and export — designed to work entirely offline. An alpha version will be tested at the Santa Barbara Mission Archive-Library (SBMAL).

## Tech Stack

- **Hardware**: Raspberry Pi CM4 + CM4IO, Raspberry Pi 5 (dual camera embedded), 2 × 64MP ArduCam autofocus cameras, 2 × Canon EOS Rebel T7 (or other gPhoto2-compatible DSLRs)
- **Backend**: Python, FastAPI
- **Frontend**: Svelte
- **Database**: PostgreSQL

## Status

> Captua is in active development and remains **pre-alpha**. Current release: [0.0.0-pre.3](https://github.com/UCSB-AMPLab/digitization-toolkit-software/releases).

## Release History

See the [GitHub Releases page](https://github.com/UCSB-AMPLab/digitization-toolkit-software/releases) for version history and release notes.

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

### Backend Dependency Management

The backend uses **pixi** for dependency management:

```bash
# First time setup
cd backend
pixi install --locked
pixi run setup-camera-link  # Raspberry Pi only

# Start backend
pixi run dev
```

## Production Distribution (SD Card Imaging)

The toolkit is designed to ship as a pre-flashed SD card. The end user only needs to insert the card, power on the Pi, and the application starts automatically — no internet connection required.

### Building the golden SD card (requires internet, done once)

Flash **Raspberry Pi OS (Legacy, 64-bit) Lite — Debian 12 "Bookworm"** — the tested
OS. Beware that Raspberry Pi Imager's plain "Raspberry Pi OS Lite (64-bit)" entry
now installs Debian 13 (Trixie), which this stack has not been validated against.
In Imager's advanced options set the username to **`pi`** — the service and kiosk
installers hardcode `User=pi` and `/home/pi/dtk` — and enable SSH if provisioning
headless.

```bash
# 0. Prerequisites — none of these ship with a fresh Raspberry Pi OS Lite
sudo apt update && sudo apt install -y git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER          # re-login for this to take effect
curl -fsSL https://pixi.sh/install.sh | bash

# 1. Clone the repository
git clone --recurse-submodules https://github.com/UCSB-AMPLab/digitization-toolkit-software.git ~/dtk
cd ~/dtk

# 2. Run the one-time provisioning script (internet required here)
#    Creates .env if missing, builds Docker images, installs pixi env,
#    applies DB migrations
sudo ./scripts/setup.sh

# 3. Install and enable the systemd service (auto-start on boot)
sudo ./scripts/install-service.sh
sudo systemctl start dtk

# 4. Kiosk mode (fullscreen browser on the attached display)
sudo ./scripts/installkb.sh
sudo ./scripts/install-kiosk-service.sh

# 5. Verify the app is running
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

## Credits and Acknowledgments

Captua is developed by Adelaida Ávila, Juan Cobo Betancourt (grant PI), Jairo Melo Flórez, Santiago Muñoz Arbeláez (grant co-PI), Lucrezia Pograri, and Catalina Salguero at the Archives, Memory, and Preservation Lab of the University of California, Santa Barbara and at the University of Texas at Austin.

Captua has been made possible in part by a major grant from the National Endowment for the Humanities: Democracy demands wisdom. ([NEH Award HAA-304052-25](https://awardsearch.neh.gov/AwardDetail.aspx?gn=HAA-304052-25): "Digitization Toolkit: a Blueprint for Egalitarian Access to Technology in Low-Resource Environments".)

Any views, findings, conclusions, or recommendations expressed in this software do not necessarily represent those of the National Endowment for the Humanities.

<img src="docs/_static/imgs/neh-preferred-seal.jpg" alt="National Endowment for the Humanities" width="250">

## License

Copyright © 2025 UCSB – Archives, Memory & Preservation Lab.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See [LICENSE](LICENSE) for the full text.

Hardware CAD files and documentation are released under CC BY 4.0.
