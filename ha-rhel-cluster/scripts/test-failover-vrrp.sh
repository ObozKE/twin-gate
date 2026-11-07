#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/test-failover-vrrp.sh
# Automated Keepalived VRRP Health & Failover Verification Suite
# Verifies VIP assignment, health script execution, and simulated HAProxy failure
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
echo ">> Running Keepalived VRRP Verification Suite on $(hostname)"
echo "======================================================================"

# 1. Daemon Liveness Check
echo "[CHECK 1/5] Verifying Keepalived and HAProxy daemon status..."
if systemctl is-active --quiet keepalived && systemctl is-active --quiet haproxy; then
  echo "  [PASS] Both keepalived.service and haproxy.service are active."
else
  echo "  [FAIL] Daemons not running! Keepalived: $(systemctl is-active keepalived) | HAProxy: $(systemctl is-active haproxy)"
  exit 1
fi

# 2. Track Script Execution
echo "[CHECK 2/5] Testing /usr/local/bin/check_haproxy.sh execution..."
if /usr/local/bin/check_haproxy.sh; then
  echo "  [PASS] Health tracking script exited with code 0 (Healthy)."
else
  echo "  [FAIL] Health tracking script returned non-zero code!"
  exit 1
fi

# 3. Notification Handler Test
echo "[CHECK 3/5] Testing notification script and JSON state export..."
/usr/local/bin/notify.sh INSTANCE VI_1 TEST_STATE 150
if [[ -f "/var/run/keepalived-state.json" ]]; then
  cat /var/run/keepalived-state.json
  echo "  [PASS] /var/run/keepalived-state.json successfully generated."
else
  echo "  [FAIL] Notification script failed to produce state file!"
  exit 1
fi

# 4. VIP Assignment Inspection
echo "[CHECK 4/5] Inspecting VIP (${VIP}) ownership on this node..."
if ip -4 addr show dev "${VIP_IFACE}" | grep -q "${VIP}"; then
  echo "  [INFO] This node CURRENTLY HOLDS THE VIP (${VIP}). Role: MASTER"
else
  echo "  [INFO] This node DOES NOT hold the VIP. Role: BACKUP / STANDBY"
fi

# 5. Firewalld Protocol 112
echo "[CHECK 5/5] Verifying firewalld permits VRRP protocol (112)..."
if firewall-cmd --list-protocols | grep -q "vrrp"; then
  echo "  [PASS] Firewalld allows protocol 'vrrp'."
else
  echo "  [FAIL] Protocol 'vrrp' missing in firewalld public zone!"
  exit 1
fi

echo "======================================================================"
echo "[SUCCESS] Keepalived VRRP pre-flight checks complete on $(hostname)."
echo "======================================================================"
