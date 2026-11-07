#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/00-base.sh
# Baseline OS Hardening, Prerequisites, Sysctl Tuning, and Firewalld Baseline
# Target OS: RHEL 9 (SELinux Enforcing, Firewalld Active)
# Safe to run repeatedly (Idempotent)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source centralized environment
if [[ -f "${PARENT_DIR}/env.sh" ]]; then
  # shellcheck source=../env.sh
  source "${PARENT_DIR}/env.sh"
elif [[ -f "${SCRIPT_DIR}/env.sh" ]]; then
  # shellcheck source=./env.sh
  source "${SCRIPT_DIR}/env.sh"
else
  echo "[WARNING] env.sh not found in standard paths. Falling back to defaults."
  export CLUSTER_SUBNET="192.168.56.0/24"
  export GATEWAY_IP="192.168.56.2"
fi

echo "======================================================================"
echo ">> Running 00-base.sh on $(hostname) [$(date '+%Y-%m-%d %H:%M:%S')]"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. SELinux Enforcement Verification
# ------------------------------------------------------------------------------
echo ">> [1/6] Checking SELinux enforcement status..."
CURRENT_SELINUX=$(getenforce)
if [[ "${CURRENT_SELINUX}" == "Disabled" ]]; then
  echo "[FATAL] SELinux is Disabled in /etc/selinux/config. This lab requires Enforcing."
  echo "Enable SELinux in /etc/selinux/config, reboot, and rerun this script."
  exit 1
elif [[ "${CURRENT_SELINUX}" == "Permissive" ]]; then
  echo "[WARN] SELinux is Permissive. Switching to Enforcing per production mandate..."
  setenforce 1
  sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
fi
echo "[OK] SELinux is currently: $(getenforce)"

# ------------------------------------------------------------------------------
# 2. Package Prerequisites Installation
# ------------------------------------------------------------------------------
echo ">> [2/6] Installing base enterprise utilities..."
dnf install -y \
  curl \
  jq \
  bind-utils \
  tar \
  policycoreutils-python-utils \
  setools-console \
  chrony \
  firewalld \
  iptables-nft \
  iproute \
  iputils \
  procps-ng \
  psmisc

# ------------------------------------------------------------------------------
# 3. Time Synchronization Verification (Chrony)
# ------------------------------------------------------------------------------
echo ">> [3/6] Configuring and verifying Chrony NTP synchronization..."
if ! grep -q "^makestep 1.0 3" /etc/chrony.conf; then
  echo "makestep 1.0 3" >> /etc/chrony.conf
fi

systemctl enable --now chronyd
chronyc makestep || true
echo "[OK] Chrony status:"
chronyc tracking | grep -E 'Reference ID|System time|Last offset' || true

# ------------------------------------------------------------------------------
# 4. Kernel / Sysctl Network Tuning
# ------------------------------------------------------------------------------
echo ">> [4/6] Applying enterprise network sysctl parameters..."
cat << 'EOF' > /etc/sysctl.d/99-ha-cluster.conf
# ==============================================================================
# High-Availability Cluster Kernel Network Settings
# ==============================================================================

# Enable IPv4 packet forwarding (required for container bridge networking & proxying)
net.ipv4.ip_forward = 1

# Prevent ARP flux and control ARP broadcast responses across multiple interfaces
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2

# Fast TCP socket reuse for high-rate connection churn during failovers
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Increase connection backlog and max SYN backlog for microbursts
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# Memory limits for network socket buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

sysctl --system > /dev/null
echo "[OK] Kernel sysctl profile applied successfully."

# ------------------------------------------------------------------------------
# 5. Firewalld Baseline Configuration
# ------------------------------------------------------------------------------
echo ">> [5/6] Securing network perimeter with Firewalld..."
systemctl enable --now firewalld

# Verify default zone is public (enforcing least-privilege)
firewall-cmd --set-default-zone=public

# Ensure SSH is open for administration
firewall-cmd --permanent --zone=public --add-service=ssh

# Log dropped packets to journald for debugging (without flooding)
firewall-cmd --set-log-denied=unicast

firewall-cmd --reload > /dev/null
echo "[OK] Firewalld is active in public zone with SSH access secured."

# ------------------------------------------------------------------------------
# 6. /etc/hosts Consistency Check
# ------------------------------------------------------------------------------
echo ">> [6/6] Verifying cluster host mapping entries..."
declare -A HOSTS_MAP=(
  ["192.168.56.10"]="vip.corp.internal vip"
  ["192.168.56.11"]="lb1.corp.internal lb1"
  ["192.168.56.12"]="lb2.corp.internal lb2"
  ["192.168.56.20"]="app1.corp.internal app1"
  ["192.168.56.30"]="mon1.corp.internal mon1"
)

for ip in "${!HOSTS_MAP[@]}"; do
  entry="${ip}  ${HOSTS_MAP[$ip]}"
  if ! grep -q "${ip}" /etc/hosts; then
    echo "${entry}" >> /etc/hosts
    echo "Added /etc/hosts entry: ${entry}"
  fi
done

echo "======================================================================"
echo "[SUCCESS] 00-base.sh completed successfully on $(hostname)."
echo "SELinux: $(getenforce) | Firewalld: $(systemctl is-active firewalld) | Chrony: $(systemctl is-active chronyd)"
echo "======================================================================"
