#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/env.sh
# Centralized Environment Configuration for High-Availability RHEL Cluster
# All IPs, ports, credentials, and tuning parameters are defined here.
# Source this file in all provisioning and operational scripts.
# ==============================================================================

# Prevent multiple inclusions
if [[ -n "${__ENV_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
export __ENV_SH_LOADED=1

# ------------------------------------------------------------------------------
# 1. NETWORK TOPOLOGY (VMnet Dedicated Subnet: 192.168.56.0/24)
# ------------------------------------------------------------------------------
export CLUSTER_SUBNET="192.168.56.0/24"
export CLUSTER_NETMASK="255.255.255.0"
export CLUSTER_PREFIX="24"
export GATEWAY_IP="192.168.56.2"           # VMware NAT Gateway
export DNS_SERVERS="192.168.56.2 8.8.8.8"   # Primary NAT DNS + Google Fallback

# Floating Virtual IP (VIP) fronting HAProxy instances
export VIP="192.168.56.10"
export VIP_CIDR="${VIP}/${CLUSTER_PREFIX}"
export VIP_PORT=8080

# Static IP Assignments
export LB1_IP="192.168.56.11"
export LB1_HOSTNAME="lb1.corp.internal"

export LB2_IP="192.168.56.12"
export LB2_HOSTNAME="lb2.corp.internal"

export APP1_IP="192.168.56.20"
export APP1_HOSTNAME="app1.corp.internal"

# Stage 8: Redundant Application & Database Secondary Node
export APP2_IP="192.168.56.21"
export APP2_HOSTNAME="app2.corp.internal"

export MON1_IP="192.168.56.30"
export MON1_HOSTNAME="mon1.corp.internal"

# Dynamic Network Interface Auto-Detection with ens33 Fallback
DETECTED_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
if [[ -z "${DETECTED_IFACE}" ]]; then
  DETECTED_IFACE=$(ip -4 addr show | grep -E 'inet 192\.168\.56\.' | awk '{print $NF}' | head -n1 || true)
fi
export VIP_IFACE="${VIP_IFACE:-${DETECTED_IFACE:-ens33}}"

# ------------------------------------------------------------------------------
# 2. VRRP / KEEPALIVED PARAMETERS (RFC 5798 Tuning for Sub-2s Failover)
# ------------------------------------------------------------------------------
export VRRP_ROUTER_ID=56                   # Virtual Router Identifier (VRID 1-255)
export VRRP_ADVERT_INT="0.3"               # Advertisement interval: 0.3s (300ms)
export VRRP_PRIORITY_MASTER=150            # lb1 priority
export VRRP_PRIORITY_BACKUP=100            # lb2 priority
export VRRP_AUTH_PASS="VrrpSecPass2026!"   # VRRP authentication password

# Gratuitous ARP burst parameters
export GARP_MASTER_DELAY=1
export GARP_MASTER_REPEAT=5
export GARP_MASTER_REFRESH=5
export GARP_MASTER_REFRESH_REPEAT=2

# ------------------------------------------------------------------------------
# 3. HAPROXY CONFIGURATION & STATS
# ------------------------------------------------------------------------------
export HAPROXY_FRONTEND_PORT="${VIP_PORT}" # 8080
export HAPROXY_STATS_PORT=8404
export HAPROXY_STATS_USER="admin"
export HAPROXY_STATS_PASS="SreLab2026!"
export HAPROXY_METRICS_PORT=8405
export HAPROXY_PG_WRITE_PORT=5000          # HAProxy routed write port to Patroni primary
export HAPROXY_PG_READ_PORT=5001           # HAProxy routed read port to standby replicas

# ------------------------------------------------------------------------------
# 4. APPLICATION & DATABASE CONFIGURATION (app1 & app2)
# ------------------------------------------------------------------------------
export APP_PORT_1=8081                     # Express API Replica 1
export APP_PORT_2=8082                     # Express API Replica 2
export API_METRICS_PATH="/metrics"
export API_HEALTH_PATH="/health"

export DB_PORT=5432
export DB_NAME="transactions_db"
export DB_USER="app_user"
export DB_PASS="TxSecurePass2026!"
export DB_REPLICATION_USER="replicator"
export DB_REPLICATION_PASS="ReplSecure2026!"

# Stage 8: Patroni & etcd Consensus Parameters
export PATRONI_API_PORT=8008
export PATRONI_CLUSTER_NAME="ha-pg-cluster"
export ETCD_PORT=2379
export ETCD_PEER_PORT=2380
export ETCD_INITIAL_CLUSTER="etcd1=http://192.168.56.20:2380,etcd2=http://192.168.56.21:2380,etcd3=http://192.168.56.30:2380"

# ------------------------------------------------------------------------------
# 5. OBSERVABILITY CONFIGURATION (mon1)
# ------------------------------------------------------------------------------
export NODE_EXPORTER_PORT=9100
export KEEPALIVED_EXPORTER_PORT=9650
export PROMETHEUS_PORT=9090
export GRAFANA_PORT=3000
export GRAFANA_ADMIN_USER="admin"
export GRAFANA_ADMIN_PASS="SreLab2026!"

# ------------------------------------------------------------------------------
# 6. TIME SYNCHRONIZATION (Chrony NTP)
# ------------------------------------------------------------------------------
export NTP_SERVERS="pool.ntp.org 0.rhel.pool.ntp.org 1.rhel.pool.ntp.org"
