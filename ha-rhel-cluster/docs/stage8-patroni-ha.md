# Stage 8: High-Availability Database & Application Tier (Patroni + etcd)

This document provides the architectural blueprint, cost/complexity estimate, and implementation specifications for eliminating the Single Point of Failure (SPOF) at `app1`.

---

## 1. Cost & Complexity Estimate

### Resource Footprint & Host RAM Impact

| Parameter | Base Build (Stages 0-7) | Stage 8 (Zero-SPOF Architecture) | Net Difference |
|---|---|---|---|
| **Virtual Machines** | 4 VMs (`lb1`, `lb2`, `app1`, `mon1`) | **5 VMs** (`lb1`, `lb2`, `app1`, `app2`, `mon1`) | **+1 VM** (`app2`) |
| **Virtual CPUs** | 6 vCPU | **8 vCPU** | **+2 vCPU** |
| **VM RAM Allocated** | 6.6 GB | **9.1 GB** | **+2.5 GB RAM** |
| **Disk Storage (Thin)** | ~100 GB (~25 GB used) | **~130 GB (~35 GB used)** | **+30 GB** |
| **Minimum Host RAM** | 16 GB | **16 GB** *(Leaves ~7 GB for Windows host)* | Acceptable |

### Complexity Analysis: Medium-High
Transitioning a stateless web tier to high-availability is straightforward. Transitioning a stateful database tier requires solving the **CAP theorem distributed consensus problem**:
1. **The Split-Brain Database Threat**: If network communication breaks between `app1` and `app2`, both database instances must **never** accept write transactions simultaneously. Dual active primaries lead to irrecoverable transaction ledger divergence.
2. **Distributed Consensus Solution**: Patroni uses an odd-numbered Distributed Configuration Store (DCS)—**etcd**—to enforce strict leader leases.
3. **Quorum Layout**: Rather than adding 3 new VMs for etcd, we deploy a lightweight 3-node etcd cluster co-located on:
   - `etcd1` on `app1` (`192.168.56.20`)
   - `etcd2` on `app2` (`192.168.56.21`)
   - `etcd3` on `mon1` (`192.168.56.30` - acts as the quorum tie-breaker with negligible RAM impact).

---

## 2. Stage 8 Architecture & Traffic Flow

```mermaid
flowchart TD
    subgraph IngressTier ["HAProxy Ingress Tier (lb1 & lb2)"]
        VIP["Virtual IP: 192.168.56.10:8080"]
        HAP_PG_WRITE["HAProxy Port 5000 (DB Write Pool)\nhttpchk GET /primary on :8008"]
        HAP_PG_READ["HAProxy Port 5001 (DB Read Pool)\nhttpchk GET /replica on :8008"]
    end

    subgraph App1_Node ["app1.corp.internal (192.168.56.20)"]
        API1["API Replica 1 (:8081)"]
        API2["API Replica 2 (:8082)"]
        PAT1["Patroni Node 1 (:8008)"]
        PG1[("PostgreSQL 16\n(PRIMARY)")]
        ETCD1["etcd Member 1 (:2379)"]
        
        PAT1 --- PG1
        PAT1 --> ETCD1
        API1 -->|Writes| HAP_PG_WRITE
        API2 -->|Writes| HAP_PG_WRITE
    end

    subgraph App2_Node ["app2.corp.internal (192.168.56.21)"]
        API3["API Replica 3 (:8081)"]
        API4["API Replica 4 (:8082)"]
        PAT2["Patroni Node 2 (:8008)"]
        PG2[("PostgreSQL 16\n(STANDBY REPLICA)")]
        ETCD2["etcd Member 2 (:2379)"]

        PAT2 --- PG2
        PAT2 --> ETCD2
        API3 -->|Writes| HAP_PG_WRITE
        API4 -->|Writes| HAP_PG_WRITE
    end

    subgraph Mon1_Node ["mon1.corp.internal (192.168.56.30)"]
        ETCD3["etcd Member 3 (:2379)\n(Tie-Breaker Quorum)"]
        PROM["Prometheus TSDB"]
    end

    ETCD1 <-->|Raft Consensus| ETCD2
    ETCD2 <-->|Raft Consensus| ETCD3
    ETCD1 <-->|Raft Consensus| ETCD3

    PG1 -.->|Streaming Replication (WAL)| PG2

    HAP_PG_WRITE ==>|Active Primary| PG1
    HAP_PG_WRITE -.->|Standby Failover| PG2

    VIP --> API1
    VIP --> API2
    VIP --> API3
    VIP --> API4
```

---

## 3. Automated Database Failover Mechanics

### Failover Timeline & Recovery Objectives
- **RPO (Recovery Point Objective)**: **0 (Zero Data Loss)** when configured with `synchronous_commit: on`. Every client transaction must be acknowledged in WAL on both nodes before committing.
- **RTO (Recovery Time Objective)**: **$\approx 8 - 12\,\text{seconds}$** for complete automated database failover, leader promotion, and connection redirection.

```
T + 0.0s ─── app1 VM suffers catastrophic hardware failure.
T + 2.0s ─── Patroni heartbeat on app1 fails.
T + 10.0s ── etcd leader key lease expires (TTL = 10s).
T + 10.2s ── Patroni on app2 wins leader election lock in etcd.
T + 10.5s ── Patroni runs 'pg_ctl promote' on app2; PostgreSQL exits recovery mode.
T + 10.6s ── app2 Patroni REST API returns HTTP 200 on 'GET /primary'.
T + 11.5s ── HAProxy health check (inter 1500ms) marks app2:5432 as UP in 'pg_write_pool'.
T + 11.6s ── Express API instances resume writing transactions to new primary on app2.
```

---

## 4. Patroni REST API & HAProxy Integration

Patroni provides an embedded HTTP REST API on port `8008`:
- `GET /primary` (or `/master`): Returns **HTTP 200 OK** if the node is the current writeable primary; returns **HTTP 503 Service Unavailable** if it is a standby replica.
- `GET /replica`: Returns **HTTP 200 OK** if the node is a read-only streaming standby.

### HAProxy Database Pool Configuration
```haproxy
# ------------------------------------------------------------------------------
# PostgreSQL High-Availability Write Pool (Port 5000)
# Routes write queries exclusively to whichever node Patroni marks as primary
# ------------------------------------------------------------------------------
frontend pg_write_front
    bind *:5000
    mode tcp
    default_backend pg_write_back

backend pg_write_back
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server check port 8008 inter 1500ms fall 2 rise 2
    server app1_pg 192.168.56.20:5432 check
    server app2_pg 192.168.56.21:5432 check
```
