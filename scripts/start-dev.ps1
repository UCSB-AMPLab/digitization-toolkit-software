# Development startup script for Digitization Toolkit
# Starts all services in Docker (database + frontend + backend)
# Use this on machines without camera hardware

# Exit on error
$ErrorActionPreference = 'Stop'

# Get script directory and project root
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir

# Change to project root
Set-Location $ProjectRoot

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Starting Digitization Toolkit (Development)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Starting all services in Docker..." -ForegroundColor Green
Write-Host "  - Database (PostgreSQL)"
Write-Host "  - Frontend (SvelteKit)"
Write-Host "  - Backend (FastAPI, no cameras)"
Write-Host ""

# Start Docker Compose with dev configuration
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up --build
