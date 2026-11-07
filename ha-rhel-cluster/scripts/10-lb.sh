#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/10-lb.sh
# Automated Bootstrap for HAProxy + Keepalived on Load Balancers (lb1 / lb2)
# Configures net.ipv4.ip_nonlocal_bind=1, SELinux, Firewalld, HAProxy, and Keepalived
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
  VRRP_PRIORITY="${VRRP_PRIORITY_MASTER:-150}"
  VRRP_INITIAL_STATE="MASTER"
  NOPREEMPT_DIRECTIVE="nopreempt"
elif [[ "$NODE_ARG" == "lb2" ]]; then
  LB_NODE_NAME="lb2"
  NODE_IP="${LB2_IP}"
  VRRP_PRIORITY="${VRRP_PRIORITY_BACKUP:-100}"
  VRRP_INITIAL_STATE="BACKUP"
  NOPREEMPT_DIRECTIVE=""
else
  # Auto-detection by IP or hostname
  CURRENT_IP=$(ip -4 addr show | grep -E 'inet 192\.168\.56\.' | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "")
  if [[ "$CURRENT_IP" == "${LB2_IP}" ]] || [[ "$(hostname)" =~ lb2 ]]; then
    LB_NODE_NAME="lb2"
    NODE_IP="${LB2_IP}"
    VRRP_PRIORITY="${VRRP_PRIORITY_BACKUP:-100}"
    VRRP_INITIAL_STATE="BACKUP"
    NOPREEMPT_DIRECTIVE=""
  else
    LB_NODE_NAME="lb1"
    NODE_IP="${LB1_IP}"
    VRRP_PRIORITY="${VRRP_PRIORITY_MASTER:-150}"
    VRRP_INITIAL_STATE="MASTER"
    NOPREEMPT_DIRECTIVE="nopreempt"
  fi
fi

echo "======================================================================"
echo ">> Provisioning Ingress Tier (HAProxy + Keepalived) on ${LB_NODE_NAME}"
echo ">> Node IP: ${NODE_IP} | Role: ${VRRP_INITIAL_STATE} (Priority: ${VRRP_PRIORITY})"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. SELinux Enforcement Verification
# ------------------------------------------------------------------------------
echo ">> [1/8] Verifying SELinux status..."
if [[ "$(getenforce)" != "Enforcing" ]]; then
  echo "[FATAL] SELinux must be Enforcing. Found: $(getenforce)"
  exit 1
fi
echo "[OK] SELinux is strictly Enforcing."

# ------------------------------------------------------------------------------
# 2. Package Installation: HAProxy, Keepalived, & Utilities
# ------------------------------------------------------------------------------
echo ">> [2/8] Installing HAProxy and Keepalived..."
dnf install -y haproxy keepalived policycoreutils-python-utils psmisc

# ------------------------------------------------------------------------------
# 3. Kernel Sysctl Configuration: net.ipv4.ip_nonlocal_bind
# ------------------------------------------------------------------------------
echo ">> [3/8] Persisting net.ipv4.ip_nonlocal_bind=1 for floating VIP binding..."
cat << 'EOF' > /etc/sysctl.d/99-haproxy-nonlocal.conf
# Permits HAProxy to bind to floating Virtual IP (192.168.56.10) in BACKUP state
net.ipv4.ip_nonlocal_bind = 1
EOF

sysctl -p /etc/sysctl.d/99-haproxy-nonlocal.conf > /dev/null
echo "[OK] net.ipv4.ip_nonlocal_bind = 1 active."

# ------------------------------------------------------------------------------
# 4. SELinux Hardening: haproxy_connect_any
# ------------------------------------------------------------------------------
echo ">> [4/8] Configuring SELinux boolean for HAProxy backend routing..."
setsebool -P haproxy_connect_any 1
echo "[OK] SELinux boolean haproxy_connect_any: $(getsebool haproxy_connect_any)"

# ------------------------------------------------------------------------------
# 5. Firewalld Configuration: VRRP Protocol 112 & Ports
# ------------------------------------------------------------------------------
echo ">> [5/8] Configuring Firewalld for VRRP heartbeats and ingress ports..."
# Allow VRRP IP protocol (Protocol 112)
firewall-cmd --permanent --zone=public --add-protocol=vrrp

# Allow API frontend port (8080)
firewall-cmd --permanent --zone=public --add-port="${VIP_PORT}/tcp"

# Allow HAProxy Stats & Prometheus metrics port (8404)
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${HAPROXY_STATS_PORT}' protocol='tcp' accept"

# Allow Prometheus Node Exporter (9100)
firewall-cmd --permanent --zone=public --add-rich-rule="rule family='ipv4' source address='${CLUSTER_SUBNET}' port port='${NODE_EXPORTER_PORT}' protocol='tcp' accept"

firewall-cmd --reload > /dev/null
echo "[OK] Firewalld rules loaded: VRRP (proto 112), Ports: ${VIP_PORT}, ${HAPROXY_STATS_PORT}, ${NODE_EXPORTER_PORT}."

# ------------------------------------------------------------------------------
# 6. Template & Start HAProxy
# ------------------------------------------------------------------------------
echo ">> [6/8] Configuring and starting HAProxy..."
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
haproxy -c -f /etc/haproxy/haproxy.cfg

systemctl restart haproxy
systemctl enable haproxy
echo "[OK] haproxy.service is running."

# ------------------------------------------------------------------------------
# 7. Configure Keepalived Scripts & Configuration
# ------------------------------------------------------------------------------
echo ">> [7/8] Configuring Keepalived and health tracking scripts..."

# Deploy check_haproxy.sh and notify.sh to /usr/local/bin
cp "${PARENT_DIR}/lb/keepalived/check_haproxy.sh" /usr/local/bin/check_haproxy.sh
cp "${PARENT_DIR}/lb/keepalived/notify.sh" /usr/local/bin/notify.sh
chmod 755 /usr/local/bin/check_haproxy.sh /usr/local/bin/notify.sh

# Apply SELinux binary context so Keepalived daemon can execute them
restorecon -v /usr/local/bin/check_haproxy.sh /usr/local/bin/notify.sh || true

# Render /etc/keepalived/keepalived.conf
sed \
  -e "s|__LB_HOSTNAME__|${LB_NODE_NAME}|g" \
  -e "s|__VIP_IFACE__|${VIP_IFACE}|g" \
  -e "s|__VRRP_ROUTER_ID__|${VRRP_ROUTER_ID}|g" \
  -e "s|__VRRP_PRIORITY__|${VRRP_PRIORITY}|g" \
  -e "s|__VRRP_ADVERT_INT__|${VRRP_ADVERT_INT}|g" \
  -e "s|__VRRP_INITIAL_STATE__|${VRRP_INITIAL_STATE}|g" \
  -e "s|__NOPREEMPT_DIRECTIVE__|${NOPREEMPT_DIRECTIVE}|g" \
  -e "s|__VIP__|${VIP}|g" \
  "${PARENT_DIR}/lb/keepalived/keepalived.conf.tmpl" > /etc/keepalived/keepalived.conf

# ------------------------------------------------------------------------------
# 8. Start and Enable Keepalived Service
# ------------------------------------------------------------------------------
echo ">> [8/8] Starting and enabling keepalived.service..."
systemctl restart keepalived
systemctl enable keepalived

sleep 2

echo "======================================================================"
echo "[SUCCESS] Ingress Tier active on ${LB_NODE_NAME}."
echo "Keepalived Status: $(systemctl is-active keepalived) | HAProxy Status: $(systemctl is-active haproxy)"
echo "Active IP addresses on ${VIP_IFACE}:"
ip -4 addr show dev "${VIP_IFACE}"
echo "======================================================================"
