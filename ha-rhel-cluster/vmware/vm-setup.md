# VMware Workstation Pro & Base OS Setup Guide

This guide details the exact host and guest operating system configurations required to establish the four-node RHEL 9 high-availability cluster environment.

---

## 1. VMware Virtual Network Architecture (VMnet2)

To ensure multicast isolation and deterministic Gratuitous ARP (GARP) behavior, all cluster VMs connect to a dedicated virtual switch with NAT egress enabled.

### Virtual Network Editor Configuration (`vmnetcfg.exe`)
1. Open VMware Workstation Pro as Administrator.
2. Navigate to **Edit** > **Virtual Network Editor** > click **Change Settings**.
3. Click **Add Network...** and select `VMnet2` (or your chosen VMnet number).
4. Configure the network settings:
   - **Type**: **NAT (shared host's IP address with VMs)**
     *(Allows cluster nodes to download RPMs and pull OCI images while remaining strictly isolated on layer 2 from corporate/home LANs)*.
   - **Subnet IP**: `192.168.56.0`
   - **Subnet Mask**: `255.255.255.0`
   - **Connect a host virtual adapter to this network**: **Checked** (Enabled).
     *(Assigns `192.168.56.1` to the Windows host, enabling the Windows load test script to target the VIP)*.
   - **Use local DHCP service to distribute IP address to VMs**: **Unchecked** (Disabled).
     *(We use deterministic static IPs configured via `nmcli`)*.
5. Click **NAT Settings**:
   - **Gateway IP**: `192.168.56.2`
   - Click **OK**.
6. Click **Apply**, then **OK**.

---

## 2. VM Sizing & Provisioning Matrix

Deploy four virtual machines with **Red Hat Enterprise Linux 9 (x86_64)**:

| Parameter | `lb1` | `lb2` | `app1` | `mon1` |
|---|---|---|---|---|
| **Hostname** | `lb1.corp.internal` | `lb2.corp.internal` | `app1.corp.internal` | `mon1.corp.internal` |
| **IP Address** | `192.168.56.11` | `192.168.56.12` | `192.168.56.20` | `192.168.56.30` |
| **Virtual CPUs** | 1 vCPU | 1 vCPU | 2 vCPU | 2 vCPU |
| **Memory (RAM)** | 1024 MB | 1024 MB | 2560 MB | 2048 MB |
| **Virtual Disk** | 20 GB (Thin) | 20 GB (Thin) | 30 GB (Thin) | 30 GB (Thin) |
| **Network Adapter** | Custom (`VMnet2`) | Custom (`VMnet2`) | Custom (`VMnet2`) | Custom (`VMnet2`) |
| **Software Selection** | Minimal Install | Minimal Install | Minimal Install | Minimal Install |

> [!TIP]
> During OS installation, uncheck **kdump** in the installer summary. Disabling kdump reclaims ~160 MB of RAM per VM, reducing total host memory overhead.

---

## 3. RHEL 9 Subscription Registration

For RHEL 9, register using your free Red Hat Developer account.

### On Each VM (`lb1`, `lb2`, `app1`, `mon1`):
```bash
# Register with Red Hat Subscription Manager
sudo subscription-manager register --username="YOUR_REDHAT_USER" --password="YOUR_PASSWORD"

# Auto-attach the Developer subscription
sudo subscription-manager attach --auto

# Verify subscription status
sudo subscription-manager status

# Enable BaseOS and AppStream repositories
sudo subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms --enable=rhel-9-for-x86_64-appstream-rpms
```

> [!NOTE]
> **If using AlmaLinux 9 or Rocky Linux 9:** Skip the `subscription-manager` steps entirely. Repositories are active out of the box.

---

## 4. Static IP Assignment via NetworkManager (`nmcli`)

Replace `<IFACE>` with your detected interface (typically `ens33` or `ens160`). Run the corresponding block on each VM.

### On `lb1` (`192.168.56.11`):
```bash
export IFACE=$(ip -4 route show 2>/dev/null | awk '{print $5}' | head -n1 || echo "ens33")
sudo hostnamectl set-hostname lb1.corp.internal

sudo nmcli connection modify "$IFACE" \
  ipv4.method manual \
  ipv4.addresses 192.168.56.11/24 \
  ipv4.gateway 192.168.56.2 \
  ipv4.dns "192.168.56.2 8.8.8.8" \
  connection.autoconnect yes

sudo nmcli connection up "$IFACE"
```

### On `lb2` (`192.168.56.12`):
```bash
export IFACE=$(ip -4 route show 2>/dev/null | awk '{print $5}' | head -n1 || echo "ens33")
sudo hostnamectl set-hostname lb2.corp.internal

sudo nmcli connection modify "$IFACE" \
  ipv4.method manual \
  ipv4.addresses 192.168.56.12/24 \
  ipv4.gateway 192.168.56.2 \
  ipv4.dns "192.168.56.2 8.8.8.8" \
  connection.autoconnect yes

sudo nmcli connection up "$IFACE"
```

### On `app1` (`192.168.56.20`):
```bash
export IFACE=$(ip -4 route show 2>/dev/null | awk '{print $5}' | head -n1 || echo "ens33")
sudo hostnamectl set-hostname app1.corp.internal

sudo nmcli connection modify "$IFACE" \
  ipv4.method manual \
  ipv4.addresses 192.168.56.20/24 \
  ipv4.gateway 192.168.56.2 \
  ipv4.dns "192.168.56.2 8.8.8.8" \
  connection.autoconnect yes

sudo nmcli connection up "$IFACE"
```

### On `mon1` (`192.168.56.30`):
```bash
export IFACE=$(ip -4 route show 2>/dev/null | awk '{print $5}' | head -n1 || echo "ens33")
sudo hostnamectl set-hostname mon1.corp.internal

sudo nmcli connection modify "$IFACE" \
  ipv4.method manual \
  ipv4.addresses 192.168.56.30/24 \
  ipv4.gateway 192.168.56.2 \
  ipv4.dns "192.168.56.2 8.8.8.8" \
  connection.autoconnect yes

sudo nmcli connection up "$IFACE"
```

---

## 5. Global Host Resolution (`/etc/hosts`)

Append the cluster mappings to `/etc/hosts` across **all four nodes**:

```bash
sudo bash -c 'cat <<EOF >> /etc/hosts
192.168.56.10  vip.corp.internal vip
192.168.56.11  lb1.corp.internal lb1
192.168.56.12  lb2.corp.internal lb2
192.168.56.20  app1.corp.internal app1
192.168.56.30  mon1.corp.internal mon1
EOF'
```

---

## 6. Time Synchronization via Chrony (Sub-Millisecond Log Correlation)

During a sub-2-second failover, analyzing logs requires sub-millisecond clock synchronization across nodes. If node clocks drift by even 500ms, cross-referencing Keepalived state changes with client-side retry logs becomes unreliable.

### On All VMs:
Ensure Chrony is configured to aggressively step the clock on startup if drift exceeds 1 second:

```bash
# Verify chrony configuration contains makestep
sudo sed -i '/^makestep/d' /etc/chrony.conf
echo "makestep 1.0 3" | sudo tee -a /etc/chrony.conf

# Restart and enable chronyd
sudo systemctl restart chronyd
sudo systemctl enable chronyd

# Force immediate synchronization
sudo chronyc makestep

# Verify clock tracking and offset (< 5ms)
chronyc tracking
```
