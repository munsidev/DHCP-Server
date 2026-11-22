# DHCP Server Setup and Management Toolkit (`dnsmasq`)

**Operating Systems Course Project**  
*Systems Programming and Network Administration Lab*  
*Target Environment: Ubuntu Linux (20.04 LTS, 22.04 LTS, 24.04 LTS)*

---

## 1. Project Overview

The **DHCP Server Setup and Management Toolkit** is a robust, menu-driven Bash application designed to configure, validate, manage, and monitor an isolated Dynamic Host Configuration Protocol (DHCP) server on Ubuntu Linux using `dnsmasq`.

The toolkit bridges theoretical Operating Systems concepts—such as protocol state machines, inter-process communication, network socket management, daemon control, and resource allocation—with practical, defensive systems engineering.

### Key Capabilities
- **Automated Environment Diagnostics**: Inspects Ubuntu distribution releases, sudo administrative rights, required networking utilities (`iproute2`, `systemctl`), and detects existing socket conflicts on UDP port 67 (DHCP) and UDP port 53 (DNS).
- **Interactive Interface Inspection**: Discovers all non-loopback network adapters, displays current IPv4 addresses, subnet masks, and interface states, and alerts the administrator if a static IP is missing.
- **Defensive Configuration Wizard**:
  - Validates IPv4 address syntaxes and CIDR boundaries.
  - Ensures pool consistency within the server's subnet.
  - **Enforces Server IP Anti-Overlap**: Rejects configuration if the server's own static IP falls within the dynamically allocated client pool.
  - Configures customizable lease lifetimes, optional default gateways (Option 3), and DNS resolvers (Option 6).
- **Conflict Avoidance Architecture**:
  - Automatically isolates configuration in `/etc/dnsmasq.d/dhcp-toolkit.conf`.
  - Disables the DNS listener (`port=0`) when running purely as a DHCP service to prevent socket binding collisions with Ubuntu's default `systemd-resolved` service.
- **Safe Lifecycle Management**:
  - Atomic backups of configuration files prior to modifications (`.bak.<timestamp>`).
  - Pre-flight syntax validation using `dnsmasq --test` before touching live system services.
  - Surgical teardown: removes only project-managed settings, leaving existing system services and other configurations untouched.
- **Dry-Run Planning Engine**: Complete simulation mode allowing risk-free review of configuration staging, syntax checks, and systemd commands without root privileges or system modifications.

---

## 2. Critical Safety Notice: Rogue DHCP Hazard

> [!CAUTION]
> **DO NOT DEPLOY THIS TOOLKIT ON PUBLIC, CAMPUS, OFFICE, OR HOME WI-FI NETWORKS.**

### Understanding Rogue DHCP Disruption
The DHCP protocol operates via unauthenticated UDP broadcasts (`255.255.255.255` across port 67/68). In an ethernet broadcast domain:
1. **Race Conditions**: When client machines send a `DHCPDISCOVER` packet, all DHCP servers on the broadcast domain reply with a `DHCPOFFER`. The client typically accepts the first offer received.
2. **IP Collisions & Routing Blackholes**: If an unauthorized server offers IP addresses from an incompatible subnet or with a non-existent default gateway, legitimate client computers will lose internet/intranet access immediately.
3. **Man-In-The-Middle (MitM)**: Offering a rogue gateway or rogue DNS server allows an adversary to hijack and inspect all outbound network traffic.

### Authorized Usage Scope
This project is strictly designed for:
- Isolated virtual machine networks (e.g., VirtualBox **Host-Only** or **Internal Network**, VMware **LAN Segment**, KVM isolated bridge).
- Linux network namespaces (`ip netns`).
- Air-gapped physical lab switch segments where you have been explicitly authorized by faculty or network administrators.

The toolkit includes an automated safety interlock: if a wireless interface (`wl*`, `wlan*`) or an interface holding the default internet route is selected, live operations are blocked unless an explicit authorization phrase (`CONFIRM-ISOLATED-LAB`) is entered.

---

## 3. System Requirements & Architecture

### Prerequisites
- **Operating System**: Ubuntu Linux 20.04 LTS (Focal), 22.04 LTS (Jammy), or 24.04 LTS (Noble).
- **Core Utility**: `dnsmasq` and `dnsmasq-base` (can be installed interactively via Option 4 of the toolkit).
- **System Tools**: `iproute2` (`ip`), `systemd` (`systemctl`), `ss` or `lsof`, `grep`, `sed`, `awk`.
- **Privileges**: Standard user with `sudo` permissions or root (`EUID 0`).

### Configuration Architecture
Rather than overwriting the monolithic `/etc/dnsmasq.conf`, this toolkit adopts Debian/Ubuntu's modular configuration directory pattern:

```
/etc/
├── dnsmasq.conf                 <-- Preserved untouched (ensures conf-dir=/etc/dnsmasq.d is loaded)
└── dnsmasq.d/
    ├── README                   <-- System documentation
    ├── other-services.conf      <-- Preserved untouched
    ├── dhcp-toolkit.conf        <-- MANAGED EXCLUSIVELY BY THIS TOOLKIT
    └── dhcp-toolkit.conf.bak.*  <-- Timestamped backups created before any modification
```

---

## 4. Quick Start Guide

### Step 1: Clone / Download and Set Permissions
```bash
cd ~/Documents/DHCP-Server
chmod +x dhcp-toolkit.sh
```

### Step 2: Run Built-In Self-Tests
Verify that bash mathematical routines, subnet calculators, and overlap checks pass:
```bash
./dhcp-toolkit.sh --test-math
```

### Step 3: Run Pre-Flight Diagnostics
Inspect the system environment, port bindings, and tool readiness:
```bash
./dhcp-toolkit.sh --check
```

### Step 4: Launch Interactive Menu in Dry-Run Mode
Simulate operations without touching `/etc`:
```bash
./dhcp-toolkit.sh --dry-run
```

### Step 5: Launch Live Interactive Menu
When operating in an authorized Ubuntu lab environment:
```bash
./dhcp-toolkit.sh
```

---

## 5. Menu-Driven Interface Guide

Upon launching `./dhcp-toolkit.sh`, the interactive main menu is presented:

```
================================================================================
           DHCP SERVER SETUP & MANAGEMENT TOOLKIT (dnsmasq)
             Operating Systems Course Project - Lab Edition
================================================================================

Active Configuration Context:
  Interface:      [Not Selected]
  Server IP:      [None]
  DHCP Pool:      None - None
  Dry-Run Mode:   DISABLED (Live System)

Main Menu Operations:
  [1]  Run Pre-flight Diagnostics (OS, Tools, Sudo, Port Conflicts)
  [2]  Select Network Interface & Inspect Details
  [3]  Configure DHCP Server Settings (Pool, Leases, Gateway, DNS)
  [4]  Install / Verify dnsmasq Package
  [5]  Validate Configuration File Syntax (dnsmasq --test)
  [6]  Start / Restart DHCP Service
  [7]  View DHCP Service Status & Active Leases
  [8]  Stop DHCP Service
  [9]  View Staged / Active Configuration File
  [10] Remove Project Configuration & Clean Up (Safe Teardown)
  [11] Review Firewall (UFW) and Netplan Guidance
  [12] Toggle Dry-Run Mode
  [13] Run Built-In Self-Tests (IP Math & Validation)
  [0]  Exit Toolkit
```

### Walkthrough of Operations

#### Option 1: Pre-flight Diagnostics
Checks whether the host is running Ubuntu, verifies `sudo` access, checks for installed utilities, and examines UDP port 67 and UDP port 53. If port 67 is already bound, it warns that another DHCP service (like `isc-dhcp-server` or `kea`) is active.

#### Option 2: Select Network Interface
Scans for non-loopback network adapters (e.g., `eth0`, `ens33`, `enp0s3`, `veth*`), displays their current IPv4 address, netmask, and type. If an interface lacks a static IP, the toolkit warns that DHCP servers require a static IP address on the serving interface.

#### Option 3: Configure DHCP Server Settings
Guides the administrator through setting:
- **Server Static IP & Netmask**: Automatically derived from the chosen interface or entered manually.
- **Subnet Boundary Display**: Calculates Network Address, Broadcast Address, and First/Last Usable host addresses.
- **DHCP Pool Start & End IP**: Enforces that the range resides within the subnet and **verifies that the server's own IP does not overlap with the pool**.
- **Lease Duration**: Validates formats such as `12h`, `24h`, `7d`, `45m`, or `infinite`.
- **Default Gateway (Router Option 3)**: Optional gateway IP; validated to ensure it belongs to the same subnet.
- **DNS Servers (Option 6)**: Comma-separated list of valid IPv4 addresses (e.g., `8.8.8.8,1.1.1.1`).
- **Domain Name (Option 15)**: Optional local search domain (e.g., `oslab.local`).

#### Option 4: Install / Verify `dnsmasq`
Displays the exact `apt-get` command that will be executed and asks for explicit confirmation before installing packages. Reinstallation is skipped if already installed.

#### Option 5: Validate Configuration File Syntax
Executes `dnsmasq --test --conf-file=/etc/dnsmasq.d/dhcp-toolkit.conf`. Verifies syntax and configuration validity without starting or interrupting services.

#### Option 6: Start / Restart DHCP Service
First enforces a syntax test. If valid, restarts the `dnsmasq` service via `systemctl restart dnsmasq` and enables it for system startup.

#### Option 7: View DHCP Service Status & Active Leases
Displays:
1. `systemctl status dnsmasq` output.
2. Active UDP port 67 socket binding.
3. Formatted table of active client leases from `/var/lib/misc/dnsmasq.leases`:
   - Expiration date and time (converted from epoch to human-readable format).
   - Client MAC address.
   - Assigned IPv4 address.
   - Client hostname.
   - Client identifier (DUID/client ID).

#### Option 8: Stop DHCP Service
Stops the `dnsmasq` service cleanly using `systemctl stop dnsmasq`.

#### Option 9: View Staged Configuration File
Outputs the full contents of `/etc/dnsmasq.d/dhcp-toolkit.conf` (or the local preview file in dry-run mode).

#### Option 10: Safe Teardown & Clean Up
Stops the service, prompts for confirmation, deletes `/etc/dnsmasq.d/dhcp-toolkit.conf`, and offers to restore the previous backup if one exists. All other configuration files in `/etc/dnsmasq.d/` and `/etc/dnsmasq.conf` are left intact.

#### Option 11: Firewall (UFW) and Netplan Guidance
Explains protocol firewall requirements (UDP 67 incoming, UDP 68 outgoing). Displays sample Netplan configuration snippets for setting static IPs and allows applying the specific UFW rule upon confirmation.

#### Option 12: Toggle Dry-Run Mode
Toggles between live execution and simulated dry-run planning.

#### Option 13: Run Built-In Self-Tests
Executes unit tests for IPv4 validation, integer math conversion, contiguous netmask verification, CIDR calculations, subnet containment, and server IP overlap detection.

---

## 6. Command-Line Options

The toolkit can be operated non-interactively using CLI flags:

| Flag | Long Option | Description |
|---|---|---|
| `-h` | `--help` | Display usage instructions and exit |
| `-d` | `--dry-run` | Launch the toolkit in dry-run simulation mode |
| `-c` | `--check` | Run system diagnostics and pre-flight checks, then exit |
| `-s` | `--status` | Show systemd service status, listening sockets, and active leases |
| `-v` | `--validate` | Validate syntax of existing dnsmasq configuration |
| `-t` | `--test-math` | Run automated unit tests for IP mathematics and overlap checks |
| `-V` | `--version` | Display toolkit version |

---

## 7. Network Interface & Firewall Setup

### Setting a Static IP via Netplan
DHCP servers cannot function with a dynamic IP address. In Ubuntu, configure your lab adapter (e.g., `eth1` or `enp0s8`) with a static IP:

Create or edit `/etc/netplan/01-lab-dhcp.yaml`:
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s8:
      dhcp4: no
      addresses:
        - 192.168.50.1/24
```
Apply the configuration:
```bash
sudo netplan apply
```

### Configuring UFW Firewall
If Ubuntu's Uncomplicated Firewall (UFW) is active:
```bash
# Allow DHCP discovery and request packets from clients on lab interface:
sudo ufw allow in on enp0s8 to any port 67 proto udp comment 'DHCP Server Lab'

# Optional: If running DNS forwarder on lab interface:
sudo ufw allow in on enp0s8 to any port 53 comment 'Lab DNS'
```

---

## 8. Troubleshooting Guide

| Issue | Cause | Solution |
|---|---|---|
| **`dnsmasq: failed to bind DHCP server socket (Address already in use)`** | Another daemon (e.g., `isc-dhcp-server`, `kea`, or an older `dnsmasq` instance) is holding UDP port 67. | Run `./dhcp-toolkit.sh --check` to identify conflicting PIDs with `ss -ulpn`. Stop the competing service: `sudo systemctl stop isc-dhcp-server`. |
| **`failed to create listening socket for port 53: Address already in use`** | `systemd-resolved` is listening on `127.0.0.53:53`. | The toolkit automatically includes `port=0` in `/etc/dnsmasq.d/dhcp-toolkit.conf` to disable the DNS listener when only DHCP is needed. |
| **`Server IP overlap detected!`** | The proposed DHCP start-end range contains the server's own static IP address. | Adjust the DHCP pool range so that the server IP is excluded (e.g., Server: `192.168.50.1`, Pool: `192.168.50.10` to `192.168.50.100`). |
| **Client machines not receiving leases** | 1. Interface is DOWN.<br>2. Client and server are not on the same virtual switch/VLAN.<br>3. Firewall is dropping UDP 67 packets. | 1. Ensure `ip link set <iface> up`.<br>2. Verify hypervisor adapter settings (both VMs set to same Internal/Host-Only network).<br>3. Review firewall rules with `sudo ufw status`. |
| **Syntax validation failure** | Missing directive or corrupted configuration line. | Run Option 5 (`dnsmasq --test`) or inspect `/etc/dnsmasq.d/dhcp-toolkit.conf`. Restore previous backup using Option 10. |

---

## 9. Logging & Auditing

The toolkit maintains structured logs without storing sensitive information:
- **Root/Production Mode**: Logs are written to `/var/log/dhcp-toolkit.log`.
- **Non-Root / Dry-Run Mode**: Logs are written to `./dhcp-toolkit.log`.

Sample log entry:
```
[2026-11-22 17:30:42] [INFO] Generating dnsmasq configuration for interface eth0...
[2026-11-22 17:30:42] [SUCCESS] Configuration written to /etc/dnsmasq.d/dhcp-toolkit.conf
[2026-11-22 17:30:42] [INFO] Validating configuration file: /etc/dnsmasq.d/dhcp-toolkit.conf
[2026-11-22 17:30:42] [SUCCESS] Configuration syntax validation PASSED: syntax check OK.
```

---

## 10. Academic Integrity and Ethical Usage

This toolkit was developed for educational purposes as part of an Operating Systems curriculum. Setting up network services that intercept or manipulate network traffic without explicit authorization is illegal under computer misuse legislation and institutional policies. Always conduct testing inside an isolated virtual lab environment.
