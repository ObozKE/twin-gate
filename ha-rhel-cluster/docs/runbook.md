# Production Demo Runbook & Cluster Operations Guide

This runbook provides the minute-by-minute execution plan for recording a carrier-grade high-availability failover demonstration, followed by the operational recovery procedure.

---

## 1. 60-Second Video Demonstration Script

### Optimal Screen Layout (1080p Resolution)
- **Left 60% of Screen**: Web Browser displaying the provisioned Grafana Dashboard (`http://192.168.56.30:3000`) in dark mode with auto-refresh set to `1s`.
- **Right 40% of Screen**: Split Terminal:
  - Top Half: Client Load Generator terminal (PowerShell or Bash).
  - Bottom Half: `journalctl -t keepalived-notify -f` on `lb2`.

```
+------------------------------------------+---------------------------------------+
|                                          | [Terminal 1: Load Generator]          |
|                                          | > node loadtest.js --rate 200 ...     |
| [Grafana Dashboard 1080p]                |                                       |
| - VIP Owner: lb1 (Green)                 +---------------------------------------+
| - Throughput: 200 req/s                  | [Terminal 2: lb2 Transition Log]      |
| - Failover Annotation Marker             | > journalctl -t keepalived-notify -f  |
|                                          |                                       |
+------------------------------------------+---------------------------------------+
```

---

### Step-by-Step Minute Timeline

| Time Index | Stage | Action / Commentary |
|---|---|---|
| **00:00 - 00:10** | **Pre-Flight Verification** | Show Grafana dashboard in baseline state: **VIP Owner** displays `lb1` in bold green. Backend health displays `100%`. HTTP error rate is `0%`. |
| **00:10 - 00:25** | **Steady-State Ingress** | Execute the rate-controlled load test in Terminal 1:<br>`node loadtest.js --url http://192.168.56.10:8080/transactions --rate 200 --duration 30 --timeout 500`<br>Point to Grafana: Throughput climbs cleanly to 200 req/s; all ingress is processed by `lb1 (Primary)`. Latency $p95$ sits at $\approx 2\,\text{ms}$. |
| **00:25 - 00:30** | **Catastrophic Power Failure** | Execute hard power-off on `lb1` without warning:<br>`vmrun -T ws stop "C:\path\to\lb1.vmx" hard`<br>*(Simulates sudden hardware PSU blow, hypervisor crash, or ungraceful kernel panic)*. |
| **00:30 - 00:40** | **Sub-2s Failover & Detection** | **Watch Grafana and Terminal simultaneously:**<br>1. In Terminal 1, raw attempts to `lb1` fail and retry with identical UUIDs.<br>2. In Terminal 2, `lb2` logs: `[VRRP-EVENT] Node: lb2 | State: MASTER` at $T = 1.083\,\text{s}$.<br>3. On Grafana, **VIP Owner** flips instantly from `lb1` (Green) to `lb2` (Orange).<br>4. A vertical orange annotation line marks the exact moment of failover.<br>5. Ingress traffic on `lb1` drops to 0; traffic on `lb2` surges to 200 req/s. |
| **00:40 - 00:50** | **Test Completion** | The load test completes its 30-second run and drains sockets. Terminal 1 prints summary:<br>`>> MEASURED FAILOVER WINDOW: ~1080 ms (< 2.0 s)`<br>`>> [TARGET ACHIEVED] Failover duration is STRICTLY UNDER 2.0 SECONDS!` |
| **00:50 - 01:00** | **Reconciliation Proof** | Execute the transaction reconciler in Terminal 1:<br>`node reconcile.js --db-host 192.168.56.20 --db-user app_user --db-name transactions_db`<br>Show the output:<br>`Missing Transactions in DB: 0`<br>`Duplicate Transactions in DB: 0`<br>`>> FINAL RECONCILIATION AUDIT: [PASS]`<br>`>> ZERO TRANSACTIONS LOST. EXACTLY-ONCE INTEGRITY PROVEN.` |

---

## 2. Pre-Flight Checklist (Run Before Every Demo)

Ensure all components are verified prior to starting a recording:

```bash
# 1. Verify clock synchronization across all cluster nodes (< 5ms drift)
sudo chronyc tracking | grep "Last offset"

# 2. Verify VIP is currently owned by lb1
ip -4 -br addr show dev ens33
# (Must display 192.168.56.10/24 on lb1, and NOT on lb2)

# 3. Verify both API replicas are healthy on app1
curl -sf http://192.168.56.20:8081/health | jq .status
curl -sf http://192.168.56.20:8082/health | jq .status

# 4. Truncate transactions table to establish a clean test baseline
podman exec -i app-postgres psql -U app_user -d transactions_db -c "TRUNCATE transactions;"

# 5. Verify Prometheus active scrape targets (all 10 targets must be UP)
curl -s http://192.168.56.30:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) [\(.health)]"'
```

---

## 3. Operational Recovery Procedure (Returning to Initial State)

Following a failover test, return the cluster to its baseline configuration:

### Step 1: Power On `lb1`
```powershell
vmrun -T ws start "C:\path\to\lb1.vmx"
```

### Step 2: Observe `nopreempt` Behavior
Because `nopreempt` is configured on `lb1`, `lb1` boots and joins the cluster in `BACKUP` state. It will **not** seize the VIP back from `lb2`, avoiding an unnecessary second traffic disruption.

Verify on `lb1`:
```bash
journalctl -t keepalived-notify -n 10 --no-pager
# Output confirms lb1 entered BACKUP state with Priority 150.
```

### Step 3: Gracefully Fail Back to `lb1`
When maintenance is complete, gracefully return the VIP to `lb1`:
```bash
# On lb2: Briefly restart Keepalived to release the VIP
sudo systemctl restart keepalived

# On lb1: Verify it claims the VIP
ip -4 -br addr show dev ens33
# Output shows 192.168.56.10/24 on lb1.
```
