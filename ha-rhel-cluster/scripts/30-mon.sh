#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/30-mon.sh
# Automated Bootstrap for Observability Tier on mon1 (192.168.56.30)
# Deploys Prometheus 2.52 + Grafana 11 with Pre-Provisioned Dashboards via Podman
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
echo ">> Provisioning Observability Tier on $(hostname) (${MON1_IP})"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. SELinux Enforcement Verification
# ------------------------------------------------------------------------------
echo ">> [1/6] Verifying SELinux status..."
if [[ "$(getenforce)" != "Enforcing" ]]; then
  echo "[FATAL] SELinux must be Enforcing. Found: $(getenforce)"
  exit 1
fi
echo "[OK] SELinux is Enforcing."

# ------------------------------------------------------------------------------
# 2. Package Prerequisites: Podman & Container Tools
# ------------------------------------------------------------------------------
echo ">> [2/6] Installing Podman and container runtime tools..."
dnf install -y podman container-tools curl jq

# ------------------------------------------------------------------------------
# 3. Firewalld Configuration: Grafana & Prometheus
# ------------------------------------------------------------------------------
echo ">> [3/6] Applying least-privilege firewalld rules for monitoring..."
# Grafana web interface (allow from host and cluster subnet)
firewall-cmd --permanent --zone=public --add-port="${GRAFANA_PORT}/tcp"

# Prometheus web interface & API
firewall-cmd --permanent --zone=public --add-port="${PROMETHEUS_PORT}/tcp"

# Local node_exporter
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${NODE_EXPORTER_PORT}' protocol='tcp' accept"

firewall-cmd --reload > /dev/null
echo "[OK] Firewalld opened ports: ${GRAFANA_PORT} (Grafana), ${PROMETHEUS_PORT} (Prometheus)."

# ------------------------------------------------------------------------------
# 4. Deploy Prometheus & Grafana Containers via Podman
# ------------------------------------------------------------------------------
echo ">> [4/6] Starting containerized Prometheus & Grafana stack..."
cd "${PARENT_DIR}/monitoring"

# Clean up any stale instances
podman rm -f mon-prometheus mon-grafana 2>/dev/null || true

# Create bridge network
podman network exists mon_net || podman network create mon_net

# Create persistent storage volumes
podman volume exists prom_data || podman volume create prom_data
podman volume exists grafana_data || podman volume create grafana_data

# Launch Prometheus 2.52 with :Z volume labels
echo "Launching Prometheus container..."
podman run -d \
  --name mon-prometheus \
  --restart always \
  --network mon_net \
  -p "${PROMETHEUS_PORT}:9090" \
  -v "${PARENT_DIR}/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z" \
  -v "${PARENT_DIR}/monitoring/prometheus/alert.rules.yml:/etc/prometheus/alert.rules.yml:ro,Z" \
  -v prom_data:/prometheus:Z \
  docker.io/prom/prometheus:v2.52.0 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle

# Launch Grafana 11 with provisioned datasources & dashboard
echo "Launching Grafana container..."
podman run -d \
  --name mon-grafana \
  --restart always \
  --network mon_net \
  -p "${GRAFANA_PORT}:3000" \
  -e GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER}" \
  -e GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASS}" \
  -e GF_USERS_ALLOW_SIGN_UP="false" \
  -e GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH="/etc/grafana/provisioning/dashboards/json/ha-cluster-overview.json" \
  -e GF_AUTH_ANONYMOUS_ENABLED="false" \
  -v "${PARENT_DIR}/monitoring/grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro,Z" \
  -v "${PARENT_DIR}/monitoring/grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro,Z" \
  -v "${PARENT_DIR}/monitoring/grafana/dashboards:/etc/grafana/provisioning/dashboards/json:ro,Z" \
  -v grafana_data:/var/lib/grafana:Z \
  docker.io/grafana/grafana:11.0.0

# ------------------------------------------------------------------------------
# 5. Service Liveness & Health Verification
# ------------------------------------------------------------------------------
echo ">> [5/6] Verifying monitoring service endpoints..."
sleep 4

# Check Prometheus
if curl -sf "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy" > /dev/null; then
  echo "[OK] Prometheus is healthy (http://127.0.0.1:${PROMETHEUS_PORT})."
else
  echo "[FATAL] Prometheus healthcheck failed!"
  podman logs mon-prometheus
  exit 1
fi

# Check Grafana
if curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" > /dev/null; then
  echo "[OK] Grafana is healthy (http://127.0.0.1:${GRAFANA_PORT})."
else
  echo "[FATAL] Grafana healthcheck failed!"
  podman logs mon-grafana
  exit 1
fi

# ------------------------------------------------------------------------------
# 6. Scrape Target Summary
# ------------------------------------------------------------------------------
echo ">> [6/6] Inspecting Prometheus active targets..."
curl -s "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets" | jq -r '.data.activeTargets[] | "\(.labels.job) -> \(.scrapeUrl) [\(.health)]"' || true

echo "======================================================================"
echo "[SUCCESS] Observability tier is fully online on mon1!"
echo "Prometheus: http://${MON1_IP}:${PROMETHEUS_PORT}"
echo "Grafana:    http://${MON1_IP}:${GRAFANA_PORT}"
echo "Login:      ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASS}"
echo "======================================================================"
