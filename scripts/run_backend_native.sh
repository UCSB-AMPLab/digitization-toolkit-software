#!/bin/bash
# Startup script for running DTK backend natively (outside Docker)
# This allows direct access to camera hardware while connecting to dockerized DB

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================="
echo "DTK Backend - Native Startup"
echo -e "==================================================${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/backend"
VENV_DIR="$BACKEND_DIR/.venv"

if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo -e "${RED}✗ Error: .env file not found at $PROJECT_ROOT/.env${NC}"
    echo "  Make sure you're running this from the project root"
    exit 1
fi

if [ ! -d "$VENV_DIR" ]; then
    echo -e "${RED}✗ Error: Virtual environment not found at $VENV_DIR${NC}"
    echo "  Run: cd backend && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi

echo -e "${YELLOW}→${NC} Activating virtual environment..."
source "$VENV_DIR/bin/activate"

if ! command -v uvicorn &> /dev/null; then
    echo -e "${RED}✗ uvicorn not found in virtual environment${NC}"
    echo "  Run: pip install -r $BACKEND_DIR/requirements.txt"
    exit 1
fi

echo -e "${YELLOW}→${NC} Checking database connectivity..."
cd "$BACKEND_DIR"

python3 << 'PREFLIGHT_CHECK'
import sys
try:
    from app.core.db import engine
    from sqlalchemy import text
    
    with engine.connect() as conn:
        result = conn.execute(text('SELECT 1'))
        result.scalar()
    
    print('\033[0;32m✓\033[0m Database connection successful')
except Exception as e:
    print(f'\033[0;31m✗ Database connection failed: {e}\033[0m')
    print(f'\033[1;33m  Make sure Docker containers are running:\033[0m')
    print(f'    docker compose up db')
    sys.exit(1)
PREFLIGHT_CHECK

if [ $? -ne 0 ]; then
    exit 1
fi

echo -e "${YELLOW}→${NC} Checking camera availability..."
python3 << 'CAMERA_CHECK'
try:
    from capture.camera_registry import CameraRegistry
    registry = CameraRegistry()
    detected = registry.detect_cameras()
    if detected:
        print(f'\033[0;32m✓\033[0m Found {len(detected)} camera(s)')
    else:
        print('\033[1;33m⚠\033[0m  No cameras detected (capture endpoints will not work)')
except Exception as e:
    print(f'\033[1;33m⚠\033[0m  Camera check failed: {e}')
    print('  (Backend will start but camera endpoints may not work)')
CAMERA_CHECK

echo ""
echo -e "${GREEN}✓ Pre-flight checks complete${NC}"
echo ""
echo -e "${BLUE}Starting FastAPI backend...${NC}"
echo -e "  Backend: ${GREEN}http://0.0.0.0:8000${NC}"
echo -e "  API Docs: ${GREEN}http://localhost:8000/docs${NC}"
echo -e "  ReDoc: ${GREEN}http://localhost:8000/redoc${NC}"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# Start uvicorn with auto-reload
cd "$BACKEND_DIR"
exec uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
