# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses pre-1.0 semantic versioning.

## [0.0.0-pre.2] - 2026-05-31

### Added

- **DSLR camera support via gPhoto2** — Canon EOS and compatible USB cameras now work alongside picamera2. Backend auto-selects via `CAMERA_BACKEND=gphoto2` env var.
- **RAW (CR2) capture** — Selecting RAW or RAW+JPEG format now correctly saves `.cr2` files. Previously the camera silently fell back to JPEG on every capture.
- **Orientation / rotation control** — Per-camera post-capture rotation (0°, 90°, 180°, 270° CW) for scanning manuscripts in portrait orientation. JPEG captures are pixel-rotated via Pillow; CR2 files receive an EXIF Orientation tag via piexif so RAW converters auto-rotate.
- **Live preview rotation** — The camera feed in the live-preview viewport reflects the selected rotation in real time so operators can frame shots correctly before capturing.
- **Floating rotation buttons on each camera feed** — Quick-access ↺ / ↻ buttons float over each camera feed (bottom-centre). Clicking them updates both the live preview rotation and the capture rotation without opening the sidebar. State stays in sync with the sidebar orientation control.
- **Nginx reverse proxy** — All traffic now routes through Nginx on port 80 (`/api/*` → backend, `/*` → frontend). Eliminates hard-coded port references in the browser.
- **Network discoverability** — Raspberry Pi is accessible on the local network by hostname (`digitool.local`) and by IP. `HOST_IP` and CORS origins are configured dynamically at startup.
- **Documentation service** — Quarto-based docs rendered and served via Docker; includes device-setup guides for CM4 and Pi 5 + IMX519.
- **SD card distribution guide** — New developer documentation for distributing pre-imaged SD cards.
- **gPhoto2 device-setup guide** — Step-by-step instructions for connecting Canon DSLR cameras.

### Fixed

- **CR2 thumbnail in record viewer** — The modal image viewer (`img-viewer-frame`) now shows a renderable JPEG instead of sending the `.cr2` file directly to the browser (which browsers cannot display). The `_preview.jpg` sidecar is served when available.
- **`image_format` reverse mapping** — Camera configuration now correctly returns human-readable values (`JPEG`, `RAW`, `RAW+JPEG`) instead of internal PTP strings.
- **Capture path mismatch** — `GPhoto2Backend.capture_image()` previously returned the originally requested `.jpg` path even when the camera had saved a `.cr2` file. It now returns the actual saved path.
- **imageformat reset on every capture** — `apply_dslr_config()` was overwriting the camera's format setting to JPEG on every shot when no explicit format was configured. It now skips the PTP write when `image_format` is `None`, leaving the camera's own setting intact.
- **Record `format` field hardcoded to `"jpg"`** — The format stored in the database now reflects the actual file extension (e.g. `"cr2"`).

### Notes

- Project remains pre-alpha pending replication and validation on additional machines.
- Default capture orientation is 90° (portrait) to match typical book/manuscript scanning setups.
- piexif must be present in the pixi environment (`pixi run python -c "import piexif"`) for CR2 EXIF rotation to apply.

## [0.0.0-pre.1]

### Added

- Initial pre-alpha release baseline.

[0.0.0-pre.1]: https://github.com/UCSB-AMPLab/digitization-toolkit/releases/tag/pre-alpha
