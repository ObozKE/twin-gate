# Cluster Troubleshooting, Split-Brain & Hardening Guide

This document covers operational failure modes, diagnostic procedures, and mitigations for the HA RHEL cluster.

---

## 1. The Split-Brain Condition: Diagnosis & Prevention

### What is VRRP Split-Brain?
Split-brain occurs when both `lb1` and `lb2` simultaneously believe they are the active `MASTER`. Both nodes assign `192.168.56.10` to their network interfaces and broadcast conflicting Gratuitous ARPs. 

**Observable symptoms:**
- Clients experience intermittent TCP connection resets (`ECONNRESET`).
- Ping to the VIP displays duplicate or flapping responses with alternating MAC addresses.
- Roughly 50% of client traffic lands on `lb1` and 50% lands on `lb2`.

### Simulating Split-Brain (Controlled Lab Test)
To simulate split-brain, block VRRP multicast traffic on `lb2` using `iptables`:
```bash
# On lb2: Block incoming VRRP (IP Protocol 112)
sudo iptables -I INPUT -p 112 -j DROP
```
**Observation:**
- `lb2` stops receiving heartbeats from `lb1`.
- After `1.083s`, `lb2` transitions from `BACKUP` to `MASTER`.
- Run `ip -br addr show` on both nodes: both will show `192.168.56.10/24`.

**Recovery:**
```bash
# On lb2: Remove the drop rule
sudo iptables -D INPUT -p 112 -j DROP
```
Because `lb1` is priority 150 and `lb2` is priority 100, `lb2` instantly yields mastership back to `lb1` and releases the VIP.

### Production Mitigations against Split-Brain
1. **Firewalld Protocol 112 Allow**: Firewalld must explicitly permit VRRP protocol globally:
   ```bash
   sudo firewall-cmd --permanent --zone=public --add-protocol=vrrp
   sudo firewall-cmd --reload
   ```
2. **Unicast Peer Fallback**: If VMware Workstation virtual switches drop multicast (`224.0.0.18`), configure Keepalived to use point-to-point unicast in `/etc/keepalived/keepalived.conf`:
   ```conf
   unicast_src_ip 192.168.56.11
   unicast_peer {
       192.168.56.12
   }
   ```
3. **Prometheus Split-Brain Alert**: An alert rule triggers immediately if both nodes export `vrrp_state{state="MASTER"} == 1` simultaneously.

---

## 2. SELinux Denials (AVC) & Remediation

SELinux remains in strict **Enforcing** mode across all cluster nodes.

### Diagnostic Command
Search the Linux audit log for recent Access Vector Cache (AVC) denials:
```bash
sudo ausearch -m avc -ts recent
```

### Potential Failure Modes & Exact Remediations

| Failure Mode | Audit Error | Cause | Remediation |
|---|---|---|---|
| **HAProxy Backend Connect** | `comm="haproxy" ... name="8081" ... scontext=...haproxy_t` | HAProxy is blocked from connecting to non-standard HTTP ports `8081` & `8082`. | `sudo setsebool -P haproxy_connect_any 1` |
| **Keepalived Script Exec** | `comm="keepalived" ... name="check_haproxy.sh" ... denied { execute }` | Keepalived security policy rejects script execution without proper permissions. | Set `enable_script_security` and `script_user root` in `global_defs`; run `chmod 755 /usr/local/bin/*.sh`. |
| **Podman Volume Write** | `comm="postgres" ... name="data" ... denied { write }` | Rootless container unable to write to host persistent storage directory. | Append `:Z` to volume flag: `-v pg_data:/var/lib/postgresql/data:Z`. |

---

## 3. Windows Host ARP Cache & VMware vSwitch Latency

When testing from a Windows host, the Windows TCP/IP stack caches IP-to-MAC associations.

### Diagnosing Stale Windows ARP Entries
Open an elevated PowerShell prompt on the Windows host:
```powershell
# Check current ARP entry for the VIP
arp -a 192.168.56.10

# Compare with physical MAC addresses of lb1 and lb2
# (Run 'ip link' on lb1 and lb2)
```

### Remediation
If Windows fails to update its ARP table within 1 second of failover:
1. Ensure Keepalived has `vrrp_garp_master_repeat 5` and `vrrp_garp_master_refresh 5`.
2. Clear the Windows ARP table manually during debugging:
   ```powershell
   arp -d 192.168.56.10
   ```

---

## 4. Verification & Diagnostic Commands Matrix

```bash
# 1. View active VIP assignment on the local interface
ip -4 -br addr show

# 2. Inspect real-time Keepalived transition logs with millisecond timestamps
journalctl -u keepalived -f

# 3. Inspect custom notification script execution in journald
journalctl -t keepalived-notify -n 30 --no-pager

# 4. View machine-readable state
cat /var/run/keepalived-state.json

# 5. Check HAProxy process and socket liveness
systemctl status haproxy
ss -tulpn | grep -E '8080|8404'
```
