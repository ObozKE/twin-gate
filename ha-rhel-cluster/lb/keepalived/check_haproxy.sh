#!/usr/bin/env bash
# ==============================================================================
# ha-rhel-cluster/lb/keepalived/check_haproxy.sh
# Health Tracking Script for Keepalived VRRP
# Verifies HAProxy process liveness AND HTTP response capability
# Returns 0 on success, 1 on failure (triggers VRRP priority reduction/failover)
# ==============================================================================

set -euo pipefail

# 1. Process Level Check: Ensure HAProxy daemon is running
if ! pidof haproxy > /dev/null 2>&1; then
  logger -t keepalived-check -p local0.err "[FAIL] HAProxy process is not running"
  exit 1
fi

# 2. Functional Check: Ensure HAProxy is actively responding to HTTP requests
# Check local stats/metrics socket or local health endpoint within 1 second
if ! curl -sf --max-time 1 "http://127.0.0.1:8404/stats" > /dev/null 2>&1; then
  # Fallback check against frontend port
  if ! curl -sf --max-time 1 "http://127.0.0.1:8080/health" > /dev/null 2>&1; then
    logger -t keepalived-check -p local0.err "[FAIL] HAProxy process alive but unresponsive to HTTP health check"
    exit 1
  fi
fi

exit 0
