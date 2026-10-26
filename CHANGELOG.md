# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses pre-1.0 semantic versioning.

## [0.1.0-beta] - 2026-10-25

0.1.0-beta is the first release built to be tested in day-to-day operation in an archive. It is tested on one configuration: a Captua unit (the Raspberry Pi scanner) with two Canon EOS Rebel T7 cameras connected over gphoto2, and a monitor, keyboard and mouse.

Captua can be used on its own or with [Fisqua](https://fisqua.org), AMPL's open-source cataloguing platform for archives. It can be used offline, or with copies kept in the cloud. Each of these is a complete way of working.
- **On its own:** volumes take the archive's own reference codes, and a volume's files leave the unit through the export.
- **Offline:** the unit needs no internet connection to capture, review or export.
- **With Fisqua:** the codes come from the archive's Fisqua catalogue, and Captua sends each finished volume to Fisqua.
- **With the cloud:** Captua keeps copies of the images and the catalogue in a bucket.

### Volumes and file names
- A volume is whatever the archive catalogues as a single item and captures as a whole: a bound volume, a folder, a bundle of loose documents. Each volume now carries a reference code: the archive's own, or, for an archive that uses Fisqua, the item's code in its Fisqua catalogue.
- That code is the stem of every file name in the volume. A stem has at most 27 characters: lowercase letters and digits, in groups joined by single hyphens, as in `co-ahr-con-t055`. Nothing can be captured into a volume until it has a stem. Once images have been captured into a volume, its stem can't be changed or given to another volume. A volume's reference code and its stem are always the same; Captua refuses one that differs from the other.
- New images are named `<stem>-img_<nnnn>_c<n>`: the stem, a number counted per volume, and the camera. Numbers are never reused, including those of retaken pages.
- On the unit's storage, each volume's files now sit in a folder of their own, named after its stem. Inside are:
  - `captures` for the masters, the original files from the camera;
  - `previews` for the JPEGs made from RAW masters;
  - `thumbnails` for the thumbnails;
  - `metadata` for the metadata.
- Renaming a project or moving a volume to another project no longer moves or renames any file. At the first start after the update, Captua moves existing files into this layout.
- Renumbering a volume changes the order of its pages and leaves the file names as they are.
- Captua leaves RAW masters exactly as the camera wrote them. Each image's rotation is recorded beside it and travels with the export.

### Capture and interface
- **Guided tour:** a first-run tour walks through the six steps from creating a project to exporting a volume. You can open it again from Ayuda.
- **Hover help:** the icon-only controls on the capture screen say what they do when the pointer rests on them.
- **Thumbnail strips:** they keep the two pages of a spread together.
- **Sliders:** the brightness, contrast and saturation sliders change how the image looks on screen. They leave the file as it is. Captua resets the rotation when you move to the next page.
- **Camera rotation:** each camera starts at the rotation saved for it, also when the unit takes a moment to detect the cameras after it starts.
- **Camera panel:** it says when the capture system is not available, instead of reporting a missing camera.
- **Renumbering:** it reports how many records were renumbered.
- **Storage warning:** the overview warns every user when the drive that holds the volumes is 85% full or more.
- **Dialogs:** dialogs fit on the unit's 800×480 screen, and you can scroll one that is too long for it. Escape or a click outside closes a dialog, except while closing it would lose work in progress.
- **User menu and shutdown:** every screen has a user menu, opened from your name in the sidebar or from the avatar on the capture and volume screens. From it, every signed-in user can shut down or restart the unit, not only administrators.
- **Removed controls:** two controls that did nothing are gone: the Filtros buttons on the project and volume lists, and Recuérdame on the sign-in screen.
- **Register:** the interface addresses you as tú throughout.

### Review
- A page can be rejected for one of nine reasons, each with a line explaining it: motion blur, glare/reflection, shadows, out of focus, exposure, debris on surface, framing, obstruction, and other. A rejection for "Other" needs a note. A note can be up to 2,000 characters.

### Copies in the cloud (optional)
- On a unit set up with a bucket in the cloud (Backblaze B2), Captua copies each master and its preview there. It then checks each copy against the bucket's own list of what it holds.
- For each volume, you can see how much of it is already in the bucket.
- Once a day, Captua copies its catalogue (the database of volumes, records and images) to the bucket, encrypted.
- Once the bucket holds a whole volume, an administrator can remove its masters and previews from the unit to free space. Thumbnails stay on the unit. Before removing a file, Captua checks it against the bucket again.
- An administrator can bring a freed volume back from the bucket.
- Copying to the bucket can be paused on the unit during maintenance, and resumed afterwards.

### Working with Fisqua (optional)
- When a volume is sent for review, and every one of its files is in the bucket, Captua sends Fisqua the volume's capture manifest: the list of its files and their checksums, which is needed to register the volume in Fisqua. No one has to exchange files by hand.
- If the unit is offline at that moment, Captua sends the manifest once the connection returns.
- The volume page shows where the volume stands in Fisqua: sent, registered, being processed, waiting for review, or refused, with the reasons.
- When pages are reviewed in Fisqua, Captua applies the decisions on the unit: it approves or rejects each record with Fisqua's reason and note, and records any rotation correction. It skips any record whose images have changed since the volume was sent.
- If Fisqua can't read the manifests this version of Captua writes, Captua stops sending and tells the administrator. Captua tries again every six hours, and sends the refused volumes again once Fisqua reads its manifests, after an update to either.
- A unit without Fisqua can still download the capture manifest from the volume page.
- Captua can import a digitisation list exported from Fisqua (the items an archive plans to capture) and create a volume for each item.

### Welcome and credits
- The welcome screen offers "Get started in English" and "Empezar en español". Each sets the interface language.
- The welcome screen acknowledges the institutions and people who have made Captua possible. A QR code on the Credits page leads to the project's page on the AMPL website.

### Name on the network
- The interface is now at `http://captua.local`. An update renames a unit still called `digitool` to `captua`, and the unit still answers at `digitool.local`, so existing bookmarks still work.
- The unit's own screen reaches Captua without going through the network, so it keeps working when the Wi-Fi drops.
- After this update the unit's screen asks for the language once, because the kiosk now opens a different address.

### Updates
- A failed update puts the previous version back when that loses nothing. Otherwise it leaves the unit stopped, with a record of what happened and how to resolve it, so the unit never starts on code and a database that don't match.
- An update refuses to install a checkout with local changes, or a version older than the one installed.
- A rollback refuses to go ahead when restoring the backup would cut volumes off from their files, and lists them.
- The unit's logs no longer record the session tokens that image and download addresses carry.

### For units already in use
- Units on which images were captured before this release need a few one-time steps after updating. These are command-line tools run by whoever manages the unit:
  - recording copies already in the bucket, including those Fisqua made under the new file names;
  - raising a volume's capture number past the numbers those copies use;
  - marking files already removed from the unit as freed;
  - recording checksums for older previews.
- The order matters, and it is set out in the deployment guide.
- The unit's settings can now use `CAPTUA_` names, and Configuración shows them. Captua still reads the old `DTK_` names. If a setting is given under both names, the `CAPTUA_` value applies.

### Known limits
- The digitisation list is imported by uploading the file. It has no screen yet, and doesn't yet arrive from Fisqua on its own.
- Space on the unit can be freed only once a volume is in a bucket. A way to free space that doesn't need a bucket is planned: a copy of the volume to three separate media, checked before anything is removed.

### For maintainers

- **The unit is called `captua`** — New cards are named `captua` and answer at `http://captua.local` (`DTK_HOSTNAME` names a second unit at a site). `update.sh` renames a unit called `digitool` to `captua` and keeps `digitool.local` answering through 0.1.x, with an mDNS alias (`dtk-mdns-alias.service`); a unit named otherwise by hand is left alone. The alias needs `avahi-utils`, which the update installs from apt, under `--no-pull` too; a unit that cannot reach apt, or an update run with the new `--no-pull --offline`, keeps the name until an update that can. A rename cut off by a power cut is finished or undone at the next start of `dtk`. `scripts/provision-hostname.sh` does the work for both scripts.
- **The API is called on the page's own origin** — The frontend calls `/api` relative to the page (`PUBLIC_API_BASE=/api`), through nginx, so the unit works by its name, by its old name or by its IP address. The kiosk opens `http://localhost` instead of the frontend container on `:3000`, and asks for a login once after the update. `update.sh`, `update.sh --resolve-forward` and `rollback-update.sh` relaunch it, and the rename points the kiosk's Chromium profile lock, which names the hostname it was taken under, at the new name; `start-kiosk.sh` also removes a stale lock before it starts Chromium.
- **`name: dtk` in `docker-compose.yml`** — The Compose project name is written out instead of derived from the checkout's directory. On a unit it is unchanged; a development checkout in another directory gets new container and volume names once.

## [0.0.0-pre.3] - 2026-07-24

The first release under the software's name, **Captua**, and the first validated end-to-end on real hardware: a fresh Raspberry Pi 5 was provisioned from the written documentation and taken through both camera backends, power-cut recovery, and the full update and rollback cycle on the bench (July 23–24). Everything integrated since 0.0.0-pre.2 is included. Captua remains pre-alpha.

### Added

**A name and a visual identity**
The software is now **Captua**. The release completes the renaming throughout the interface and ships the new identity: the Captua logo and wordmark, light and dark favicons, and Mulish as the interface typeface.

**Per-unit secrets at first boot**
Captua ships as a cloned SD card, and anything on the card at imaging time is copied bit-for-bit onto every unit — including credentials. A new first-boot service detects placeholder or cloned secrets before the application starts, generates a per-unit signing key and database password, rotates the live Postgres password crash-safely, and records the Pi's hardware serial so a card moved to a new machine regenerates on its own. Imaging a test-booted master is now safe.

**Safe updates, with a way back**
The update script now dumps the database before migrating, does all its network work before stopping the service, refuses to run unattended when it cannot confirm the update is offline-safe, and verifies the stack came back up. A companion rollback script restores the pre-update dump and returns the code to the last recorded deployment — never blindly to the current tip.

**Storage on removable media**
External drives can be mounted, activated as the projects storage root, and safely unmounted from the interface. The privileged operations run through a scoped helper with a single sudoers entry, replacing the previous open-ended mount permissions; unmounting a drive that is the active storage automatically reverts to internal storage.

**A firewall, and kiosk escape hatches**
Provisioning now closes the appliance's LAN surface to the web interface, SSH, and mDNS only. The kiosk gets two documented recovery paths out of the box: Ctrl+Alt+F2 drops to a terminal (Ctrl+Alt+F1 returns), and a `dtk-no-kiosk` file on the boot partition skips the kiosk for a session.

**Interface in Spanish and English**
The interface now runs from a full bilingual catalog, selected at login; the choice persists across reboots.

**Integrity checking**
Administrators can reconcile the database, the files on disk, and the capture manifests from a single endpoint. The check is strictly read-only — it reports discrepancies and never deletes or moves anything. The backend also refuses to start on an unmigrated database, failing visibly instead of running against a wrong schema.

**Honest clocks**
The Pi has no battery-backed clock, so a power cut used to scramble capture timestamps. Setup now installs fake-hwclock and chrony: time persists across reboots and corrects itself whenever the unit is online.

### Fixed

**Provisioning survives a fresh start**
A verbatim run of the documented setup previously failed several ways: the setup script had lost its executable bit, nothing created the environment file (leaving the database half-initialized with wrong credentials), and the nginx image was never pulled — so a card shipped offline crash-looped on first boot. All fixed; setup also now installs the camera system packages explicitly and adds the operator to the docker group.

**Cameras work against the pinned environment**
The locked Python environment was ABI-incompatible with the system camera stack, so the ArduCam backend reported no cameras on a fresh install; the DSLR backend's bundled USB library detected nothing even when the command-line tools saw both bodies. The environment now pins numpy below 2 and builds python-gphoto2 from source against the system library. Camera import failures also now report the real error instead of a misleading claim about the operating system.

**Capture and display**
Collections over one hundred records display in full. The thumbnail strip keeps a stable order under rapid consecutive captures. The collection hierarchy endpoint no longer errors on nested collections. Uploads are size-capped with orphaned files cleaned up on failure. Renaming a project moves its file tree along with it. Storage-override writes are atomic, and a corrupt override file now fails loudly instead of silently falling back.

**Sessions and permissions**
Session handling got a guard against expired tokens, camera status checks are auth-aware, camera controls are admin-only, annotation deletion is properly guarded, and authentication failures return explicit 401s.

### Known limitations

Updating an existing unit requires a current pixi (the lockfile is now format v7) — check `pixi --version` on target hardware first. The in-backend guard against placeholder secrets is not yet implemented; the systemd ordering is the operative protection. ArduCam dual capture runs seven to eight seconds per pair at medium resolution (DSLR: about four) — optimization is tracked. The frontend is pinned at the bench-tested state; the volume workflow and bug-report panel land next cycle.

## [0.0.0-pre.2] - 2026-05-31

### Added

- **DSLR camera support via gPhoto2** — Canon EOS and compatible USB cameras now work alongside picamera2. Backend auto-selects via `CAMERA_BACKEND=gphoto2` env var.
- **RAW (CR2) capture** — Selecting RAW or RAW+JPEG format now correctly saves `.cr2` files. Previously the camera silently fell back to JPEG on every capture.
- **Orientation / rotation control** — Per-camera post-capture rotation (0°, 90°, 180°, 270° CW) for scanning manuscripts in portrait orientation. JPEG captures are pixel-rotated via Pillow; CR2 files receive an EXIF Orientation tag via piexif so RAW converters auto-rotate.
- **Live preview rotation** — The camera feed in the live-preview viewport reflects the selected rotation in real time so operators can frame shots correctly before capturing.
- **Floating rotation buttons on each camera feed** — Quick-access ↺ / ↻ buttons float over each camera feed (bottom-centre). Clicking them updates both the live preview rotation and the capture rotation without opening the sidebar. State stays in sync with the sidebar orientation control.
- **Nginx reverse proxy** — All traffic now routes through Nginx on port 80 (`/api/*` → backend, `/*` → frontend). Eliminates hard-coded port references in the browser.
- **Network discoverability** — Raspberry Pi is accessible on the local network by hostname (`digitool.local`) and by IP. `HOST_IP` and CORS origins are static values in `.env`, set by hand.
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
