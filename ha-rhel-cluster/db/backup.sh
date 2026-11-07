#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/db/backup.sh
# Automated PostgreSQL Backup Script using Podman
# ==============================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgres}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/transactions_db_${TIMESTAMP}.sql.gz"
CONTAINER_NAME="app-postgres"
DB_NAME="${DB_NAME:-transactions_db}"
DB_USER="${DB_USER:-app_user}"

mkdir -p "${BACKUP_DIR}"

echo ">> Starting PostgreSQL backup for database: ${DB_NAME} at $(date)"

# Check if postgres container is running
if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "[ERROR] Container '${CONTAINER_NAME}' is not running!"
  exit 1
fi

# Stream pg_dump through gzip directly to destination
podman exec -t "${CONTAINER_NAME}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" --clean --if-exists | gzip > "${BACKUP_FILE}"

# Verify file was written and is not empty
if [[ -s "${BACKUP_FILE}" ]]; then
  echo "[SUCCESS] Backup created successfully: ${BACKUP_FILE} ($(du -h "${BACKUP_FILE}" | cut -f1))"
else
  echo "[FATAL] Backup file is empty or missing!"
  exit 1
fi

# Retention policy: remove backups older than 7 days
find "${BACKUP_DIR}" -name "transactions_db_*.sql.gz" -mtime +7 -delete || true
echo ">> Backup cycle complete."
