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
- **Database**: SQLite

## Status

> Project currently in development. Kick-off: September 2025
> Alpha prototype planned for deployment at SBMAL in June 2025.

***

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
