# Course Report Outline: DHCP Server Setup and Management Toolkit

**Course**: Operating Systems / Network Systems Administration  
**Project**: DHCP Server Setup and Management Toolkit using `dnsmasq`  
**Target Environment**: Ubuntu Linux (20.04 LTS, 22.04 LTS, 24.04 LTS)  

---

## Document Overview
This document provides a comprehensive academic and technical outline for the formal course project report. It bridges theoretical Operating Systems principles (network protocol state machines, socket programming, daemon lifecycle, inter-process resource isolation) with the defensive engineering practices implemented in the `dhcp-toolkit.sh` Bash suite.

---

## Detailed Report Structure

### Title Page
- **Project Title**: Design, Implementation, and Evaluation of a Defensive DHCP Server Management Toolkit for Ubuntu Linux
- **Course Title & Code**: Operating Systems (CS 300 / CS 400 Series)
- **Author Information**: Student Name, Student ID, Institutional Email
- **Academic Term & Date**: Current Semester, Academic Year
- **Instructor / Supervisor**: Faculty Advisor / Course Instructor

---

### Executive Summary / Abstract
- High-level synopsis of the Dynamic Host Configuration Protocol (DHCP) and its fundamental role in network bootstrap.
- Problem statement: Risks of misconfiguration and rogue DHCP deployment in educational and enterprise networks.
- Proposed solution: A defensive, modular, menu-driven Bash toolkit leveraging `dnsmasq` on Ubuntu Linux.
- Key results: Successful zero-eval pure-Bash IP calculation engine, automatic conflict avoidance with `systemd-resolved`, atomic backups, non-destructive teardown, and 100% verified lease allocation across isolated lab testbeds.

---

### Table of Contents
1. Introduction & Theoretical Foundations
2. DHCP Architecture, Address Pools, and Lease Lifecycles
3. Threat Modeling & Network Safety Considerations
4. Toolkit System Architecture and Design
5. Implementation Details
6. Experimental Verification & Results
7. Limitations & Future Extensions
8. Conclusion & References

---

### Chapter 1: Introduction & Theoretical Foundations

#### 1.1 The Network Bootstrap Problem
- Limitations of static manual IP assignment in dynamic operating system environments.
- Historical evolution from RARP (Reverse ARP, RFC 903) and BOOTP (Bootstrap Protocol, RFC 951) to DHCP (RFC 2131).
- The client-server model over UDP: Port 67 (Server daemon) and Port 68 (Client agent).

#### 1.2 The DORA Protocol State Machine
Detailed theoretical breakdown of the four-way DHCP handshake:
1. **DHCPDISCOVER**:
   - Client sends broadcast packet ($0.0.0.0:68 \to 255.255.255.255:67$).
   - Header flags: Broadcast bit, Transaction ID (`xid`), Client MAC address (`chaddr`).
2. **DHCPOFFER**:
   - Server reserves an IP address from its pool and responds with unicast or broadcast.
   - Proposed IP (`yiaddr`), server identifier, lease time, and network options.
3. **DHCPREQUEST**:
   - Client announces its selected offer and broadcasts request to inform competing servers.
   - Server identity option (Option 54) indicating chosen server.
4. **DHCPACK**:
   - Chosen server confirms reservation, records entry in lease database, and commits network parameters.

```
       Client (0.0.0.0:68)                 Server (192.168.50.1:67)
              |                                       |
              | --- DHCPDISCOVER (Broadcast UDP) ---> |
              |                                       |
              | <--- DHCPOFFER (Unicast/Bcast UDP) -- |
              |                                       |
              | --- DHCPREQUEST (Broadcast UDP) ----> |
              |                                       |
              | <--- DHCPACK (Unicast/Bcast UDP) ---- |
              |                                       |
```

#### 1.3 DHCP Options Architecture (RFC 2132)
- Type-Length-Value (TLV) encoding of DHCP options.
- Essential options implemented in this project:
  - **Option 1**: Subnet Mask (`255.255.255.0`).
  - **Option 3**: Router / Default Gateway list.
  - **Option 6**: Domain Name Server (DNS) addresses.
  - **Option 15**: Domain Name string (e.g., `oslab.local`).
  - **Option 51**: IP Address Lease Time (seconds or human units).
  - **Option 53**: DHCP Message Type.
  - **Option 54**: Server Identifier.

---

### Chapter 2: DHCP Architecture, Address Pools, and Lease Lifecycles

#### 2.1 Address Pool Mathematics & Boundary Theory
- IPv4 32-bit address space representation.
- Subnet mask partitioning: Network prefix versus Host identifier.
- Mathematical constraints on dynamic allocation:
  $$\text{Network ID} = \text{IP} \ \& \ \text{Netmask}$$
  $$\text{Broadcast Address} = \text{Network ID} \ | \ (\sim\text{Netmask} \ \& \ \text{0xFFFFFFFF})$$
  $$\text{Valid Pool Range} \subset [\text{Network ID} + 1, \text{Broadcast Address} - 1]$$
- **The Server IP Invariant**:
  $$\text{Server IP} \notin [\text{Pool Start}, \text{Pool End}]$$
  Analysis of why allocating the server's own IP creates fatal ARP conflicts and immediate network partitioning.

#### 2.2 The Lease State Lifecycle
- **Allocation**: Initial binding upon DHCPACK transmission.
- **Renewal ($T_1$)**:
  - Occurs at 50% of lease duration ($T_1 = 0.5 \times \text{LeaseTime}$).
  - Client sends unicast `DHCPREQUEST` directly to the leasing server.
- **Rebinding ($T_2$)**:
  - Occurs if renewal fails, at 87.5% of lease duration ($T_2 = 0.875 \times \text{LeaseTime}$).
  - Client sends broadcast `DHCPREQUEST` to any available DHCP server.
- **Expiration / Release**:
  - Client sends `DHCPRELEASE` when terminating or graceful shutdown.
  - Unrenewed leases expire and return to the available allocation pool.

#### 2.3 Lease Persistence in `dnsmasq`
- Structure and semantics of `/var/lib/misc/dnsmasq.leases`:
  ```
  <expiry_epoch> <mac_address> <ip_address> <hostname> <client_id>
  ```
- File locking, atomic updates, and crash recovery mechanisms in Linux daemons.

---

### Chapter 3: Threat Modeling & Network Safety Considerations

#### 3.1 Rogue DHCP Server Threat Vector
- **The Broadcast Race Condition**: In broadcast domains without 802.1x or DHCP Snooping, any host can answer `DHCPDISCOVER`.
- **Denial of Service (DoS)**: Handing out invalid subnets or exhausted pools.
- **Default Gateway Hijacking (Man-in-the-Middle)**: Directing traffic to an attacker-controlled router for interception and SSL stripping.
- **DNS Spoofing**: Supplying fraudulent DNS resolvers to redirect client queries.

#### 3.2 Defensive Safeguards Implemented
- **Physical/Virtual Interlock**: Pre-flight inspection for Wi-Fi interfaces (`wl*`, `wlan*`) and default gateways.
- **Mandatory Authorization Gate**: Requiring explicit confirmation keywords (`CONFIRM-ISOLATED-LAB`) before proceeding with potentially dangerous interfaces.
- **Port 67 Pre-flight Conflict Probe**: Preventing competing daemon collisions with `ss -ulpn`.
- **Systemd-Resolved Coexistence**: Addressing Ubuntu's default local resolver on `127.0.0.53:53` by configuring `dnsmasq` with `port=0` (pure DHCP mode).

---

### Chapter 4: Toolkit System Architecture and Design

#### 4.1 Architectural Philosophy
- **Defensive Shell Programming**: Strict adherence to POSIX standards, zero `eval` usage, mandatory variable quoting, and `set -euo pipefail`.
- **Separation of Concerns**: Non-monolithic configuration strategy. System files in `/etc/dnsmasq.conf` remain untouched; project settings are isolated in `/etc/dnsmasq.d/dhcp-toolkit.conf`.
- **Atomic Operations & Backups**: Every write is preceded by a timestamped copy (`.bak.<timestamp>`).
- **Dry-Run Planning Capability**: Simulating package checks, configuration compilation, and systemd invocations without modifying system state.

#### 4.2 System Component Diagram

```
+-----------------------------------------------------------------------------+
|                               dhcp-toolkit.sh                               |
+-----------------------------------------------------------------------------+
       |                  |                     |                   |
       v                  v                     v                   v
+--------------+  +---------------+     +---------------+   +-----------------+
| Pre-Flight   |  | Pure-Bash IP  |     | Configuration |   | Lifecycle &     |
| Diagnostics  |  | Math Engine   |     | & Backup Mgr  |   | Lease Monitor   |
|--------------|  |---------------|     |---------------|   |-----------------|
| - Ubuntu ID  |  | - ipv4_to_int |     | - .conf gen   |   | - systemctl     |
| - Sudo check |  | - netmask/CIDR|     | - .bak copy   |   | - port 67 bind  |
| - Port 67/53 |  | - anti-overlap|     | - syntax test |   | - lease table   |
| - Iface scan |  | - boundaries  |     | - safe teardown|  | - audit logs    |
+--------------+  +---------------+     +---------------+   +-----------------+
```

---

### Chapter 5: Implementation Details

#### 5.1 Pure-Bash IP Math & Subnet Calculation Engine
- Implementation of 32-bit unsigned arithmetic using Bash 64-bit integer expressions:
  - `ipv4_to_int()`: Dotted-quad to integer conversion via bit shifting.
  - `int_to_ipv4()`: Bitwise masking and extraction of octets.
  - `netmask_to_cidr()`: Validating contiguous netmasks by checking `((inverted + 1) & inverted) == 0`.
  - `is_ip_in_subnet()`: Verifying bitwise AND match between candidate IP and subnet network ID.
  - `Anti-Overlap Verification`: Direct integer interval comparison:
    ```bash
    if (( srv_int >= start_int && srv_int <= end_int )); then
        # Raise fatal collision error
    fi
    ```

#### 5.2 Modular Configuration & Backup Pipeline
- Generation of `/etc/dnsmasq.d/dhcp-toolkit.conf`.
- Inclusion of `bind-interfaces`, `dhcp-authoritative`, `dhcp-range`, and explicit options.
- Execution of `dnsmasq --test --conf-file=...` to ensure syntax validity before initiating service restarts.

#### 5.3 Audit Logging and Secret Hygiene
- Dual-target logging: Console output (colored ANSI) and structured file logging (`/var/log/dhcp-toolkit.log` or local `./dhcp-toolkit.log`).
- ISO-8601 timestamps, log level tagging (`[INFO]`, `[WARN]`, `[ERROR]`, `[SUCCESS]`, `[DRY-RUN]`).
- Stripping ANSI escape sequences from log files for clean parsing.

---

### Chapter 6: Experimental Verification & Results

#### 6.1 Testbed Setup
- **Virtualization Environment**: VirtualBox / VMware host-only network (`vboxnet0`, `192.168.50.0/24`).
- **Linux Network Namespaces (`ip netns`)**: Zero-overhead dual-namespace testbed (`server_ns` connected via `veth` pair to `client_ns`).

#### 6.2 Test Results Matrix
- Table of executed test cases:
  - Static analysis and Bash syntax checks (`bash -n`).
  - Unit tests for IP math and netmask validation (`--test-math`).
  - Non-destructive dry-run simulation (`--dry-run`).
  - System pre-flight diagnostics (`--check`).
  - Live DORA handshake and lease issuance.
  - Overlap injection test (verifying prompt rejection).
  - Safe teardown and backup restoration.

#### 6.3 Packet Capture Analysis
- Tcpdump / Wireshark capture of UDP 67/68 traffic.
- Analysis of packet payload fields during DORA exchange.
- Verification of Option 1 (Netmask), Option 3 (Router), and Option 6 (DNS) delivery to client.

---

### Chapter 7: Limitations & Future Extensions

#### 7.1 Current System Limitations
- IPv4-only scope (DHCPv6 is not currently configured).
- Static lease reservations (MAC-to-IP binding) require manual file additions.
- Single-homed interface support per instance.

#### 7.2 Proposed Future Enhancements
- **DHCPv6 Support (RFC 8415)**: Prefix delegation and stateful IPv6 address allocation.
- **Dynamic DNS Integration (RFC 2136)**: Automatic DNS record updates upon lease issuance.
- **Failover & High Availability (HA)**: Distributed lease database synchronization between primary and secondary servers.
- **Web-Based Dashboard**: Lightweight REST API or Prometheus exporter for lease utilization telemetry.

---

### Chapter 8: Conclusion & References

#### 8.1 Summary of Contributions
- Successful delivery of an automated, defensive, educational DHCP toolkit.
- Practical demonstration of operating systems networking principles in Linux.
- Elimination of configuration corruption risks through modular directories and dry-run planning.

#### 8.2 References
1. RFC 2131: Dynamic Host Configuration Protocol.
2. RFC 2132: DHCP Options and BOOTP Vendor Extensions.
3. RFC 951: Bootstrap Protocol (BOOTP).
4. `dnsmasq(8)` Manual Pages, Simon Kelley.
5. Systemd Architecture & `systemd-resolved` Network Name Resolution, FreeDesktop.org.
6. Computer Networks (5th Edition), Andrew S. Tanenbaum and David J. Wetherall.
