# Development startup script for Digitization Toolkit
# Starts all services in Docker (database + frontend + backend)
# Use this on machines without camera hardware
#
# Version: 0.1.0-beta

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir

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

docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up --build
