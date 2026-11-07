#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/20-app.sh
# Automated Bootstrap for Application Tier on app1 (192.168.56.20)
# Deploys PostgreSQL 16 + 2x Express API Replicas via Podman
# Strictly enforces SELinux Enforcing and Least-Privilege Firewalld Rules
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PARENT_DIR}/env.sh" ]]; then
  # shellcheck source=../env.sh
  source "${PARENT_DIR}/env.sh"
elif [[ -f "${SCRIPT_DIR}/env.sh" ]]; then
  # shellcheck source=./env.sh
  source "${SCRIPT_DIR}/env.sh"
fi

echo "======================================================================"
echo ">> Provisioning Application & Database Tier on $(hostname) (${APP1_IP})"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. SELinux & Base OS Check
# ------------------------------------------------------------------------------
echo ">> [1/6] Verifying SELinux status..."
if [[ "$(getenforce)" != "Enforcing" ]]; then
  echo "[FATAL] SELinux must be Enforcing. Currently: $(getenforce)"
  exit 1
fi
echo "[OK] SELinux is Enforcing."

# ------------------------------------------------------------------------------
# 2. Package Prerequisites: Podman & Container Tools
# ------------------------------------------------------------------------------
echo ">> [2/6] Installing Podman and container runtime tools..."
dnf install -y podman podman-docker container-tools

# Install podman-compose if not present
if ! command -v podman-compose &> /dev/null; then
  echo "Installing podman-compose via dnf / pip..."
  dnf install -y podman-compose || pip3 install podman-compose
fi

# ------------------------------------------------------------------------------
# 3. Firewalld Hardening (Explicit Port Openings & Subnet Isolation)
# ------------------------------------------------------------------------------
echo ">> [3/6] Applying least-privilege firewalld rules for application tier..."
# Allow API ports 8081 & 8082 from cluster subnet
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${APP_PORT_1}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${APP_PORT_2}' protocol='tcp' accept"

# PostgreSQL 5432 strictly restricted to cluster subnet (defense-in-depth)
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${DB_PORT}' protocol='tcp' accept"

# Prometheus Node Exporter port
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${NODE_EXPORTER_PORT}' protocol='tcp' accept"

firewall-cmd --reload > /dev/null
echo "[OK] Firewalld rules configured for ports 8081, 8082, 5432, 9100."

# ------------------------------------------------------------------------------
# 4. SELinux Container Configuration
# ------------------------------------------------------------------------------
echo ">> [4/6] Configuring SELinux booleans for container volume management..."
# Ensure containers can bind network ports and run rootless cgroups if needed
setsebool -P container_manage_cgroup 1 || true

# ------------------------------------------------------------------------------
# 5. Build and Deploy Containers via Podman
# ------------------------------------------------------------------------------
echo ">> [5/6] Building and starting containerized services..."
cd "${PARENT_DIR}/app"

# Clean up any stale existing containers
podman rm -f app-api-1 app-api-2 app-postgres 2>/dev/null || true

# Build local API image
echo "Building API container image (localhost/ha-api:latest)..."
podman build -t localhost/ha-api:latest -f Containerfile .

# Create application bridge network if not existing
podman network exists app_net || podman network create app_net

# Create persistent PostgreSQL volume
podman volume exists pg_data || podman volume create pg_data

# Launch PostgreSQL 16 container with :Z label for SELinux volume relabeling
echo "Starting PostgreSQL 16 container..."
podman run -d \
  --name app-postgres \
  --restart always \
  --network app_net \
  -p 5432:5432 \
  -e POSTGRES_DB="${DB_NAME}" \
  -e POSTGRES_USER="${DB_USER}" \
  -e POSTGRES_PASSWORD="${DB_PASS}" \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v pg_data:/var/lib/postgresql/data:Z \
  -v "${PARENT_DIR}/db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro,Z" \
  docker.io/library/postgres:16-alpine

# Wait for PostgreSQL to become ready
echo "Waiting for PostgreSQL to accept connections..."
for i in {1..30}; do
  if podman exec app-postgres pg_isready -U "${DB_USER}" -d "${DB_NAME}" &>/dev/null; then
    echo "[OK] PostgreSQL is ready and accepting queries."
    break
  fi
  sleep 1
  if [[ $i -eq 30 ]]; then
    echo "[FATAL] Timed out waiting for PostgreSQL container."
    podman logs app-postgres
    exit 1
  fi
done

# Launch API Replica 1 (Port 8081)
echo "Starting API Replica 1 on port ${APP_PORT_1}..."
podman run -d \
  --name app-api-1 \
  --restart always \
  --network app_net \
  -p "${APP_PORT_1}:3000" \
  -e PORT=3000 \
  -e BACKEND_NAME="api-replica-1" \
  -e DB_HOST="app-postgres" \
  -e DB_PORT="5432" \
  -e DB_USER="${DB_USER}" \
  -e DB_PASSWORD="${DB_PASS}" \
  -e DB_NAME="${DB_NAME}" \
  localhost/ha-api:latest

# Launch API Replica 2 (Port 8082)
echo "Starting API Replica 2 on port ${APP_PORT_2}..."
podman run -d \
  --name app-api-2 \
  --restart always \
  --network app_net \
  -p "${APP_PORT_2}:3000" \
  -e PORT=3000 \
  -e BACKEND_NAME="api-replica-2" \
  -e DB_HOST="app-postgres" \
  -e DB_PORT="5432" \
  -e DB_USER="${DB_USER}" \
  -e DB_PASSWORD="${DB_PASS}" \
  -e DB_NAME="${DB_NAME}" \
  localhost/ha-api:latest

# ------------------------------------------------------------------------------
# 6. Verification and Health Check
# ------------------------------------------------------------------------------
echo ">> [6/6] Verifying API replica health..."
sleep 2

echo "Checking API Replica 1 (http://127.0.0.1:${APP_PORT_1}/health)..."
curl -sf "http://127.0.0.1:${APP_PORT_1}/health" | jq .

echo "Checking API Replica 2 (http://127.0.0.1:${APP_PORT_2}/health)..."
curl -sf "http://127.0.0.1:${APP_PORT_2}/health" | jq .

echo "======================================================================"
echo "[SUCCESS] Application and database tier active on app1."
echo "Podman containers:"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "======================================================================"
