#!/usr/bin/env bash
set -euo pipefail

APP_USER="dtk"
APP_GROUP="dtk"

DATA_DIR="/var/lib/dtk"
LOG_DIR="/var/log/dtk"

echo "[dtk] Bootstrapping host directories and user..."

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (try: sudo $0)"
  exit 1
fi

getent group "${APP_GROUP}" >/dev/null || groupadd --system "${APP_GROUP}"
id -u "${APP_USER}" >/dev/null 2>&1 || useradd \
  --system \
  --gid "${APP_GROUP}" \
  --home "${DATA_DIR}" \
  --shell /usr/sbin/nologin \
  "${APP_USER}"

mkdir -p \
  "${DATA_DIR}/projects" \
  "${DATA_DIR}/exports" \
  "${DATA_DIR}/backups" \
  "${DATA_DIR}/db" \
  "${LOG_DIR}"

# Ownership + permissions
chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}"
chmod -R 750 "${DATA_DIR}" "${LOG_DIR}"

# Marker file
echo "DTK bootstrap completed on $(date -Iseconds)" > "${DATA_DIR}/.bootstrap"

echo "[dtk] Done."
echo "  Data: ${DATA_DIR}"
echo "  Logs: ${LOG_DIR}"
