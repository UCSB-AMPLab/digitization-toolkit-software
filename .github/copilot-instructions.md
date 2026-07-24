---
applyTo: "**"
---

# AI Agent Instructions for Digitization Toolkit

## Project Overview

Offline-capable digitization toolkit for Raspberry Pi with dual camera support. FastAPI backend + Svelte frontend + PostgreSQL. Designed for standalone deployment in low-resource environments (archives, community centers).

**Critical Architecture Decision:** Backend runs **natively** (not in Docker) to access Raspberry Pi hardware (libcamera, picamera2). Database and frontend run in Docker.

## Core Architecture Patterns

### 1. Dual Deployment Modes

```bash
# Development (any machine, no cameras): All services in Docker with Vite live reload
./scripts/start-dev.sh  # or: docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up

# Production (Raspberry Pi with cameras): Native backend + Docker DB + pre-built frontend
./scripts/start.sh      # or: docker compose up -d && cd backend && pixi run dev
```

**Why:** System camera libraries (python3-libcamera, python3-kms++) cannot be installed via pip and must be accessed from system packages.

### 1a. Offline-First Frontend

The frontend uses a **multi-stage production Docker build** (`frontend/Dockerfile`):
- Stage 1 (builder): Installs npm deps + compiles SvelteKit → static Node.js server
- Stage 2 (runner): Copies only the compiled output — no npm, no source code

The running container needs **zero internet access**. The only requirement is a one-time internet-connected build:
```bash
# With internet access (e.g. at home / office):
docker compose build frontend    # or: docker compose build

# Then take the Pi offline — it will run forever from the cached image:
docker compose up -d
```

Adapter: `@sveltejs/adapter-node` (produces `node build/index.js`), port 3000.

`docker-compose.dev.yml` overrides the frontend service to use `Dockerfile.dev` (Vite dev server, port 5173, hot reload, volume mounts). Used only during development with internet.

### 2. Camera Backend Plugin System

Two interchangeable backends via `CAMERA_BACKEND` env var:
- **picamera2** (default): Direct libcamera2 bindings, 91.5% faster, supports live preview
- **subprocess**: Fallback using rpicam-still CLI, more compatible

Implementation: [backend/capture/backends/](backend/capture/backends/)
- `base.py`: Abstract `CameraBackend` class
- `picamera2_backend.py`: Native picamera2 implementation  
- `subprocess_backend.py`: CLI wrapper via rpicam-still

Switch backends: Set `CAMERA_BACKEND=subprocess` in `.env`

### 3. Hardware Identification System

Cameras identified by **hardware ID** (model + serial), not index (0, 1). Prevents config loss when cables swap.

```python
# backend/capture/camera_registry.py
class CameraRegistry:
    """Global registry at PROJECTS_ROOT/cameras.json tracks:
    - Hardware IDs (arducam_imx519_<serial>)
    - Per-camera calibration matrices
    - Role assignments (left/right)
    - Human-friendly labels
    """
```

API layer ([backend/app/api/cameras.py](backend/app/api/cameras.py)) uses index for simplicity, but core capture layer uses hardware IDs.

## Database & Migrations: CRITICAL RULES

### ⚠️ NEVER Add `Base.metadata.create_all()`

Tables are managed **exclusively through Alembic migrations**. This is not negotiable.

**WRONG:**
```python
# app/core/db.py
def init_db():
    Base.metadata.create_all(bind=engine)  # ❌ NEVER DO THIS
```

**CORRECT:**
```python
# app/core/db.py
def init_db() -> None:
    """Import all models to register them with SQLAlchemy."""
    import app.models.document  # Just import, no create_all()
    import app.models.camera
    import app.models.project
    import app.models.user
```

### Workflow for Schema Changes

1. Modify model in `app/models/`
2. Generate migration: `docker compose exec backend alembic revision --autogenerate -m "description"`
3. Review generated file in `backend/alembic/versions/`
4. Apply: `docker compose exec backend alembic upgrade head`

**Native backend with pixi:**
```bash
cd backend
pixi run db-migrate "add new column"  # Generate migration
pixi run db-upgrade                   # Apply migration
```

### PostgreSQL Connection Format

Use `postgresql+psycopg://` (psycopg3), **not** `postgresql://` (legacy psycopg2).

```python
# app/core/config.py
DATABASE_URL = f"postgresql+psycopg://{user}:{password}@{host}:{port}/{database}"
```

## Authentication System

**Custom HMAC token system** for offline/standalone operation. Do NOT suggest replacing with JWT libraries (python-jose, PyJWT) or OAuth2.

```python
# app/core/security.py
def create_access_token(subject: str) -> str:
    """Custom token: {b64u(payload)}.{b64u(hmac_sig)}"""
    # No external JWT library needed for offline Raspberry Pi
```

Why: Intentionally lightweight for embedded deployment, no OAuth2 providers, minimal dependencies.

## Configuration Management

**Only add settings that application code actually uses.** Infrastructure settings belong in `docker-compose.yml`.

```python
# app/core/config.py
class Settings(BaseSettings):
    DATABASE_USER: str = "user"
    CAMERA_BACKEND: str = "picamera2"  # ✅ Used by camera registry
    # NOT: uvicorn_host - that's infrastructure, not application logic
```

Settings pattern:
- `Settings` class loads from `.env` via pydantic-settings
- Computed properties for paths: `projects_dir`, `exports_dir`, `data_dir`
- Accessed globally via `from app.core.config import settings`

## Dependency Management: Pixi (Recommended)

Project migrated from venv to **pixi** for better reproducibility.

```bash
# First time setup
cd backend
pixi install
pixi run setup-camera-link  # Raspberry Pi only: links system camera packages

# Common commands
pixi run dev              # Start dev server
pixi run -e dev test      # Run pytest
pixi run db-upgrade       # Apply migrations
pixi add package-name     # Add dependency
```

Configuration: [backend/pixi.toml](backend/pixi.toml)

**System Package Linking (Raspberry Pi):** Picamera2 requires system-installed libcamera bindings. Pixi task `setup-camera-link` creates `.pth` file to expose `/usr/lib/python3/dist-packages`.

Legacy venv still works but pixi preferred for new development.

## Testing Strategy

```bash
# Backend tests (in backend/ directory)
pixi run -e dev test            # All tests
pixi run test-cameras           # Camera-specific integration tests
pixi run -e dev test-verbose    # Pytest with -v

# Check camera hardware detection
rpicam-hello --list-cameras
```

Camera tests handle both backends gracefully, skip if hardware unavailable.

## File Organization

```
backend/
├── app/                    # FastAPI application
│   ├── api/               # Route handlers (documents, cameras, projects, auth)
│   ├── core/              # Config, DB, security
│   ├── models/            # SQLAlchemy models
│   └── schemas/           # Pydantic schemas
├── capture/               # Camera capture service (hardware layer)
│   ├── backends/         # Pluggable camera backends
│   ├── camera_registry.py # Hardware ID tracking
│   ├── calibration.py    # Camera calibration
│   └── project_manager.py # Capture orchestration
├── alembic/               # Database migrations
└── pixi.toml              # Dependency management

frontend/
└── src/
    ├── lib/              # Shared components/utilities
    └── routes/           # SvelteKit pages
```

## Documentation & Script Policy for AI Agents

### Documentation Files

**DO NOT create new standalone documentation files** (README.md, GUIDE.md, NOTES.md, etc.) for recording changes or providing instructions.

Instead:
- **Update THIS file** (.github/copilot-instructions.md) with new patterns or architectural decisions
- **Create .github/skills/*.md** for reusable procedures (e.g., "how to add a new camera backend")
- **Update existing docs** (backend/DEVELOPMENT.md, backend/DEPENDENCIES.md) if adding technical details

**Never create:**
- ❌ CHANGELOG.md, UPDATES.md, NOTES.md - Use git commits
- ❌ SETUP.md, QUICKSTART.md, CHEATSHEET.md - Info belongs in README.md
- ❌ INSTRUCTIONS.md, AGENT.md - Update this file instead
- ❌ Informational "status update" files - These are traceback logs, not documentation

### Shell Scripts

**DO NOT create shell scripts for simple tasks.** The project uses pixi tasks for backend workflows.

**Only create scripts for:**
- ✅ Multi-service orchestration (start-dev.sh, start.sh, stop.sh)
- ✅ System-level operations (install-service.sh, uninstall-service.sh)

**Never create scripts for:**
- ❌ Database migrations - Use `pixi run db-upgrade` or `pixi run db-migrate "message"`
- ❌ Running single services - Use `pixi run dev` directly
- ❌ One-time setup tasks - Document in README.md instead
- ❌ Simple command wrappers - Users can run commands directly

**Existing pixi tasks** (defined in backend/pixi.toml):
- `pixi run dev` - Start development server
- `pixi run -e dev test` - Run tests
- `pixi run db-upgrade` - Apply migrations
- `pixi run db-migrate "message"` - Create migration
- `pixi run setup-camera-link` - Link system camera packages

**Decision criteria:** "Does this require coordinating multiple services or system-level changes?" If no, use pixi tasks or document the command.

## Common Mistakes AI Agents Make

1. ❌ Re-adding `Base.metadata.create_all()` after it was intentionally removed
2. ❌ Suggesting JWT/OAuth2 for a standalone offline application
3. ❌ Adding unused config fields "just in case" to Settings
4. ❌ Using `postgresql://` instead of `postgresql+psycopg://`
5. ❌ Creating migrations outside Docker (wrong database host)
6. ❌ Forgetting backend must run natively for camera access
7. ❌ Breaking hardware ID system by reverting to index-based camera refs
8. ❌ Creating new documentation files instead of updating existing ones
9. ❌ Creating shell scripts for simple tasks (use pixi tasks instead)
10. ❌ Replacing `frontend/Dockerfile` (production multi-stage build) with `Dockerfile.dev` in `docker-compose.yml` — that would re-introduce npm downloads at startup and break offline use

## Quick Reference Commands

```bash
# Start full stack development (no cameras) — Vite dev server at :5173
./scripts/start-dev.sh

# Start production with cameras
./scripts/start.sh

# Backend only (native)
cd backend && pixi run dev

# Apply database migrations
docker compose exec backend alembic upgrade head
# OR: cd backend && pixi run db-upgrade

# Camera testing
rpicam-hello --list-cameras
cd backend && pixi run test-cameras

# Check database connection
docker compose exec backend python -c "from app.core.db import engine; from sqlalchemy import inspect; print(inspect(engine).get_table_names())"
```

## Documentation References

- [DEVELOPMENT.md](backend/DEVELOPMENT.md) - Critical development guidelines
- [DEPENDENCIES.md](backend/DEPENDENCIES.md) - Camera system dependencies
- [README.md](README.md) - Setup instructions and quick start

## Context for Code Generation

- **Deployment:** Offline-capable Raspberry Pi, single-instance
- **Database:** PostgreSQL with psycopg3, Alembic-only migrations
- **Auth:** Custom HMAC tokens (no JWT libraries)
- **Camera Hardware:** libcamera/picamera2 via system packages
- **Dependency Manager:** Pixi (preferred), venv (legacy)
- **Git:** Uses submodules for frontend/backend

**Before making changes:** Check git history to avoid reverting intentional architectural decisions.
