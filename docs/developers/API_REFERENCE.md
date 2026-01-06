# Digitization Toolkit - API Reference & Implementation Guide


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
python test_api.py
```

Expected output:
```
============================================================
BACKEND API VALIDATION TEST SUITE
============================================================
Imports................................. ✓ PASS
Password Hashing........................ ✓ PASS
Token Generation........................ ✓ PASS
Schemas................................. ✓ PASS
Models.................................. ✓ PASS
Routes.................................. ✓ PASS
------------------------------------------------------------
Total: 6/6 tests passed (100%)
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

The Digitization Toolkit API consists of **21 endpoints** organized into **5 routers**.
All endpoints run on: [`http://localhost:8000`](http://localhost:8000).


### 🔐 **Auth Router** (`/auth`)
User authentication and session management.

- User registration and login
- JWT access token issuance and refresh
- Password change functionality

### 📄 **Documents Router** (`/documents`)
Full CRUD for digitized documents with typology support:

- book
- dossier
- document
- map
- planimetry
- other

Supports metadata, EXIF data, and camera settings linkage.

### 📂 **Projects Router** (`/projects`)
Project-based organization for grouping documents into collections.

- Create and list projects
- Add/remove documents from projects

### 📷 **Cameras Router** (`/cameras`)
Camera device abstraction and metadata storage.

- Device enumeration (stub)
- Capture trigger (stub)
- Persistent camera settings per document

### ❤️ **Health Check** (`/health`)
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
| GET | `/cameras/devices` | ❌ | List devices (stub) |
| POST | `/cameras/capture` | ❌ | Trigger capture (stub) |
| GET | `/health` | ❌ | Health check |

> **Legend of the API endpoints matrix:** 
> 
>✅ = requires authentication
>
>❌ = public access

---

## 4. Testing the API

### 4.1 Option 1: Interactive Docs on Swagger UI (Recommended) 🚀

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
python test_api.py
```
Validates all imports, models, schemas, routes, and core security functions.

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

List available camera devices (public endpoint, no authentication required).

**Response** (200 OK)
```json
[
  {
    "id": "sim-0",
    "name": "Simulated Camera",
    "available": true
  },
  {
    "id": "/dev/video0",
    "name": "Raspberry Pi Camera v3",
    "available": true
  }
]
```

**Note**: Currently returns simulated device stub. Will enumerate actual /dev/video* devices after libcamera/picamera2 integration.

**Python Example**
```python
response = requests.get("http://localhost:8000/cameras/devices")
devices = response.json()
for device in devices:
    print(f"Device: {device['name']}")
```

---

### POST `/cameras/capture`

Trigger a capture on a device (public endpoint, stub implementation).

**Query Parameters**
- `device_id` (string, default: "sim-0") - Device ID to capture from

**Response** (200 OK)
```json
{
  "detail": "capture triggered on sim-0"
}
```

**Python Example**
```python
response = requests.post(
    "http://localhost:8000/cameras/capture",
    params={"device_id": "sim-0"}
)
print(response.json()["detail"])
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
print(f"   ✓ Available: {[d['name'] for d in devices]}")

# 5. Create document with book typology
print("\n5. Creating book document...")
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

# 6. Add camera settings
print("\n6. Adding camera settings...")
cam_resp = requests.post(
    f"{BASE_URL}/cameras/",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "document_image_id": doc['id'],
        "camera_model": "Raspberry Pi Camera v3",
        "iso": 100,
        "aperture": 2.9
    }
)
camera = cam_resp.json()
print(f"   ✓ Camera: {camera['camera_model']}")

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
def live_scan_workflow(token):
    """
    Example workflow for the live scan page.
    User captures image and saves document metadata.
    """
    
    # 1. Get available cameras
    print("1. Getting cameras...")
    devices_resp = requests.get(f"{BASE_URL}/cameras/devices")
    devices = devices_resp.json()
    selected_device = devices[0] if devices else None
    print(f"   Selected: {selected_device['name']}")
    
    # 2. Trigger capture
    print("\n2. Triggering capture...")
    capture_resp = requests.post(
        f"{BASE_URL}/cameras/capture",
        params={"device_id": selected_device['id']}
    )
    print(f"   {capture_resp.json()['detail']}")
    
    # 3. Image now saved to SD card at /mnt/sd/image_001.jpg
    # (this happens on frontend/device level)
    
    # 4. Save document metadata to backend
    print("\n3. Saving document metadata...")
    doc_resp = requests.post(
        f"{BASE_URL}/documents/",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "filename": "image_001.jpg",
            "file_path": "/mnt/sd/image_001.jpg",
            "format": "jpeg",
            "object_typology": "book",
            "title": "Page 1 of Ancient Manuscript",
            "author": "Unknown",
            "material": "parchment",
            "date": "1500-01-01",
            "resolution_width": 4000,
            "resolution_height": 3000
        }
    )
    doc = doc_resp.json()
    print(f"   ✓ Saved: {doc['filename']} (ID: {doc['id']})")
    
    # 5. Add camera settings from capture metadata
    print("\n4. Adding camera metadata...")
    cam_resp = requests.post(
        f"{BASE_URL}/cameras/",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "document_image_id": doc['id'],
            "camera_model": "Raspberry Pi Camera v3",
            "iso": 100,
            "aperture": 2.9,
            "white_balance": "daylight"
        }
    )
    print(f"   ✓ Camera settings saved")

live_scan_workflow(token)
```

---

## 13. Frontend Integration

### Configuration Page (`pages/configurations`)

**Goals:**
- User authentication setup
- Camera device testing
- Document typology selection

**API Calls:**
1. `POST /auth/register` - Register new user (optional, if first time)
2. `POST /auth/login` - User login
3. `GET /cameras/devices` - Show available cameras
4. `POST /cameras/capture` - Test camera device

**Frontend Flow:**
```
1. Show login form
2. User enters credentials
3. POST /auth/login → receive token
4. Store token in localStorage/sessionStorage
5. Get camera list: GET /cameras/devices
6. Show camera list to user
7. User clicks "Test Camera"
8. POST /cameras/capture?device_id=<selected>
9. Show typology selector: book, dossier, document, map, planimetry, other
10. Display dynamic input fields based on typology
```

---

### Live Scan Page (`pages/scan`)

**Goals:**
- Capture images with selected camera
- Enter document metadata
- Save to backend

**API Calls:**
1. `GET /cameras/devices` - List cameras (on load)
2. `POST /cameras/capture` - Trigger capture (on button click)
3. `POST /documents/` - Save document with metadata

**Frontend Flow:**
```
1. Load page, get cameras: GET /cameras/devices
2. Show camera selector dropdown
3. User clicks "Capture"
4. POST /cameras/capture?device_id=<selected>
5. Capture happens on device, image saved to SD card
6. User fills in metadata form:
   - filename
   - file_path (path to image on SD card)
   - title, author, material, date
   - object_typology (user selected earlier)
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
- **Camera Stubs**: Ready for libcamera/picamera2 integration

---

## 15. Next Steps

### Priority 1: Camera Device Implementation
- Integrate libcamera or picamera2
- Enumerate actual /dev/video* devices
- Implement real capture with image save to SD card
- Add device status checks

### Priority 2: File Upload (Optional)
- Add `/documents/upload` endpoint
- Validate image format and resolution
- Handle SD card storage

### Priority 3: Search & Filtering (Optional)
- Add query params: `?typology=book&author=Smith&date_from=2024-01-01`
- Full-text search on title/description

### Priority 4: Testing (Recommended)
- Integration tests with real HTTP
- End-to-end tests
- Load testing

---

## Support & Resources

- **FastAPI Documentation**: https://fastapi.tiangolo.com/
- **SQLAlchemy Documentation**: https://docs.sqlalchemy.org/
- **Pydantic Documentation**: https://docs.pydantic.dev/
- **Interactive API Docs**: http://localhost:8000/docs (when running)

---

**Backend Status**: ✅ Core implementation complete and tested (6/6 tests passing)

**Last Updated**: December 17, 2024

**Implementation Phase**: Complete - Camera integration pending
