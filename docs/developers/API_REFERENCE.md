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
5. [Authentication](#5-authentication)
6. [Documents](#6-documents)
7. [Projects](#7-projects)
8. [Cameras](#8-cameras)
9. [Health Check](#9-health-check)
10. [Data Models](#10-data-models)
11. [Error Handling](#11-error-handling)
12. [Code Examples](#12-code-examples)
13. [Frontend Integration](#13-frontend-integration)
14. [Configuration](#14-configuration)
15. [Next Steps](#15-next-steps)
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
==================== test session starts ====================
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

The Digitization Toolkit API consists of **27 endpoints** organized into **5 routers**.
All endpoints run on: [`http://localhost:8000`](http://localhost:8000).


### **Auth Router** (`/auth`)
User authentication and session management.

- User registration and login
- JWT access token issuance and refresh
- Password change functionality

### **Documents Router** (`/documents`)
Full CRUD for digitized documents with typology support:

- book
- dossier
- document
- map
- planimetry
- other

Supports metadata, EXIF data, and camera settings linkage.

### **Projects Router** (`/projects`)
Project-based organization for grouping documents into collections.

- Create and list projects
- Add/remove documents from projects

### **Cameras Router** (`/cameras`)
Camera device management, capture control, and calibration.

- Device enumeration with hardware detection
- Single and dual camera capture with database integration
- Focus and white balance calibration
- Camera settings management per document
- Camera registry for persistent calibration data

### **Health Check** (`/health`)
Simple system status endpoint used for monitoring and validation.

---

Endpoints are grouped by functionality and implemented using FastAPI routers.
Below is a **complete endpoint reference overview**.


| Method | Endpoint | Auth | Purpose |
|--------|----------|------|---------|
| POST | `/auth/register` | ❌ | Register new user |
| POST | `/auth/login` | ❌ | Login, get token |
| POST | `/auth/refresh` | ✅ | Refresh token |
| POST | `/auth/password-reset` | ✅ | Change password |
| POST | `/documents/` | ✅ | Create document |
| GET | `/documents/` | ✅ | List documents |
| GET | `/documents/{id}` | ❌ | Get document |
| PATCH | `/documents/{id}` | ✅ | Update document |
| PUT | `/documents/{id}` | ✅ | Replace document |
| DELETE | `/documents/{id}` | ✅ | Delete document |
| POST | `/projects/` | ✅ | Create project |
| GET | `/projects/` | ✅ | List projects |
| GET | `/projects/{id}` | ✅ | Get project |
| POST | `/projects/{id}/add_document/{doc_id}` | ✅ | Add doc to project |
| POST | `/projects/{id}/remove_document/{doc_id}` | ✅ | Remove doc from project |
| POST | `/cameras/` | ✅ | Create camera settings |
| GET | `/cameras/` | ✅ | List camera settings |
| GET | `/cameras/{id}` | ✅ | Get camera settings |
| PUT | `/cameras/settings/{id}` | ✅ | Update camera settings |
| DELETE | `/cameras/settings/{id}` | ✅ | Delete camera settings |
| GET | `/cameras/devices` | ❌ | List detected devices |
| POST | `/cameras/capture` | ✅ | Single camera capture |
| POST | `/cameras/capture/dual` | ✅ | Dual camera capture |
| POST | `/cameras/calibrate` | ✅ | Calibrate autofocus |
| POST | `/cameras/calibrate/white-balance` | ✅ | Calibrate white balance |
| GET | `/health` | ❌ | Health check |

> **Legend of the API endpoints matrix:** 
> 
>✅ = requires authentication
>
>❌ = public access

---

## 4. Testing the API

### 4.1 Option 1: Interactive Docs on Swagger UI (Recommended)

The fastest way to test endpoints is using the interactive documentation.
The interface allows to see request/response examples and test parameters directly.

#### **Getting Started with Swagger UI**

1. **Open in Browser**
   ```
   http://localhost:8000/docs
   ```

2. **You'll see:**
   - List of all API endpoints grouped by category (Auth, Documents, Projects, Cameras) with collapsible sections
   - Green `POST`, `GET`, `PATCH`, `PUT`, `DELETE` method badges

#### **Swagger UI Navigation Guide**

##### Finding Endpoints

```
📌 Top-right corner: "Swagger UI" logo and version
📌 Left side: Search box to find endpoints by name
📌 Main area: All endpoints sorted by tags (Auth, Documents, Projects, Cameras, Health)
```

**Example:** To find the login endpoint:
1. Look for the **Auth** section (it will have a blue badge)
2. Expand the Auth section by clicking on it
3. Scroll to find `POST /auth/login`

**Step-by-step example of how to test an endpoint (e.g., Login):**

**Step 1: Find the Endpoint**
- Locate `POST /auth/login` under the **Auth** section
- Click on the endpoint row to expand it

**Step 2: Review Endpoint Details**
Once expanded, you'll see:
- **Description:** "Login and retrieve access token"
- **Request body schema** with required fields (username, password)
- **Response examples** showing expected 200 OK response

**Step 3: Click "Try it out" Button**
- Located on the right side of the expanded endpoint
- Changes the interface to "request mode"
- Text fields become editable

**Step 4: Fill in Request Body**
After clicking "Try it out", a text editor appears with a template:
```json
{
  "username": "string",
  "password": "string"
}
```

Replace with real arbitrary values:
```json
{
  "username": "john_doe",
  "password": "secure_password_123"
}
```

**Step 5: Click "Execute" Button**
- Blue button below the request editor
- Sends the request to the server
- Shows loading spinner briefly

**Step 6: View Response**

After execution, you'll see:

- Response headers (showing HTTP status):
```
HTTP/1.1 200 OK
content-length: 156
content-type: application/json
date: Tue, 17 Dec 2024 10:30:45 GMT
```

- Response body (the actual data):
```json
{
  "access_token": "eyJzdWIiOiIxIiwiZXhwIjoxNzM0NDUyNjAwfQ.sig...",
  "token_type": "bearer"
}
```

- cURL command (for reference):
```bash
curl -X 'POST' \
  'http://localhost:8000/auth/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{"username":"john_doe","password":"secure_password_123"}'
```
---

**Using Bearer Tokens for Protected Endpoints**

Many endpoints require authentication. Here's how to use your token:

**Step 1: Get Token from Login**
1. Test `POST /auth/login` as shown above
2. Copy the `access_token` value from the response

**Step 2: Authorize in Swagger UI**
1. Click the green **"Authorize"** button in the top-right corner
2. A modal dialog appears with an input field labeled "Value"
3. Paste your token exactly as it appears (or with `Bearer ` prefix):
   ```
   Bearer eyJzdWIiOiIxIiwiZXhwIjoxNzM0NDUyNjAwfQ.sig...
   ```
   Or just the token without prefix (Swagger adds it automatically):
   ```
   eyJzdWIiOiIxIiwiZXhwIjoxNzM0NDUyNjAwfQ.sig...
   ```
4. Click **"Authorize"** button in the modal
5. Click **"Close"** to dismiss the modal

**Step 3: Test Protected Endpoints**
Once authorized:
- All subsequent requests automatically include your token
- Protected endpoints (marked with 🔒 lock icon) will now work
- Green checkmark appears next to "Authorize" button

**Testing a Protected Endpoint Example: Create Document**

1. After authorization, find `POST /documents/` under **Documents** section
2. Click "Try it out"
3. Fill in the request body:
   ```json
   {
     "filename": "book_page_001.jpg",
     "file_path": "/mnt/sd/book_page_001.jpg",
     "format": "jpeg",
     "title": "Ancient Manuscript",
     "object_typology": "book",
     "author": "Unknown",
     "material": "parchment",
     "date": "1500-01-01"
   }
   ```
4. Click "Execute"
5. View successful 201 Created response with document ID

##### Key Swagger UI Features

**Response Status Indicators**
- **2xx (Green):** Success - request worked as expected
- **4xx (Red):** Client error - check your request
- **5xx (Red):** Server error - backend issue

**Example Responses**
- Click the "Example Value" tab to see formatted JSON
- Click "Schema" tab to see field definitions
- Useful for understanding required vs optional fields

**Schemas Tab**
- Shows data models used by the API
- Each field shows: name, type, description, constraints
- Example: "username" is a string, min 3 characters, max 50

**Testing Different Response Scenarios**

Create a document successfully:
```json
{
  "filename": "test.jpg",
  "file_path": "/mnt/sd/test.jpg",
  "format": "jpeg",
  "object_typology": "book"
}
```
Expected: **201 Created** ✅

Attempt without required fields:
```json
{
  "title": "No filename"
}
```
Expected: **400 Bad Request** with validation errors ❌

---

### 4.2 Option 2: Complete Testing Workflow in Swagger UI

Here's a recommended order to test the entire API:

1. **Health Check** → `GET /health` (no auth needed)
2. **Register User** → `POST /auth/register` 
3. **Login** → `POST /auth/login` (save token)
4. **Authorize** → Click Authorize button, paste token
5. **Create Project** → `POST /projects/`
6. **Create Document** → `POST /documents/`
7. **Add to Project** → `POST /projects/{id}/add_document/{doc_id}`
8. **Get Document** → `GET /documents/{id}`
9. **Update Document** → `PATCH /documents/{id}`
10. **Delete Document** → `DELETE /documents/{id}`

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

# Run system validation
python tests/validate_system.py

# Run with verbose output
python -m pytest -v

# Run tests and show coverage
python -m pytest --cov=app --cov-report=html
```

**Test Organization:**
- `tests/unit/test_api.py` - API endpoint validation, imports, models, schemas
- `tests/integration/test_capture_integration.py` - Full capture workflow with database
- `tests/test_cameras.py` - Camera hardware tests (requires connected cameras)
- `tests/validate_system.py` - Complete system validation script
- `tests/conftest.py` - Shared pytest fixtures

### Option 4: Python Code Examples
See [Code Examples](#code-examples) section below for complete Python workflows:
- Registration and login
- Document creation with typology
- Project management
- Gallery listing

### Option 5: JavaScript/TypeScript
Frontend examples provided in [Frontend Integration](#frontend-integration) section.

### Option 6: Manual Testing (cURL)
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
```

---

### Alternative Documentation Views

**ReDoc** (Read-only documentation):
```
http://localhost:8000/redoc
```
- Cleaner, more organized layout
- Better for reading documentation
- Cannot test endpoints directly

**OpenAPI JSON** (Raw specification):
```
http://localhost:8000/openapi.json
```
- Machine-readable API specification
- Used by third-party tools
- Complete schema and endpoint definitions

---

Below are provided specific testing examples in Swagger UI for all the 21 endpoints.

## 5. Authentication

### POST `/auth/register`

Register a new user.

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
  "is_active": true,
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `409 Conflict` - Username or email already exists
- `400 Bad Request` - Invalid email format or missing fields

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
print(f"Registered: {user['username']}")
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
- `401 Unauthorized` - Invalid credentials
- `403 Forbidden` - User account inactive

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/auth/login",
    json={"username": "john_doe", "password": "secure_password_123"}
)
token = response.json()["access_token"]
print(f"Token: {token[:20]}...")
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

**Errors**
- `401 Unauthorized` - Token expired or invalid

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/auth/refresh",
    headers={"Authorization": f"Bearer {old_token}"}
)
new_token = response.json()["access_token"]
```

---

### POST `/auth/password-reset`

Change user password (requires valid token and old password verification).

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

**Errors**
- `401 Unauthorized` - Invalid old password or token expired
- `400 Bad Request` - New password invalid

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/auth/password-reset",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "old_password": "old_pass",
        "new_password": "new_pass"
    }
)
print(response.json()["detail"])
```

---

## 6. Documents

All document endpoints require authentication except GET by ID (public read).

### POST `/documents/`

Create a new document with optional camera settings and EXIF data.

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "filename": "ancient_book_001.jpg",
  "file_path": "/mnt/sd/digitized/ancient_book_001.jpg",
  "format": "jpeg",
  "title": "Ancient Manuscript",
  "description": "Historical document from 1500s",
  "file_size": 8388608,
  "resolution_width": 4000,
  "resolution_height": 3000,
  "object_typology": "book",
  "author": "Unknown Scribe",
  "material": "parchment",
  "date": "1500-01-01",
  "custom_attributes": "{\"isbn\": \"N/A\", \"condition\": \"fair\", \"pages\": 150}"
}
```

**Response** (201 Created)
```json
{
  "id": 1,
  "filename": "ancient_book_001.jpg",
  "file_path": "/mnt/sd/digitized/ancient_book_001.jpg",
  "format": "jpeg",
  "title": "Ancient Manuscript",
  "object_typology": "book",
  "author": "Unknown Scribe",
  "material": "parchment",
  "date": "1500-01-01",
  "uploaded_by": "john_doe",
  "project_id": null,
  "created_at": "2024-12-17T10:30:00",
  "modified_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `409 Conflict` - Filename already exists

**Python Example**
```python
import json

doc = requests.post(
    "http://localhost:8000/documents/",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "filename": "book_001.jpg",
        "file_path": "/mnt/sd/book_001.jpg",
        "format": "jpeg",
        "object_typology": "book",
        "title": "Ancient Book",
        "author": "Unknown",
        "material": "parchment",
        "date": "1500-01-01"
    }
)
doc_data = doc.json()
print(f"Created document: {doc_data['id']}")
```

---

### GET `/documents/`

List all documents (paginated, requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Query Parameters**
- `skip` (int, default: 0) - Number of documents to skip
- `limit` (int, default: 100, max: 1000) - Number of documents to return

**Example Request**
```
GET /documents/?skip=0&limit=50
```

**Response** (200 OK)
```json
[
  {
    "id": 1,
    "filename": "book_001.jpg",
    "file_path": "/mnt/sd/book_001.jpg",
    "format": "jpeg",
    "title": "Ancient Book",
    "object_typology": "book",
    "author": "Unknown",
    "uploaded_by": "john_doe",
    "created_at": "2024-12-17T10:30:00"
  },
  {
    "id": 2,
    "filename": "map_001.jpg",
    "file_path": "/mnt/sd/map_001.jpg",
    "format": "jpeg",
    "title": "Historical Map",
    "object_typology": "map",
    "created_at": "2024-12-17T11:00:00"
  }
]
```

**Errors**
- `401 Unauthorized` - No or invalid token

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/documents/",
    headers={"Authorization": f"Bearer {token}"},
    params={"skip": 0, "limit": 50}
)
documents = response.json()
print(f"Found {len(documents)} documents")
for doc in documents:
    print(f"- {doc['filename']}: {doc['object_typology']}")
```

---

### GET `/documents/{id}`

Get a specific document by ID (public, no authentication required).

**Response** (200 OK)
```json
{
  "id": 1,
  "filename": "book_001.jpg",
  "file_path": "/mnt/sd/book_001.jpg",
  "format": "jpeg",
  "title": "Ancient Book",
  "description": "Historical manuscript",
  "file_size": 8388608,
  "resolution_width": 4000,
  "resolution_height": 3000,
  "object_typology": "book",
  "author": "Unknown",
  "material": "parchment",
  "date": "1500-01-01",
  "uploaded_by": "john_doe",
  "project_id": 1,
  "custom_attributes": "{\"isbn\": \"N/A\", \"condition\": \"fair\"}",
  "created_at": "2024-12-17T10:30:00",
  "modified_at": "2024-12-17T10:30:00",
  "camera_settings": {
    "id": 1,
    "camera_model": "Raspberry Pi Camera v3",
    "iso": 100,
    "aperture": 2.9
  },
  "exif_data": {
    "id": 1,
    "exposure_time": "1/100"
  }
}
```

**Errors**
- `404 Not Found` - Document ID doesn't exist

**Python Example**
```python
response = requests.get("http://localhost:8000/documents/1")
doc = response.json()
print(f"{doc['title']} by {doc['author']}")
print(f"Camera: {doc['camera_settings']['camera_model']}")
```

---

### PATCH `/documents/{id}`

Partially update a document (only provided fields are updated).

**Headers**
```
Authorization: Bearer <token>
```

**Request** (all fields optional)
```json
{
  "title": "Updated Title",
  "material": "parchment with leather binding"
}
```

**Response** (200 OK)
```json
{
  "id": 1,
  "title": "Updated Title",
  "material": "parchment with leather binding",
  ...
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Document ID doesn't exist

**Python Example**
```python
response = requests.patch(
    "http://localhost:8000/documents/1",
    headers={"Authorization": f"Bearer {token}"},
    json={"title": "New Title", "material": "new material"}
)
updated_doc = response.json()
print(f"Updated: {updated_doc['title']}")
```

---

### PUT `/documents/{id}`

Replace entire document (all fields required).

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "filename": "book_001_v2.jpg",
  "file_path": "/mnt/sd/book_001_v2.jpg",
  "format": "jpeg",
  "title": "Ancient Book - Version 2",
  "object_typology": "book",
  "author": "Updated Author"
}
```

**Response** (200 OK)
```json
{
  "id": 1,
  "filename": "book_001_v2.jpg",
  ...
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Document ID doesn't exist
- `400 Bad Request` - Missing required fields

**Python Example**
```python
response = requests.put(
    "http://localhost:8000/documents/1",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "filename": "updated.jpg",
        "file_path": "/mnt/sd/updated.jpg",
        "format": "jpeg",
        "title": "Updated Title"
    }
)
```

---

### DELETE `/documents/{id}`

Delete a document (also deletes associated camera settings and EXIF data).

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "detail": "document deleted"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Document ID doesn't exist

**Python Example**
```python
response = requests.delete(
    "http://localhost:8000/documents/1",
    headers={"Authorization": f"Bearer {token}"}
)
print(response.json()["detail"])
```

---

## 7. Projects

All project endpoints require authentication.

### POST `/projects/`

Create a new project.

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "name": "Book Digitization Project",
  "description": "Scanning historical books from the archive"
}
```

**Response** (201 Created)
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
- `401 Unauthorized` - No or invalid token
- `409 Conflict` - Project name already exists

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/projects/",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "name": "My Project",
        "description": "Description here"
    }
)
project = response.json()
print(f"Created project: {project['id']}")
```

---

### GET `/projects/`

List all projects (paginated).

**Headers**
```
Authorization: Bearer <token>
```

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

**Response** (200 OK)
```json
[
  {
    "id": 1,
    "name": "Book Digitization Project",
    "description": "Scanning historical books",
    "created_by": "john_doe",
    "created_at": "2024-12-17T10:30:00"
  }
]
```

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/projects/",
    headers={"Authorization": f"Bearer {token}"},
    params={"skip": 0, "limit": 50}
)
projects = response.json()
```

---

### POST `/projects/{id}/initialize`

Initialize project filesystem structure (requires authentication).

Creates the directory structure for storing captured images, temporary files, and export packages.

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "resolution": "medium"
}
```

**Response** (200 OK)
```json
{
  "detail": "project initialized",
  "directories_created": [
    "/var/lib/dtk/projects/my_project/images/main",
    "/var/lib/dtk/projects/my_project/images/temp",
    "/var/lib/dtk/projects/my_project/images/trash",
    "/var/lib/dtk/projects/my_project/packages"
  ]
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

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Project ID doesn't exist

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/projects/1/initialize",
    headers={"Authorization": f"Bearer {token}"},
    json={"resolution": "medium"}
)
print(response.json()["detail"])
```

---

### GET `/projects/{id}/documents`

Get all documents in a project (requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
[
  {
    "id": 1,
    "filename": "IMG_20260109_143022_c0.jpg",
    "file_path": "/var/lib/dtk/projects/my_project/images/main/IMG_20260109_143022_c0.jpg",
    "title": "Page 1",
    "resolution_width": 3840,
    "resolution_height": 2160,
    "created_at": "2026-01-09T14:30:22"
  }
]
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Project ID doesn't exist

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/projects/1/documents",
    headers={"Authorization": f"Bearer {token}"}
)
docs = response.json()
print(f"Project has {len(docs)} documents")
```

---

### GET `/projects/{id}`

Get a specific project.

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "id": 1,
  "name": "Book Digitization Project",
  "description": "Scanning historical books",
  "created_by": "john_doe",
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Project ID doesn't exist

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/projects/1",
    headers={"Authorization": f"Bearer {token}"}
)
project = response.json()
```

---

### POST `/projects/{id}/add_document/{doc_id}`

Add a document to a project.

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "detail": "document added to project"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Project or document doesn't exist

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/projects/1/add_document/5",
    headers={"Authorization": f"Bearer {token}"}
)
print(response.json()["detail"])
```

---

### POST `/projects/{id}/remove_document/{doc_id}`

Remove a document from a project.

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "detail": "document removed from project"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Project or document doesn't exist

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/projects/1/remove_document/5",
    headers={"Authorization": f"Bearer {token}"}
)
```

---

## 8. Cameras

### GET `/cameras/devices`

List available camera devices detected via libcamera/picamera2 (public endpoint).

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

**Note**: Returns empty list on non-Pi systems or if camera libraries unavailable. Each device includes:
- `hardware_id`: Unique camera identifier for registry lookup
- `model`: Camera model name from libcamera
- `index`: Camera index (0, 1) for capture operations
- `location`: Physical location (cam0, cam1)
- `machine_id`: Host machine identifier
- `label`: User-friendly label from registry
- `calibrated`: Whether focus calibration data exists

**Python Example**
```python
response = requests.get("http://localhost:8000/cameras/devices")
devices = response.json()
for device in devices:
    status = "✓ calibrated" if device['calibrated'] else "⚠ needs calibration"
    print(f"[{device['index']}] {device['model']} - {status}")
```

---

### POST `/cameras/capture`

Trigger a single image capture on specified camera (requires authentication).

Captures image to local storage (microSD), extracts metadata, and creates database record automatically.

**Headers**
```
Authorization: Bearer <token>
```

**Request Body**
```json
{
  "project_name": "BookScanning2024",
  "camera_index": 0,
  "resolution": "medium",
  "include_resolution_in_filename": false
}
```

**Request Parameters:**
- `project_name` (string, required): Project name (must exist, use `/projects/{id}/initialize` first)
- `camera_index` (int, default: 0): Camera index (0 or 1)
- `resolution` (string, default: "medium"): Image resolution:
  - `"low"`: 2312x1736 (~4MP, 195 DPI)
  - `"medium"`: 3840x2160 (~8MP, 350 DPI) - **Recommended**
  - `"high"`: 4624x3472 (16MP, 420 DPI)
- `include_resolution_in_filename` (bool, default: false): Add resolution to filename

**Response** (200 OK)
```json
{
  "success": true,
  "file_path": "/var/lib/dtk/projects/BookScanning2024/images/main/IMG_20240117_143022.jpg",
  "timing": null,
  "error": null
}
```

**Response on Error**
```json
{
  "success": false,
  "file_path": null,
  "error": "Camera 0 is not connected"
}
```

**Automatic Actions:**
1. Validates camera connection
2. Loads calibration data from registry (if available)
3. Captures image to project directory
4. Extracts EXIF metadata
5. Creates `DocumentImage` database record
6. Creates `CameraSettings` record
7. Creates `ExifData` record (if available)

**Errors**
- `401 Unauthorized` - No or invalid token
- Camera not connected - Returns success=false with error message

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/capture",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "project_name": "BookScanning2024",
        "camera_index": 0,
        "resolution": "medium",
        "include_resolution_in_filename": False
    }
)
result = response.json()
if result['success']:
    print(f"Captured: {result['file_path']}")
else:
    print(f"Error: {result['error']}")
```

---

### POST `/cameras/capture/dual`

Trigger simultaneous capture on both cameras (requires authentication).

Used for book scanning where left and right pages are captured together.
Both images are stored locally and metadata saved to database.

**Headers**
```
Authorization: Bearer <token>
```

**Request Body**
```json
{
  "project_name": "BookScanning2024",
  "resolution": "medium",
  "include_resolution_in_filename": false,
  "stagger_ms": 20
}
```

**Request Parameters:**
- `project_name` (string, required): Project name
- `resolution` (string, default: "medium"): Image resolution (low/medium/high)
- `include_resolution_in_filename` (bool, default: false): Add resolution to filename
- `stagger_ms` (int, default: 20): Milliseconds delay between camera triggers

**Response** (200 OK)
```json
{
  "success": true,
  "file_paths": [
    "/var/lib/dtk/projects/BookScanning2024/images/main/IMG_20240117_143022_cam0.jpg",
    "/var/lib/dtk/projects/BookScanning2024/images/main/IMG_20240117_143022_cam1.jpg"
  ],
  "timing": {
    "cam0_capture_ms": 245,
    "cam1_capture_ms": 248,
    "total_ms": 493
  },
  "error": null
}
```

**Automatic Actions:**
1. Validates both cameras connected
2. Loads calibration for both cameras
3. Captures both images with stagger delay
4. Creates two `DocumentImage` records
5. Creates `CameraSettings` for each
6. Creates `ExifData` for each

**Errors**
- `401 Unauthorized` - No or invalid token
- Camera not connected - Returns success=false with error

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/capture/dual",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "project_name": "BookScanning2024",
        "resolution": "medium",
        "stagger_ms": 20
    }
)
result = response.json()
if result['success']:
    print(f"Captured {len(result['file_paths'])} images")
    for path in result['file_paths']:
        print(f"  - {path}")
```

---

### POST `/cameras/calibrate`

Run autofocus calibration to find optimal lens position (requires authentication).

For fixed-distance setups (book scanning), this determines the best focus position
which is stored in the camera registry and reused for faster captures.

**Headers**
```
Authorization: Bearer <token>
```

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

**Response Parameters:**
- `lens_position`: Optimal lens position value (saved to registry)
- `distance_meters`: Estimated focus distance
- `af_time`: Autofocus operation time in seconds

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/calibrate",
    headers={"Authorization": f"Bearer {token}"},
    json={"camera_index": 0, "resolution": "high"}
)
result = response.json()
if result['success']:
    print(f"Calibrated: lens_position={result['lens_position']}")
```

---

### POST `/cameras/calibrate/white-balance`

Calibrate white balance for consistent color reproduction (requires authentication).

For best results, place a neutral gray card or white paper in the frame before running.
The camera runs AWB until converges, then saves the gains for future captures.

**Headers**
```
Authorization: Bearer <token>
```

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

**Response Parameters:**
- `awb_gains`: Red and blue channel gains (saved to registry)
- `colour_temperature`: Detected color temperature in Kelvin
- `converged`: Whether AWB algorithm converged successfully

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/calibrate/white-balance",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "camera_index": 0,
        "resolution": "high",
        "stabilization_frames": 30
    }
)
result = response.json()
if result['success'] and result['converged']:
    print(f"WB Calibrated: {result['colour_temperature']}K")
```

---

### POST `/cameras/`

Create camera settings for a document (requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Request**
```json
{
  "document_image_id": 1,
  "camera_model": "Raspberry Pi Camera v3",
  "camera_manufacturer": "Raspberry Pi Foundation",
  "iso": 100,
  "aperture": 2.9,
  "shutter_speed": "1/100",
  "white_balance": "daylight",
  "flash_used": false
}
```

**Response** (201 Created)
```json
{
  "id": 1,
  "document_image_id": 1,
  "camera_model": "Raspberry Pi Camera v3",
  "iso": 100,
  "aperture": 2.9,
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Document doesn't exist
- `409 Conflict` - Settings already exist for document

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "document_image_id": 1,
        "camera_model": "Raspberry Pi Camera v3",
        "iso": 100,
        "aperture": 2.9
    }
)
settings = response.json()
```

---

### GET `/cameras/`

List all camera settings (paginated, requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Query Parameters**
- `skip` (int, default: 0)
- `limit` (int, default: 100, max: 1000)

**Response** (200 OK)
```json
[
  {
    "id": 1,
    "document_image_id": 1,
    "camera_model": "Raspberry Pi Camera v3",
    "iso": 100,
    "aperture": 2.9,
    "created_at": "2024-12-17T10:30:00"
  }
]
```

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/cameras/",
    headers={"Authorization": f"Bearer {token}"},
    params={"limit": 50}
)
```

---

### GET `/cameras/{id}`

Get specific camera settings (requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "id": 1,
  "document_image_id": 1,
  "camera_model": "Raspberry Pi Camera v3",
  "camera_manufacturer": "Raspberry Pi Foundation",
  "iso": 100,
  "aperture": 2.9,
  "shutter_speed": "1/100",
  "white_balance": "daylight",
  "flash_used": false,
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Settings ID doesn't exist

**Python Example**
```python
response = requests.get(
    "http://localhost:8000/cameras/1",
    headers={"Authorization": f"Bearer {token}"}
)
settings = response.json()
```

---

### PUT `/cameras/settings/{id}`

Update camera settings (requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Request** (all fields optional)
```json
{
  "camera_model": "Arducam IMX519",
  "iso": 200,
  "white_balance": "custom"
}
```

**Response** (200 OK)
```json
{
  "id": 1,
  "document_image_id": 1,
  "camera_model": "Arducam IMX519",
  "iso": 200,
  "white_balance": "custom",
  "created_at": "2024-12-17T10:30:00"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Settings ID doesn't exist

---

### DELETE `/cameras/settings/{id}`

Delete camera settings (requires authentication).

**Headers**
```
Authorization: Bearer <token>
```

**Response** (200 OK)
```json
{
  "detail": "Camera settings deleted"
}
```

**Errors**
- `401 Unauthorized` - No or invalid token
- `404 Not Found` - Settings ID doesn't exist

---

## 9. Health Check

### GET `/health`

Health check endpoint (no authentication required).

**Response** (200 OK)
```json
{
  "status": "ok"
}
```

**Python Example**
```python
response = requests.get("http://localhost:8000/health")
print(response.json()["status"])
```

---

## 10. Data Models

### UserCreate (Request)
```json
{
  "username": "string",
  "email": "string (must be valid email)",
  "password": "string (min 8 chars recommended)"
}
```

### UserRead (Response)
```json
{
  "id": "integer",
  "username": "string",
  "email": "string",
  "is_active": "boolean",
  "created_at": "datetime or null"
}
```

---

### DocumentCreate (Request)
```json
{
  "filename": "string (required)",
  "file_path": "string (required)",
  "format": "string (required, e.g., 'jpeg', 'tiff')",
  "title": "string or null",
  "description": "string or null",
  "file_size": "integer or null (bytes)",
  "resolution_width": "integer or null (pixels)",
  "resolution_height": "integer or null (pixels)",
  "uploaded_by": "string or null (auto-filled from token)",
  "object_typology": "book|dossier|document|map|planimetry|other or null",
  "author": "string or null",
  "material": "string or null (e.g., 'paper', 'parchment')",
  "date": "string or null (YYYY-MM-DD)",
  "custom_attributes": "JSON string or null (typology-specific data)"
}
```

### DocumentRead (Response)
```json
{
  "id": "integer",
  "filename": "string",
  "file_path": "string",
  "format": "string",
  "title": "string or null",
  "description": "string or null",
  "file_size": "integer or null",
  "resolution_width": "integer or null",
  "resolution_height": "integer or null",
  "uploaded_by": "string or null",
  "project_id": "integer or null",
  "object_typology": "string or null",
  "author": "string or null",
  "material": "string or null",
  "date": "string or null",
  "custom_attributes": "string or null",
  "created_at": "datetime or null",
  "modified_at": "datetime or null",
  "camera_settings": "CameraSettingsRead or null",
  "exif_data": "ExifDataRead or null"
}
```

### DocumentUpdate (Request - PATCH only)
```json
{
  "title": "string or null",
  "description": "string or null",
  "file_size": "integer or null",
  "resolution_width": "integer or null",
  "resolution_height": "integer or null",
  "project_id": "integer or null",
  "object_typology": "string or null",
  "author": "string or null",
  "material": "string or null",
  "date": "string or null",
  "custom_attributes": "string or null"
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
  "document_image_id": "integer (required)",
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
  "document_image_id": "integer",
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

## 10.1. File Storage  Architecture

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

- `YYYYMMDD` - Date (ISO format)
- `HHMMSS` - Time (24-hour format)
- `mmm` - Milliseconds (000-999)
- `cX` - Camera index (c0, c1)

**Example**: `20260109_143652_123_c0.jpg`
- January 9, 2026
- 14:36:52.123 UTC
- Camera 0

### Data Flow Architecture

```
┌─────────────────┐
│  API Client     │  (Frontend / cURL / Python)
└────────┬────────┘
         │ POST /cameras/capture
         ▼
┌──────────────────────┐
│  FastAPI Endpoint    │  cameras.py
│  (cameras.py)        │  - Validates request
└────────┬─────────────┘  - Checks camera connection
         │
         ▼
┌──────────────────────────────────┐
│  Capture Service                 │  capture/service.py
│  - Loads calibration from        │  - Uses picamera2/libcamera
│    camera registry                │  - Applies camera settings
│  - Captures image to:             │
│    /var/lib/dtk/projects/.../    │
│    images/main/                   │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│  Metadata Extraction             │  PIL / EXIF
│  - Image dimensions              │  - Resolution
│  - EXIF data (datetime, GPS)     │  - File size
│  - Camera settings used          │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│  Create Database Records         │  SQLAlchemy ORM
│  - DocumentImage (main record)   │
│  - CameraSettings (capture cfg)  │
│  - ExifData (image metadata)     │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│  PostgreSQL Database             │
│  - Image metadata stored         │  - File path persisted
│  - Linked to project             │  - Full audit trail
└──────────────────────────────────┘
```

### Database Relationships

All three record types link together:

```
DocumentImage (file_path, project_id)
    ├─> CameraSettings (camera_model, white_balance, lens_position)
    ├─> ExifData (raw_exif, datetime_original, GPS)
    ├─> Project (name, description)
    └─> User (uploaded_by)
```

### Performance Metrics

**Capture Speed:**
- Single capture: ~3-4 seconds (camera init + capture + save)
- Dual capture: ~5-7 seconds (parallel capture with 20ms stagger)
- Database insert: ~100-150ms per document

**Throughput (Medium Resolution):**
- Pages per hour: ~880 pph (single camera)
- Book (300 pages): ~20 minutes
- Dual camera: Effectively 1760 pph (both cameras)

**Storage Requirements:**
- Low resolution (2312x1736): ~2-3 MB per image
- Medium resolution (3840x2160): ~4-5 MB per image
- High resolution (4624x3472): ~8-10 MB per image
- 100-page book at medium: ~400-500 MB

---

## 11. Error Handling

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
| 403 | Forbidden | User account inactive |
| 404 | Not Found | Resource ID doesn't exist |
| 409 | Conflict | Duplicate entry, resource already exists |
| 500 | Internal Server Error | Unexpected server error |

---

## 12. Code Examples

### Complete Workflow: Registration to Gallery

```python
import requests
import json

BASE_URL = "http://localhost:8000"

# 1. Register user
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
print(f"   ✓ Registered: {user['username']}")

# 2. Login
print("\n2. Logging in...")
login_resp = requests.post(
    f"{BASE_URL}/auth/login",
    json={"username": "john_doe", "password": "secure_password_123"}
)
token = login_resp.json()["access_token"]
print(f"   ✓ Token: {token[:20]}...")

# 3. Create project
print("\n3. Creating project...")
project_resp = requests.post(
    f"{BASE_URL}/projects/",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "name": "Book Digitization",
        "description": "Scanning historical books"
    }
)
project = project_resp.json()
print(f"   ✓ Project: {project['name']} (ID: {project['id']})")

# 4. List devices
print("\n4. Listing cameras...")
devices_resp = requests.get(f"{BASE_URL}/cameras/devices")
devices = devices_resp.json()
if devices:
    print(f"   ✓ Available cameras:")
    for dev in devices:
        status = "✓ calibrated" if dev['calibrated'] else "⚠ needs calibration"
        print(f"     [{dev['index']}] {dev['model']} - {status}")
else:
    print("   ⚠ No cameras detected (run on Raspberry Pi)")

# 5. Capture image directly (creates document automatically)
print("\n5. Capturing image with camera...")
capture_resp = requests.post(
    f"{BASE_URL}/cameras/capture",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "project_name": "Book Digitization",
        "camera_index": 0,
        "resolution": "medium",
        "include_resolution_in_filename": False
    }
)
capture_result = capture_resp.json()
if capture_result['success']:
    print(f"   ✓ Captured: {capture_result['file_path']}")
    # Extract document ID from database query
    # In practice, you'd query /documents/ to find the latest
else:
    print(f"   ✗ Capture failed: {capture_result.get('error')}")
    # Fallback: Create document manually for demo
    doc_resp = requests.post(
        f"{BASE_URL}/documents/",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "filename": "ancient_book_001.jpg",
            "file_path": "/mnt/sd/ancient_book_001.jpg",
            "format": "jpeg",
            "object_typology": "book",
            "title": "Ancient Manuscript",
            "author": "Unknown Scribe",
            "material": "parchment",
            "date": "1500-01-01",
            "resolution_width": 4000,
            "resolution_height": 3000
        }
    )
    doc = doc_resp.json()
    print(f"   ✓ Document: {doc['filename']} (ID: {doc['id']})")

# 6. Get latest document (from capture or manual creation)
print("\n6. Fetching latest document...")
list_resp = requests.get(
    f"{BASE_URL}/documents/",
    headers={"Authorization": f"Bearer {token}"},
    params={"limit": 1}
)
docs = list_resp.json()
if docs:
    doc = docs[0]
    print(f"   ✓ Found: {doc['filename']} (ID: {doc['id']})")
    if doc.get('camera_settings'):
        print(f"   ✓ Camera: {doc['camera_settings'].get('camera_model', 'N/A')}")

# 7. Add document to project
print("\n7. Adding document to project...")
add_resp = requests.post(
    f"{BASE_URL}/projects/{project['id']}/add_document/{doc['id']}",
    headers={"Authorization": f"Bearer {token}"}
)
print(f"   ✓ {add_resp.json()['detail']}")

# 8. List all documents (gallery)
print("\n8. Fetching gallery...")
list_resp = requests.get(
    f"{BASE_URL}/documents/",
    headers={"Authorization": f"Bearer {token}"},
    params={"limit": 50}
)
docs = list_resp.json()
print(f"   ✓ Total documents: {len(docs)}")
for d in docs[:3]:
    print(f"   - {d['filename']}: {d.get('object_typology', 'unknown')}")

# 9. Get full document details
print("\n9. Fetching document details...")
detail_resp = requests.get(f"{BASE_URL}/documents/{doc['id']}")
full_doc = detail_resp.json()
print(f"   ✓ {full_doc['title']} by {full_doc['author']}")
print(f"   ✓ Camera: {full_doc['camera_settings']['camera_model']}")

print("\n✅ Workflow complete!")
```

---

### Configuration Page Example

```python
def configuration_page_flow(token):
    """
    Example flow for the configuration/setup page.
    User selects device, tests it, and chooses document typology.
    """
    
    # Step 1: Get available cameras
    print("Getting available cameras...")
    devices_resp = requests.get(f"{BASE_URL}/cameras/devices")
    devices = devices_resp.json()
    print(f"Devices: {devices}")
    
    # Step 2: Test device
    if devices:
        device_id = devices[0]['id']
        print(f"\nTesting device: {device_id}")
        test_resp = requests.post(
            f"{BASE_URL}/cameras/capture",
            params={"device_id": device_id}
        )
        print(f"Result: {test_resp.json()['detail']}")
    
    # Step 3: Show available typologies
    typologies = ["book", "dossier", "document", "map", "planimetry", "other"]
    print(f"\nAvailable document types: {typologies}")
    selected_type = "book"
    print(f"User selected: {selected_type}")
    
    # Step 4: Show dynamic fields for selected typology
    typology_fields = {
        "book": ["title", "author", "material", "date", "isbn", "publisher", "pages", "condition"],
        "dossier": ["title", "author", "date", "contents_summary"],
        "document": ["title", "author", "date", "signature"],
        "map": ["title", "region", "scale", "coverage"],
        "planimetry": ["title", "scale", "project_name"],
        "other": ["title", "description"]
    }
    
    print(f"\nFields for '{selected_type}': {typology_fields[selected_type]}")

configuration_page_flow(token)
```

---

### Gallery/View Page Example

```python
def gallery_view(token):
    """
    Example flow for the gallery/view page.
    Display all captured documents grouped by typology.
    """
    
    # Fetch all documents
    print("Fetching documents...")
    list_resp = requests.get(
        f"{BASE_URL}/documents/",
        headers={"Authorization": f"Bearer {token}"},
        params={"limit": 100}
    )
    documents = list_resp.json()
    
    print(f"\nTotal Documents: {len(documents)}\n")
    
    # Group by typology
    by_type = {}
    for doc in documents:
        typology = doc.get('object_typology', 'unknown')
        if typology not in by_type:
            by_type[typology] = []
        by_type[typology].append(doc)
    
    # Display by typology
    for typology, docs in sorted(by_type.items()):
        print(f"\n{typology.upper()} ({len(docs)} items)")
        print("-" * 60)
        for doc in docs[:5]:  # Show first 5
            print(f"  • {doc.get('title', doc['filename'])}")
            print(f"    Author: {doc.get('author', 'N/A')}")
            print(f"    Date: {doc.get('date', 'N/A')}")
            print(f"    Path: {doc['file_path']}")
            if doc.get('camera_settings'):
                print(f"    Camera: {doc['camera_settings'].get('camera_model', 'N/A')}")
            print()

gallery_view(token)
```

---

### Live Scan Page Example

```python
def live_scan_workflow(token, project_name="BookScanning2024"):
    """
    Example workflow for the live scan page.
    User captures image - metadata is automatically saved.
    """
    
    # 1. Get available cameras
    print("1. Getting cameras...")
    devices_resp = requests.get(f"{BASE_URL}/cameras/devices")
    devices = devices_resp.json()
    
    if not devices:
        print("   ⚠ No cameras detected")
        return
    
    selected_device = devices[0]
    print(f"   Selected: [{selected_device['index']}] {selected_device['model']}")
    if not selected_device['calibrated']:
        print("   ⚠ Camera not calibrated - consider running calibration first")
    
    # 2. Trigger capture (automatically creates document record)
    print("\n2. Triggering capture...")
    capture_resp = requests.post(
        f"{BASE_URL}/cameras/capture",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "project_name": project_name,
            "camera_index": selected_device['index'],
            "resolution": "medium",
            "include_resolution_in_filename": False
        }
    )
    result = capture_resp.json()
    
    if result['success']:
        print(f"   ✓ Captured: {result['file_path']}")
        
        # 3. Get the created document to show details
        print("\n3. Fetching document details...")
        list_resp = requests.get(
            f"{BASE_URL}/documents/",
            headers={"Authorization": f"Bearer {token}"},
            params={"limit": 1}  # Get most recent
        )
        docs = list_resp.json()
        if docs:
            doc = docs[0]
            print(f"   ✓ Document ID: {doc['id']}")
            print(f"   ✓ Resolution: {doc['resolution_width']}x{doc['resolution_height']}")
            if doc.get('camera_settings'):
                print(f"   ✓ Camera: {doc['camera_settings'].get('camera_model', 'N/A')}")
            
            # 4. Optional: Update document metadata after capture
            print("\n4. Updating metadata...")
            update_resp = requests.patch(
                f"{BASE_URL}/documents/{doc['id']}",
                headers={"Authorization": f"Bearer {token}"},
                json={
                    "title": "Page 1 of Ancient Manuscript",
                    "object_typology": "book",
                    "author": "Unknown Scribe",
                    "material": "parchment",
                    "date": "1500-01-01"
                }
            )
            updated = update_resp.json()
            print(f"   ✓ Updated: {updated['title']}")
    else:
        print(f"   ✗ Capture failed: {result['error']}")

live_scan_workflow(token)
```

**Note**: The capture endpoint now automatically:
- Captures the image
- Extracts resolution and EXIF data
- Creates the DocumentImage record
- Creates CameraSettings record
- Returns the file path

This eliminates the need to manually create documents after capture.

---

## 13. Frontend Integration

### Configuration Page (`pages/configurations`)

**Goals:**
- User authentication setup
- Camera device testing and calibration
- Document typology selection

**API Calls:**
1. `POST /auth/register` - Register new user (optional, if first time)
2. `POST /auth/login` - User login
3. `GET /cameras/devices` - Show available cameras with calibration status
4. `POST /cameras/calibrate` - Calibrate camera focus (optional)
5. `POST /cameras/calibrate/white-balance` - Calibrate white balance (optional)
6. `POST /cameras/capture` - Test camera capture

**Frontend Flow:**
```
1. Show login form
2. User enters credentials
3. POST /auth/login → receive token
4. Store token in localStorage/sessionStorage
5. Get camera list: GET /cameras/devices
6. Display cameras with calibration status indicators
7. Optional: Run calibration if camera not calibrated
   - POST /cameras/calibrate → get lens position
   - POST /cameras/calibrate/white-balance → get AWB gains
8. User clicks "Test Camera"
9. POST /cameras/capture (with project_name, camera_index, resolution)
10. Show typology selector: book, dossier, document, map, planimetry, other
11. Display dynamic input fields based on typology
```

---

### Live Scan Page (`pages/scan`)

**Goals:**
- Capture images with selected camera
- Document metadata is automatically created
- Optional: Update metadata after capture

**API Calls:**
1. `GET /cameras/devices` - List cameras (on load)
2. `POST /cameras/capture` - Capture with automatic database record creation
3. `GET /documents/` - List recent captures
4. `PATCH /documents/{id}` - Update metadata (optional)

**Frontend Flow:**
```
1. Load page, get cameras: GET /cameras/devices
2. Show camera selector dropdown with calibration status
3. User selects resolution (low/medium/high)
4. User clicks "Capture"
5. POST /cameras/capture with:
   - project_name (from config or project selector)
   - camera_index (selected camera)
   - resolution (user choice)
6. Backend automatically:
   - Captures image to SD card
   - Extracts metadata
   - Creates DocumentImage record
   - Creates CameraSettings record
   - Returns file_path
7. Frontend shows success with file path
8. Optional: Allow user to update document metadata:
   - title, author, material, date
   - object_typology
   - custom_attributes (JSON)
9. PATCH /documents/{id} with updated fields
   - custom_attributes (JSON based on typology)
7. User clicks "Save"
8. POST /documents/ with all metadata → receive document ID
9. Optionally: POST /cameras/ to save camera settings
10. Show confirmation and offer next capture
```

---

### Gallery Page (`pages/gallery`)

**Goals:**
- Display all captured documents
- Filter/search by typology
- View document details

**API Calls:**
1. `GET /documents/` - List all documents (paginated)
2. `GET /documents/{id}` - Get full document details
3. `DELETE /documents/{id}` - Delete document (optional)

**Frontend Flow:**
```
1. Load page, get documents: GET /documents/?limit=50
2. Display grid/list of thumbnails
3. Group by typology (book, map, dossier, etc.)
4. User clicks on document
5. GET /documents/{id} → full details + camera settings
6. Show modal/detail view with:
   - Image from file_path (served from SD card)
   - Metadata: title, author, material, date
   - Camera info: model, ISO, aperture, etc.
7. Optional: Edit button → PATCH /documents/{id}
8. Optional: Delete button → DELETE /documents/{id}
```

---

### Authentication Flow

```
1. POST /auth/register (optional)
   Request: { username, email, password }
   Response: { id, username, email, is_active, created_at }

2. POST /auth/login
   Request: { username, password }
   Response: { access_token, token_type }

3. Store token: localStorage.setItem("token", access_token)

4. Use token in all protected requests:
   headers: { "Authorization": `Bearer ${token}` }

5. Token expires after 1 hour by default

6. Before expiry, refresh:
   POST /auth/refresh
   Headers: { Authorization: Bearer <old_token> }
   Response: { access_token, token_type }

7. On logout:
   localStorage.removeItem("token")
```

---

## 14. Configuration

### Environment Variables (`.env`)

```env
# Database
DATABASE_URL=postgresql://user:password@localhost:5432/digitization_toolkit
DATABASE_USER=user
DATABASE_PASSWORD=password
DATABASE_HOST=db
DATABASE_PORT=5432
DATABASE_NAME=digitization_toolkit

# Security
SECRET_KEY=change-this-to-a-random-string
ACCESS_TOKEN_EXPIRE_SECONDS=3600

# Server
UVICORN_HOST=0.0.0.0
UVICORN_PORT=8000
LOG_LEVEL=info
```

---

### CORS Configuration

Currently allows `http://localhost:5173` (Svelte dev server).

**For production**, update `app/main.py`:
```python
allow_origins=["https://yourdomain.com", "https://www.yourdomain.com"]
```

---

### Token Expiration

Default: 1 hour (3600 seconds)

Change via `ACCESS_TOKEN_EXPIRE_SECONDS` in `.env`

---

## Architecture Overview

### Security
- **Password Hashing**: PBKDF2 with 100,000 iterations
- **Tokens**: HMAC-SHA256 signed, time-based expiration
- **Authentication**: HTTPBearer scheme with automatic dependency injection
- **User Status**: Inactive users cannot login

### Database
- **ORM**: SQLAlchemy 2.0
- **Engine**: PostgreSQL
- **Relationships**: Proper foreign keys with cascading deletes
- **Timestamps**: Automatic created_at/modified_at on all resources

### Validation
- **Schemas**: Pydantic for all inputs/outputs
- **Type Safety**: Full type hints throughout
- **Email Validation**: Verified email format for user registration

### Extensibility
- **Typology System**: 6 built-in document types (book, dossier, document, map, planimetry, other)
- **Custom Attributes**: JSON field for typology-specific metadata
- **Camera Integration**: Camera(s) integration (libcamera/picamera2) with hardware detection
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
