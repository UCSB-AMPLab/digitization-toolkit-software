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

```bash
# 1. Navigate to backend folder
cd backend

# 2. Create/Activate virtual environment
python -m venv .venv
.venv\Scripts\Activate.ps1  # Windows PowerShell
# or: source .venv/bin/activate  # Linux/macOS

# 3. Install dependencies
pip install -r requirements.txt

# 4. Run development server
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### Verify it works:

- **Interactive API Docs**: http://localhost:8000/docs (Swagger UI)
- **Health Check**: http://localhost:8000/health
- **ReDoc**: http://localhost:8000/redoc

### Test everything:

```bash
cd backend

# Run all tests
python -m pytest

# Or run specific test suites:
python -m pytest tests/unit/          # Unit tests
python -m pytest tests/integration/   # Integration tests
python tests/validate_system.py       # System validation
```

Expected output:
```
==================== test session results ====================
platform win32 -- Python 3.x.x
collected X items

tests/unit/test_api.py ......                        [100%]

==================== X passed in X.XXs =====================
```

---

## 2. Key Resources

| Resource | Location | Purpose |
|----------|----------|---------|
| **API Reference** | This document | Complete endpoint documentation with examples |
| **Backend Setup** | [../../../backend/README.md](../../../backend/README.md) | Quick start and environment setup |
| **Configuration Example** | [Code Examples](#complete-workflow-registration-to-gallery) | How to build configuration page |
| **Live Scan Example** | [Code Examples](#live-scan-page-example) | How to build live scan page |
| **Gallery Example** | [Code Examples](#galleryview-page-example) | How to build gallery page |
| **Device Setup** | `device_setup_CM4.qmd`, `device_setup_pi5_imx519.qmd` | Raspberry Pi configuration |

---

## 3. API Reference

The complete reference for every endpoint, request and response schema, and error shape is **generated from the code** and served by the running backend:

| | |
|---|---|
| **Swagger UI** | [`http://localhost:8000/docs`](http://localhost:8000/docs) — interactive; send real requests, including authenticated ones |
| **ReDoc** | [`http://localhost:8000/redoc`](http://localhost:8000/redoc) — readable single-page reference |
| **OpenAPI schema** | [`http://localhost:8000/openapi.json`](http://localhost:8000/openapi.json) — machine-readable, for client generation |

FastAPI derives these from the routers themselves, so they cannot fall out of step with the implementation. This document deliberately does not duplicate them.

It used to. A hand-written endpoint table, data-model list and error-code table lived here and drifted until they covered barely half the API, documented three roles incorrectly, and described an error shape the backend does not return — with nothing able to notice. They were removed rather than repaired.

What remains here is what a schema cannot express: how to get the stack running, how to test it, how storage is laid out, worked examples, and the reasoning behind the architecture.

**Reaching the schema on a deployed appliance.** Use a development stack for API exploration. On a provisioned unit the backend's port 8000 is firewalled to the appliance's own compose network (`scripts/setup-firewall.sh`), so it is not reachable from the venue LAN — and the proxied `/api/docs` path does not render Swagger UI correctly, because the page requests `/openapi.json` at the site root, which Nginx routes to the frontend.

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
     "object_typology": "book",
     "author": "Unknown",
     "material": "parchment",
     "date": "1500-01-01"
   }
   ```
3. Click "Execute": view 201 Created response with record ID

##### Swagger UI Features

- **2xx (Green):** Success
- **4xx (Red):** Client error - check your request or role permissions
- **5xx (Red):** Server error - backend issue

---

### 4.2 Option 2: Complete Testing Workflow in Swagger UI

Recommended order to test the entire API:

1. **Health Check** → `GET /health` (no auth needed)
2. **Register User** → `POST /auth/register` (first user becomes admin)
3. **Login** → `POST /auth/login` (save token)
4. **Authorize** → Click Authorize button, paste token
5. **Get Current User** → `GET /users/me` (check your role)
6. **Create Project** → `POST /projects/`
7. **Create Record** → `POST /records/`
8. **Upload Image** → `POST /records/{id}/images`
9. **Add to Project** → `POST /projects/{id}/add_record/{rec_id}`
10. **Get Record** → `GET /records/{id}`
11. **Delete Record** → `DELETE /records/{id}`

---

### 4.3 Option 3: Run Test Suite

```bash
cd backend

# Run all tests with pytest
python -m pytest

# Run specific test categories
python -m pytest tests/unit/          # Unit tests (API, models, schemas)
python -m pytest tests/integration/   # Integration tests (capture workflow)
python -m pytest tests/test_cameras.py -m camera  # Camera tests (requires hardware)

# Run with verbose output
python -m pytest -v

# Run tests and show coverage
python -m pytest --cov=app --cov-report=html
```

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

Images are stored on the Raspberry Pi's microSD card at `/var/lib/dtk/projects/`:

```
/var/lib/dtk/projects/
├── project_1/
│   ├── images/
│   │   ├── main/           ← Captured images here
│   │   │   ├── 20260109_143652_123_c0.jpg
│   │   │   ├── 20260109_143652_123_c1.jpg
│   │   │   └── ...
│   │   ├── temp/           ← Working files
│   │   └── trash/          ← Deleted images (soft delete)
│   └── packages/           ← Export packages (IIIF, ZIP)
├── project_2/
│   └── ...
```

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
Record (title, object_typology, project_id, collection_id)
    └─> RecordImage[] (file_path, filename, format, role)
            ├─> CameraSettings (camera_model, white_balance, lens_position)
            └─> ExifData (raw_exif, datetime_original, GPS)

Project (name, description)
    └─> Record[]
    └─> Collection[]
            └─> Collection[] (nested sub-collections)
```

### Performance Metrics

**Capture Speed:**
- Single capture: ~3–4 seconds (camera init + capture + save)
- Dual capture: ~5–7 seconds (parallel capture with 20ms stagger)
- Database insert: ~100–150ms per record

**Throughput (Medium Resolution):**
- Pages per hour: ~880 pph (single camera)
- Book (300 pages): ~20 minutes
- Dual camera: Effectively 1760 pph

**Storage Requirements:**
- Low resolution (2312×1736): ~2–3 MB per image
- Medium resolution (3840×2160): ~4–5 MB per image
- High resolution (4624×3472): ~8–10 MB per image
- 100-page book at medium: ~400–500 MB

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

# 4. Create project (operator+ required)
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
            "object_typology": "book",
            "author": "Unknown Scribe",
            "material": "parchment",
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
    print(f"   - {r['title']}: {r.get('object_typology', 'unknown')}")

print("\nWorkflow complete!")
```

---

### Configuration Page Example

```python
def configuration_page_flow(token):
    """Flow for the configuration/setup page: cameras, calibration, typology selector."""
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

    # Step 3: Show available typologies
    typologies = ["book", "dossier", "document", "map", "planimetry", "other"]
    print(f"Available document types: {typologies}")

    # Step 4: Dynamic fields per typology
    typology_fields = {
        "book": ["title", "author", "material", "date", "isbn", "publisher", "pages"],
        "dossier": ["title", "author", "date", "contents_summary"],
        "document": ["title", "author", "date", "signature"],
        "map": ["title", "region", "scale", "coverage"],
        "planimetry": ["title", "scale", "project_name"],
        "other": ["title", "description"]
    }
    selected = "book"
    print(f"Fields for '{selected}': {typology_fields[selected]}")
```

---

### Live Scan Page Example

```python
def live_scan_workflow(token, project_name="BookScanning2024"):
    """Workflow for the live scan page: capture → auto-save → optional metadata update."""
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

    # 3. Find the latest record and update its metadata
    records = requests.get(
        f"{BASE_URL}/records/",
        headers=headers,
        params={"limit": 1}
    ).json()
    if records:
        rec_id = records[0]['id']
        update_resp = requests.patch(
            f"{BASE_URL}/records/{rec_id}",
            headers=headers,
            json={
                "title": "Page 1 of Ancient Manuscript",
                "object_typology": "book",
                "author": "Unknown Scribe"
            }
        )
        print(f"Updated: {update_resp.json()['title']}")
```

---

### Gallery/View Page Example

```python
def gallery_view(token):
    """Display all captured records grouped by typology."""
    headers = {"Authorization": f"Bearer {token}"}

    records = requests.get(
        f"{BASE_URL}/records/",
        headers=headers,
        params={"limit": 100}
    ).json()

    print(f"Total Records: {len(records)}\n")

    # Group by typology
    by_type = {}
    for rec in records:
        typology = rec.get('object_typology', 'unknown')
        by_type.setdefault(typology, []).append(rec)

    for typology, recs in sorted(by_type.items()):
        print(f"\n{typology.upper()} ({len(recs)} items)")
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
1. POST /auth/register
   Request: { username, email, password }
   Response: { id, username, email, role, is_active, created_at }
   Note: first user becomes admin, all others become reviewer

2. POST /auth/login
   Request: { username, password }
   Response: { access_token, token_type }

3. Store token: localStorage.setItem("token", access_token)

4. GET /users/me
   Headers: { Authorization: Bearer <token> }
   Response: { id, username, role, ... }
   → Use role to determine which UI sections to show:
     - admin:    full dashboard + user management panel
     - operator: full dashboard, no user management
     - reviewer: read-only views only

5. Use token in all protected requests:
   headers: { "Authorization": `Bearer ${token}` }

6. Before expiry (~1 hour), refresh:
   POST /auth/refresh
   Headers: { Authorization: Bearer <old_token> }
   Response: { access_token, token_type }

7. On logout:
   localStorage.removeItem("token")
```

---

### Configuration Page (`pages/configurations`)

**Goals:** Camera device testing and calibration, document typology selection.

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
6. Show typology selector: book, dossier, document, map, planimetry, other
7. Display dynamic input fields based on typology
```

---

### Live Scan Page (`pages/scan`)

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
6. Optional: PATCH /records/{id} with title, typology, author, etc.
```

---

### Gallery Page (`pages/gallery`)

**Goals:** Display all captured records, filter by typology, view details.

**API Calls:**
1. `GET /records/` — List all records (reviewer+)
2. `GET /records/{id}` — Get full record with images (reviewer+)
3. `GET /records/images/{img_id}/thumbnail?token=<jwt>` — Display thumbnails (reviewer+)
4. `DELETE /records/{id}` — Delete record (operator+)

**Frontend Flow:**
```
1. GET /records/?limit=50 → display grid
2. Group by typology
3. Use /records/images/{img_id}/thumbnail?token=<jwt> for <img src>
4. Click record → GET /records/{id} → detail view
5. If operator/admin: show edit/delete controls
```

---

### Projects & Collections Page

**API Calls:**
1. `GET /projects/` — List projects (reviewer+)
2. `POST /projects/` — Create project (operator+)
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
4. `DELETE /auth/{id}` — Delete user

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

What keeps port 8000 off the venue LAN is the host firewall installed by `scripts/setup-firewall.sh`: ufw defaults to deny-inbound and allows 8000/tcp only from the appliance's own compose network (`172.30.0.0/24`), so Nginx can reach the backend and nothing else on the LAN can. Nginx itself is a reverse proxy, not a filter — it restricts nothing on its own. Container ports are handled separately, by loopback binds in `docker-compose.yml`, because Docker's iptables chains sit ahead of ufw's.

Changing the address the backend actually binds to, as opposed to filtering access to it, means editing the uvicorn invocation in `backend/pixi.toml`.

---

### CORS Configuration

Allowed origins come from the `CORS_ORIGINS` environment variable, bound in `app/core/config.py` and applied at `app/main.py:33`. Set it in `.env` as a JSON array; it defaults to `http://localhost:5173` (Vite dev server) and `http://localhost:3000` (production Node server).

```env
CORS_ORIGINS=["http://digitool.local","http://localhost:5173","http://localhost:3000"]
```

Do **not** edit `allow_origins` in `app/main.py` — it reads `settings.CORS_ORIGINS`, so a source edit is overridden by configuration.

In the production stack the browser reaches both the frontend and `/api/` through the Nginx reverse proxy on port 80, so it is a single origin and CORS does not come into play in normal use.

---

### Token Expiration

Default: 8 hours (28800 seconds), per `ACCESS_TOKEN_EXPIRE_SECONDS` in `app/core/config.py`. Change via `ACCESS_TOKEN_EXPIRE_SECONDS` in `.env`.

This is the bound on how long a deactivated user keeps a working session, so shorten it on units in shared spaces.

---

## Architecture Overview

### Security
- **Password Hashing**: PBKDF2 with 100,000 iterations
- **Tokens**: HMAC-SHA256 signed, time-based expiration
- **Authentication**: HTTPBearer scheme with automatic dependency injection
- **Authorization**: Role-based via `RoleChecker` dependency (`admin`, `operator`, `reviewer`)
- **Bootstrap**: First registered user becomes admin; all others start as reviewer
- **User Status**: Inactive users cannot log in

### Database
- **ORM**: SQLAlchemy 2.0
- **Engine**: PostgreSQL
- **Relationships**: Proper foreign keys with cascading deletes
- **Timestamps**: Automatic `created_at`/`modified_at` on all resources
- **Migrations**: Alembic (`alembic upgrade head` runs automatically on container startup)

### Validation
- **Schemas**: Pydantic v2 for all inputs/outputs
- **Type Safety**: Full type hints throughout
- **Email Validation**: Verified email format for user registration

### Extensibility
- **Typology System**: 6 built-in document types (book, dossier, document, map, planimetry, other)
- **Custom Attributes**: JSON field for typology-specific metadata
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
