#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/ping-matrix.sh
# Ping & Latency Matrix Verification across Cluster Nodes and Gateway
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

TARGETS=(
  "Gateway:192.168.56.2"
  "Host Adapter:192.168.56.1"
  "lb1:192.168.56.11"
  "lb2:192.168.56.12"
  "app1:192.168.56.20"
  "mon1:192.168.56.30"
)

MY_IP=$(ip -4 addr show | grep -E 'inet 192\.168\.56\.' | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "unknown")
echo "======================================================================"
echo "Cluster Ping Matrix from $(hostname) (${MY_IP})"
echo "======================================================================"
printf "%-18s %-16s %-10s %-12s\n" "NODE" "IP ADDRESS" "STATUS" "AVG RTT"
echo "----------------------------------------------------------------------"

ALL_PASSED=true

for item in "${TARGETS[@]}"; do
  name="${item%%:*}"
  ip="${item##*:}"

  if [[ "$ip" == "$MY_IP" ]]; then
    printf "%-18s %-16s %-10s %-12s\n" "$name" "$ip" "[LOCAL]" "0.000 ms"
    continue
  fi

  # Send 2 ICMP packets with 1s timeout
  ping_out=$(ping -c 2 -W 1 "$ip" 2>&1 || true)

  if echo "$ping_out" | grep -q "2 packets transmitted, 2 received"; then
    rtt=$(echo "$ping_out" | grep -E "min/avg/max" | awk -F/ '{print $5}')
    printf "%-18s %-16s %-10s %-12s\n" "$name" "$ip" "PASS" "${rtt} ms"
  elif echo "$ping_out" | grep -q "1 received"; then
    rtt=$(echo "$ping_out" | grep -E "min/avg/max" | awk -F/ '{print $5}')
    printf "%-18s %-16s %-10s %-12s\n" "$name" "$ip" "WARN (50%)" "${rtt} ms"
  else
    printf "%-18s %-16s %-10s %-12s\n" "$name" "$ip" "FAIL" "UNREACHABLE"
    ALL_PASSED=false
  fi
done

echo "----------------------------------------------------------------------"
if [[ "$ALL_PASSED" == "true" ]]; then
  echo "[RESULT] Network mesh fully reachable from $(hostname)."
  exit 0
else
  echo "[RESULT] Network connectivity errors detected. Check VMnet2 & firewalld."
  exit 1
fi
