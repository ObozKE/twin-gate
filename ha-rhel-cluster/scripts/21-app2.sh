#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/21-app2.sh
# Automated Bootstrap for Secondary Application Node on app2 (192.168.56.21)
# Deploys API Replicas 3 & 4, Patroni Standby, and etcd Consensus Member 2
# Target OS: RHEL 9 (SELinux Enforcing)
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
echo ">> Provisioning Secondary Application Tier on $(hostname) (${APP2_IP})"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. SELinux Enforcement Verification
# ------------------------------------------------------------------------------
echo ">> [1/6] Verifying SELinux status..."
if [[ "$(getenforce)" != "Enforcing" ]]; then
  echo "[FATAL] SELinux must be Enforcing. Found: $(getenforce)"
  exit 1
fi
echo "[OK] SELinux is strictly Enforcing."

# ------------------------------------------------------------------------------
# 2. Package Prerequisites
# ------------------------------------------------------------------------------
echo ">> [2/6] Installing Podman and container runtime tools..."
dnf install -y podman container-tools curl jq

# ------------------------------------------------------------------------------
# 3. Firewalld Rules for Secondary Tier
# ------------------------------------------------------------------------------
echo ">> [3/6] Configuring firewalld for application replicas and consensus..."
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${APP_PORT_1}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${APP_PORT_2}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${DB_PORT}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${PATRONI_API_PORT}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${ETCD_PORT}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${ETCD_PEER_PORT}' protocol='tcp' accept"
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${NODE_EXPORTER_PORT}' protocol='tcp' accept"

firewall-cmd --reload > /dev/null
echo "[OK] Firewalld ports configured: 8081, 8082, 5432, 8008, 2379, 2380, 9100."

# ------------------------------------------------------------------------------
# 4. Start etcd Member 2
# ------------------------------------------------------------------------------
echo ">> [4/6] Deploying etcd consensus member 2..."
mkdir -p /var/lib/etcd/data
podman rm -f etcd-member 2>/dev/null || true

podman run -d \
  --name etcd-member \
  --restart always \
  --network host \
  -e ETCD_NAME="etcd2" \
  -e ETCD_DATA_DIR="/var/lib/etcd/data" \
  -e ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379" \
  -e ETCD_ADVERTISE_CLIENT_URLS="http://${APP2_IP}:2379" \
  -e ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380" \
  -e ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${APP2_IP}:2380" \
  -e ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER}" \
  -e ETCD_INITIAL_CLUSTER_STATE="new" \
  -e ETCD_INITIAL_CLUSTER_TOKEN="patroni-etcd-cluster" \
  -v /var/lib/etcd/data:/var/lib/etcd/data:Z \
  quay.io/coreos/etcd:v3.5.13

# ------------------------------------------------------------------------------
# 5. Build and Deploy API Replicas 3 & 4
# ------------------------------------------------------------------------------
echo ">> [5/6] Starting API Replicas 3 & 4 on app2..."
cd "${PARENT_DIR}/app"
podman build -t localhost/ha-api:latest -f Containerfile .

podman network exists app_net || podman network create app_net

# Replica 3 (Port 8081)
podman rm -f app-api-3 app-api-4 2>/dev/null || true
podman run -d \
  --name app-api-3 \
  --restart always \
  --network app_net \
  -p "${APP_PORT_1}:3000" \
  -e PORT=3000 \
  -e BACKEND_NAME="api-replica-3" \
  -e DB_HOST="${APP1_IP}" \
  -e DB_PORT="${DB_PORT}" \
  -e DB_USER="${DB_USER}" \
  -e DB_PASSWORD="${DB_PASS}" \
  -e DB_NAME="${DB_NAME}" \
  localhost/ha-api:latest

# Replica 4 (Port 8082)
podman run -d \
  --name app-api-4 \
  --restart always \
  --network app_net \
  -p "${APP_PORT_2}:3000" \
  -e PORT=3000 \
  -e BACKEND_NAME="api-replica-4" \
  -e DB_HOST="${APP1_IP}" \
  -e DB_PORT="${DB_PORT}" \
  -e DB_USER="${DB_USER}" \
  -e DB_PASSWORD="${DB_PASS}" \
  -e DB_NAME="${DB_NAME}" \
  localhost/ha-api:latest

# ------------------------------------------------------------------------------
# 6. Verification
# ------------------------------------------------------------------------------
echo ">> [6/6] Verifying API Replicas on app2..."
sleep 3
curl -sf "http://127.0.0.1:${APP_PORT_1}/health" | jq .
curl -sf "http://127.0.0.1:${APP_PORT_2}/health" | jq .

echo "======================================================================"
echo "[SUCCESS] Secondary Application Tier online on app2 (${APP2_IP})."
echo "Containers running:"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "======================================================================"
