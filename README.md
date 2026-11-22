# DHCP Server Setup and Management Toolkit (`dnsmasq`)

**Operating Systems Course Project**  
*Systems Programming & Network Administration Lab*  
*Target Platform: Ubuntu Linux (20.04 LTS, 22.04 LTS, 24.04 LTS)*  
*Repository: [https://github.com/munsidev/DHCP-Server.git](https://github.com/munsidev/DHCP-Server.git)*

---

## 1. Project Overview

The **DHCP Server Setup and Management Toolkit** is an automated, menu-driven Bash application designed to configure, validate, manage, and monitor a real Dynamic Host Configuration Protocol (DHCP) server on Ubuntu Linux using `dnsmasq`.

It bridges core Operating Systems concepts—protocol state machines, process isolation, socket binding, daemon lifecycle, inter-process communication, and resource allocation—with practical, defensive systems engineering.

### Key Capabilities
- **Dual Demonstration Tracks**:
  - **Track A (1-VM Demo Mode)**: Uses Linux Network Namespaces (`ip netns`) and virtual ethernet (`veth`) cables to simulate a real client and server with a **live DORA handshake on a single machine**, without touching your internet connection.
  - **Track B (Real Multi-Machine Mode)**: Full setup for an isolated physical lab switch or a 2-VM hypervisor environment (VirtualBox, VMware, KVM).
- **Automated Pre-Flight Diagnostics**: Inspects Ubuntu releases, root/sudo execution rights, required utilities (`iproute2`, `systemctl`), and detects existing socket conflicts on UDP port 67 (DHCP) and UDP port 53 (DNS).
- **Pure-Bash IP Mathematics**: Validates IPv4 dotted-quad syntax, verifies contiguous netmask bitmasks, computes network/broadcast boundaries, and calculates CIDR prefixes without using external binaries or unsafe `eval`.
- **Server IP Anti-Overlap Invariant**: Automatically calculates network boundaries and strictly rejects configuration if the server's own static IP falls inside the dynamically allocated client pool.
- **Port 53 Conflict Resolution**: Injects `port=0` to run purely as a DHCP daemon, completely avoiding port collisions with Ubuntu's default `systemd-resolved` service.
- **Safe Modular Configuration**: Keeps project settings isolated in `/etc/dnsmasq.d/dhcp-toolkit.conf`. Monolithic system files (`/etc/dnsmasq.conf`) and unrelated services remain completely untouched.
- **Atomic Backups & Safe Teardown**: Creates timestamped backups (`.bak.<timestamp>`) before any write, enforces syntax validation (`dnsmasq --test`) before reloads, and provides a 1-click surgical rollback option.
- **Non-Destructive Dry-Run Engine**: Allows review and testing of configuration staging, syntax checks, and systemd service commands without root access or system modifications.

---

## 2. Critical Safety Notice: Rogue DHCP Hazard

> [!CAUTION]
> **DO NOT DEPLOY THIS TOOLKIT ON PUBLIC, CAMPUS, OFFICE, OR HOME WI-FI NETWORKS.**

### Understanding Rogue DHCP Disruption
The DHCP protocol operates via unauthenticated UDP broadcasts (`255.255.255.255` across ports 67 and 68). In any shared ethernet broadcast domain:
1. **Broadcast Race Conditions**: When client devices send a `DHCPDISCOVER` packet, all DHCP servers on the broadcast domain reply with a `DHCPOFFER`. Clients typically accept the fastest reply.
2. **IP Collisions & Blackholes**: If an unauthorized server issues IP addresses from an incompatible subnet or with a non-existent gateway, legitimate computers will immediately lose intranet and internet connectivity.
3. **Man-In-The-Middle (MitM)**: Offering a rogue default gateway or DNS resolver allows an attacker to intercept, inspect, or tamper with outbound user traffic.

### Built-in Safety Interlocks
The toolkit includes automatic safeguards:
- Scans for active wireless interfaces (`wl*`, `wlan*`, `/sys/class/net/*/wireless`) and warns of severe disruption. Live activation requires typing `CONFIRM-ISOLATED-LAB`.
- Detects whether the selected interface carries the host's default internet route.
- Probes UDP port 67 before startup to prevent collisions with pre-existing DHCP daemons.

---

## 3. Demonstration Track A: 1-VM Quick Live Demo for Your Professor (Recommended)

*Use this track if you have only **one Ubuntu machine or VM** and want to demonstrate a real client receiving a real IP address live, with zero risk to your Wi-Fi or internet connection.*

### How It Works
Linux provides built-in kernel isolation primitives called **Network Namespaces (`ip netns`)**—the core technology underpinning Docker and Kubernetes. The included [`demo-lab.sh`](file:///Users/macbook/Documents/DHCP-Server/demo-lab.sh) script creates two isolated namespaces (`server_ns` and `client_ns`) connected by a virtual ethernet cable (`veth-srv` $\leftrightarrow$ `veth-clt`).

```
+-------------------------------------------------------------------------+
|                         SINGLE UBUNTU MACHINE                           |
|                                                                         |
|   +-----------------------+              +-----------------------+      |
|   |   Server Namespace    |              |   Client Namespace    |      |
|   |      (server_ns)      |              |      (client_ns)      |      |
|   |                       |              |                       |      |
|   |  dhcp-toolkit.sh      |              |  dhclient / udhcpc    |      |
|   |  (dnsmasq on UDP 67)  |              |  (DHCP Client)        |      |
|   |                       |              |                       |      |
|   |  Interface: veth-srv  |<============>|  Interface: veth-clt  |      |
|   |  Static IP:           | Virtual VETH |  Assigned IP:         |      |
|   |  192.168.50.1/24      | Cable Pair   |  192.168.50.42/24     |      |
|   +-----------------------+              +-----------------------+      |
|                                                                         |
|   [Host Physical / Wi-Fi Adapter (PCI Ethernet) - 100% UNTOUCHED]       |
+-------------------------------------------------------------------------+
```

---

### Method A1: 1-Command All-In-One Live Demo

In your terminal:
```bash
cd DHCP-Server
sudo ./demo-lab.sh demo
```

**What happens automatically:**
1. Creates the isolated virtual cable (`veth-srv` $\leftrightarrow$ `veth-clt`).
2. Configures and starts the DHCP server on `192.168.50.1`.
3. Triggers the client to request an IP over the virtual cable.
4. Outputs the real-time **DORA Handshake** on your screen.
5. Prints the assigned IP address and displays the active lease table!

---

### Method A2: Interactive 2-Terminal Live Walkthrough

For an in-depth demonstration where you show the menu interface to your professor:

#### Terminal 1 — Start the Server:
```bash
cd DHCP-Server
# 1. Start the virtual network cable
sudo ./demo-lab.sh start

# 2. Launch the menu inside the server namespace
sudo ./demo-lab.sh server
```
Inside the interactive menu:
1. Select **Option 2** $\to$ Choose the virtual interface `veth-srv`.
2. Select **Option 3** $\to$ Run the Configuration Wizard:
   - Server IP: `192.168.50.1` (Netmask: `255.255.255.0`)
   - Pool Start: `192.168.50.10`
   - Pool End: `192.168.50.50`
   - Lease Duration: `12h`
   - Default Gateway: `192.168.50.1`
   - DNS Server: `8.8.8.8`
   - Save configuration: `yes`
3. Select **Option 5** $\to$ Validate syntax with `dnsmasq --test`.
4. Select **Option 6** $\to$ Start the DHCP service!

#### Terminal 2 — Request IP from the Client:
Open a second terminal window and run:
```bash
sudo ./demo-lab.sh client
```

#### What You and Your Professor Will See (Live DORA Handshake):
```text
=== Requesting Real IP Address from Client Namespace ===
Triggering DHCP DORA transaction over virtual cable...

Listening on LPF/veth-clt/aa:73:65:22:4a:55
Sending on   LPF/veth-clt/aa:73:65:22:4a:55
DHCPDISCOVER on veth-clt to 255.255.255.255 port 67 interval 3
DHCPOFFER of 192.168.50.42 from 192.168.50.1
DHCPREQUEST for 192.168.50.42 on veth-clt to 255.255.255.255 port 67
DHCPACK of 192.168.50.42 from 192.168.50.1
bound to 192.168.50.42 -- renewal in 20509 seconds.

[SUCCESS] Client DHCP request completed!

--- Current Isolated Lab Network Status ---
[Server Namespace: server_ns]
veth-srv@if6     UP             192.168.50.1/24

[Client Namespace: client_ns]
veth-clt@if7     UP             192.168.50.42/24
Assigned Routes:
default via 192.168.50.1 dev veth-clt 
192.168.50.0/24 dev veth-clt proto kernel scope link src 192.168.50.42
```

#### Terminal 1 — Inspect Active Leases:
Return to Terminal 1 and select **Option 7** in the toolkit menu:
- The formatted table will show the client's MAC address, allocated IP `192.168.50.42`, and expiration time parsed directly from `/var/lib/misc/dnsmasq.leases`.

#### Clean Up When Finished:
```bash
sudo ./demo-lab.sh stop
```
*Deletes the virtual namespaces and returns your machine to its original state.*

---

## 4. Demonstration Track B: Real Multi-Machine / 2-VM Lab Setup

*Use this track if your course requires two separate virtual machines or physical PCs connected over an isolated lab switch.*

### Step 1: Hypervisor Network Setup (VirtualBox / VMware / UTM)
1. **Server Machine (Ubuntu 20.04/22.04/24.04)**:
   - Go to VM **Settings $\to$ Network $\to$ Adapter 2**.
   - Enable the adapter and set "Attached to" to **Host-Only Network** (e.g., `vboxnet0`) or **Internal Network** (`os-dhcp-lab`).
2. **Client Machine (Ubuntu / Debian / Alpine)**:
   - Set its primary network adapter to the **exact same Host-Only or Internal Network**.
   - Ensure Adapter 1 (NAT/Wi-Fi) is disabled or detached on the client so it only requests DHCP over the lab link.

---

### Step 2: Configure Server Static IP via Netplan (Server VM)
A DHCP server cannot use dynamic addressing on its serving interface.

In your Server VM terminal, create or edit `/etc/netplan/01-lab-dhcp.yaml`:
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s8:  # Replace with your lab interface name (find using: ip link)
      dhcp4: no
      addresses:
        - 192.168.50.1/24
```
Apply the network settings:
```bash
sudo netplan apply
```
*(Alternatively, configure manually via Ubuntu Settings $\to$ Network $\to$ Gear Icon $\to$ IPv4 $\to$ Manual: `192.168.50.1`, Netmask: `255.255.255.0`)*

---

### Step 3: Run the Toolkit on the Server Machine
```bash
cd DHCP-Server
chmod +x dhcp-toolkit.sh
sudo ./dhcp-toolkit.sh
```
1. Select **Option 1**: Run pre-flight diagnostics to verify tools, privileges, and ports.
2. Select **Option 2**: Choose your configured static interface (e.g., `enp0s8`).
3. Select **Option 4**: Install `dnsmasq` if not already installed (confirms command before running).
4. Select **Option 3**: Configure DHCP parameters:
   - Server IP: `192.168.50.1` (Netmask: `255.255.255.0`)
   - Pool Start: `192.168.50.10`
   - Pool End: `192.168.50.100`
   - Lease Duration: `12h`
   - Default Gateway: `192.168.50.1`
   - DNS Servers: `8.8.8.8,1.1.1.1`
   - Save configuration: `yes`
5. Select **Option 5**: Validate syntax (`dnsmasq --test`).
6. Select **Option 6**: Start the DHCP service!

---

### Step 4: Request a Lease on the Client Machine
On the separate Client VM / physical client:
```bash
# Release any existing lease:
sudo dhclient -r enp0s3

# Request a new lease with verbose output:
sudo dhclient -v -1 enp0s3
```
You will observe the live DORA packets:
```text
DHCPDISCOVER on enp0s3 to 255.255.255.255 port 67
DHCPOFFER of 192.168.50.10 from 192.168.50.1
DHCPREQUEST for 192.168.50.10 on enp0s3 to 255.255.255.255 port 67
DHCPACK of 192.168.50.10 from 192.168.50.1
bound to 192.168.50.10 -- renewal in 21600 seconds.
```

---

### Step 5: Verify the Lease on Both Machines
- **On the Client**: Run `ip addr show enp0s3` and `ip route show` to confirm IP `192.168.50.10` and default route `192.168.50.1`.
- **On the Server**: Select **Option 7** in the toolkit menu to view the live lease table recorded in `/var/lib/misc/dnsmasq.leases`.

---

### Step 6: Safe Teardown & Clean Rollback
When finished testing:
1. In the toolkit menu, choose **Option 10** (`Remove Project Configuration & Clean Up`).
2. Type `yes` to confirm.
3. The toolkit stops the daemon, unlinks `/etc/dnsmasq.d/dhcp-toolkit.conf`, restores any previous backup, and preserves all other system files.

---

## 5. Built-In Testing & Simulation Modes

The toolkit includes non-destructive command-line modes for code inspection and grading:

### 1. Pure-Bash IP Mathematics Self-Tests
Verify that all IP arithmetic, 32-bit bitshifts, contiguous netmask checks, and overlap detection functions pass without errors:
```bash
./dhcp-toolkit.sh --test-math
```

### 2. Pre-Flight Diagnostics Check
Scan the environment, check sudo access, verify network tools, and audit UDP socket bindings:
```bash
./dhcp-toolkit.sh --check
```

### 3. Non-Destructive Dry-Run Mode
Simulate the full menu, configure parameters, and review staged configuration in a local preview file without touching `/etc` or running system services:
```bash
./dhcp-toolkit.sh --dry-run
```

---

## 6. Menu-Driven Toolkit Reference

| Option | Name | Description |
|---|---|---|
| **[1]** | **Pre-flight Diagnostics** | Audits Ubuntu release version, tool availability (`ip`, `ss`, `grep`), sudo rights, and scans ports 67 and 53 for socket conflicts. |
| **[2]** | **Select Network Interface** | Discovers non-loopback adapters, shows IP/CIDR and MAC address. Triggers safety confirmation if Wi-Fi or default gateway route is detected. |
| **[3]** | **Configure DHCP Settings** | Interactive wizard for subnet mask, IP range, lease duration, gateway (Option 3), DNS (Option 6), and domain (Option 15). Enforces server IP anti-overlap invariant. |
| **[4]** | **Install / Verify dnsmasq** | Displays the exact `apt-get` installation command and requests explicit confirmation before package installation. |
| **[5]** | **Validate Configuration Syntax** | Runs `dnsmasq --test --conf-file=...` to verify configuration validity without restarting services. |
| **[6]** | **Start / Restart DHCP Service** | Enforces syntax validation gate first, then safely reloads/restarts the service via `systemctl` or direct process in namespaces. |
| **[7]** | **View Status & Active Leases** | Displays service active state, port 67 socket binding, and formatted lease table from `/var/lib/misc/dnsmasq.leases` with human-readable timestamps. |
| **[8]** | **Stop DHCP Service** | Gracefully stops the DHCP server daemon. |
| **[9]** | **View Staged Configuration** | Displays the active or staged `/etc/dnsmasq.d/dhcp-toolkit.conf` file. |
| **[10]** | **Safe Project Teardown** | Prompts for confirmation, stops the service, deletes **only** `dhcp-toolkit.conf`, and offers to restore the previous backup. |
| **[11]** | **Firewall & Netplan Guidance** | Details UDP ports 67/68, displays Netplan static IP configuration snippets, and offers to add a targeted UFW firewall rule. |
| **[12]** | **Toggle Dry-Run Mode** | Switches runtime mode between live system operations and simulated preview execution. |
| **[13]** | **Run Built-In Self-Tests** | Executes the automated test suite for IPv4 validation, integer math, and boundary enforcement. |
| **[0]** | **Exit Toolkit** | Exits cleanly. |

---

## 7. Command-Line Flags

| Flag | Long Option | Description |
|---|---|---|
| `-h` | `--help` | Show CLI flag summary and safety guidelines |
| `-d` | `--dry-run` | Launch the toolkit in dry-run simulation mode |
| `-c` | `--check` | Run system diagnostics and pre-flight checks, then exit |
| `-s` | `--status` | Show systemd service status, listening sockets, and active leases |
| `-v` | `--validate` | Validate syntax of existing dnsmasq configuration |
| `-t` | `--test-math` | Run automated self-tests for IP math and safety rules |
| `-V` | `--version` | Display toolkit version |

---

## 8. Defensive Engineering Highlights

### 1. Pure-Bash 32-Bit Arithmetic
To maintain compatibility across all bash environments without relying on external python, perl, or bc binaries, IP addresses are converted to 32-bit integers using arithmetic bit-shifts:
$$\text{ip\_int} = (o_1 \ll 24) + (o_2 \ll 16) + (o_3 \ll 8) + o_4$$
Contiguous netmask verification checks that inverted bits plus one equals a single set bit:
$$(({\sim}\text{mask\_int} + 1) \ \& \ {\sim}\text{mask\_int}) == 0$$

### 2. Server IP Anti-Overlap Invariant
Allocating the server's own IP address causes catastrophic ARP conflicts and severs communication with all clients. The toolkit enforces:
$$\text{server\_ip\_int} \ge \text{start\_ip\_int} \quad \land \quad \text{server\_ip\_int} \le \text{end\_ip\_int}$$
If this evaluates to true, the configuration wizard halts and requires the administrator to select a range that excludes the server.

### 3. Conflict Avoidance with `systemd-resolved`
Ubuntu 20.04+ runs `systemd-resolved` on `127.0.0.53:53`. Attempting to start a standard DNS daemon causes an `Address already in use` fatal crash. This toolkit automatically adds `port=0` to `/etc/dnsmasq.d/dhcp-toolkit.conf`, disabling the DNS listener and configuring `dnsmasq` to run strictly as a lightweight DHCP daemon.

### 4. Zero `eval` Policy & Strict Scripting Standards
The code adheres to defensive shell best practices:
- Zero occurrences of `eval`.
- Mandatory variable quoting.
- Explicit `set -euo pipefail` error handling.
- ANSI escape stripping from log files to prevent log-injection vulnerabilities.

---

## 9. Firewall (UFW) Configuration Reference

If Ubuntu's Uncomplicated Firewall (UFW) is active:
```bash
# Allow DHCP discovery and request packets from clients on the lab interface:
sudo ufw allow in on enp0s8 to any port 67 proto udp comment 'DHCP Server Lab'

# Optional: If DNS forwarder is enabled on lab interface:
sudo ufw allow in on enp0s8 to any port 53 comment 'Lab DNS'
```

---

## 10. Professor Presentation Cheat Sheet

Use these concise, technical answers when explaining the project to your instructor:

| Question | Winning Answer |
|---|---|
| **"Why did you use `dnsmasq` instead of `isc-dhcp-server`?"** | *"ISC-DHCP-Server reached end-of-life (EOL) in 2022. `dnsmasq` is standard on modern Ubuntu, actively maintained, lightweight, and supports modular configuration directories."* |
| **"How did you avoid port 53 clashes with `systemd-resolved`?"** | *"Ubuntu runs `systemd-resolved` on `127.0.0.53:53`. In `/etc/dnsmasq.d/dhcp-toolkit.conf`, I explicitly inject `port=0` so `dnsmasq` operates purely as a DHCP daemon without binding to DNS port 53."* |
| **"Why is a rogue DHCP server dangerous?"** | *"DHCP operates via broadcast. A rogue server answering `DHCPDISCOVER` faster than legitimate routers can inject an invalid subnet (causing denial of service) or inject its own IP as default gateway to execute a Man-in-the-Middle attack."* |
| **"How did you demonstrate client allocation on a single VM?"** | *"I used Linux Network Namespaces (`ip netns`) and virtual ethernet (`veth`) pairs. This leverages the Linux kernel's process isolation primitives to create an air-gapped broadcast domain on a single machine."* |
| **"What happens during lease renewal ($T_1$) vs rebinding ($T_2$)?"** | *"At $T_1$ (50% of lease time), the client unicasts a `DHCPREQUEST` to the original server. If no response is received by $T_2$ (87.5%), it broadcasts `DHCPREQUEST` to any available server on the subnet."* |

---

## 11. Project File Manifest

```
DHCP-Server/
├── dhcp-toolkit.sh        # Main interactive menu-driven Bash toolkit
├── demo-lab.sh            # 1-VM Network Namespace demonstration assistant
├── README.md              # Complete technical documentation & setup guides
├── report-outline.md      # Academic course report outline
├── test-plan.md           # 34-test verification plan & test reporting matrix
└── .gitignore             # Ignores runtime logs, leases, previews, and backups
```
