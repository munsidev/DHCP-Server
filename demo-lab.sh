#!/usr/bin/env bash
# ==============================================================================
# Isolated 1-VM Lab Demonstration Assistant
# Operating Systems Course Project: DHCP Server Toolkit
#
# Purpose:
#   Simulates an isolated, real-hardware client and server on a SINGLE Ubuntu VM
#   using Linux Network Namespaces (ip netns) and a Virtual Ethernet (veth) cable.
#
# Guarantees:
#   - 100% Isolated: Zero traffic touches your Wi-Fi or Internet adapter.
#   - Zero New VMs: Runs entirely on your existing Ubuntu machine.
#   - Real IP Allocation: Client sends real DHCP packets and gets a real IP.
# ==============================================================================

set -euo pipefail

readonly NS_SERVER="server_ns"
readonly NS_CLIENT="client_ns"
readonly IFACE_SERVER="veth-srv"
readonly IFACE_CLIENT="veth-clt"
readonly SERVER_IP="192.168.50.1/24"

# Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[0;32m'
C_CYAN='\033[0;36m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        printf "${C_RED}[ERROR] This helper script requires sudo privileges.${C_RESET}\n" >&2
        printf "Please run: sudo %s %s\n" "$0" "${1:-}" >&2
        exit 1
    fi
}

start_lab() {
    require_root "start"

    printf "${C_CYAN}${C_BOLD}=== Creating Isolated 1-VM Virtual Lab Network ===${C_RESET}\n"

    # Clean existing namespaces if left over
    stop_lab_quiet

    # 1. Create two isolated network namespaces
    printf "1. Creating network namespaces: %s (Server) and %s (Client)...\n" "${NS_SERVER}" "${NS_CLIENT}"
    ip netns add "${NS_SERVER}"
    ip netns add "${NS_CLIENT}"

    # 2. Create virtual ethernet (veth) pair (virtual cable)
    printf "2. Connecting namespaces with a virtual ethernet cable (%s <---> %s)...\n" "${IFACE_SERVER}" "${IFACE_CLIENT}"
    ip link add "${IFACE_SERVER}" type veth peer name "${IFACE_CLIENT}"

    # 3. Move each interface into its respective namespace
    ip link set "${IFACE_SERVER}" netns "${NS_SERVER}"
    ip link set "${IFACE_CLIENT}" netns "${NS_CLIENT}"

    # 4. Bring up server interface with static IP
    printf "3. Assigning static IP %s to server interface %s...\n" "${SERVER_IP}" "${IFACE_SERVER}"
    ip netns exec "${NS_SERVER}" ip addr add "${SERVER_IP}" dev "${IFACE_SERVER}"
    ip netns exec "${NS_SERVER}" ip link set "${IFACE_SERVER}" up
    ip netns exec "${NS_SERVER}" ip link set lo up

    # 5. Bring up client interface (no IP yet, waiting for DHCP)
    printf "4. Enabling client interface %s (waiting for DHCP lease)...\n" "${IFACE_CLIENT}"
    ip netns exec "${NS_CLIENT}" ip link set "${IFACE_CLIENT}" up
    ip netns exec "${NS_CLIENT}" ip link set lo up

    printf "\n${C_GREEN}${C_BOLD}[SUCCESS] Virtual lab is ready and 100%% isolated from your internet!${C_RESET}\n\n"
    printf "${C_BOLD}Next Steps to show your professor:${C_RESET}\n"
    printf "  Step A: Start the DHCP server:\n"
    printf "          ${C_CYAN}sudo ./demo-lab.sh server${C_RESET}\n"
    printf "          (In the menu, choose Option 2 -> select '%s', Option 3 -> configure, Option 6 -> start)\n\n" "${IFACE_SERVER}"
    printf "  Step B: In a second terminal, trigger the client to get an IP:\n"
    printf "          ${C_CYAN}sudo ./demo-lab.sh client${C_RESET}\n\n"
}

run_server() {
    require_root "server"

    if ! ip netns list | grep -qw "${NS_SERVER}"; then
        printf "${C_YELLOW}Virtual lab is not started yet. Starting it now...${C_RESET}\n"
        start_lab
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    printf "${C_CYAN}${C_BOLD}Launching DHCP Toolkit inside isolated server namespace...${C_RESET}\n"
    ip netns exec "${NS_SERVER}" "${script_dir}/dhcp-toolkit.sh" "$@"
}

run_client() {
    require_root "client"

    if ! ip netns list | grep -qw "${NS_CLIENT}"; then
        printf "${C_RED}[ERROR] Virtual lab is not running! Run 'sudo ./demo-lab.sh start' first.${C_RESET}\n" >&2
        exit 1
    fi

    printf "${C_CYAN}${C_BOLD}=== Requesting Real IP Address from Client Namespace ===${C_RESET}\n"
    printf "Triggering DHCP DORA transaction over virtual cable...\n\n"

    # Check for dhclient
    if ! command -v dhclient >/dev/null 2>&1; then
        printf "${C_YELLOW}'dhclient' not found. Installing isc-dhclient...${C_RESET}\n"
        apt-get update -qq && apt-get install -y -qq isc-dhclient
    fi

    # Release any prior lease
    ip netns exec "${NS_CLIENT}" dhclient -r "${IFACE_CLIENT}" >/dev/null 2>&1 || true

    # Request new lease with verbose output showing DORA handshake
    ip netns exec "${NS_CLIENT}" dhclient -v -1 "${IFACE_CLIENT}"

    printf "\n${C_GREEN}${C_BOLD}[SUCCESS] Client received an IP address!${C_RESET}\n\n"
    show_status
}

show_status() {
    require_root "status"

    printf "${C_BOLD}--- Current Isolated Lab Network Status ---${C_RESET}\n"

    printf "\n${C_CYAN}[Server Namespace: %s]${C_RESET}\n" "${NS_SERVER}"
    if ip netns list | grep -qw "${NS_SERVER}"; then
        ip netns exec "${NS_SERVER}" ip -br addr show "${IFACE_SERVER}" 2>/dev/null || echo "Interface not configured"
    else
        printf "${C_YELLOW}Server namespace not active.${C_RESET}\n"
    fi

    printf "\n${C_CYAN}[Client Namespace: %s]${C_RESET}\n" "${NS_CLIENT}"
    if ip netns list | grep -qw "${NS_CLIENT}"; then
        ip netns exec "${NS_CLIENT}" ip -br addr show "${IFACE_CLIENT}" 2>/dev/null || echo "Interface not configured"
        local client_route
        client_route="$(ip netns exec "${NS_CLIENT}" ip route 2>/dev/null || true)"
        if [[ -n "${client_route}" ]]; then
            printf "Assigned Routes:\n%s\n" "${client_route}"
        fi
    else
        printf "${C_YELLOW}Client namespace not active.${C_RESET}\n"
    fi
    printf "\n"
}

stop_lab_quiet() {
    ip netns del "${NS_SERVER}" 2>/dev/null || true
    ip netns del "${NS_CLIENT}" 2>/dev/null || true
}

stop_lab() {
    require_root "stop"
    printf "${C_YELLOW}Tearing down virtual network namespaces...${C_RESET}\n"
    stop_lab_quiet
    printf "${C_GREEN}[SUCCESS] Virtual lab completely removed. Host is in original state.${C_RESET}\n"
}

print_help() {
    cat << EOF
Usage: sudo $(basename "$0") <COMMAND>

Commands for 1-VM Safe Demonstration:
  start     Set up isolated virtual client/server namespaces and virtual cable
  server    Launch dhcp-toolkit.sh inside the server namespace
  client    Request a real IP address on the client (shows DORA handshake)
  status    Inspect assigned IP addresses and routes on both sides
  stop      Safely tear down the virtual namespaces and clean up

Demonstration Flow for Professor:
  1. Terminal 1: sudo $(basename "$0") start
  2. Terminal 1: sudo $(basename "$0") server  (Option 2 -> veth-srv, Option 3, Option 6)
  3. Terminal 2: sudo $(basename "$0") client  (Watch real DORA handshake & IP allocation)
  4. Terminal 1: In toolkit menu, choose Option 7 to show the real-time lease table!
  5. Terminal 1: sudo $(basename "$0") stop
EOF
}

case "${1:-help}" in
    start|setup)
        start_lab
        ;;
    server)
        shift
        run_server "$@"
        ;;
    client|dhclient)
        run_client
        ;;
    status)
        show_status
        ;;
    stop|clean|teardown)
        stop_lab
        ;;
    -h|--help|help)
        print_help
        ;;
    *)
        printf "${C_RED}Unknown command: %s${C_RESET}\n" "$1" >&2
        print_help
        exit 1
        ;;
esac
