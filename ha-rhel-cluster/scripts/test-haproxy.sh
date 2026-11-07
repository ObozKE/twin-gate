#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/test-haproxy.sh
# Automated Test Suite for HAProxy on LB Nodes (lb1 / lb2)
# Verifies health checks, round-robin proxying, X-LB-Node headers, and stats/metrics
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

TARGET_IP="${1:-${LB1_IP}}"
EXPECTED_LB="${2:-auto}"

echo "======================================================================"
echo ">> Running HAProxy Automated Verification against ${TARGET_IP}:${VIP_PORT}"
echo "======================================================================"

# 1. Health check verification through HAProxy
echo "[TEST 1/5] Testing /health via HAProxy frontend..."
health_resp=$(curl -s "http://${TARGET_IP}:${VIP_PORT}/health")
if echo "$health_resp" | grep -q '"status":"UP"'; then
  echo "  [PASS] /health returned 200 UP via HAProxy."
else
  echo "  [FAIL] /health returned unexpected payload: ${health_resp}"
  exit 1
fi

# 2. X-LB-Node header verification
echo "[TEST 2/5] Checking X-LB-Node response header..."
lb_header=$(curl -sI "http://${TARGET_IP}:${VIP_PORT}/health" | grep -i 'x-lb-node:' | tr -d '\r\n' | awk '{print $2}')
echo "  Reported X-LB-Node: '${lb_header}'"

if [[ -n "$lb_header" ]]; then
  if [[ "$EXPECTED_LB" != "auto" ]] && [[ "$lb_header" != "$EXPECTED_LB" ]]; then
    echo "  [FAIL] Expected X-LB-Node '${EXPECTED_LB}', got '${lb_header}'"
    exit 1
  fi
  echo "  [PASS] X-LB-Node header present and valid."
else
  echo "  [FAIL] Missing X-LB-Node response header!"
  exit 1
fi

# 3. Round-robin backend distribution check
echo "[TEST 3/5] Verifying round-robin balancing across backend API replicas (10 requests)..."
r1_count=0
r2_count=0

for i in {1..10}; do
  backend=$(curl -sI "http://${TARGET_IP}:${VIP_PORT}/whoami" | grep -i 'x-backend:' | tr -d '\r\n' | awk '{print $2}')
  if [[ "$backend" == *"replica-1"* ]]; then
    ((r1_count++))
  elif [[ "$backend" == *"replica-2"* ]]; then
    ((r2_count++))
  fi
done

echo "  Distribution over 10 requests: api-replica-1=${r1_count}, api-replica-2=${r2_count}"
if [[ $r1_count -gt 0 ]] && [[ $r2_count -gt 0 ]]; then
  echo "  [PASS] Round-robin balancing successfully distributed load across both replicas."
else
  echo "  [FAIL] Imbalanced routing! One replica received zero traffic."
  exit 1
fi

# 4. HAProxy Stats Authentication
echo "[TEST 4/5] Checking HAProxy Stats dashboard access..."
stats_status=$(curl -s -o /dev/null -w "%{http_code}" -u "${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASS}" "http://${TARGET_IP}:${HAPROXY_STATS_PORT}/stats")
if [[ "$stats_status" == "200" ]]; then
  echo "  [PASS] Authenticated stats page accessible (HTTP 200)."
else
  echo "  [FAIL] Stats page returned HTTP ${stats_status}."
  exit 1
fi

# 5. Prometheus Metrics Endpoint
echo "[TEST 5/5] Testing HAProxy built-in Prometheus exporter (/metrics)..."
metrics_out=$(curl -s "http://${TARGET_IP}:${HAPROXY_STATS_PORT}/metrics")
if echo "$metrics_out" | grep -q "haproxy_frontend_bytes_in_total" || echo "$metrics_out" | grep -q "haproxy_process_uptime_seconds"; then
  echo "  [PASS] Prometheus metrics successfully scraped from HAProxy."
else
  echo "  [FAIL] Prometheus exporter returned invalid or empty metrics output."
  exit 1
fi

echo "======================================================================"
echo "[SUCCESS] ALL 5 HAPROXY CHECKS PASSED FOR ${TARGET_IP}!"
echo "======================================================================"
