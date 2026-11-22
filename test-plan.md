# Comprehensive Test Plan: DHCP Server Setup and Management Toolkit

**Project**: DHCP Server Setup and Management Toolkit (`dnsmasq`)  
**Operating Systems Course Project - Lab Verification Suite**  
**Target Platform**: Ubuntu Linux (20.04 LTS, 22.04 LTS, 24.04 LTS)  

---

## 1. Test Strategy & Safety Philosophy

### Scope
This test plan provides comprehensive, step-by-step verification procedures for the DHCP Toolkit. It evaluates static code quality, environment detection, pure-Bash IP mathematics, safety interlocks, configuration generation, service lifecycle, lease allocation, network option delivery, and clean teardown.

### Safety Invariants
- **Non-Destructive Development**: Development and local verification are restricted to static syntax checks, unit tests, and `--dry-run` simulation. No system packages, `/etc` files, network interfaces, or firewall rules are modified during offline development.
- **Strict Network Isolation**: All live DHCP testing must be conducted inside an isolated Virtual Machine network (Host-Only / Internal Switch) or inside dedicated Linux Network Namespaces (`ip netns`). Under no circumstances should tests be conducted on campus, home, or public Wi-Fi networks.

---

## 2. Test Environment Setup Options

### Environment Option A: Two Isolated Ubuntu Virtual Machines (Recommended for Course Grading)
1. **Hypervisor**: VirtualBox, VMware Workstation/Fusion, or KVM.
2. **Server VM**: Ubuntu 22.04 LTS (Desktop or Server).
   - Network Adapter 1: Host-Only Adapter (e.g., `vboxnet0`, subnet `192.168.50.0/24`) or Internal Network (`os-dhcp-lab`).
   - Static IP configured on Server VM: `192.168.50.1/24`.
3. **Client VM**: Ubuntu 22.04 LTS, Debian, or Alpine Linux.
   - Network Adapter 1: Attached to the identical Host-Only or Internal Network.
   - Configured to obtain an IPv4 address dynamically via DHCP.

### Environment Option B: Linux Network Namespaces (`ip netns`) on a Single Ubuntu Machine
For fast, zero-virtualization testing on a single Ubuntu instance without risk to physical adapters:

```bash
# 1. Create two isolated network namespaces: server_ns and client_ns
sudo ip netns add server_ns
sudo ip netns add client_ns

# 2. Create a virtual ethernet (veth) cable connecting them
sudo ip link add veth-srv type veth peer name veth-clt

# 3. Move the respective ends into the namespaces
sudo ip link set veth-srv netns server_ns
sudo ip link set veth-clt netns client_ns

# 4. Bring up loopback and assign static IP to server interface
sudo ip netns exec server_ns ip link set lo up
sudo ip netns exec server_ns ip link set veth-srv up
sudo ip netns exec server_ns ip addr add 192.168.100.1/24 dev veth-srv

# 5. Bring up loopback and client interface
sudo ip netns exec client_ns ip link set lo up
sudo ip netns exec client_ns ip link set veth-clt up
```

*(To clean up later: `sudo ip netns del server_ns && sudo ip netns del client_ns`)*

---

## 3. Test Cases Specification

### Test Suite 1: Static Code Quality & Syntax Analysis

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-01** | Bash Syntax Check | `bash -n dhcp-toolkit.sh` | Zero errors returned; exit code 0. | Exit code 0 |
| **TC-02** | Zero-Eval Policy Audit | `grep -E '\beval\b' dhcp-toolkit.sh` | No occurrences found. | Zero matches |
| **TC-03** | Command-Line Help Flag | `./dhcp-toolkit.sh --help` | Outputs CLI flag summary and safety guidelines. | Exit code 0 |
| **TC-04** | Version Information | `./dhcp-toolkit.sh --version` | Outputs `DHCP Management Toolkit v1.0.0`. | Exit code 0 |

---

### Test Suite 2: Environment Detection & Pre-Flight Diagnostics

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-05** | Automated Pre-Flight Check | `./dhcp-toolkit.sh --check` | Detects OS release, verifies sudo capabilities, checks required tools, and inspects ports 67/53. | Structured diagnostics printed without crashes |
| **TC-06** | Non-Ubuntu Safety Warning | Execute on macOS or non-Ubuntu Linux: `./dhcp-toolkit.sh --check` | Detects non-Ubuntu kernel, displays warning recommending Dry-Run mode. | Warning logged and displayed |
| **TC-07** | Socket Conflict Detection | Bind dummy process to UDP 67: `nc -u -l 67 &`<br>Run: `./dhcp-toolkit.sh --check` | Identifies that UDP port 67 is bound; warns of competing DHCP service. | Port 67 conflict flagged |

---

### Test Suite 3: Pure-Bash IP Math & Subnet Validation Engine

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-08** | Automated Self-Test Suite | `./dhcp-toolkit.sh --test-math` | Executes internal test harness: IPv4 regex, IP-to-integer conversion, contiguous netmask check, subnet containment. | "All automated self-tests passed cleanly (0 errors)" |
| **TC-09** | Invalid IPv4 Rejection | Enter `256.0.0.1` or `192.168.01.1` in configuration wizard | Rejected with specific formatting error. | Invalid IP rejected |
| **TC-10** | Non-Contiguous Mask Rejection | Enter `255.255.255.1` in wizard | Rejected: subnet mask must be contiguous 1s followed by 0s. | Invalid mask rejected |
| **TC-11** | Cross-Subnet Pool Rejection | Server IP `192.168.50.1/24`, enter Pool Start `192.168.60.10` | Rejected: pool must reside within the server's subnet. | Cross-subnet rejected |
| **TC-12** | Inverted Range Rejection | Enter Start `192.168.50.100`, End `192.168.50.50` | Rejected: End IP cannot be smaller than Start IP. | Inverted range rejected |
| **TC-13** | Network/Broadcast Collision | Enter Pool Start `192.168.50.0` or End `192.168.50.255` | Rejected: Pool boundaries cannot touch network or broadcast IDs. | Boundary addresses rejected |

---

### Test Suite 4: Critical Safety Interlocks & Overlap Enforcement

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-14** | Server IP Anti-Overlap Invariant | Server IP: `192.168.50.1`.<br>Enter Pool: `192.168.50.1` to `192.168.50.50`. | **FATAL ERROR RAISED**: "SERVER IP OVERLAP DETECTED! The server's own IP falls inside the pool range." | Overlap strictly blocked |
| **TC-15** | Wi-Fi Interface Interlock | Select wireless interface (`wlan0` or `wl*`) in Menu Option 2. | High-visibility warning displayed. Operation blocked unless exact phrase `CONFIRM-ISOLATED-LAB` is entered. | Unconfirmed selection aborted |
| **TC-16** | Default Gateway Interlock | Select an interface currently routing the host's default gateway. | Warning displayed: interface is connected to upstream LAN/Internet. Requires explicit confirmation. | Warning displayed |

---

### Test Suite 5: Non-Destructive Dry-Run & Staging

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-17** | Dry-Run Configuration Staging | Launch `./dhcp-toolkit.sh --dry-run`. Choose Option 2 (select `eth0`), Option 3 (configure parameters), Option 9 (view). | Configuration is written to `./dnsmasq-dhcp-toolkit.conf.preview`. `/etc/` remains untouched. | System files unchanged; preview generated |
| **TC-18** | Dry-Run Syntax Validation | Run `./dhcp-toolkit.sh --dry-run`, select Option 5. | Validates preview file structure without starting services. | Validation passes |
| **TC-19** | Dry-Run Safe Cleanup | Run `./dhcp-toolkit.sh --dry-run`, select Option 10. | Removes `./dnsmasq-dhcp-toolkit.conf.preview`. | Preview file deleted |

---

### Test Suite 6: Live Service Lifecycle & Socket Verification (Ubuntu Lab VM)

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-20** | Package Installation Confirmation | In live Ubuntu VM: run toolkit, choose Option 4 (`Install dnsmasq`). | Shows command `apt-get install -y dnsmasq`. Waits for user confirmation `yes`. | Installs only upon confirmation |
| **TC-21** | Atomic Backup Creation | Modify existing configuration via Option 3. | Previous `/etc/dnsmasq.d/dhcp-toolkit.conf` is copied to `dhcp-toolkit.conf.bak.<timestamp>`. | Backup file created with timestamp |
| **TC-22** | Pre-Start Syntax Gate | Corrupt `/etc/dnsmasq.d/dhcp-toolkit.conf` with a typo, attempt Option 6 (`Start Service`). | Validation fails; service restart is **ABORTED** before `systemctl` is invoked. | Service restart prevented |
| **TC-23** | Live Service Startup | Option 6 with valid configuration. | Service restarts cleanly. `systemctl is-active dnsmasq` returns `active`. | Service active |
| **TC-24** | Port 67 Socket Binding | Option 7 or `ss -ulpn 'sport = :67'` | Shows `dnsmasq` listening on UDP port 67 on the designated interface. | Port 67 bound |
| **TC-25** | Systemd-Resolved Coexistence | Inspect port 53: `ss -ulpn 'sport = :53'` | `dnsmasq` does not clash with `systemd-resolved` because `port=0` is set in configuration. | Zero port 53 clashes |

---

### Test Suite 7: Live DORA Lease Allocation & Options Verification

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-26** | Client Lease Acquisition (DORA) | On Client VM on same host-only network, run: `sudo dhclient -v -1 <client_iface>` | Client broadcasts `DHCPDISCOVER`, receives `DHCPOFFER`, sends `DHCPREQUEST`, receives `DHCPACK`. Client receives an IP inside the pool. | Valid IP assigned to client |
| **TC-27** | Subnet Mask Propagation | On Client VM: `ip addr show <client_iface>` | Netmask matches the configured Option 1 value (e.g., `/24`). | Netmask correct |
| **TC-28** | Default Gateway Option Delivery | On Client VM: `ip route show` | Default route matches the configured Option 3 router IP. | Default gateway correct |
| **TC-29** | DNS Server Option Delivery | On Client VM: `resolvectl status <client_iface>` or `cat /etc/resolv.conf` | DNS servers match the configured Option 6 IPs (e.g., `8.8.8.8, 1.1.1.1`). | DNS servers match |
| **TC-30** | Lease Persistence & Inspection | On Server VM: toolkit Option 7 (`View Leases`) | Lease entry appears in `/var/lib/misc/dnsmasq.leases` displaying expiry timestamp, client MAC, IP, and hostname. | Lease displayed in table |

---

### Test Suite 8: Lease Renewal & Expiration Behavior

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-31** | Short Lease Expiration Test | Configure lease duration to `2m` (2 minutes). Request lease on client. | Client requests renewal at $T_1 = 60\text{s}$. Unrenewed lease expires after 120s and can be reallocated. | Lease renewal / expiry confirmed |
| **TC-32** | Lease Release (DHCPRELEASE) | On Client VM: `sudo dhclient -r <client_iface>` | Client releases lease; server logs release event. | Release logged |

---

### Test Suite 9: Safe Teardown, Rollback & Preservation of Unrelated Settings

| Test ID | Test Title | Execution Command | Expected Result | Pass/Fail Criteria |
|---|---|---|---|---|
| **TC-33** | Surgical File Removal | Create unrelated file `/etc/dnsmasq.d/other.conf`. Run toolkit Option 10 (`Remove Configuration`). | Deletes `/etc/dnsmasq.d/dhcp-toolkit.conf`. `/etc/dnsmasq.d/other.conf` and `/etc/dnsmasq.conf` **REMAIN UNTOUCHED**. | Unrelated files preserved |
| **TC-34** | Backup Restoration | Select `yes` to restore backup when prompted during Option 10. | Restores previous `.bak` file to active configuration. | Backup restored |

---

## 4. Test Execution Record Template

When executing tests on the Ubuntu lab machine, record results using the table below:

| Test ID | Date / Time | Tester Name | Ubuntu Release | Target Interface | Result (PASS / FAIL) | Notes / Observations |
|---|---|---|---|---|---|---|
| **TC-01** | | | | | | |
| **TC-05** | | | | | | |
| **TC-08** | | | | | | |
| **TC-14** | | | | | | |
| **TC-17** | | | | | | |
| **TC-23** | | | | | | |
| **TC-26** | | | | | | |
| **TC-30** | | | | | | |
| **TC-33** | | | | | | |

---

## 5. Lab Demonstration Checklist for Grading

Prior to presenting the project to the course instructor or teaching assistants:
- [ ] Verify that hypervisor adapters are strictly set to **Host-Only** or **Internal Network**.
- [ ] Confirm Server VM has a static IP assigned via Netplan.
- [ ] Run `./dhcp-toolkit.sh --test-math` to demonstrate pure-Bash arithmetic validity.
- [ ] Run `./dhcp-toolkit.sh --dry-run` to demonstrate the non-destructive planning capability.
- [ ] Run `./dhcp-toolkit.sh` to configure and start the live DHCP server.
- [ ] Boot or renew Client VM to demonstrate live DORA address allocation.
- [ ] Open Option 7 to demonstrate real-time lease table tracking.
- [ ] Execute Option 10 to demonstrate clean, surgical teardown and configuration preservation.
