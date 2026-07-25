# Digitization Toolkit - API Reference and Implementation Guide

Documentation of the backend API endpoints, data models, implementation details, and code examples for frontend integration.

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Key Resources](#2-key-resources)
3. [API Endpoints Overview](#3-api-endpoints-overview)
4. [Testing the API](#4-testing-the-api)
   - [Option 1: Interactive Docs on Swagger UI (Recommended)](#41-option-1-interactive-docs-on-swagger-ui-recommended)
   - [Option 2: Complete Testing Workflow in Swagger UI](#42-option-2-complete-testing-workflow-in-swagger-ui)
   - [Option 3: Run Test Suite](#43-option-3-run-test-suite)
5. [Authentication & User Management](#5-authentication--user-management)
6. [Records](#6-records)
7. [Projects](#7-projects)
8. [Collections](#8-collections)
9. [Cameras](#9-cameras)
10. [System](#10-system)
11. [Health Check](#11-health-check)
12. [Data Models](#12-data-models)
13. [Error Handling](#13-error-handling)
14. [Code Examples](#14-code-examples)
15. [Frontend Integration](#15-frontend-integration)
16. [Configuration](#16-configuration)

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

## 3. API Endpoints Overview

The Digitization Toolkit API consists of **49 endpoints** organized into **7 routers**.
All endpoints run on: [`http://localhost:8000`](http://localhost:8000).

### **Auth & Users Routers** (`/auth`, `/users`)

User authentication, session management, and user administration.

- Registration, login, token refresh, password change
- `GET /users/me` for the current user's profile and role
- Admin-only endpoints to list users, change roles, and deactivate accounts

### **Records Router** (`/records`)

Full CRUD for archival records and their captured images.

A **Record** represents a physical object being digitized (book, map, document, etc.). Each Record can have multiple **RecordImages** — individual scans or photographs.

Supported typologies:
- `book`, `dossier`, `document`, `map`, `planimetry`, `other`

### **Projects Router** (`/projects`)

Project-based organization for grouping records.

- Create, update, delete projects
- Add/remove records from projects
- Initialize project filesystem structure on the device

### **Collections Router** (`/collections`)

Nested collection hierarchy within projects.

- Create top-level collections inside a project
- Create sub-collections nested inside other collections
- Full hierarchy traversal

### **Cameras Router** (`/cameras`)

Camera device management, capture control, and calibration.

- Device enumeration with hardware detection
- Single and dual camera capture with automatic database record creation
- Focus and white balance calibration
- Camera settings management per record image

### **System Router** (`/system`)

Hardware monitoring endpoints (temperature, etc.).

### **Health Check** (`/health`)

Simple system status endpoint for monitoring and validation.

---

Endpoints are grouped by functionality and implemented using FastAPI routers.
Below is a **complete endpoint reference overview**.

> **Legend:**
> - `public` — no authentication required
> - `reviewer+` — any authenticated user (reviewer, operator, or admin)
> - `operator+` — operator or admin only
> - `admin` — admin only

| Method | Endpoint | Role | Purpose |
|--------|----------|------|---------|
| POST | `/auth/register` | public | Register new user |
| POST | `/auth/login` | public | Login, get token |
| POST | `/auth/refresh` | reviewer+ | Refresh token |
| POST | `/auth/password-reset` | reviewer+ | Change own password |
| GET | `/users/me` | reviewer+ | Get current user's profile and role |
| GET | `/auth/users` | admin | List all users |
| GET | `/auth/users/{id}` | admin | Get user by ID |
| PATCH | `/auth/users/{id}/role` | admin | Change user's role |
| PATCH | `/auth/users/{id}/active` | admin | Activate/deactivate user |
| DELETE | `/auth/{id}` | admin | Delete user |
| POST | `/records/` | operator+ | Create record |
| GET | `/records/` | reviewer+ | List records |
| GET | `/records/{id}` | reviewer+ | Get record with images |
| PATCH | `/records/{id}` | operator+ | Update record metadata |
| DELETE | `/records/{id}` | operator+ | Delete record |
| POST | `/records/{id}/images` | operator+ | Upload image to record |
| GET | `/records/{id}/images` | reviewer+ | List images of a record |
| GET | `/records/images/{img_id}` | reviewer+ | Get image metadata |
| PATCH | `/records/images/{img_id}` | operator+ | Update image metadata |
| DELETE | `/records/images/{img_id}` | operator+ | Delete image |
| GET | `/records/images/{img_id}/file` | reviewer+ | Download image file |
| GET | `/records/images/{img_id}/thumbnail` | reviewer+ | Get image thumbnail |
| POST | `/projects/` | operator+ | Create project |
| GET | `/projects/` | reviewer+ | List projects |
| GET | `/projects/{id}` | reviewer+ | Get project |
| PUT | `/projects/{id}` | operator+ | Update project |
| DELETE | `/projects/{id}` | operator+ | Delete project |
| POST | `/projects/{id}/initialize` | operator+ | Initialize project filesystem |
| POST | `/projects/{id}/add_record/{rec_id}` | operator+ | Add record to project |
| POST | `/projects/{id}/remove_record/{rec_id}` | operator+ | Remove record from project |
| GET | `/projects/{id}/records` | reviewer+ | List project's records |
| POST | `/collections/` | operator+ | Create collection |
| GET | `/collections/` | reviewer+ | List collections |
| GET | `/collections/{id}` | reviewer+ | Get collection |
| GET | `/collections/{id}/hierarchy` | reviewer+ | Get collection with nested children |
| PATCH | `/collections/{id}` | operator+ | Update collection |
| DELETE | `/collections/{id}` | operator+ | Delete collection |
| GET | `/cameras/devices` | reviewer+ | List detected camera devices |
| POST | `/cameras/capture` | operator+ | Single camera capture |
| POST | `/cameras/capture/dual` | operator+ | Dual camera capture |
| POST | `/cameras/calibrate` | operator+ | Calibrate autofocus |
| POST | `/cameras/calibrate/white-balance` | operator+ | Calibrate white balance |
| POST | `/cameras/` | operator+ | Create camera settings |
| GET | `/cameras/` | reviewer+ | List camera settings |
| GET | `/cameras/{id}` | reviewer+ | Get camera settings |
| PUT | `/cameras/settings/{id}` | operator+ | Update camera settings |
| DELETE | `/cameras/settings/{id}` | operator+ | Delete camera settings |
| GET | `/system/temperature` | reviewer+ | Get device CPU temperature |
| GET | `/health` | public | Health check |

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

## 5. Authentication & User Management

### Role System

The API enforces three roles with graduated permissions:

| Role | Permissions |
|------|-------------|
| `admin` | Full access including user management and system configuration |
| `operator` | Full access to records, projects, collections, and cameras — cannot manage users |
| `reviewer` | Read-only access to records, projects, collections, and camera devices |

**Bootstrap behavior**: The first user to register becomes `admin`. All subsequent registrations receive the `reviewer` role. Use `PATCH /auth/users/{id}/role` to promote users.

---

### POST `/auth/register`

Register a new user. The first user becomes `admin`; all subsequent users become `reviewer`.

**Request**
```json
{
  "username": "john_doe",
  "email": "john@example.com",
  "password": "secure_password_123"
}
```

**Response** (201 Created)
```json
{
  "id": 1,
  "username": "john_doe",
  "email": "john@example.com",
  "role": "admin",
  "is_active": true,
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `409 Conflict` — Username or email already exists
- `400 Bad Request` — Invalid email format or missing fields

**Python Example**
```python
import requests

response = requests.post(
    "http://localhost:8000/auth/register",
    json={
        "username": "john_doe",
        "email": "john@example.com",
        "password": "secure_password_123"
    }
)
user = response.json()
print(f"Registered: {user['username']} (role: {user['role']})")
```

---

### POST `/auth/login`

Login and get access token.

**Request**
```json
{
  "username": "john_doe",
  "password": "secure_password_123"
}
```

**Response** (200 OK)
```json
{
  "access_token": "eyJzdWIiOiIxIiwiZXhwIjoxNzM0NDUyNjAwfQ.sig...",
  "token_type": "bearer"
}
```

**Errors**
- `401 Unauthorized` — Invalid credentials
- `403 Forbidden` — User account inactive

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/auth/login",
    json={"username": "john_doe", "password": "secure_password_123"}
)
token = response.json()["access_token"]
```

---

### GET `/users/me`

Get the current authenticated user's profile, including their role. Used by the frontend immediately after login to determine which UI sections to show.

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "id": 1,
  "username": "john_doe",
  "email": "john@example.com",
  "role": "admin",
  "is_active": true,
  "created_at": "2024-12-17T10:30:00"
}
```

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/users/me",
    headers={"Authorization": f"Bearer {token}"}
)
me = response.json()
print(f"Role: {me['role']}")
```

---

### POST `/auth/refresh`

Refresh an existing access token before expiry.

**Headers**
```
Authorization: Bearer <current_token>
```

**Response** (200 OK)
```json
{
  "access_token": "new_token_here...",
  "token_type": "bearer"
}
```

---

### POST `/auth/password-reset`

Change own password. Requires the current password.

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "old_password": "secure_password_123",
  "new_password": "new_secure_password_456"
}
```

**Response** (200 OK)
```json
{
  "detail": "password updated successfully"
}
```

---

### GET `/auth/users` — Admin only

List all registered users.

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

**Response** (200 OK) — array of `UserRead`

---

### GET `/auth/users/{user_id}` — Admin only

Get a user by ID.

**Response** (200 OK) — `UserRead`

---

### PATCH `/auth/users/{user_id}/role` — Admin only

Change a user's role. Admins cannot change their own role.

**Request**
```json
{
  "role": "operator"
}
```

Valid roles: `"admin"`, `"operator"`, `"reviewer"`

**Response** (200 OK) — updated `UserRead`

**Errors**
- `400 Bad Request` — Trying to change own role
- `404 Not Found` — User ID doesn't exist

---

### PATCH `/auth/users/{user_id}/active` — Admin only

Activate or deactivate a user account. Admins cannot deactivate their own account.

**Query Parameters**
- `is_active` (bool, required)

**Response** (200 OK) — updated `UserRead`

---

### DELETE `/auth/{user_id}` — Admin only

Permanently delete a user account.

**Response** (200 OK)
```json
{
  "detail": "user deleted successfully"
}
```

---

## 6. Records

A **Record** is a conceptual archival object (a book, map, document, etc.) that groups one or more **RecordImages** — the individual captures or scans. Records hold the descriptive metadata; RecordImages hold the file paths, camera settings, and EXIF data.

---

### POST `/records/` — Operator+

Create a new archival record.

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "title": "Ancient Manuscript",
  "description": "Historical document from 1500s",
  "object_typology": "book",
  "author": "Unknown Scribe",
  "material": "parchment",
  "date": "1500-01-01",
  "project_id": 1,
  "collection_id": null,
  "custom_attributes": "{\"isbn\": \"N/A\", \"condition\": \"fair\", \"pages\": 150}"
}
```

**Response** (200 OK)
```json
{
  "id": 1,
  "title": "Ancient Manuscript",
  "object_typology": "book",
  "author": "Unknown Scribe",
  "material": "parchment",
  "date": "1500-01-01",
  "project_id": 1,
  "collection_id": null,
  "created_by": "john_doe",
  "created_at": "2024-12-17T10:30:00",
  "modified_at": "2024-12-17T10:30:00",
  "images": []
}
```

**Errors**
- `401 Unauthorized` — No or invalid token
- `403 Forbidden` — Role insufficient (reviewer cannot create)

**Python Example**
```python
rec = requests.post(
    "http://localhost:8000/records/",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "title": "Ancient Book",
        "object_typology": "book",
        "author": "Unknown",
        "material": "parchment",
        "date": "1500-01-01"
    }
)
rec_data = rec.json()
print(f"Created record: {rec_data['id']}")
```

---

### GET `/records/` — Reviewer+

List all records (paginated).

**Headers**
```
Authorization: Bearer <token>
```

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

**Response** (200 OK) — array of `RecordRead`

---

### GET `/records/{id}` — Reviewer+

Get a specific record including all its images, camera settings, and EXIF data.

**Response** (200 OK)
```json
{
  "id": 1,
  "title": "Ancient Manuscript",
  "object_typology": "book",
  "author": "Unknown Scribe",
  "project_id": 1,
  "created_at": "2024-12-17T10:30:00",
  "images": [
    {
      "id": 1,
      "filename": "20260109_143652_123_c0.jpg",
      "file_path": "/var/lib/dtk/projects/my_project/images/main/20260109_143652_123_c0.jpg",
      "format": "jpeg",
      "resolution_width": 3840,
      "resolution_height": 2160,
      "role": "left",
      "camera_settings": {
        "id": 1,
        "camera_model": "Arducam 16MP IMX519",
        "iso": 100,
        "aperture": 2.9
      },
      "exif_data": {
        "id": 1,
        "datetime_original": "2026-01-09T14:36:52"
      }
    }
  ]
}
```

**Errors**
- `404 Not Found` — Record ID doesn't exist

---

### PATCH `/records/{id}` — Operator+

Partially update a record's metadata (only provided fields are changed).

**Request** (all fields optional)
```json
{
  "title": "Updated Title",
  "material": "parchment with leather binding"
}
```

**Response** (200 OK) — updated `RecordRead`

---

### DELETE `/records/{id}` — Operator+

Delete a record and all its images.

**Response** (200 OK)
```json
{
  "detail": "record deleted"
}
```

---

### POST `/records/{id}/images` — Operator+

Upload an image file to a record. Accepts multipart form upload and creates a `RecordImage` with optional embedded camera settings and EXIF data.

**Headers**
```
Authorization: Bearer <token>
Content-Type: multipart/form-data
```

**Form Fields**
- `file` (file, required) — The image file
- `metadata` (JSON string, optional) — `RecordImageCreate` schema

**Response** (200 OK) — `RecordImageRead`

---

### GET `/records/{id}/images` — Reviewer+

List all images belonging to a record.

**Response** (200 OK) — array of `RecordImageRead`

---

### GET `/records/images/{img_id}` — Reviewer+

Get metadata for a specific image.

**Response** (200 OK) — `RecordImageRead`

---

### PATCH `/records/images/{img_id}` — Operator+

Update image metadata (sequence, role, thumbnail path).

**Request**
```json
{
  "sequence": 2,
  "role": "right"
}
```

---

### DELETE `/records/images/{img_id}` — Operator+

Delete an image and its associated file.

---

### GET `/records/images/{img_id}/file` — Reviewer+

Download the original image file. Supports `?token=<jwt>` query parameter for `<img src>` use in browsers.

**Response** — File download (JPEG, TIFF, etc.)

---

### GET `/records/images/{img_id}/thumbnail` — Reviewer+

Get a generated thumbnail of the image. Supports `?token=<jwt>` query parameter.

**Response** — JPEG thumbnail

---

## 7. Projects

All project endpoints require authentication.

### POST `/projects/` — Operator+

Create a new project.

**Request**
```json
{
  "name": "Book Digitization Project",
  "description": "Scanning historical books from the archive"
}
```

**Response** (200 OK)
```json
{
  "id": 1,
  "name": "Book Digitization Project",
  "description": "Scanning historical books from the archive",
  "created_by": "john_doe",
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `409 Conflict` — Project name already exists

---

### GET `/projects/` — Reviewer+

List all projects (paginated).

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

---

### GET `/projects/{id}` — Reviewer+

Get a specific project.

---

### PUT `/projects/{id}` — Operator+

Update a project's name or description.

**Request**
```json
{
  "name": "Updated Project Name",
  "description": "Updated description"
}
```

**Errors**
- `409 Conflict` — New name already in use by another project

---

### DELETE `/projects/{id}` — Operator+

Delete a project. Associated records are unlinked but not deleted.

**Response** (200 OK)
```json
{
  "detail": "project deleted"
}
```

---

### POST `/projects/{id}/initialize` — Operator+

Initialize project filesystem structure on the device.

Creates the directory layout needed before capturing images.

**Request**
```json
{
  "resolution": "high"
}
```

**Response** (200 OK)
```json
{
  "success": true,
  "project_path": "/var/lib/dtk/projects/Book_Digitization_Project"
}
```

**Directory Structure Created:**
```
/var/lib/dtk/projects/{project_name}/
├── images/
│   ├── main/      ← Captured images stored here
│   ├── temp/      ← Temporary/working files
│   └── trash/     ← Deleted images (soft delete)
└── packages/      ← Export packages (IIIF, ZIP, etc.)
```

---

### POST `/projects/{id}/add_record/{rec_id}` — Operator+

Add an existing record to a project.

**Response** (200 OK)
```json
{
  "detail": "record added"
}
```

---

### POST `/projects/{id}/remove_record/{rec_id}` — Operator+

Remove a record from a project (unlinks it; does not delete the record).

**Response** (200 OK)
```json
{
  "detail": "record removed"
}
```

---

### GET `/projects/{id}/records` — Reviewer+

List all records associated with a project.

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

**Response** (200 OK) — array of `RecordRead`

---

## 8. Collections

Collections provide a nested organizational hierarchy within projects. A collection can contain records directly or group sub-collections.

### POST `/collections/` — Operator+

Create a new collection. Specify either `project_id` (top-level) or `parent_collection_id` (nested), not both.

**Request**
```json
{
  "name": "Volume I",
  "description": "First volume of the manuscript series",
  "collection_type": "series",
  "project_id": 1
}
```

**Response** (201 Created) — `CollectionRead`

**Errors**
- `400 Bad Request` — Both or neither parent specified
- `404 Not Found` — Parent project or collection not found

---

### GET `/collections/` — Reviewer+

List collections with optional filters.

**Query Parameters**
- `project_id` (int, optional) — Filter by project (returns top-level collections only)
- `parent_collection_id` (int, optional) — Filter by parent collection (returns sub-collections)
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

**Response** (200 OK) — array of `CollectionRead`

---

### GET `/collections/{id}` — Reviewer+

Get a specific collection.

**Response** (200 OK) — `CollectionRead`

---

### GET `/collections/{id}/hierarchy` — Reviewer+

Get a collection with its full nested child hierarchy and record counts.

**Response** (200 OK) — `CollectionWithChildren`

```json
{
  "id": 1,
  "name": "Volume I",
  "record_count": 42,
  "child_collections": [
    {
      "id": 2,
      "name": "Chapter 1",
      "record_count": 15,
      "child_collections": []
    }
  ]
}
```

---

### PATCH `/collections/{id}` — Operator+

Update a collection's name, description, type, metadata, or move it to a different parent.
Circular hierarchy creation is prevented.

**Request** (all fields optional)
```json
{
  "name": "Updated Name",
  "parent_collection_id": 3
}
```

**Errors**
- `400 Bad Request` — Circular hierarchy detected

---

### DELETE `/collections/{id}` — Operator+

Delete a collection. Child collections are cascade-deleted; records in this collection are orphaned.

---

## 9. Cameras

### GET `/cameras/devices` — Reviewer+

List available camera devices detected via libcamera/picamera2.

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
[
  {
    "hardware_id": "imx519_0x001a",
    "model": "Arducam 16MP IMX519",
    "index": 0,
    "location": "cam0",
    "machine_id": "pi5-001",
    "label": "Left Camera",
    "calibrated": true
  },
  {
    "hardware_id": "imx519_0x002b",
    "model": "Arducam 16MP IMX519",
    "index": 1,
    "location": "cam1",
    "machine_id": "pi5-001",
    "label": "Right Camera",
    "calibrated": false
  }
]
```

Returns empty list on non-Pi systems or when camera libraries are unavailable.

---

### POST `/cameras/capture` — Operator+

Trigger a single image capture on a specified camera.

Captures the image to local storage, extracts metadata, and creates `RecordImage`, `CameraSettings`, and `ExifData` records automatically.

**Request Body**
```json
{
  "project_name": "BookScanning2024",
  "camera_index": 0,
  "resolution": "medium",
  "include_resolution_in_filename": false
}
```

**Parameters:**
- `project_name` (string, required) — Project name (use `/projects/{id}/initialize` first)
- `camera_index` (int, default: 0) — Camera index (0 or 1)
- `resolution` (string, default: "medium"):
  - `"low"`: 2312×1736 (~4MP, 195 DPI)
  - `"medium"`: 3840×2160 (~8MP, 350 DPI) — **Recommended**
  - `"high"`: 4624×3472 (16MP, 420 DPI)
- `include_resolution_in_filename` (bool, default: false)

**Response** (200 OK)
```json
{
  "success": true,
  "file_path": "/var/lib/dtk/projects/BookScanning2024/images/main/20240117_143022_000_c0.jpg",
  "timing": null,
  "error": null
}
```

**Automatic Actions:**
1. Validates camera connection
2. Loads calibration data from registry (if available)
3. Captures image to project directory
4. Extracts EXIF metadata
5. Creates `RecordImage`, `CameraSettings`, and `ExifData` database records

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/capture",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "project_name": "BookScanning2024",
        "camera_index": 0,
        "resolution": "medium"
    }
)
result = response.json()
if result['success']:
    print(f"Captured: {result['file_path']}")
else:
    print(f"Error: {result['error']}")
```

---

### POST `/cameras/capture/dual` — Operator+

Trigger simultaneous capture on both cameras.

**Request Body**
```json
{
  "project_name": "BookScanning2024",
  "resolution": "medium",
  "include_resolution_in_filename": false,
  "stagger_ms": 20
}
```

**Parameters:**
- `stagger_ms` (int, default: 20) — Milliseconds delay between camera triggers

**Response** (200 OK)
```json
{
  "success": true,
  "file_paths": [
    "/var/lib/dtk/projects/BookScanning2024/images/main/20240117_143022_000_c0.jpg",
    "/var/lib/dtk/projects/BookScanning2024/images/main/20240117_143022_020_c1.jpg"
  ],
  "timing": {
    "cam0_capture_ms": 245,
    "cam1_capture_ms": 248,
    "total_ms": 493
  },
  "error": null
}
```

---

### POST `/cameras/calibrate` — Operator+

Run autofocus calibration to find optimal lens position. Calibration data is saved to the camera registry and reused for faster captures.

**Request Body**
```json
{
  "camera_index": 0,
  "resolution": "high"
}
```

**Response** (200 OK)
```json
{
  "success": true,
  "lens_position": 1.85,
  "distance_meters": 0.42,
  "af_time": 2.34,
  "error": null
}
```

---

### POST `/cameras/calibrate/white-balance` — Operator+

Calibrate white balance. Place a neutral gray card in frame for best results.

**Request Body**
```json
{
  "camera_index": 0,
  "resolution": "high",
  "stabilization_frames": 30
}
```

**Response** (200 OK)
```json
{
  "success": true,
  "awb_gains": [1.92, 1.45],
  "colour_temperature": 5200,
  "converged": true,
  "error": null
}
```

---

### POST `/cameras/` — Operator+

Manually create camera settings for a record image.

**Request**
```json
{
  "record_image_id": 1,
  "camera_model": "Arducam 16MP IMX519",
  "iso": 100,
  "aperture": 2.9,
  "shutter_speed": "1/100",
  "white_balance": "daylight",
  "flash_used": false
}
```

**Response** (201 Created) — `CameraSettingsRead`

---

### GET `/cameras/` — Reviewer+

List all camera settings (paginated).

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

---

### GET `/cameras/{id}` — Reviewer+

Get specific camera settings by ID.

---

### PUT `/cameras/settings/{id}` — Operator+

Update camera settings (all fields optional).

**Request**
```json
{
  "iso": 200,
  "white_balance": "custom"
}
```

---

### DELETE `/cameras/settings/{id}` — Operator+

Delete camera settings.

**Response** (200 OK)
```json
{
  "detail": "Camera settings deleted"
}
```

---

## 10. System

### GET `/system/temperature` — Reviewer+

Get Raspberry Pi CPU temperature via `vcgencmd measure_temp`.

Returns `available: false` on non-Pi systems or when `vcgencmd` is not installed.

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "temperature": 47.2,
  "unit": "C",
  "available": true
}
```

**Response when unavailable**
```json
{
  "temperature": null,
  "unit": "C",
  "available": false
}
```

---

## 11. Health Check

### GET `/health`

Health check endpoint (no authentication required).

**Response** (200 OK)
```json
{
  "status": "ok"
}
```

---

## 12. Data Models

### UserCreate (Request)
```json
{
  "username": "string",
  "email": "string (valid email format)",
  "password": "string"
}
```

Note: Role is assigned automatically by the server — not accepted from the request body.

### UserRead (Response)
```json
{
  "id": "integer",
  "username": "string",
  "email": "string",
  "role": "admin | operator | reviewer",
  "is_active": "boolean",
  "created_at": "datetime or null"
}
```

### UserRoleUpdate (Request — admin only)
```json
{
  "role": "admin | operator | reviewer"
}
```

---

### RecordCreate (Request)
```json
{
  "title": "string (required)",
  "description": "string or null",
  "object_typology": "book|dossier|document|map|planimetry|other or null",
  "author": "string or null",
  "material": "string or null",
  "date": "string or null (YYYY-MM-DD)",
  "custom_attributes": "JSON string or null (typology-specific data)",
  "project_id": "integer or null",
  "collection_id": "integer or null",
  "created_by": "string or null (auto-filled from token if omitted)"
}
```

### RecordRead (Response)
```json
{
  "id": "integer",
  "title": "string",
  "description": "string or null",
  "object_typology": "string or null",
  "author": "string or null",
  "material": "string or null",
  "date": "string or null",
  "custom_attributes": "string or null",
  "project_id": "integer or null",
  "collection_id": "integer or null",
  "created_by": "string or null",
  "created_at": "datetime or null",
  "modified_at": "datetime or null",
  "images": "array of RecordImageRead"
}
```

### RecordUpdate (Request — PATCH only)
```json
{
  "title": "string or null",
  "description": "string or null",
  "object_typology": "string or null",
  "author": "string or null",
  "material": "string or null",
  "date": "string or null",
  "custom_attributes": "string or null",
  "project_id": "integer or null",
  "collection_id": "integer or null"
}
```

---

### RecordImageCreate (Request)
```json
{
  "filename": "string (required)",
  "file_path": "string (required)",
  "format": "string (required, e.g. 'jpeg', 'tiff')",
  "file_size": "integer or null (bytes)",
  "resolution_width": "integer or null",
  "resolution_height": "integer or null",
  "capture_id": "string or null (UUID for grouping captures)",
  "pair_id": "string or null (UUID for dual-camera pairs)",
  "sequence": "integer or null",
  "role": "string or null ('left', 'right', 'single', 'overview')",
  "uploaded_by": "string or null",
  "camera_settings": "CameraSettingsCreate or null",
  "exif_data": "ExifDataCreate or null"
}
```

### RecordImageRead (Response)
```json
{
  "id": "integer",
  "record_id": "integer",
  "filename": "string",
  "file_path": "string",
  "thumbnail_path": "string or null",
  "format": "string",
  "file_size": "integer or null",
  "resolution_width": "integer or null",
  "resolution_height": "integer or null",
  "capture_id": "string or null",
  "pair_id": "string or null",
  "sequence": "integer or null",
  "role": "string or null",
  "uploaded_by": "string or null",
  "created_at": "datetime or null",
  "camera_settings": "CameraSettingsRead or null",
  "exif_data": "ExifDataRead or null"
}
```

---

### ProjectCreate (Request)
```json
{
  "name": "string (required)",
  "description": "string or null"
}
```

### ProjectRead (Response)
```json
{
  "id": "integer",
  "name": "string",
  "description": "string or null",
  "created_by": "string or null",
  "created_at": "datetime or null"
}
```

---

### CameraSettingsCreate (Request)
```json
{
  "camera_model": "string or null",
  "camera_manufacturer": "string or null",
  "lens_model": "string or null",
  "iso": "integer or null",
  "aperture": "float or null",
  "shutter_speed": "string or null",
  "focal_length": "float or null",
  "exposure_compensation": "float or null",
  "white_balance": "string or null",
  "flash_used": "boolean or null"
}
```

### CameraSettingsRead (Response)
```json
{
  "id": "integer",
  "record_image_id": "integer",
  "camera_model": "string or null",
  "camera_manufacturer": "string or null",
  "lens_model": "string or null",
  "iso": "integer or null",
  "aperture": "float or null",
  "shutter_speed": "string or null",
  "focal_length": "float or null",
  "exposure_compensation": "float or null",
  "white_balance": "string or null",
  "flash_used": "boolean or null",
  "created_at": "datetime or null"
}
```

---

## 12.1. File Storage Architecture

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

## 13. Error Handling

All errors follow this format:

```json
{
  "detail": "error message"
}
```

### HTTP Status Codes

| Code | Meaning | Example |
|------|---------|---------|
| 200 | OK | Successful GET, PATCH, PUT, DELETE |
| 201 | Created | Successful POST (resource created) |
| 400 | Bad Request | Validation error, missing fields |
| 401 | Unauthorized | Invalid/missing token, wrong credentials |
| 403 | Forbidden | Role insufficient, or account inactive |
| 404 | Not Found | Resource ID doesn't exist |
| 409 | Conflict | Duplicate entry, resource already exists |
| 500 | Internal Server Error | Unexpected server error |

**403 vs 401:**
- `401` — Token is missing, expired, or invalid
- `403` — Token is valid but the user's role does not permit the operation

---

## 14. Code Examples

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

## 15. Frontend Integration

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

## 16. Configuration

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
