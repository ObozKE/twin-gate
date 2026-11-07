#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/scripts/test-app-tier.sh
# End-to-End Test Suite for Application & Database Tier
# Verifies both API replicas, X-Backend headers, idempotency replay, and metrics
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

APP_TARGET="${1:-${APP1_IP}}"
API1_URL="http://${APP_TARGET}:${APP_PORT_1}"
API2_URL="http://${APP_TARGET}:${APP_PORT_2}"

echo "======================================================================"
echo ">> Running Automated Test Suite for App Tier against ${APP_TARGET}"
echo "======================================================================"

# 1. Health Checks
echo "[TEST 1/5] Checking /health on both replicas..."
health1=$(curl -s "${API1_URL}/health")
health2=$(curl -s "${API2_URL}/health")

if echo "$health1" | grep -q '"status":"UP"' && echo "$health2" | grep -q '"status":"UP"'; then
  echo "  [PASS] Both replicas report status: UP."
else
  echo "  [FAIL] Health check failed! Output 1: $health1 | Output 2: $health2"
  exit 1
fi

# 2. WhoAmI and X-Backend Headers
echo "[TEST 2/5] Verifying /whoami and X-Backend header..."
hdr1=$(curl -sI "${API1_URL}/whoami" | grep -i 'x-backend:' | tr -d '\r\n')
hdr2=$(curl -sI "${API2_URL}/whoami" | grep -i 'x-backend:' | tr -d '\r\n')

echo "  Replica 1 returned: ${hdr1}"
echo "  Replica 2 returned: ${hdr2}"

if echo "$hdr1" | grep -qi "api-replica-1" && echo "$hdr2" | grep -qi "api-replica-2"; then
  echo "  [PASS] X-Backend header correctly identifies replica instances."
else
  echo "  [FAIL] X-Backend headers did not match expected values!"
  exit 1
fi

# 3. Idempotent Transaction Submission
echo "[TEST 3/5] Submitting fresh transaction and validating idempotent replay..."
TEST_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
INITIAL_COUNT=$(curl -s "${API1_URL}/transactions/count" | jq -r .count)

# Initial submission to Replica 1
tx_resp1=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${API1_URL}/transactions" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${TEST_UUID}" \
  -d "{\"account_id\": \"ACC-TEST-99\", \"amount\": 1500.00, \"currency\": \"KES\", \"tx_type\": \"DEBIT\"}")

status1=$(echo "$tx_resp1" | grep 'HTTP_STATUS:' | cut -d: -f2)
body1=$(echo "$tx_resp1" | grep -v 'HTTP_STATUS:')

if [[ "$status1" -ne 201 ]]; then
  echo "  [FAIL] Expected HTTP 201 for fresh transaction, got ${status1}: ${body1}"
  exit 1
fi
echo "  [PASS] Fresh transaction committed with HTTP 201."

# Replay submission to Replica 2 with exact same UUID
tx_resp2=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${API2_URL}/transactions" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${TEST_UUID}" \
  -d "{\"account_id\": \"ACC-TEST-99\", \"amount\": 1500.00, \"currency\": \"KES\", \"tx_type\": \"DEBIT\"}")

status2=$(echo "$tx_resp2" | grep 'HTTP_STATUS:' | cut -d: -f2)
body2=$(echo "$tx_resp2" | grep -v 'HTTP_STATUS:')

if [[ "$status2" -ne 200 ]]; then
  echo "  [FAIL] Expected HTTP 200 for replayed transaction, got ${status2}: ${body2}"
  exit 1
fi

is_replay=$(echo "$body2" | jq -r .is_replay)
if [[ "$is_replay" != "true" ]]; then
  echo "  [FAIL] Replayed transaction did not set is_replay=true! Body: ${body2}"
  exit 1
fi
echo "  [PASS] Replayed transaction correctly identified with HTTP 200 and is_replay=true."

# 4. Count Verification (Zero Duplication)
echo "[TEST 4/5] Verifying database count reflects exactly 1 insert..."
FINAL_COUNT=$(curl -s "${API2_URL}/transactions/count" | jq -r .count)
DIFF=$(( FINAL_COUNT - INITIAL_COUNT ))

if [[ "$DIFF" -eq 1 ]]; then
  echo "  [PASS] Database count increased by exactly 1 (Initial: ${INITIAL_COUNT}, Final: ${FINAL_COUNT})."
else
  echo "  [FAIL] Expected database count delta of 1, got delta: ${DIFF}"
  exit 1
fi

# 5. Prometheus Metrics
echo "[TEST 5/5] Checking /metrics endpoint..."
metrics_out=$(curl -s "${API1_URL}/metrics")
if echo "$metrics_out" | grep -q "transactions_total" && echo "$metrics_out" | grep -q "http_requests_total"; then
  echo "  [PASS] Prometheus metrics successfully exposed."
else
  echo "  [FAIL] /metrics did not contain expected counters!"
  exit 1
fi

echo "======================================================================"
echo "[SUCCESS] ALL 5 APP TIER TESTS PASSED SUCCESSFULLY!"
echo "======================================================================"
