:: Development startup script for Digitization Toolkit
:: Starts all services in Docker (database + frontend + backend)
:: Use this on machines without camera hardware

@echo off

SET script_dir=%~dp0
CD /D "%script_dir%.."

echo ==========================================
echo Starting Digitization Toolkit (Development)
echo ==========================================
echo.
echo Starting all services in Docker...
echo   - Database (PostgreSQL)
echo   - Frontend (SvelteKit)
echo   - Backend (FastAPI, no cameras)
echo.

docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up --build
