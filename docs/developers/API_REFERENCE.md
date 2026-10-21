# Digitization Toolkit - API Reference and Implementation Guide

Documentation of the backend API endpoints, data models, implementation details, and code examples for frontend integration.

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Key Resources](#2-key-resources)
3. [API Reference](#3-api-reference)
4. [Testing the API](#4-testing-the-api)
   - [Option 1: Interactive Docs on Swagger UI](#41-option-1-interactive-docs-on-swagger-ui)
   - [Option 2: Complete Testing Workflow in Swagger UI](#42-option-2-complete-testing-workflow-in-swagger-ui)
   - [Option 3: Run Test Suite](#43-option-3-run-test-suite)
   - [Option 4: Manual Testing (cURL)](#option-4-manual-testing-curl)
5. [File Storage Architecture](#5-file-storage-architecture)
6. [Code Examples](#6-code-examples)
7. [Frontend Integration](#7-frontend-integration)
8. [Configuration](#8-configuration)

---

## 1. Quick Start

### Backend Setup

How to get the backend running:

The backend runs **in Docker for development** and **natively through pixi on the Raspberry Pi**. A legacy virtualenv + `pip install -r requirements.txt` still works on Linux, but pixi is preferred for new development (`.github/copilot-instructions.md`).

It does **not** work on Windows or macOS: `backend/requirements.txt` pins `picamera2` and `gphoto2`, which are Linux/Pi camera libraries, and `backend/pixi.toml` declares only `linux-aarch64` and `linux-64`. Use Docker on those platforms.

**Development — any machine, no cameras attached:**

```bash
./scripts/start-dev.sh
```

This brings the whole stack up in Docker — PostgreSQL, the FastAPI backend and the SvelteKit dev server — and applies Alembic migrations on startup. It is shorthand for:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up --build
```

**Production — on the Pi:** `./scripts/start.sh` runs the database and frontend in Docker and the backend natively via pixi, because camera access needs Pi-specific libraries (libcamera, picamera2) that cannot run in a container.

See `backend/DEVELOPMENT.md` for the dependency-manifest rules that follow from this split.

### Verify it works:

After `start-dev.sh` (development):

- **Frontend**: http://localhost:5173 (Vite dev server)
- **Interactive API Docs**: http://localhost:8000/docs (Swagger UI)
- **Health Check**: http://localhost:8000/health
- **ReDoc**: http://localhost:8000/redoc

After `start.sh` (production on the Pi), there is no Vite server: Nginx serves the UI and proxies the API on **port 80** — `http://<hostname>.local`. Port 8000 is not open to the LAN (see §3).

### Test everything:

Tests run inside the backend container:

```bash
# Run all tests
docker compose exec backend python -m pytest

# Or run specific test suites:
docker compose exec backend python -m pytest tests/unit/
docker compose exec backend python -m pytest tests/integration/
docker compose exec backend python tests/validate_system.py
```

---

## 2. Key Resources

| Resource | Location | Purpose |
|----------|----------|---------|
| **Endpoint reference** | `http://localhost:8000/docs` | Generated from the code; always current |
| **Backend Setup** | [../../backend/README.md](../../backend/README.md) | Quick start and environment setup |
| **Configuration Example** | [Code Examples](#complete-workflow-registration-to-gallery) | How to build configuration page |
| **Live Scan Example** | [Code Examples](#live-scan-page-example) | How to build live scan page |
| **Gallery Example** | [Code Examples](#galleryview-page-example) | How to build gallery page |
| **Device Setup** | `device_setup_CM4.qmd`, `device_setup_pi5_imx519.qmd` | Raspberry Pi configuration |

---

## 3. API Reference

The endpoint list, path and query parameters, and request/response schemas are **generated from the code** and served by the running backend:

| | |
|---|---|
| **Swagger UI** | [`http://localhost:8000/docs`](http://localhost:8000/docs) — interactive; send real requests, including authenticated ones |
| **ReDoc** | [`http://localhost:8000/redoc`](http://localhost:8000/redoc) — readable single-page reference |
| **OpenAPI schema** | [`http://localhost:8000/openapi.json`](http://localhost:8000/openapi.json) — machine-readable, for client generation |

FastAPI derives these from the routers themselves, so they cannot fall out of step with the implementation. This document deliberately does not duplicate them.

Two limits worth knowing, because the schema is only as complete as the routes declare it. Endpoints without a `response_model` — `POST /auth/login` and `GET /auth/setup/status` among them — appear with no response schema. On errors, the schema is partial: no route in `backend/app/api/` declares `responses=`, so the only error FastAPI advertises is the `422` with an `HTTPValidationError` body it adds automatically wherever a route validates input. **Every other code the application raises is absent from the schema: 400, 401, 403, 404, 409, 413, 429, 500, 501, 502, 503 and 504** — and so is the application's own `422`, which is a different thing from the automatic one. Two more can reach a client from the framework beneath the application, and the grep below does not see them: `405` from Starlette's router when the path exists and the method does not, and `416` from `FileResponse` when a `Range` header cannot be satisfied — the image download at `records.py:602` returns one.

Three of those are worth knowing individually, because a client that assumes the list is shorter will mis-handle them.

- **`422` is two codes wearing one number.** FastAPI's is a validation failure whose body is an object with a `detail` array. Nineteen places in `backend/app/api/` raise their own, carrying a `detail` string or, on the handover and export refusals in `collections.py`, a dict — `{message, blocking_record_ids}`. The move refusal that names records the same way is a `409`, not a `422` (`collections.py:321`). And a refusal from the background export job never arrives as an error status at all: the job records it, and `GET .../export/status/{job_id}` returns it at `200` with the message in a top-level `error` field (`collections.py:703`). A client that reads 422 as "your request was malformed" will report a collection refused for unapproved records as a bug in itself.
- **`401` comes from one file, and `403` mostly does.** All fourteen 401s are in `app/api/auth.py`. Three are in `get_current_user`, the dependency of every route except `/health` and five auth routes, so a client can meet them anywhere. The other eleven are raised by the auth routes themselves — login, register, refresh and reset-password — for that route's own reason: a wrong password, a wrong bootstrap token at first-user registration (`_authorize_bootstrap`, called only there, `auth.py:63`), and at refresh and reset an invalid or expired token as well (`auth.py:172`, `:192`). Which of them mean the session is gone is the route's, not the status code's, to say. Three of the five 403s are in `auth.py` too, one of them `RoleChecker.__call__` (`auth.py:232`), the role gate routes declare as a dependency. The other two are domain rules: an annotation with a recorded creator may only be deleted by that creator or an admin, and one with none by anyone who can reach the route (`records.py:715`); and `_apply_status_change` checks the caller's role (`records.py:868`). That helper is also called from `promote_collection`, so a role refusal can arrive from the handover — but the bulk status route calls it too and catches the refusal and returns `200` with only the records it did change (`records.py:948-963`); a refused record is logged on the server and not reported to the client.
- **`500` is a documented outcome, not only a crash.** Fifteen routes raise it deliberately: a camera control that failed, a storage command (`lsblk`, mount, unmount) that failed, a file operation that failed, or a database commit that failed after files had already changed. One of them reports a half-completed operation: `POST /collections/{id}/images/renumber` says the files were renumbered on disk and the database update was not (`collections.py:477`). `POST /records/{id}/images` is the opposite case — when its commit fails it unlinks the saved file and thumbnail before raising (`records.py:421-427`). A failure after the commit, in the refresh at `records.py:428`, is also a 500 and cleans nothing up, so the two cannot be told apart from the status alone.

To re-derive this rather than trust it, which is what let the previous list go stale:

```bash
grep -rhoE 'HTTPException\(\s*(status_code\s*=\s*)?(status\.HTTP_)?[0-9]{3}|status_code\s*=\s*(status\.HTTP_)?[0-9]{3}' backend/app/ \
  | grep -oE '[0-9]{3}' | sort -u
```

Then drop the success codes the decorators declare — 200, 201, 202, 204. One raiser sits outside `backend/app/api/`: `app/core/db_errors.py`, which turns any `IntegrityError` — not only a unique-constraint one — into a 409 carrying a message and, when one could be recovered, the constraint name. For any single route, read it: the `HTTPException` calls are explicit, and seven callables in `backend/app/api/` raise on a route's behalf — `_authorize_bootstrap`, `get_current_user` and `RoleChecker.__call__` in `auth.py`, `_resolve_capture_target` in `cameras.py`, `assert_movable`, `_assert_promotable` and `_apply_status_change` in `records.py` — so a route can return a code its own body never names.

It used to. A hand-written endpoint table, data-model list and error-code table lived here and drifted until they covered barely half the API, documented three roles incorrectly, and presented one error shape as universal when capture endpoints report failure as `{success: false, error: ...}` at HTTP 200 — with nothing able to notice. They were removed rather than repaired.

What remains here is what a schema cannot express: how to get the stack running, how to test it, how storage is laid out, worked examples, and the reasoning behind the architecture.

**`external_id` — on the record response, in no request body.** The field holds the identifier of the catalogue entry a record was captured for: Fisqua's `reference_code`. Its absence from every request body is deliberate. Nothing writes it yet — the only writer will be the exchange importer, which is not built — so no record on any appliance carries a value.

Two rules the schema cannot state:

- **Unique.** Two records cannot claim the same catalogue entry. Any number of records may have no `external_id` at all.
- **Written once.** Once a record has a value, an assignment that would change it raises instead of updating, and clearing it to `NULL` counts as a change. Re-assigning the same value is allowed, since nothing changes. The check is on the model — `Record._external_id_is_write_once` in `app/models/record.py` — so it covers every writer that assigns the attribute, and a bulk `UPDATE` or raw SQL goes around it.

**Reaching the schema on a deployed appliance.** A development stack is the easiest place to explore the API. On a provisioned unit, `scripts/setup-firewall.sh` allows port 8000 from the appliance's own compose network (`172.30.0.0/24`) and over `tailscale0`, but not from the venue LAN — so it is reachable for remote support, not from a laptop in the room. Note also that the proxied `/api/docs` path does not render Swagger UI, because the page requests `/openapi.json` at the site root and Nginx routes `/` to the frontend; `/api/openapi.json` does proxy correctly, so the raw schema is retrievable that way.

---


## 4. Testing the API

### 4.1 Option 1: Interactive Docs on Swagger UI

The fastest way to test endpoints is using the interactive documentation.

#### **Getting Started with Swagger UI**

1. **Open in Browser**
   ```
   http://localhost:8000/docs
   ```

2. **You'll see:**
   - All API endpoints grouped by tag (auth, users, records, projects, collections, cameras, system)
   - Green `POST`, blue `GET`, orange `PATCH`, purple `PUT`, red `DELETE` method badges

#### **Swagger UI Navigation Guide**

**Example:** To test the login endpoint:
1. Look for the **auth** section and expand it
2. Click `POST /auth/login`
3. Click **"Try it out"**, fill in credentials, click **"Execute"**
4. Copy the `access_token` from the response

**Using Bearer Tokens for Protected Endpoints**

1. Test `POST /auth/login`, copy the `access_token`
2. Click the green **"Authorize"** button (top-right)
3. Paste the token (with or without `Bearer ` prefix) and click **"Authorize"**
4. All subsequent requests automatically include your token

**Testing a Protected Endpoint Example: Create Record**

1. After authorization, find `POST /records/` under **records** section
2. Click "Try it out", fill in the request body:
   ```json
   {
     "title": "Ancient Manuscript",
     "capture_mode": "single",
     "author": "Unknown",
     "date": "1500-01-01"
   }
   ```
3. Click "Execute": view the 200 OK response with the record ID (this endpoint does not set 201; `POST /collections/` does)

##### Swagger UI Features

- **2xx (Green):** Success
- **4xx (Red):** Client error - check your request or role permissions
- **5xx (Red):** Server error - backend issue

---

### 4.2 Option 2: Complete Testing Workflow in Swagger UI

Recommended order to test the entire API:

1. **Health Check** → `GET /health` (no auth needed)
2. **Check setup state** → `GET /auth/setup/status` (no auth needed)
3. **Bootstrap, only if `needs_setup` is true** → `POST /auth/register`. This first user becomes admin. If an account already exists, skip this step: registration then requires an admin token and returns 401 without one.
4. **Login** → `POST /auth/login` (save token)
5. **Authorize** → Click Authorize button, paste token
6. **Get Current User** → `GET /users/me` (check your role)
7. **Create Project** → `POST /projects/` (admin only)
8. **Create Record** → `POST /records/`
9. **Upload Image** → `POST /records/{id}/images`
10. **Add to Project** → `POST /projects/{id}/add_record/{rec_id}`
11. **Get Record** → `GET /records/{id}`
12. **Delete Record** → `DELETE /records/{id}`

---

### 4.3 Option 3: Run Test Suite

```bash
# Run all tests with pytest
docker compose exec backend python -m pytest

# Run specific test categories
docker compose exec backend python -m pytest tests/unit/          # API, models, schemas
docker compose exec backend python -m pytest tests/integration/   # capture workflow
# Camera tests need real hardware AND the native pixi environment on the Pi;
# the dev container has no camera devices and no libcamera (Dockerfile.dev
# installs none) — see backend/DEPENDENCIES.md. On the Pi, in backend/:
#   pixi run -e dev pytest tests/test_cameras.py -m camera
# Note: the `test-cameras` pixi task is currently broken — it points at
# test/test_cameras.py, and the file is tests/test_cameras.py (NEH-195).

# Run with verbose output
docker compose exec backend python -m pytest -v

```

`pytest-cov` is not currently in either dependency manifest, so `--cov` is unavailable; `backend/pytest.ini` keeps the coverage options commented out for that reason.

**Test Organization:**
- `tests/unit/test_api.py` — API endpoint validation, imports, models, schemas
- `tests/integration/test_capture_integration.py` — Full capture workflow with database
- `tests/test_cameras.py` — Camera hardware tests (requires connected cameras)
- `tests/validate_system.py` — Complete system validation script
- `tests/conftest.py` — Shared pytest fixtures

### Option 4: Manual Testing (cURL)

```bash
# Health check
curl http://localhost:8000/health

# Register user
curl -X POST http://localhost:8000/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","email":"test@example.com","password":"pass123"}'

# Login
curl -X POST http://localhost:8000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"pass123"}'

# Get current user's role
curl http://localhost:8000/users/me \
  -H "Authorization: Bearer <token>"
```

---

### Alternative Documentation Views

**ReDoc** (Read-only documentation):
```
http://localhost:8000/redoc
```

**OpenAPI JSON** (Raw specification):
```
http://localhost:8000/openapi.json
```

---

## 5. File Storage Architecture

### Storage Structure

Images are stored under the active projects root, `/var/lib/dtk/projects/` by default:

```
<projects root>/
├── project_1/
│   ├── collection_a/            ← captures into a collection land here
│   │   └── images/
│   │       └── main/
│   │           ├── 20260109_143652_123_c0.jpg
│   │           ├── 20260109_143652_123_c1.jpg
│   │           └── ...
│   ├── images/
│   │   └── main/                ← captures with no collection
│   ├── metadata/
│   │   ├── project_manifest.jsonl   ← written at project init
│   │   └── manifest.jsonl           ← one line per capture, appended
│   └── packages/                ← created at init, currently unused
├── project_2/
│   └── ...
```

Five things worth knowing, each of which the previous version of this section got wrong:

- **The append-only manifests live in `metadata/`.** `append_manifest_record()` (`backend/capture/manifestHandler.py:269-275`) creates the directory and writes `project_manifest.jsonl` at init and one `manifest.jsonl` line per capture, each carrying the capture-time sha256. This is the provenance record; it is not optional and it is not in `images/`.
- **Captures usually sit one level deeper than the project.** `image_output_dir()` (`backend/capture/project_manager.py:57-63`) returns `<project>/<collection>/images/main/` whenever a collection is supplied, and `_resolve_capture_target` (`backend/app/api/cameras.py:43-56`) supplies one for every capture made against a collection. Only project-level captures use `<project>/images/main/`.
- **`packages/` is not where exports go.** It is created at project init and nothing writes into it. BagIt exports are written to `settings.exports_dir` — `/var/lib/dtk/exports` by default (`backend/app/core/config.py:92`, `backend/app/core/export_service.py:113`).
- **There is no `temp/` or `trash/` directory under the projects root, and deletion is permanent.** Deleting a record unlinks its files, as does deleting a single image (`delete_record` and the image delete handler in `backend/app/api/records.py`); each takes the master, the thumbnail and the `_preview.jpg` sidecar beside the master. There is no recovery directory, and on a backup-less appliance a delete is final.
- **The root is not fixed.** Activating an external storage device changes `settings.projects_dir` at runtime, so captures may live somewhere other than the default microSD path.

### Filename Format

Captured images follow the format: `YYYYMMDD_HHMMSS_mmm_cX.jpg`

- `YYYYMMDD` — Date (ISO format)
- `HHMMSS` — Time (24-hour format)
- `mmm` — Milliseconds (000–999)
- `cX` — Camera index (c0, c1)

**Example**: `20260109_143652_123_c0.jpg`
- January 9, 2026 · 14:36:52.123 UTC · Camera 0

### Data Flow Architecture

```
┌─────────────────┐
│  API Client     │  (Frontend / cURL / Python)
└────────┬────────┘
         │ POST /cameras/capture
         ▼
┌──────────────────────┐
│  FastAPI Endpoint    │  cameras.py
│  - Validates request │
│  - Checks auth/role  │
└────────┬─────────────┘
         ▼
┌──────────────────────────────────┐
│  Capture Service                 │  capture/service.py
│  - Loads calibration from        │  - Uses picamera2/libcamera
│    camera registry               │  - Applies camera settings
│  - Captures image to:            │
│    /var/lib/dtk/projects/.../    │
│    images/main/                  │
└────────┬─────────────────────────┘
         ▼
┌──────────────────────────────────┐
│  Metadata Extraction             │  PIL / EXIF
│  - Image dimensions              │
│  - EXIF data (datetime, GPS)     │
│  - Camera settings used          │
└────────┬─────────────────────────┘
         ▼
┌──────────────────────────────────┐
│  Create Database Records         │  SQLAlchemy ORM
│  - RecordImage (main record)     │
│  - CameraSettings (capture cfg)  │
│  - ExifData (image metadata)     │
└────────┬─────────────────────────┘
         ▼
┌──────────────────────────────────┐
│  PostgreSQL Database             │
│  - Image metadata stored         │
│  - Linked to project + record    │
└──────────────────────────────────┘
```

### Database Relationships

```
Record (title, capture_mode, project_id, collection_id)
    └─> RecordImage[] (file_path, filename, format, role)
            ├─> CameraSettings (camera_model, white_balance, lens_model)
            └─> ExifData (raw_exif, datetime_original, GPS)

Project (name, description)
    └─> Record[]
    └─> Collection[]
            └─> Collection[] (nested sub-collections)
```

### Performance Metrics

Measured on a Pi 5 during hardware validation, 23–24 July 2026. The picamera2
figures are at the medium preset; the presets do not apply to gphoto2, which
shot at whatever the camera bodies were set to (see the storage note below).
Earlier figures in this section were estimates, and were roughly double the
real throughput and six to eight times the real file sizes.

**Dual capture, seconds per pair:**

| Backend | Measured | Note |
|---|---|---|
| gphoto2 (Canon EOS 1500D ×2) | ~4 s | |
| picamera2 (IMX519 ×2) | 7–8 s | too slow for production; NEH-173 tracks the fix |

Both already fire the two cameras in parallel (ThreadPool with a 20 ms stagger,
`capture/service.py:605`), and both backends lock per camera index rather
than globally, so the cost is per-capture work and not serialisation.

**Throughput** follows from the above: roughly 900 pages/hour on picamera2 and
1800 on gphoto2, at two pages per capture. Treat these as ceilings — they
exclude page turning, which dominates in practice.

**Storage, picamera2 only:** at the medium preset, paired JPEGs measured
**560–780 KB each**, so 100 pages is roughly 56–78 MB.

This figure does not transfer to gphoto2. No file sizes were measured on the
DSLR path, and the resolution presets do not apply to it at all — most
`CameraConfig` fields are picamera2-specific and are silently ignored by the
gphoto2 backend (`capture/backends/gphoto2_backend.py`, `capture_image()`), which shoots
at whatever the body is set to. Sizing storage for a DSLR unit from the number
above will under-provision badly. The low and high picamera2 presets are also
unmeasured.

---

## 6. Code Examples

### Complete Workflow: Registration to Gallery

```python
import requests

BASE_URL = "http://localhost:8000"

# 1. Register first user (becomes admin)
print("1. Registering user...")
user_resp = requests.post(
    f"{BASE_URL}/auth/register",
    json={
        "username": "john_doe",
        "email": "john@example.com",
        "password": "secure_password_123"
    }
)
user = user_resp.json()
print(f"   Registered: {user['username']} (role: {user['role']})")

# 2. Login
print("\n2. Logging in...")
login_resp = requests.post(
    f"{BASE_URL}/auth/login",
    json={"username": "john_doe", "password": "secure_password_123"}
)
token = login_resp.json()["access_token"]
headers = {"Authorization": f"Bearer {token}"}

# 3. Get current user role (frontend uses this for dashboard routing)
me_resp = requests.get(f"{BASE_URL}/users/me", headers=headers)
me = me_resp.json()
print(f"   Role: {me['role']}")

# 4. Create project (admin only)
print("\n4. Creating project...")
project_resp = requests.post(
    f"{BASE_URL}/projects/",
    headers=headers,
    json={
        "name": "Book Digitization",
        "description": "Scanning historical books"
    }
)
project = project_resp.json()
print(f"   Project: {project['name']} (ID: {project['id']})")

# 5. List devices
print("\n5. Listing cameras...")
devices_resp = requests.get(f"{BASE_URL}/cameras/devices", headers=headers)
devices = devices_resp.json()
if devices:
    for dev in devices:
        status = "calibrated" if dev['calibrated'] else "needs calibration"
        print(f"   [{dev['index']}] {dev['model']} - {status}")
else:
    print("   No cameras detected (run on Raspberry Pi)")

# 6. Capture image (creates RecordImage automatically)
print("\n6. Capturing image...")
capture_resp = requests.post(
    f"{BASE_URL}/cameras/capture",
    headers=headers,
    json={
        "project_name": "Book Digitization",
        "camera_index": 0,
        "resolution": "medium"
    }
)
capture_result = capture_resp.json()
if capture_result['success']:
    print(f"   Captured: {capture_result['file_path']}")
else:
    print(f"   Capture failed: {capture_result.get('error')}")

    # Fallback: create record manually
    rec_resp = requests.post(
        f"{BASE_URL}/records/",
        headers=headers,
        json={
            "title": "Ancient Manuscript",
            "capture_mode": "single",
            "author": "Unknown Scribe",
            "date": "1500-01-01",
            "project_id": project['id']
        }
    )
    rec = rec_resp.json()
    print(f"   Created record: {rec['title']} (ID: {rec['id']})")

# 7. List records (gallery)
print("\n7. Fetching gallery...")
list_resp = requests.get(
    f"{BASE_URL}/records/",
    headers=headers,
    params={"limit": 50}
)
records = list_resp.json()
print(f"   Total records: {len(records)}")
for r in records[:3]:
    print(f"   - {r['title']}: {r['capture_mode']}")

print("\nWorkflow complete!")
```

---

### Configuration Page Example

```python
def configuration_page_flow(token):
    """Flow for the configuration/setup page: cameras and calibration."""
    headers = {"Authorization": f"Bearer {token}"}

    # Step 1: Get available cameras
    devices = requests.get(f"{BASE_URL}/cameras/devices", headers=headers).json()
    print(f"Devices: {len(devices)} found")

    # Step 2: Run calibration if needed
    if devices and not devices[0]['calibrated']:
        cal_resp = requests.post(
            f"{BASE_URL}/cameras/calibrate",
            headers=headers,
            json={"camera_index": 0, "resolution": "high"}
        )
        result = cal_resp.json()
        if result['success']:
            print(f"Calibrated: lens_position={result['lens_position']}")
```

---

### Live Scan Page Example

```python
def live_scan_workflow(token, project_name):
    """Workflow for the live scan page: capture → auto-save → optional metadata update.

    project_name must already exist: this example sends no collection_id, and
    an unmatched name returns 422. (If a capture does send collection_id,
    _resolve_capture_target resolves the path from the collection and never
    reads project_name — cameras.py:43-56.)
    """
    headers = {"Authorization": f"Bearer {token}"}

    # 1. Get cameras
    devices = requests.get(f"{BASE_URL}/cameras/devices", headers=headers).json()
    if not devices:
        print("No cameras detected")
        return
    selected = devices[0]
    print(f"Selected: [{selected['index']}] {selected['model']}")

    # 2. Capture (automatically creates RecordImage, CameraSettings, ExifData)
    capture_resp = requests.post(
        f"{BASE_URL}/cameras/capture",
        headers=headers,
        json={
            "project_name": project_name,
            "camera_index": selected['index'],
            "resolution": "medium"
        }
    )
    result = capture_resp.json()
    if not result['success']:
        print(f"Capture failed: {result['error']}")
        return
    print(f"Captured: {result['file_path']}")

    # 3. Update the metadata of the record this capture created.
    #    Use record_id from the capture response — do NOT list records and
    #    take the first. An unfiltered GET /records/ orders by id ASCENDING
    #    (see list_records in records.py), so `limit=1` returns the OLDEST
    #    record in the database and patching it overwrites an unrelated page.
    #    With ?collection_id=N the order is sequence-then-id in the same
    #    function, so you get whatever the operator ranked first — also not
    #    your capture.
    rec_id = result.get('record_id')
    if rec_id:
        update_resp = requests.patch(
            f"{BASE_URL}/records/{rec_id}",
            headers=headers,
            json={
                "title": "Page 1 of Ancient Manuscript",
                "author": "Unknown Scribe"
            }
        )
        print(f"Updated: {update_resp.json()['title']}")
```

---

### Gallery/View Page Example

```python
def gallery_view(token):
    """Display all captured records grouped by capture mode."""
    headers = {"Authorization": f"Bearer {token}"}

    records = requests.get(
        f"{BASE_URL}/records/",
        headers=headers,
        params={"limit": 100}
    ).json()

    print(f"Total Records: {len(records)}\n")

    # Group by capture mode ("single" or "dual")
    by_mode = {}
    for rec in records:
        by_mode.setdefault(rec['capture_mode'], []).append(rec)

    for mode, recs in sorted(by_mode.items()):
        print(f"\n{mode.upper()} ({len(recs)} items)")
        print("-" * 60)
        for rec in recs[:5]:
            print(f"  - {rec['title']}")
            print(f"    Author: {rec.get('author', 'N/A')}")
            print(f"    Images: {len(rec.get('images', []))}")
```

---

## 7. Frontend Integration

### Authentication Flow

```
1. GET /auth/setup/status                    (no auth)
   Response: { needs_setup: boolean }
   → true  = no user exists yet; route to first-run setup
     false = route to login
   The frontend calls this on the unauthenticated path, from the welcome
   and setup routes; an existing session in localStorage short-circuits
   straight to the dashboard without it.

2. POST /auth/register
   Request: { username, email, password }
   Response: { id, username, email, role, is_active, created_at }
   Note: first user becomes admin, all others become reviewer.
   Note: PUBLIC ONLY FOR THE FIRST USER. Once one account exists this
         endpoint requires an authenticated admin — 401 without a token,
         403 for a non-admin. Account creation is admin-controlled: an
         admin submits the new user's credentials directly. There is no
         invitation or token flow. Role is ignored if sent; elevate
         afterwards with PATCH /auth/users/{id}/role.

3. POST /auth/login
   Request: { username, password }
   Response: { access_token, token_type }

4. Store token: localStorage.setItem("access_token", access_token)

5. GET /users/me
   Headers: { Authorization: Bearer <token> }
   Response: { id, username, role, ... }
   → Use role to determine which UI sections to show:
     - admin:    full dashboard + user management panel
     - operator: full dashboard, no user management
     - reviewer: cannot create or edit records, projects or collections,
       BUT is not passive — reviewers drive the QA workflow, annotating
       records and moving them in_review -> approved / rejected
       (approval: STATUS_TRANSITIONS, schemas/record.py:55;
       rejection is its own route, POST /records/{id}/reject, records.py:970), and may trigger a BagIt export
       (export_collection_bagit, collections.py:633). They cannot send a
       record back to captured: rejected -> captured is operator/admin, and
       there is no approved -> captured for anyone -- an approved record goes
       back to in_review first (reviewer/admin).
       Note each router defines its own allow_read_only — the one in
       records.py governs records; the one in auth.py governs only auth
       endpoints.

6. Use token in all protected requests:
   headers: { "Authorization": `Bearer ${token}` }

7. Before expiry (8 hours by default — ACCESS_TOKEN_EXPIRE_SECONDS), refresh:
   POST /auth/refresh
   Headers: { Authorization: Bearer <old_token> }
   Response: { access_token, token_type }

8. On logout, clear BOTH keys:
   localStorage.removeItem("access_token")
   localStorage.removeItem("auth_user")
   The client stores the user alongside the token (stores/auth.ts:82),
   and the two keys hydrate independently, so half-cleared state is
   reachable. The hazard is a leftover TOKEN, not a leftover user:
   isAuthenticated() tests token !== null alone (stores/auth.ts:123,
   159), so a session with auth_user removed still reads as
   authenticated, with userRole silently null. (The root route is
   stricter: a token with no user is cleared and the client is sent to
   /welcome — routes/+page.svelte:28.)
```

---

### Configuration Page (`/dashboard/config`)

**Goals:** Camera device testing and calibration.

**API Calls:**
1. `POST /auth/login` — User login
2. `GET /users/me` — Get role for UI gating
3. `GET /cameras/devices` — Show available cameras with calibration status
4. `POST /cameras/calibrate` — Calibrate autofocus (operator+ required)
5. `POST /cameras/calibrate/white-balance` — Calibrate white balance (operator+ required)

**Frontend Flow:**
```
1. POST /auth/login → receive token
2. GET /users/me → get role
3. Show camera list: GET /cameras/devices
4. Display cameras with calibration status indicators
5. If operator/admin: show calibration controls
   - POST /cameras/calibrate → get lens position
   - POST /cameras/calibrate/white-balance → get AWB gains
```

---

### Live Scan Page (`/live-preview`)

**Goals:** Capture images, automatic database record creation.

**API Calls:**
1. `GET /cameras/devices` — List cameras on load (reviewer+)
2. `POST /cameras/capture` — Capture + automatic RecordImage creation (operator+)
3. `GET /records/` — List recent captures (reviewer+)
4. `PATCH /records/{id}` — Update metadata after capture (operator+)

**Frontend Flow:**
```
1. GET /cameras/devices → show camera selector
2. User selects resolution (low/medium/high)
3. User clicks "Capture"
4. POST /cameras/capture with project_name, camera_index, resolution
   → Backend creates RecordImage + CameraSettings + ExifData
   → Returns file_path
5. Show success, file path, and option to update metadata
6. Optional: PATCH /records/{id} with title, author, etc.
```

---

### Gallery Page (`/dashboard/projects/{projectId}/collections/{collectionId}`)

**Goals:** Display all captured records, view details.

**API Calls:**
1. `GET /records/` — List all records (reviewer+)
2. `GET /records/{id}` — Get full record with images (reviewer+)
3. `GET /records/images/{img_id}/thumbnail?token=<token>` — Display thumbnails (reviewer+)
4. `DELETE /records/{id}` — Delete record (operator+)

**Frontend Flow:**
```
1. GET /records/?limit=50 → display grid
2. Use /records/images/{img_id}/thumbnail?token=<token> for <img src>
   (the session token is a custom HMAC-SHA256 string, not a JWT — see
    core/security.py:68-90; using JWT libraries here is a documented no)
3. Click record → GET /records/{id} → detail view
4. If operator/admin: show edit/delete controls
```

---

### Projects & Collections Page

**API Calls:**
1. `GET /projects/` — List projects (reviewer+)
2. `POST /projects/` — Create project (admin only)
3. `POST /projects/{id}/initialize` — Init filesystem (operator+)
4. `GET /collections/?project_id={id}` — List top-level collections (reviewer+)
5. `GET /collections/{id}/hierarchy` — Full collection tree (reviewer+)
6. `POST /collections/` — Create collection (operator+)
7. `GET /projects/{id}/records` — List project records (reviewer+)

---

### User Management Page (Admin only)

**API Calls:**
1. `GET /auth/users` — List all users
2. `PATCH /auth/users/{id}/role` — Promote/demote user
3. `PATCH /auth/users/{id}/active` — Activate/deactivate user
4. `DELETE /auth/users/{id}` — Delete user

---

## 8. Configuration

### Environment Variables (`.env`)

```env
# Database — the backend builds its connection URL from these
DATABASE_USER=user
DATABASE_PASSWORD=password
DATABASE_HOST=db
DATABASE_PORT=5432
DATABASE_NAME=digitization_toolkit

# Optional, Alembic only: if set, migrations use this verbatim instead of
# building the URL from the DATABASE_* values above (alembic/env.py).
# The application itself never reads it. Note the +psycopg driver — a bare
# postgresql:// URL selects psycopg2, which is not installed.
DATABASE_URL=postgresql+psycopg://user:password@localhost:5432/digitization_toolkit

# Security
SECRET_KEY=change-this-to-a-random-string
ACCESS_TOKEN_EXPIRE_SECONDS=28800
```

The repository root `.env.example` is the authoritative list of supported variables; the block above shows only those relevant to the API. Keep the two in step — a variable the backend does not read belongs in neither.

The server host and port are not configurable by environment: the pixi `start` and `dev` tasks hardcode `--host 0.0.0.0 --port 8000`, so the native backend listens on every interface.

What keeps port 8000 off the venue LAN is the host firewall installed by `scripts/setup-firewall.sh`: ufw defaults to deny-inbound and allows 8000/tcp only from the appliance's own compose network (`172.30.0.0/24`), so Nginx can reach the backend and nothing else on the LAN can. Nginx itself is a reverse proxy, not a filter — it restricts nothing on its own. Container ports are handled separately, because Docker's iptables chains sit ahead of ufw's — but only some are loopback-bound. `docker-compose.yml` binds the database to `127.0.0.1:5432` and the production frontend to `127.0.0.1:3000`, while the backend service publishes `8000:8000` and the dev overlay publishes `5173:5173`, both on all interfaces. On a development machine on an untrusted network, those two are exposed.

Changing the address the backend actually binds to, as opposed to filtering access to it, means editing the uvicorn invocation in `backend/pixi.toml`.

---

### CORS Configuration

Allowed origins come from the `CORS_ORIGINS` environment variable, bound in `app/core/config.py` and applied at `app/main.py:62`. Set it in `.env` as a JSON array; it defaults to `http://localhost:5173` (Vite dev server) and `http://localhost:3000` (production Node server).

```env
CORS_ORIGINS=["http://digitool.local","http://localhost:5173","http://localhost:3000"]
```

Do **not** edit `allow_origins` in `app/main.py` — it reads `settings.CORS_ORIGINS`, so a source edit is overridden by configuration.

In the production stack the browser reaches both the frontend and `/api/` through the Nginx reverse proxy on port 80, so it is a single origin and CORS does not come into play in normal use.

---

### Token Expiration

Default: 8 hours (28800 seconds), per `ACCESS_TOKEN_EXPIRE_SECONDS` in `app/core/config.py`. Change via `ACCESS_TOKEN_EXPIRE_SECONDS` in `.env`.

Deactivation does not wait for this: `get_current_user` checks `is_active` on every request (`app/api/auth.py:222`), so a deactivated user is refused on the next call to any route that depends on it. `POST /auth/reset-password` does not (`auth.py:195`): it verifies the token and the old password and changes the password without checking `is_active`. What the expiry bounds is how long a token that has left its owner keeps working, so shorten it on units in shared spaces.

---

## Architecture Overview

### Security
- **Password Hashing**: PBKDF2-HMAC-SHA256 with 600,000 iterations (`PBKDF2_ITERATIONS`, `backend/app/core/security.py`). 100,000 is the *legacy* count, kept only to verify hashes stored before the format carried its own iteration count; login re-hashes those at the current count on the next successful sign-in.
- **Tokens**: HMAC-SHA256 signed, time-based expiration
- **Authentication**: HTTPBearer scheme with automatic dependency injection
- **Authorization**: Role-based via `RoleChecker` dependency (`admin`, `operator`, `reviewer`)
- **Bootstrap**: First registered user becomes admin; all others start as reviewer
- **User Status**: Inactive users cannot log in

### Database
- **ORM**: SQLAlchemy 2.0
- **Engine**: PostgreSQL
- **Relationships**: Proper foreign keys with cascading deletes
- **Timestamps**: not uniform. Most models carry `created_at`, but `ProjectMember` uses `added_at` instead (`models/project_member.py:14`). For modification times, `Record` has `modified_at` (`models/record.py`, without a line number: that file is under active edit and the number has moved three times) and `Collection` has `updated_at` (`models/collection.py:27`); no other model tracks one
- **Migrations**: Alembic. Automatic only in the dev container, whose command is `alembic upgrade head && uvicorn …`. Production runs `pixi run start`, a bare uvicorn; the Pi is migrated by `scripts/update.sh`, and `assert_schema_at_head()` fails startup if that has not happened

### Validation
- **Schemas**: Pydantic v2 for all inputs/outputs
- **Type Safety**: Full type hints throughout
- **Email Validation**: A basic format regex, deliberately — `pydantic[email]` is excluded to keep the appliance offline-capable (`schemas/user.py:15-21`)

### Extensibility
- **Custom Attributes**: JSON string for free-form record metadata
- **Camera Integration**: libcamera/picamera2 with hardware detection
- **Camera Registry**: Persistent calibration storage across system reboots
- **Dual Camera Support**: Synchronized captures for book scanning
- **Resolution Profiles**: Three DPI-optimized presets (low/medium/high)

## Support & Resources

- **FastAPI Documentation**: https://fastapi.tiangolo.com/
- **SQLAlchemy Documentation**: https://docs.sqlalchemy.org/
- **Pydantic Documentation**: https://docs.pydantic.dev/
- **Libcamera Documentation**: https://libcamera.org/
- **Picamera2 Documentation**: https://datasheets.raspberrypi.com/camera/picamera2-manual.pdf
- **Interactive API Docs**: http://localhost:8000/docs (when running)

---
