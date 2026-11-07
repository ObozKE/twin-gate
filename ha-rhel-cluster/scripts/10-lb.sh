#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/10-lb.sh
# Automated Bootstrap for HAProxy on Load Balancer Nodes (lb1 / lb2)
# Configures net.ipv4.ip_nonlocal_bind=1, SELinux booleans, Firewalld, and HAProxy
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

# Detect or accept target node identity
NODE_ARG="${1:-auto}"
if [[ "$NODE_ARG" == "lb1" ]]; then
  LB_NODE_NAME="lb1"
  NODE_IP="${LB1_IP}"
elif [[ "$NODE_ARG" == "lb2" ]]; then
  LB_NODE_NAME="lb2"
  NODE_IP="${LB2_IP}"
else
  # Auto-detection by IP or hostname
  CURRENT_IP=$(ip -4 addr show | grep -E 'inet 192\.168\.56\.' | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "")
  if [[ "$CURRENT_IP" == "${LB2_IP}" ]] || [[ "$(hostname)" =~ lb2 ]]; then
    LB_NODE_NAME="lb2"
    NODE_IP="${LB2_IP}"
  else
    LB_NODE_NAME="lb1"
    NODE_IP="${LB1_IP}"
  fi
fi

echo "======================================================================"
echo ">> Provisioning HAProxy on ${LB_NODE_NAME} (${NODE_IP})"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. SELinux Enforcement Verification
# ------------------------------------------------------------------------------
echo ">> [1/7] Verifying SELinux status..."
if [[ "$(getenforce)" != "Enforcing" ]]; then
  echo "[FATAL] SELinux must be Enforcing. Found: $(getenforce)"
  exit 1
fi
echo "[OK] SELinux is strictly Enforcing."

# ------------------------------------------------------------------------------
# 2. Package Installation: HAProxy & SELinux Policy Tools
# ------------------------------------------------------------------------------
echo ">> [2/7] Installing HAProxy..."
dnf install -y haproxy policycoreutils-python-utils

# ------------------------------------------------------------------------------
# 3. Kernel Sysctl Configuration: net.ipv4.ip_nonlocal_bind
# ------------------------------------------------------------------------------
echo ">> [3/7] Persisting net.ipv4.ip_nonlocal_bind=1 for floating VIP binding..."
cat << 'EOF' > /etc/sysctl.d/99-haproxy-nonlocal.conf
# ==============================================================================
# High-Availability Non-Local Binding Setting
# Permits HAProxy to bind to floating Virtual IP (192.168.56.10) even when this
# specific node does not currently own the VIP (i.e. in VRRP BACKUP state).
# ==============================================================================
net.ipv4.ip_nonlocal_bind = 1
EOF

sysctl -p /etc/sysctl.d/99-haproxy-nonlocal.conf > /dev/null

NONLOCAL_VAL=$(sysctl -n net.ipv4.ip_nonlocal_bind)
if [[ "${NONLOCAL_VAL}" != "1" ]]; then
  echo "[FATAL] Failed to set net.ipv4.ip_nonlocal_bind=1"
  exit 1
fi
echo "[OK] net.ipv4.ip_nonlocal_bind = 1 is active and persisted."

# ------------------------------------------------------------------------------
# 4. SELinux Hardening: haproxy_connect_any
# ------------------------------------------------------------------------------
echo ">> [4/7] Applying SELinux boolean for backend microservice proxying..."
# HAProxy needs to establish outbound TCP connections to backend ports 8081 & 8082
setsebool -P haproxy_connect_any 1
echo "[OK] SELinux boolean haproxy_connect_any: $(getsebool haproxy_connect_any)"

# ------------------------------------------------------------------------------
# 5. Firewalld Configuration
# ------------------------------------------------------------------------------
echo ">> [5/7] Configuring Firewalld for HAProxy frontend and stats endpoints..."
# Allow API frontend port (8080)
firewall-cmd --permanent --zone=public --add-port="${VIP_PORT}/tcp"

# Allow HAProxy Stats & Prometheus metrics port (8404)
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${HAPROXY_STATS_PORT}' protocol='tcp' accept"

# Allow Prometheus Node Exporter (9100)
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${NODE_EXPORTER_PORT}' protocol='tcp' accept"

firewall-cmd --reload > /dev/null
echo "[OK] Firewalld ports configured: ${VIP_PORT}, ${HAPROXY_STATS_PORT}, ${NODE_EXPORTER_PORT}."

# ------------------------------------------------------------------------------
# 6. Template & Validate HAProxy Configuration
# ------------------------------------------------------------------------------
echo ">> [6/7] Generating and validating /etc/haproxy/haproxy.cfg..."
sed \
  -e "s|__VIP__|${VIP}|g" \
  -e "s|__VIP_PORT__|${VIP_PORT}|g" \
  -e "s|__NODE_IP__|${NODE_IP}|g" \
  -e "s|__LB_NODE_NAME__|${LB_NODE_NAME}|g" \
  -e "s|__APP1_IP__|${APP1_IP}|g" \
  -e "s|__APP_PORT_1__|${APP_PORT_1}|g" \
  -e "s|__APP_PORT_2__|${APP_PORT_2}|g" \
  -e "s|__HAPROXY_STATS_PORT__|${HAPROXY_STATS_PORT}|g" \
  -e "s|__HAPROXY_STATS_USER__|${HAPROXY_STATS_USER}|g" \
  -e "s|__HAPROXY_STATS_PASS__|${HAPROXY_STATS_PASS}|g" \
  "${PARENT_DIR}/lb/haproxy/haproxy.cfg.tmpl" > /etc/haproxy/haproxy.cfg

# Validate HAProxy configuration syntax
echo "Validating HAProxy syntax..."
haproxy -c -f /etc/haproxy/haproxy.cfg

# ------------------------------------------------------------------------------
# 7. Start and Enable HAProxy Service
# ------------------------------------------------------------------------------
echo ">> [7/7] Starting and enabling haproxy.service..."
systemctl restart haproxy
systemctl enable haproxy

# Quick status check
if systemctl is-active --quiet haproxy; then
  echo "[OK] haproxy.service is active and running."
else
  echo "[FATAL] haproxy.service failed to start!"
  journalctl -u haproxy --no-pager -n 25
  exit 1
fi

echo "======================================================================"
echo "[SUCCESS] HAProxy provisioning completed successfully on ${LB_NODE_NAME}."
echo "Listening sockets:"
ss -tulpn | grep haproxy || true
echo "======================================================================"
