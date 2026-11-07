#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/lb/keepalived/notify.sh
# Millisecond-Precision State Transition Notification Handler for Keepalived
# Logs directly to systemd-journald and writes JSON state for Prometheus
# Invoked as: notify.sh <TYPE> <NAME> <STATE> <PRIORITY>
# ==============================================================================

set -euo pipefail

TYPE="${1:-INSTANCE}"
NAME="${2:-VI_1}"
STATE="${3:-UNKNOWN}"
PRIORITY="${4:-0}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S.%3N')
NODE_NAME=$(hostname -s)
STATE_FILE="/var/run/keepalived-state.json"

LOG_MSG="[${TIMESTAMP}] [VRRP-EVENT] Node: ${NODE_NAME} | Instance: ${NAME} | State: ${STATE} | Priority: ${PRIORITY}"

# 1. Log with high visibility to journald via logger
logger -t keepalived-notify -p local0.notice "${LOG_MSG}"

# 2. Append to persistent cluster transition log
mkdir -p /var/log/cluster
echo "${LOG_MSG}" >> /var/log/cluster/vrrp-transitions.log

# 3. Export machine-readable state JSON for Prometheus exporter and observability
cat << EOF > "${STATE_FILE}"
{
  "timestamp": "${TIMESTAMP}",
  "node": "${NODE_NAME}",
  "instance": "${NAME}",
  "state": "${STATE}",
  "priority": ${PRIORITY},
  "is_master": $([[ "${STATE}" == "MASTER" ]] && echo "true" || echo "false")
}
EOF

# 4. Actions per state
case "${STATE}" in
  "MASTER")
    logger -t keepalived-notify -p local0.notice "[${TIMESTAMP}] [VIP-ACQUIRED] ${NODE_NAME} is now MASTER. VIP 192.168.56.10 active."
    ;;
  "BACKUP")
    logger -t keepalived-notify -p local0.notice "[${TIMESTAMP}] [VIP-RELEASED] ${NODE_NAME} transitioned to BACKUP. VIP released."
    ;;
  "FAULT")
    logger -t keepalived-notify -p local0.err "[${TIMESTAMP}] [VRRP-FAULT] ${NODE_NAME} entered FAULT state! HAProxy check failed."
    ;;
  *)
    logger -t keepalived-notify -p local0.info "[${TIMESTAMP}] [VRRP-STATE] State: ${STATE}"
    ;;
esac

exit 0
