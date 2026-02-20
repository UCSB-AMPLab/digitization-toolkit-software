#!/bin/bash
# Development startup script for Digitization Toolkit
# Starts all services in Docker (database + frontend + backend)
# Use this on machines without camera hardware

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "=========================================="
echo "Starting Digitization Toolkit (Development)"
echo "=========================================="
echo ""
echo "Starting all services in Docker..."
echo "  - Database (PostgreSQL)"
echo "  - Frontend (SvelteKit)"
echo "  - Backend (FastAPI, no cameras)"
echo ""

docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up --build
