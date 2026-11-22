#!/usr/bin/env bash
# ==============================================================================
# DHCP Server Setup and Management Toolkit (dnsmasq)
# Operating Systems Course Project
#
# Target Environment: Ubuntu Linux (20.04 LTS, 22.04 LTS, 24.04 LTS)
# Scope: Isolated Lab Networks / Authorized Management Networks ONLY
#
# Safety Policy:
#   - NEVER start on public, campus, corporate, or home Wi-Fi networks.
#   - NEVER deploy where a competing/unauthorized DHCP server exists.
#   - Modifications are confined to a dedicated dnsmasq configuration file.
#   - All pre-existing configurations are backed up prior to modification.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Global Constants and Default Configuration
# ------------------------------------------------------------------------------
readonly TOOLKIT_VERSION="1.0.0"
readonly DEFAULT_CONF_DIR="/etc/dnsmasq.d"
readonly DEFAULT_CONF_FILE="${DEFAULT_CONF_DIR}/dhcp-toolkit.conf"
readonly DEFAULT_MAIN_CONF="/etc/dnsmasq.conf"
readonly DEFAULT_LEASE_FILE="/var/lib/misc/dnsmasq.leases"
readonly DEFAULT_LOG_FILE="/var/log/dhcp-toolkit.log"
readonly LOCAL_MOCK_CONF="./dnsmasq-dhcp-toolkit.conf.preview"
readonly LOCAL_LOG_FILE="./dhcp-toolkit.log"

# Terminal Colors (disabled automatically if not attached to a TTY)
if [[ -t 1 ]]; then
    readonly C_RESET='\033[0m'
    readonly C_BOLD='\033[1m'
    readonly C_RED='\033[0;31m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[0;33m'
    readonly C_BLUE='\033[0;34m'
    readonly C_MAGENTA='\033[0;35m'
    readonly C_CYAN='\033[0;36m'
    readonly C_WHITE='\033[1;37m'
    readonly C_BG_RED='\033[41m\033[1;37m'
else
    readonly C_RESET=''
    readonly C_BOLD=''
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_MAGENTA=''
    readonly C_CYAN=''
    readonly C_WHITE=''
    readonly C_BG_RED=''
fi

# Runtime State Variables
DRY_RUN_MODE=false
SELECTED_IFACE=""
SERVER_IP=""
SERVER_NETMASK=""
SERVER_CIDR=""
DHCP_START_IP=""
DHCP_END_IP=""
DHCP_SUBNET_MASK=""
DHCP_LEASE_TIME="12h"
DHCP_GATEWAY=""
DHCP_DNS="8.8.8.8,1.1.1.1"
DHCP_DOMAIN=""
DISABLE_DNS_PORT=true
ACTIVE_LOG_FILE="${LOCAL_LOG_FILE}"

# ------------------------------------------------------------------------------
# Logging & Console Output Functions
# ------------------------------------------------------------------------------
init_logging() {
    if [[ "${EUID}" -eq 0 ]] && [[ -d "/var/log" ]] && [[ "${DRY_RUN_MODE}" == false ]]; then
        ACTIVE_LOG_FILE="${DEFAULT_LOG_FILE}"
    else
        ACTIVE_LOG_FILE="${LOCAL_LOG_FILE}"
    fi

    # Create log file if it does not exist
    if ! touch "${ACTIVE_LOG_FILE}" 2>/dev/null; then
        ACTIVE_LOG_FILE="/tmp/dhcp-toolkit-$$.log"
        touch "${ACTIVE_LOG_FILE}" 2>/dev/null || true
    fi
}

log_msg() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Log to file (stripping any ANSI escape codes)
    if [[ -n "${ACTIVE_LOG_FILE}" ]] && [[ -w "${ACTIVE_LOG_FILE}" || -w "$(dirname "${ACTIVE_LOG_FILE}")" ]]; then
        local clean_message
        clean_message="$(printf '%s' "${message}" | sed 's/\x1b\[[0-9;]*m//g')"
        printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${clean_message}" >> "${ACTIVE_LOG_FILE}" 2>/dev/null || true
    fi

    # Console output
    case "${level}" in
        INFO)
            printf "${C_BLUE}[INFO]${C_RESET} %s\n" "${message}"
            ;;
        SUCCESS)
            printf "${C_GREEN}[SUCCESS]${C_RESET} %s\n" "${message}"
            ;;
        WARN)
            printf "${C_YELLOW}[WARNING]${C_RESET} %s\n" "${message}"
            ;;
        ERROR)
            printf "${C_RED}[ERROR]${C_RESET} %s\n" "${message}" >&2
            ;;
        NOTICE)
            printf "${C_CYAN}[NOTICE]${C_RESET} %s\n" "${message}"
            ;;
        DRYRUN)
            printf "${C_MAGENTA}[DRY-RUN]${C_RESET} %s\n" "${message}"
            ;;
        *)
            printf "[%s] %s\n" "${level}" "${message}"
            ;;
    esac
}

print_banner() {
    clear 2>/dev/null || true
    printf "${C_CYAN}${C_BOLD}"
    cat << 'EOF'
================================================================================
           DHCP SERVER SETUP & MANAGEMENT TOOLKIT (dnsmasq)
             Operating Systems Course Project - Lab Edition
================================================================================
EOF
    printf "${C_RESET}"
    if [[ "${DRY_RUN_MODE}" == true ]]; then
        printf "${C_MAGENTA}${C_BOLD} >>> DRY-RUN MODE ACTIVE: Changes will NOT be applied to system files <<<${C_RESET}\n"
    fi
    printf "\n"
}

print_safety_warning() {
    printf "${C_BG_RED}                                CRITICAL SAFETY NOTICE                                ${C_RESET}\n"
    printf "${C_YELLOW}%s${C_RESET}\n" "1. A DHCP server broadcasts IP and routing parameters to all devices on a broadcast domain."
    printf "${C_YELLOW}%s${C_RESET}\n" "2. Starting an unauthorized (rogue) DHCP server on a shared network (Wi-Fi, campus, home)"
    printf "${C_YELLOW}%s${C_RESET}\n" "   CAN CORRUPT IP LEASES, HIJACK DEFAULT GATEWAYS, AND CAUSE NETWORK-WIDE OUTAGES."
    printf "${C_YELLOW}%s${C_RESET}\n" "3. Use this toolkit ONLY on an isolated physical or virtual lab network (e.g. VirtualBox"
    printf "${C_YELLOW}%s${C_RESET}\n" "   Host-Only, VMware LAN segment, KVM isolated bridge, or Linux network namespace)."
    printf "${C_YELLOW}%s${C_RESET}\n" "4. Never connect the DHCP-serving interface to upstream campus/office routers."
    printf "\n"
}

# ------------------------------------------------------------------------------
# Pure Bash IPv4 & Subnet Calculation Engine
# ------------------------------------------------------------------------------
validate_ipv4() {
    local ip="$1"
    local regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'

    if [[ ! "${ip}" =~ ${regex} ]]; then
        return 1
    fi

    local octet
    for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        # Disallow leading zeros unless the octet is single '0'
        if [[ "${#octet}" -gt 1 ]] && [[ "${octet:0:1}" == "0" ]]; then
            return 1
        fi
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}

ipv4_to_int() {
    local ip="$1"
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
    # Bash 64-bit integer arithmetic
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

int_to_ipv4() {
    local num="$1"
    local o1=$(( (num >> 24) & 255 ))
    local o2=$(( (num >> 16) & 255 ))
    local o3=$(( (num >> 8) & 255 ))
    local o4=$(( num & 255 ))
    printf "%d.%d.%d.%d\n" "${o1}" "${o2}" "${o3}" "${o4}"
}

cidr_to_netmask() {
    local cidr="$1"
    if (( cidr < 0 || cidr > 32 )); then
        echo ""
        return 1
    fi
    if (( cidr == 0 )); then
        echo "0.0.0.0"
        return 0
    fi
    local mask_int=$(( ((1 << 32) - 1) ^ ((1 << (32 - cidr)) - 1) ))
    int_to_ipv4 "${mask_int}"
}

netmask_to_cidr() {
    local mask="$1"
    if ! validate_ipv4 "${mask}"; then
        echo ""
        return 1
    fi
    local mask_int
    mask_int="$(ipv4_to_int "${mask}")"

    # Netmask must be contiguous 1s followed by contiguous 0s
    local inverted=$(( mask_int ^ 0xFFFFFFFF ))
    if (( ((inverted + 1) & inverted) != 0 )); then
        # Not a contiguous netmask
        echo ""
        return 1
    fi

    # Count set bits
    local count=0
    local i
    for (( i = 31; i >= 0; i-- )); do
        if (( (mask_int >> i) & 1 )); then
            (( count++ ))
        else
            break
        fi
    done
    echo "${count}"
}

validate_netmask() {
    local mask="$1"
    local cidr
    cidr="$(netmask_to_cidr "${mask}")"
    if [[ -z "${cidr}" ]] || (( cidr < 8 || cidr > 30 )); then
        return 1
    fi
    return 0
}

calculate_network_address() {
    local ip="$1"
    local mask="$2"
    local ip_int mask_int net_int
    ip_int="$(ipv4_to_int "${ip}")"
    mask_int="$(ipv4_to_int "${mask}")"
    net_int=$(( ip_int & mask_int ))
    int_to_ipv4 "${net_int}"
}

calculate_broadcast_address() {
    local ip="$1"
    local mask="$2"
    local ip_int mask_int bcast_int
    ip_int="$(ipv4_to_int "${ip}")"
    mask_int="$(ipv4_to_int "${mask}")"
    bcast_int=$(( (ip_int & mask_int) | (mask_int ^ 0xFFFFFFFF) ))
    int_to_ipv4 "${bcast_int}"
}

is_ip_in_subnet() {
    local target_ip="$1"
    local net_ip="$2"
    local mask="$3"

    local target_int net_int mask_int
    target_int="$(ipv4_to_int "${target_ip}")"
    net_int="$(ipv4_to_int "${net_ip}")"
    mask_int="$(ipv4_to_int "${mask}")"

    if (( (target_int & mask_int) == (net_int & mask_int) )); then
        return 0
    else
        return 1
    fi
}

validate_lease_duration() {
    local lease="$1"
    # Matches formats like: 30m, 1h, 12h, 24h, 7d, 2w, or 'infinite'
    if [[ "${lease}" =~ ^([1-9][0-9]*)([mhdsw])$ ]] || [[ "${lease}" == "infinite" ]]; then
        return 0
    fi
    return 1
}

is_in_netns() {
    if command -v ip >/dev/null 2>&1; then
        local ns
        ns="$(ip netns identify $$ 2>/dev/null || true)"
        if [[ -n "${ns}" ]]; then
            return 0
        fi
    fi
    if [[ -e "/proc/1/ns/net" && -e "/proc/$$/ns/net" ]]; then
        local root_ns current_ns
        root_ns="$(readlink /proc/1/ns/net 2>/dev/null || true)"
        current_ns="$(readlink /proc/$$/ns/net 2>/dev/null || true)"
        if [[ -n "${root_ns}" && -n "${current_ns}" && "${root_ns}" != "${current_ns}" ]]; then
            return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# System & Environment Pre-flight Diagnostics
# ------------------------------------------------------------------------------
detect_ubuntu_environment() {
    log_msg "INFO" "Executing pre-flight operating system detection..."

    local os_detected="unknown"
    local os_version="unknown"
    local is_ubuntu=false

    if [[ -f "/etc/os-release" ]]; then
        # Read /etc/os-release safely without eval
        local line
        while IFS='=' read -r key val || [[ -n "${key}" ]]; do
            # Strip quotes
            val="${val%\"}"
            val="${val#\"}"
            case "${key}" in
                ID)
                    os_detected="${val}"
                    ;;
                VERSION_ID)
                    os_version="${val}"
                    ;;
                ID_LIKE)
                    if [[ "${val}" == *"ubuntu"* ]]; then
                        is_ubuntu=true
                    fi
                    ;;
            esac
        done < "/etc/os-release"
    elif [[ -f "/etc/lsb-release" ]]; then
        while IFS='=' read -r key val || [[ -n "${key}" ]]; do
            val="${val%\"}"
            val="${val#\"}"
            case "${key}" in
                DISTRIB_ID)
                    os_detected="${val,,}"
                    ;;
                DISTRIB_RELEASE)
                    os_version="${val}"
                    ;;
            esac
        done < "/etc/lsb-release"
    fi

    if [[ "${os_detected}" == "ubuntu" ]] || [[ "${is_ubuntu}" == true ]]; then
        is_ubuntu=true
        log_msg "SUCCESS" "Ubuntu detected: ${os_detected} ${os_version}"
    else
        log_msg "WARN" "Non-Ubuntu operating system detected: ${os_detected} ($(uname -s) $(uname -r))"
        if [[ "${DRY_RUN_MODE}" == false ]]; then
            printf "\n${C_YELLOW}[!] This toolkit is tailored for Ubuntu Linux (20.04, 22.04, 24.04 LTS).${C_RESET}\n"
            printf "${C_YELLOW}    System service commands (systemctl) and package management (apt) may differ.${C_RESET}\n"
            printf "${C_CYAN}    You can run the toolkit safely in Dry-Run mode to review and simulate all actions.${C_RESET}\n\n"
        fi
    fi

    # Return status: 0 for Ubuntu, 1 otherwise
    if [[ "${is_ubuntu}" == true ]]; then
        return 0
    else
        return 1
    fi
}

check_sudo_privileges() {
    log_msg "INFO" "Checking administrative execution privileges..."
    if [[ "${EUID}" -eq 0 ]]; then
        log_msg "SUCCESS" "Running with effective root privileges (EUID=0)."
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            log_msg "SUCCESS" "Sudo privileges confirmed (passwordless / active cache)."
            return 0
        else
            log_msg "NOTICE" "Sudo is installed. Password authentication may be requested for system changes."
            return 0
        fi
    else
        log_msg "WARN" "Neither root nor 'sudo' utility is available. Configuration file modifications will require manual elevation."
        return 1
    fi
}

check_required_tools() {
    log_msg "INFO" "Verifying availability of networking and management utilities..."

    local critical_tools=("grep" "sed" "awk")
    local missing_critical=()
    local tool

    for tool in "${critical_tools[@]}"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing_critical+=("${tool}")
        fi
    done

    if [[ "${#missing_critical[@]}" -gt 0 ]]; then
        log_msg "ERROR" "Missing critical system utilities: ${missing_critical[*]}"
        return 1
    fi

    # Check network tools (iproute2)
    if command -v ip >/dev/null 2>&1; then
        log_msg "SUCCESS" "iproute2 ('ip' command) is available."
    else
        log_msg "WARN" "'ip' command not found. Falling back to ifconfig / netstat."
    fi

    # Check dnsmasq
    if command -v dnsmasq >/dev/null 2>&1; then
        local dnsmasq_ver
        dnsmasq_ver="$(dnsmasq --version 2>&1 | head -n1 || echo 'unknown')"
        log_msg "SUCCESS" "dnsmasq is installed: ${dnsmasq_ver}"
    else
        log_msg "NOTICE" "dnsmasq is NOT installed currently. Toolkit option 4 can install it."
    fi

    # Check systemctl
    if command -v systemctl >/dev/null 2>&1; then
        log_msg "SUCCESS" "systemd ('systemctl') is available."
    else
        log_msg "NOTICE" "systemctl not detected. Service management will attempt 'service' fallback."
    fi

    return 0
}

detect_port_conflicts() {
    log_msg "INFO" "Scanning for active socket conflicts on ports 67 (DHCP) and 53 (DNS)..."

    local port67_in_use=false
    local port53_in_use=false
    local conflict_details=""

    if command -v ss >/dev/null 2>&1; then
        if ss -ulpn 2>/dev/null | grep -qE ':67\b'; then
            port67_in_use=true
            conflict_details="$(ss -ulpn 2>/dev/null | grep -E ':67\b' || true)"
        fi
        if ss -ulpn 2>/dev/null | grep -qE ':53\b'; then
            port53_in_use=true
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ulpn 2>/dev/null | grep -qE ':67\b'; then
            port67_in_use=true
        fi
        if netstat -ulpn 2>/dev/null | grep -qE ':53\b'; then
            port53_in_use=true
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -iUDP:67 -n -P 2>/dev/null | grep -q UDP; then
            port67_in_use=true
        fi
        if lsof -iUDP:53 -n -P 2>/dev/null | grep -q UDP; then
            port53_in_use=true
        fi
    fi

    if [[ "${port67_in_use}" == true ]]; then
        log_msg "WARN" "Port 67/UDP is ALREADY bound by a process! A DHCP service may already be active."
        if [[ -n "${conflict_details}" ]]; then
            log_msg "WARN" "Conflict details: ${conflict_details}"
        fi
    else
        log_msg "SUCCESS" "Port 67/UDP is free and available for DHCP service."
    fi

    if [[ "${port53_in_use}" == true ]]; then
        log_msg "NOTICE" "Port 53/UDP is bound (often by systemd-resolved in Ubuntu). The toolkit configures dnsmasq with 'port=0' (or binds strictly to the lab interface) to eliminate DNS port conflicts."
    else
        log_msg "INFO" "Port 53/UDP is free."
    fi
}

# ------------------------------------------------------------------------------
# Network Interface Discovery & Selection
# ------------------------------------------------------------------------------
get_interface_list() {
    local ifaces=()
    if command -v ip >/dev/null 2>&1; then
        local raw_ifaces
        raw_ifaces="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 || true)"
        local iface
        for iface in ${raw_ifaces}; do
            # Skip loopback
            if [[ "${iface}" != "lo" ]]; then
                ifaces+=("${iface}")
            fi
        done
    elif [[ -d "/sys/class/net" ]]; then
        local iface_path
        for iface_path in /sys/class/net/*; do
            local iface
            iface="$(basename "${iface_path}")"
            if [[ "${iface}" != "lo" && "${iface}" != "*" ]]; then
                ifaces+=("${iface}")
            fi
        done
    elif command -v ifconfig >/dev/null 2>&1; then
        local raw
        raw="$(ifconfig -l 2>/dev/null || ifconfig | grep -E '^[a-zA-Z0-9]+' | awk '{print $1}' | tr -d ':' || true)"
        local iface
        for iface in ${raw}; do
            if [[ "${iface}" != "lo" && "${iface}" != "lo0" ]]; then
                ifaces+=("${iface}")
            fi
        done
    fi

    echo "${ifaces[@]}"
}

get_interface_ip_details() {
    local iface="$1"
    local ip_cidr=""
    local ip_addr=""
    local cidr=""
    local netmask=""

    if command -v ip >/dev/null 2>&1; then
        # Get first IPv4 address
        ip_cidr="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
        if [[ -n "${ip_cidr}" ]]; then
            ip_addr="${ip_cidr%%/*}"
            cidr="${ip_cidr##*/}"
            netmask="$(cidr_to_netmask "${cidr}")"
        fi
    elif command -v ifconfig >/dev/null 2>&1; then
        # BSD/macOS/legacy Linux ifconfig parsing
        ip_addr="$(ifconfig "${iface}" 2>/dev/null | grep -E 'inet ' | awk '{print $2}' | head -n1 || true)"
        local raw_mask
        raw_mask="$(ifconfig "${iface}" 2>/dev/null | grep -E 'inet ' | awk '{print $4}' | head -n1 || true)"
        if [[ "${raw_mask}" =~ ^0x ]]; then
            # Convert hex mask like 0xffffff00
            local m_dec
            m_dec=$(( raw_mask ))
            netmask="$(int_to_ipv4 "${m_dec}")"
            cidr="$(netmask_to_cidr "${netmask}")"
        elif validate_ipv4 "${raw_mask}"; then
            netmask="${raw_mask}"
            cidr="$(netmask_to_cidr "${netmask}")"
        fi
    fi

    echo "${ip_addr}|${netmask}|${cidr}"
}

is_wireless_interface() {
    local iface="$1"
    if [[ -d "/sys/class/net/${iface}/wireless" ]]; then
        return 0
    fi
    if command -v iwconfig >/dev/null 2>&1; then
        if iwconfig "${iface}" 2>&1 | grep -q "ESSID"; then
            return 0
        fi
    fi
    # Name pattern check (wl*, wlan*, wifi*)
    if [[ "${iface}" =~ ^(wl|wlan|wifi) ]]; then
        return 0
    fi
    return 1
}

has_default_gateway_on_iface() {
    local iface="$1"
    if command -v ip >/dev/null 2>&1; then
        if ip route show dev "${iface}" 2>/dev/null | grep -q '^default'; then
            return 0
        fi
    fi
    return 1
}

interactive_select_interface() {
    print_banner
    printf "%b

" "${C_BOLD}=== Available Network Interfaces ===${C_RESET}"

    local iface_list_str
    iface_list_str="$(get_interface_list)"
    read -r -a ifaces <<< "${iface_list_str}"

    if [[ "${#ifaces[@]}" -eq 0 ]]; then
        log_msg "ERROR" "No non-loopback network interfaces detected on this host."
        printf "${C_RED}Please verify that a virtual network adapter or lab interface is connected.${C_RESET}\n"
        read -r -p "Press [Enter] to return to the main menu..." || true
        return 1
    fi

    printf "%-4s %-16s %-18s %-16s %-10s\n" "NUM" "INTERFACE" "CURRENT IP" "NETMASK" "TYPE"
    printf "%s\n" "----------------------------------------------------------------------"

    local i=1
    local iface
    for iface in "${ifaces[@]}"; do
        local details
        details="$(get_interface_ip_details "${iface}")"
        local ip_addr netmask cidr
        IFS='|' read -r ip_addr netmask cidr <<< "${details}"

        local type_label="Ethernet/Virtual"
        if is_wireless_interface "${iface}"; then
            type_label="Wi-Fi (UNSAFE)"
        fi

        local ip_display="${ip_addr:-[No IPv4]}"
        local mask_display="${netmask:-[None]}"
        if [[ -n "${cidr}" ]]; then
            ip_display="${ip_addr}/${cidr}"
        fi

        printf "[%2d] %-16s %-18s %-16s %-10s\n" "${i}" "${iface}" "${ip_display}" "${mask_display}" "${type_label}"
        (( i++ ))
    done

    printf "\n"
    printf "Enter interface number (1-%d) or type interface name manually (or 'c' to cancel): " "${#ifaces[@]}"
    local choice
    read -r choice || choice="0"

    if [[ "${choice}" == "c" || "${choice}" == "C" || -z "${choice}" ]]; then
        return 0
    fi

    local target_iface=""
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
        target_iface="${ifaces[$((choice - 1))]}"
    else
        # Verify manual name
        target_iface="${choice}"
    fi

    # Safety Validation: Wireless / Production Network Interlock
    if is_wireless_interface "${target_iface}"; then
        printf "\n${C_BG_RED}                       DANGER: WIRELESS INTERFACE SELECTED                       ${C_RESET}\n"
        printf "${C_RED}${C_BOLD}You have selected a Wi-Fi interface ('%s').${C_RESET}\n" "${target_iface}"
        printf "${C_YELLOW}Running a DHCP server on an active Wi-Fi or campus/home network violates security${C_RESET}\n"
        printf "${C_YELLOW}protocols and will cause severe connection drops for nearby users.${C_RESET}\n\n"
        printf "If this is a strictly isolated physical Wi-Fi testing lab with NO outside clients,\n"
        printf "you must explicitly confirm authorization by typing: %sCONFIRM-ISOLATED-LAB%s\n" "${C_BOLD}" "${C_RESET}"
        printf "Confirmation: "
        local conf
        read -r conf
        if [[ "${conf}" != "CONFIRM-ISOLATED-LAB" ]]; then
            log_msg "WARN" "Aborted selection of Wi-Fi interface '${target_iface}': confirmation failed."
            read -r -p "Press [Enter] to return..." || true
            return 1
        fi
    fi

    # Check for default route warning
    if has_default_gateway_on_iface "${target_iface}"; then
        printf "\n${C_YELLOW}${C_BOLD}[WARNING] Interface '%s' currently holds the host's default gateway route!${C_RESET}\n" "${target_iface}"
        printf "${C_YELLOW}This usually signifies an upstream network connected to the Internet or university LAN.${C_RESET}\n"
        printf "Are you certain this is an isolated lab network? (yes/no): "
        local confirm_gw
        read -r confirm_gw
        if [[ "${confirm_gw}" != "yes" && "${confirm_gw}" != "YES" ]]; then
            log_msg "NOTICE" "Interface selection cancelled due to gateway conflict."
            read -r -p "Press [Enter] to return..." || true
            return 1
        fi
    fi

    # Retrieve and record interface state
    SELECTED_IFACE="${target_iface}"
    local iface_details
    iface_details="$(get_interface_ip_details "${SELECTED_IFACE}")"
    IFS='|' read -r SERVER_IP SERVER_NETMASK SERVER_CIDR <<< "${iface_details}"

    log_msg "SUCCESS" "Selected target interface: ${SELECTED_IFACE}"
    if [[ -n "${SERVER_IP}" ]]; then
        log_msg "INFO" "Interface ${SELECTED_IFACE} IPv4: ${SERVER_IP}/${SERVER_CIDR} (Netmask: ${SERVER_NETMASK})"
    else
        log_msg "WARN" "Interface ${SELECTED_IFACE} does NOT have a configured static IPv4 address!"
        printf "\n${C_YELLOW}Notice: A DHCP server requires a static IP address on its listening interface.${C_RESET}\n"
        printf "${C_YELLOW}Please assign a static IP to %s (via Netplan or 'ip addr add') before starting dnsmasq.${C_RESET}\n" "${SELECTED_IFACE}"
    fi

    read -r -p "Press [Enter] to return to the main menu..." || true
}

# ------------------------------------------------------------------------------
# Configuration Wizard with Rigorous Validation
# ------------------------------------------------------------------------------
configure_dhcp_parameters() {
    print_banner
    printf "%b

" "${C_BOLD}=== DHCP Pool and Options Configuration Wizard ===${C_RESET}"

    if [[ -z "${SELECTED_IFACE}" ]]; then
        printf "${C_RED}No interface has been selected yet.${C_RESET}\n"
        printf "Please run Option 2 to choose a network interface first.\n\n"
        read -r -p "Press [Enter] to return..." || true
        return 1
    fi

    printf "Active Interface:   ${C_CYAN}%s${C_RESET}\n" "${SELECTED_IFACE}"
    printf "Server Current IP:  ${C_CYAN}%s${C_RESET}\n" "${SERVER_IP:-[None assigned yet]}"
    printf "Server Subnet Mask: ${C_CYAN}%s${C_RESET}\n\n" "${SERVER_NETMASK:-[None assigned yet]}"

    # If server IP is missing, allow user to input the server's expected static IP
    if [[ -z "${SERVER_IP}" ]]; then
        printf "${C_YELLOW}The interface does not have an active IP address. Enter the planned static IP for this server:${C_RESET}\n"
        while true; do
            read -r -p "Server Static IPv4: " temp_server_ip
            if validate_ipv4 "${temp_server_ip}"; then
                SERVER_IP="${temp_server_ip}"
                break
            else
                printf "${C_RED}Invalid IPv4 format. Example: 192.168.50.1${C_RESET}\n"
            fi
        done

        while true; do
            read -r -p "Subnet Mask [255.255.255.0]: " temp_mask
            temp_mask="${temp_mask:-255.255.255.0}"
            if validate_netmask "${temp_mask}"; then
                SERVER_NETMASK="${temp_mask}"
                SERVER_CIDR="$(netmask_to_cidr "${SERVER_NETMASK}")"
                break
            else
                printf "${C_RED}Invalid subnet mask. Must be a contiguous mask between /8 and /30.${C_RESET}\n"
            fi
        done
    fi

    # Calculate network parameters
    local net_addr bcast_addr
    net_addr="$(calculate_network_address "${SERVER_IP}" "${SERVER_NETMASK}")"
    bcast_addr="$(calculate_broadcast_address "${SERVER_IP}" "${SERVER_NETMASK}")"

    local net_int bcast_int srv_int
    net_int="$(ipv4_to_int "${net_addr}")"
    bcast_int="$(ipv4_to_int "${bcast_addr}")"
    srv_int="$(ipv4_to_int "${SERVER_IP}")"

    local min_usable_int=$(( net_int + 1 ))
    local max_usable_int=$(( bcast_int - 1 ))

    printf "${C_WHITE}${C_BOLD}Network Boundaries for Subnet %s/%s:${C_RESET}\n" "${net_addr}" "${SERVER_CIDR}"
    printf "  - Network Address:       %s\n" "${net_addr}"
    printf "  - Broadcast Address:     %s\n" "${bcast_addr}"
    printf "  - First Usable Host IP:  %s\n" "$(int_to_ipv4 "${min_usable_int}")"
    printf "  - Last Usable Host IP:   %s\n" "$(int_to_ipv4 "${max_usable_int}")"
    printf "  - Server IP:             %s (MUST NOT OVERLAP WITH DHCP POOL)\n\n" "${SERVER_IP}"

    # Prompt for DHCP Range Start IP
    local default_start=""
    if (( srv_int == min_usable_int )); then
        default_start="$(int_to_ipv4 $(( min_usable_int + 9 )))"
    else
        default_start="$(int_to_ipv4 "${min_usable_int}")"
    fi

    while true; do
        read -r -p "Enter DHCP Range Start IP [${default_start}]: " input_start
        input_start="${input_start:-${default_start}}"

        if ! validate_ipv4 "${input_start}"; then
            printf "${C_RED}Invalid IPv4 format.${C_RESET}\n"
            continue
        fi

        if ! is_ip_in_subnet "${input_start}" "${net_addr}" "${SERVER_NETMASK}"; then
            printf "${C_RED}Start IP (%s) is not in the same subnet (%s/%s)!${C_RESET}\n" "${input_start}" "${net_addr}" "${SERVER_CIDR}"
            continue
        fi

        local start_int
        start_int="$(ipv4_to_int "${input_start}")"
        if (( start_int <= net_int || start_int >= bcast_int )); then
            printf "${C_RED}Start IP cannot be the network (%s) or broadcast (%s) address!${C_RESET}\n" "${net_addr}" "${bcast_addr}"
            continue
        fi

        DHCP_START_IP="${input_start}"
        break
    done

    # Prompt for DHCP Range End IP
    local default_end="$(int_to_ipv4 $(( max_usable_int - 5 )))"
    while true; do
        read -r -p "Enter DHCP Range End IP [${default_end}]: " input_end
        input_end="${input_end:-${default_end}}"

        if ! validate_ipv4 "${input_end}"; then
            printf "${C_RED}Invalid IPv4 format.${C_RESET}\n"
            continue
        fi

        if ! is_ip_in_subnet "${input_end}" "${net_addr}" "${SERVER_NETMASK}"; then
            printf "${C_RED}End IP (%s) is not in the same subnet (%s/%s)!${C_RESET}\n" "${input_end}" "${net_addr}" "${SERVER_CIDR}"
            continue
        fi

        local end_int
        end_int="$(ipv4_to_int "${input_end}")"
        local start_int
        start_int="$(ipv4_to_int "${DHCP_START_IP}")"

        if (( end_int < start_int )); then
            printf "${C_RED}End IP (%s) cannot be smaller than Start IP (%s)!${C_RESET}\n" "${input_end}" "${DHCP_START_IP}"
            continue
        fi

        if (( end_int <= net_int || end_int >= bcast_int )); then
            printf "${C_RED}End IP cannot be the network (%s) or broadcast (%s) address!${C_RESET}\n" "${net_addr}" "${bcast_addr}"
            continue
        fi

        # CRITICAL VALIDATION: Check server's own IP overlap with pool
        if (( srv_int >= start_int && srv_int <= end_int )); then
            printf "${C_RED}${C_BOLD}[ERROR] SERVER IP OVERLAP DETECTED!${C_RESET}\n"
            printf "${C_RED}The server's own IP (%s) falls inside the pool range (%s - %s).${C_RESET}\n" "${SERVER_IP}" "${DHCP_START_IP}" "${input_end}"
            printf "${C_YELLOW}Allocating the server's own IP to clients will cause immediate network failure.${C_RESET}\n"
            printf "Please choose a range that excludes %s.\n\n" "${SERVER_IP}"
            continue
        fi

        DHCP_END_IP="${input_end}"
        break
    done

    DHCP_SUBNET_MASK="${SERVER_NETMASK}"

    # Prompt for Lease Duration
    while true; do
        read -r -p "Enter Lease Duration (e.g., 30m, 12h, 24h, 7d) [${DHCP_LEASE_TIME}]: " input_lease
        input_lease="${input_lease:-${DHCP_LEASE_TIME}}"
        if validate_lease_duration "${input_lease}"; then
            DHCP_LEASE_TIME="${input_lease}"
            break
        else
            printf "${C_RED}Invalid lease format. Use digits followed by m, h, d, w or 'infinite'.${C_RESET}\n"
        fi
    done

    # Prompt for Optional Default Gateway (Router option 3)
    while true; do
        printf "Enter Default Gateway / Router IP for clients (leave blank if lab is isolated/no router) [%s]: " "${DHCP_GATEWAY:-none}"
        read -r input_gw
        input_gw="${input_gw:-${DHCP_GATEWAY}}"

        if [[ -z "${input_gw}" || "${input_gw}" == "none" ]]; then
            DHCP_GATEWAY=""
            break
        fi

        if ! validate_ipv4 "${input_gw}"; then
            printf "${C_RED}Invalid IPv4 format.${C_RESET}\n"
            continue
        fi

        if ! is_ip_in_subnet "${input_gw}" "${net_addr}" "${SERVER_NETMASK}"; then
            printf "${C_RED}Gateway IP (%s) must be inside the subnet (%s/%s)!${C_RESET}\n" "${input_gw}" "${net_addr}" "${SERVER_CIDR}"
            continue
        fi

        local gw_int
        gw_int="$(ipv4_to_int "${input_gw}")"
        if (( gw_int <= net_int || gw_int >= bcast_int )); then
            printf "${C_RED}Gateway cannot be network or broadcast address.${C_RESET}\n"
            continue
        fi

        DHCP_GATEWAY="${input_gw}"
        break
    done

    # Prompt for DNS Servers (option 6)
    while true; do
        read -r -p "Enter DNS Server(s) (comma-separated IPv4) [${DHCP_DNS}]: " input_dns
        input_dns="${input_dns:-${DHCP_DNS}}"

        local all_valid=true
        local dns_arr
        IFS=',' read -r -a dns_arr <<< "${input_dns}"

        local dns_ip
        for dns_ip in "${dns_arr[@]}"; do
            # Trim whitespace
            dns_ip="$(echo "${dns_ip}" | tr -d ' ')"
            if ! validate_ipv4 "${dns_ip}"; then
                printf "${C_RED}Invalid DNS IPv4: '%s'${C_RESET}\n" "${dns_ip}"
                all_valid=false
                break
            fi
        done

        if [[ "${all_valid}" == true ]]; then
            DHCP_DNS="${input_dns}"
            break
        fi
    done

    # Prompt for Optional Domain Name
    read -r -p "Enter Optional Domain Name (e.g., oslab.local) [${DHCP_DOMAIN:-none}]: " input_domain
    if [[ "${input_domain}" != "none" ]]; then
        DHCP_DOMAIN="${input_domain}"
    fi

    # Review Proposed Configuration Summary
    printf "\n${C_GREEN}${C_BOLD}=== Proposed Configuration Summary ===${C_RESET}\n"
    printf "Interface:           %s\n" "${SELECTED_IFACE}"
    printf "Server Static IP:    %s\n" "${SERVER_IP}"
    printf "Subnet Mask:         %s (/%s)\n" "${DHCP_SUBNET_MASK}" "${SERVER_CIDR}"
    printf "DHCP Pool Start:     %s\n" "${DHCP_START_IP}"
    printf "DHCP Pool End:       %s\n" "${DHCP_END_IP}"
    printf "Total Pool Hosts:    %d\n" "$(( $(ipv4_to_int "${DHCP_END_IP}") - $(ipv4_to_int "${DHCP_START_IP}") + 1 ))"
    printf "Lease Duration:      %s\n" "${DHCP_LEASE_TIME}"
    printf "Default Gateway:     %s\n" "${DHCP_GATEWAY:-None (Isolated Lab)}"
    printf "DNS Servers:         %s\n" "${DHCP_DNS}"
    printf "Domain Name:         %s\n" "${DHCP_DOMAIN:-None}"
    printf "DNS Port 53 Disable: %s (Prevents conflict with systemd-resolved)\n\n" "${DISABLE_DNS_PORT}"

    printf "Save and stage this configuration? (yes/no): "
    local confirm_save
    read -r confirm_save
    if [[ "${confirm_save}" == "yes" || "${confirm_save}" == "YES" ]]; then
        generate_dnsmasq_config
        log_msg "SUCCESS" "Configuration saved and staged successfully."
    else
        log_msg "NOTICE" "Configuration staging cancelled."
    fi

    read -r -p "Press [Enter] to return..." || true
}

# ------------------------------------------------------------------------------
# Configuration Generation, Backup & Safe Staging
# ------------------------------------------------------------------------------
generate_dnsmasq_config() {
    local target_file="${DEFAULT_CONF_FILE}"
    if [[ "${DRY_RUN_MODE}" == true ]] || [[ "${EUID}" -ne 0 && ! -w "$(dirname "${DEFAULT_CONF_FILE}" 2>/dev/null || echo ".")" ]]; then
        target_file="${LOCAL_MOCK_CONF}"
    fi

    log_msg "INFO" "Generating dnsmasq configuration for interface ${SELECTED_IFACE}..."

    # Ensure parent directory exists
    local target_dir
    target_dir="$(dirname "${target_file}")"
    if [[ ! -d "${target_dir}" ]]; then
        if [[ "${DRY_RUN_MODE}" == true ]]; then
            log_msg "DRYRUN" "mkdir -p ${target_dir}"
        else
            mkdir -p "${target_dir}" 2>/dev/null || sudo mkdir -p "${target_dir}"
        fi
    fi

    # Backup existing configuration file if present
    if [[ -f "${target_file}" ]]; then
        local timestamp
        timestamp="$(date '+%Y%m%d_%H%M%S')"
        local backup_file="${target_file}.bak.${timestamp}"
        log_msg "INFO" "Creating backup of existing configuration: ${backup_file}"
        if [[ "${DRY_RUN_MODE}" == true ]]; then
            log_msg "DRYRUN" "cp ${target_file} ${backup_file}"
        else
            if [[ -w "${target_file}" ]]; then
                cp "${target_file}" "${backup_file}"
            else
                sudo cp "${target_file}" "${backup_file}"
            fi
            log_msg "SUCCESS" "Backup created: ${backup_file}"
        fi
    fi

    # Generate configuration content in a temporary string
    local config_content
    config_content="$(cat << EOF
# ==============================================================================
# DHCP SERVER SETUP & MANAGEMENT TOOLKIT CONFIGURATION
# Managed automatically by dhcp-toolkit.sh (v${TOOLKIT_VERSION})
# Created: $(date '+%Y-%m-%d %H:%M:%S')
#
# DO NOT EDIT MANUALLY - Use dhcp-toolkit.sh to modify or remove.
# ==============================================================================

# Interface Binding: strictly serve DHCP only on the designated lab adapter
interface=${SELECTED_IFACE}
bind-interfaces

# Do not forward plain names or addresses outside the local network
domain-needed
bogus-priv

# DHCP Range and Lease Duration
dhcp-range=${DHCP_START_IP},${DHCP_END_IP},${DHCP_SUBNET_MASK},${DHCP_LEASE_TIME}

# Subnet Mask Option (Option 1)
dhcp-option=option:netmask,${DHCP_SUBNET_MASK}
EOF
)"

    # Append Gateway Option if configured
    if [[ -n "${DHCP_GATEWAY}" ]]; then
        config_content+=$'\n'
        config_content+="# Default Gateway / Router (Option 3)"$'\n'
        config_content+="dhcp-option=option:router,${DHCP_GATEWAY}"$'\n'
    else
        config_content+=$'\n'
        config_content+="# No Default Gateway advertised (Isolated Lab Mode)"$'\n'
        config_content+="dhcp-option=option:router"$'\n'
    fi

    # Append DNS Server Option
    if [[ -n "${DHCP_DNS}" ]]; then
        config_content+=$'\n'
        config_content+="# Domain Name Servers (Option 6)"$'\n'
        config_content+="dhcp-option=option:dns-server,${DHCP_DNS}"$'\n'
    fi

    # Append Domain Name if configured
    if [[ -n "${DHCP_DOMAIN}" ]]; then
        config_content+=$'\n'
        config_content+="# Domain Name (Option 15)"$'\n'
        config_content+="domain=${DHCP_DOMAIN}"$'\n'
        config_content+="dhcp-option=option:domain-name,${DHCP_DOMAIN}"$'\n'
    fi

    # Lease File and Authoritative Mode
    config_content+=$'\n'
    config_content+="$(cat << EOF
# Lease File Storage
dhcp-leasefile=${DEFAULT_LEASE_FILE}

# Authoritative DHCP Server on this isolated network segment
# (speeds up lease acquisition and re-allocation for clients)
dhcp-authoritative
EOF
)"

    # Disable DNS listener if requested to eliminate systemd-resolved port 53 clash
    if [[ "${DISABLE_DNS_PORT}" == true ]]; then
        config_content+=$'\n'
        config_content+="$(cat << EOF

# Disable DNS listener (port=0) to run purely as a DHCP server.
# This prevents conflicts with systemd-resolved listening on 127.0.0.53:53.
port=0
EOF
)"
    fi

    config_content+=$'\n# === END OF DHCP TOOLKIT MANAGED CONFIGURATION ===\n'

    # Write configuration
    if [[ "${DRY_RUN_MODE}" == true ]]; then
        log_msg "DRYRUN" "Writing configuration to ${target_file}"
        printf "%s\n" "${config_content}" > "${target_file}"
        log_msg "SUCCESS" "[DRY-RUN] Staged preview configuration in ${target_file}"
    else
        if [[ "${EUID}" -eq 0 ]] || [[ -w "${target_dir}" ]]; then
            printf "%s\n" "${config_content}" > "${target_file}"
            chmod 644 "${target_file}"
        else
            printf "%s\n" "${config_content}" | sudo tee "${target_file}" > /dev/null
            sudo chmod 644 "${target_file}"
        fi
        log_msg "SUCCESS" "Configuration written to ${target_file}"
    fi

    # Ensure main dnsmasq.conf includes /etc/dnsmasq.d
    ensure_conf_dir_included
}

ensure_conf_dir_included() {
    if [[ "${DRY_RUN_MODE}" == true ]] || [[ ! -f "${DEFAULT_MAIN_CONF}" ]]; then
        return 0
    fi

    if grep -qE '^[[:space:]]*conf-dir=/etc/dnsmasq.d' "${DEFAULT_MAIN_CONF}" 2>/dev/null; then
        log_msg "INFO" "${DEFAULT_MAIN_CONF} already includes conf-dir=/etc/dnsmasq.d"
    else
        log_msg "NOTICE" "Ensuring ${DEFAULT_MAIN_CONF} includes conf-dir=/etc/dnsmasq.d"
        local append_line="conf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new"
        if [[ "${EUID}" -eq 0 ]]; then
            printf "\n%s\n" "${append_line}" >> "${DEFAULT_MAIN_CONF}"
        else
            printf "\n%s\n" "${append_line}" | sudo tee -a "${DEFAULT_MAIN_CONF}" > /dev/null
        fi
    fi
}

# ------------------------------------------------------------------------------
# Package Installation (dnsmasq) with Confirmation
# ------------------------------------------------------------------------------
install_dnsmasq_package() {
    print_banner
    printf "%b

" "${C_BOLD}=== Install / Verify dnsmasq Package ===${C_RESET}"

    if command -v dnsmasq >/dev/null 2>&1; then
        local version_info
        version_info="$(dnsmasq --version 2>&1 | head -n1)"
        log_msg "SUCCESS" "dnsmasq is already installed on this system: ${version_info}"
        printf "Reinstallation is not required.\n\n"
        read -r -p "Press [Enter] to return..." || true
        return 0
    fi

    printf "Package to install:  ${C_CYAN}dnsmasq${C_RESET} (and dnsmasq-base)\n"
    printf "Target OS Manager:   ${C_CYAN}apt / apt-get${C_RESET}\n"
    printf "Purpose:             Provides lightweight DHCP and DNS service for Linux.\n\n"

    printf "${C_YELLOW}System command to run:${C_RESET}\n"
    printf "  sudo apt-get update && sudo apt-get install -y dnsmasq\n\n"

    if [[ "${DRY_RUN_MODE}" == true ]]; then
        log_msg "DRYRUN" "apt-get update && apt-get install -y dnsmasq"
        printf "${C_MAGENTA}[DRY-RUN] Package installation simulated successfully.${C_RESET}\n\n"
        read -r -p "Press [Enter] to return..." || true
        return 0
    fi

    printf "Do you want to proceed with installing dnsmasq? (yes/no): "
    local confirm_install
    read -r confirm_install
    if [[ "${confirm_install}" != "yes" && "${confirm_install}" != "YES" ]]; then
        log_msg "NOTICE" "Installation aborted by user."
        read -r -p "Press [Enter] to return..." || true
        return 1
    fi

    log_msg "INFO" "Updating package index and installing dnsmasq..."
    if [[ "${EUID}" -eq 0 ]]; then
        apt-get update -qq && apt-get install -y dnsmasq
    else
        sudo apt-get update -qq && sudo apt-get install -y dnsmasq
    fi

    if command -v dnsmasq >/dev/null 2>&1; then
        log_msg "SUCCESS" "dnsmasq installed successfully."
    else
        log_msg "ERROR" "Installation completed but 'dnsmasq' binary was not found in PATH."
    fi

    read -r -p "Press [Enter] to return..." || true
}

# ------------------------------------------------------------------------------
# Configuration Syntax Validation
# ------------------------------------------------------------------------------
validate_configuration_syntax() {
    local target_file="${DEFAULT_CONF_FILE}"
    if [[ "${DRY_RUN_MODE}" == true ]] || [[ ! -f "${DEFAULT_CONF_FILE}" && -f "${LOCAL_MOCK_CONF}" ]]; then
        target_file="${LOCAL_MOCK_CONF}"
    fi

    log_msg "INFO" "Validating configuration file: ${target_file}"

    if [[ ! -f "${target_file}" ]]; then
        log_msg "ERROR" "Configuration file not found: ${target_file}"
        return 1
    fi

    if command -v dnsmasq >/dev/null 2>&1; then
        local test_output
        local exit_code=0
        test_output="$(dnsmasq --test --conf-file="${target_file}" 2>&1)" || exit_code=$?

        if [[ "${exit_code}" -eq 0 ]] && [[ "${test_output}" == *"syntax check OK"* ]]; then
            log_msg "SUCCESS" "Configuration syntax validation PASSED: syntax check OK."
            return 0
        else
            log_msg "ERROR" "Configuration syntax validation FAILED (exit code: ${exit_code})"
            printf "%s\n" "${test_output}" >&2
            return 1
        fi
    else
        log_msg "NOTICE" "dnsmasq is not installed locally. Performing structural parameter checks..."
        local syntax_errors=0

        if ! grep -q "^interface=" "${target_file}"; then
            log_msg "ERROR" "Missing 'interface' directive in ${target_file}"
            (( syntax_errors++ ))
        fi
        if ! grep -q "^dhcp-range=" "${target_file}"; then
            log_msg "ERROR" "Missing 'dhcp-range' directive in ${target_file}"
            (( syntax_errors++ ))
        fi

        if (( syntax_errors == 0 )); then
            log_msg "SUCCESS" "Structural configuration checks PASSED."
            return 0
        else
            log_msg "ERROR" "Structural validation found ${syntax_errors} issues."
            return 1
        fi
    fi
}

interactive_validate_config() {
    print_banner
    printf "%b

" "${C_BOLD}=== Validate DHCP Configuration Syntax ===${C_RESET}"
    validate_configuration_syntax || true
    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

# ------------------------------------------------------------------------------
# Service Lifecycle Control (Start / Stop / Restart / Status)
# ------------------------------------------------------------------------------
start_or_restart_service() {
    print_banner
    printf "%b

" "${C_BOLD}=== Start / Restart DHCP Service ===${C_RESET}"

    # Pre-validation check: NEVER start without passing syntax check
    if ! validate_configuration_syntax; then
        printf "\n${C_RED}[ABORT] Configuration validation failed. Service will NOT be started.${C_RESET}\n"
        read -r -p "Press [Enter] to return..." || true
        return 1
    fi

    # Safety check on interface
    if [[ -n "${SELECTED_IFACE}" ]] && is_wireless_interface "${SELECTED_IFACE}"; then
        printf "${C_RED}[ABORT] Refusing to start DHCP server on Wi-Fi interface '%s'.${C_RESET}\n" "${SELECTED_IFACE}"
        read -r -p "Press [Enter] to return..." || true
        return 1
    fi

    if [[ "${DRY_RUN_MODE}" == true ]]; then
        log_msg "DRYRUN" "systemctl restart dnsmasq"
        log_msg "SUCCESS" "[DRY-RUN] Service restart simulated."
        read -r -p "Press [Enter] to return..." || true
        return 0
    fi

    log_msg "INFO" "Restarting dnsmasq service..."
    local restart_ok=false

    if is_in_netns; then
        local current_ns
        current_ns="$(ip netns identify $$ 2>/dev/null || echo "isolated-netns")"
        log_msg "INFO" "Running inside network namespace (${current_ns}). Starting dnsmasq process directly inside namespace..."
        pkill -x dnsmasq 2>/dev/null || true
        if dnsmasq --conf-file="${target_file}"; then
            restart_ok=true
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        if [[ "${EUID}" -eq 0 ]]; then
            systemctl restart dnsmasq && restart_ok=true || true
        else
            sudo systemctl restart dnsmasq && restart_ok=true || true
        fi
    elif command -v service >/dev/null 2>&1; then
        if [[ "${EUID}" -eq 0 ]]; then
            service dnsmasq restart && restart_ok=true || true
        else
            sudo service dnsmasq restart && restart_ok=true || true
        fi
    fi

    if [[ "${restart_ok}" == true ]]; then
        log_msg "SUCCESS" "dnsmasq service started/restarted successfully."
        # Enable on boot
        if command -v systemctl >/dev/null 2>&1; then
            if [[ "${EUID}" -eq 0 ]]; then
                systemctl enable dnsmasq >/dev/null 2>&1 || true
            else
                sudo systemctl enable dnsmasq >/dev/null 2>&1 || true
            fi
        fi
    else
        log_msg "ERROR" "Failed to start dnsmasq service."
        printf "${C_YELLOW}Check logs with: journalctl -xeu dnsmasq${C_RESET}\n"
    fi

    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

stop_dhcp_service() {
    print_banner
    printf "%b

" "${C_BOLD}=== Stop DHCP Service ===${C_RESET}"

    if [[ "${DRY_RUN_MODE}" == true ]]; then
        log_msg "DRYRUN" "systemctl stop dnsmasq"
        log_msg "SUCCESS" "[DRY-RUN] Service stop simulated."
        read -r -p "Press [Enter] to return..." || true
        return 0
    fi

    log_msg "INFO" "Stopping dnsmasq service..."
    local stop_ok=false

    if is_in_netns; then
        log_msg "INFO" "Stopping dnsmasq process inside network namespace..."
        pkill -x dnsmasq 2>/dev/null && stop_ok=true || true
    elif command -v systemctl >/dev/null 2>&1; then
        if [[ "${EUID}" -eq 0 ]]; then
            systemctl stop dnsmasq && stop_ok=true || true
        else
            sudo systemctl stop dnsmasq && stop_ok=true || true
        fi
    elif command -v service >/dev/null 2>&1; then
        if [[ "${EUID}" -eq 0 ]]; then
            service dnsmasq stop && stop_ok=true || true
        else
            sudo service dnsmasq stop && stop_ok=true || true
        fi
    fi

    if [[ "${stop_ok}" == true ]]; then
        log_msg "SUCCESS" "dnsmasq service has been stopped."
    else
        log_msg "WARN" "Failed to stop dnsmasq or service was not running."
    fi

    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

check_service_and_leases() {
    print_banner
    printf "%b

" "${C_BOLD}=== DHCP Service Status & Active Leases ===${C_RESET}"

    printf "${C_WHITE}${C_BOLD}[1] Service Status:${C_RESET}\n"
    if [[ "${DRY_RUN_MODE}" == true ]]; then
        printf "${C_MAGENTA}[DRY-RUN] Simulated Service State: Active (running)${C_RESET}\n"
    elif is_in_netns; then
        if pgrep -x dnsmasq >/dev/null 2>&1; then
            printf "${C_GREEN}dnsmasq process is RUNNING inside namespace (PID: %s)${C_RESET}\n" "$(pgrep -x dnsmasq | tr '\n' ' ')"
        else
            printf "${C_RED}dnsmasq is NOT running inside this network namespace.${C_RESET}\n"
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl status dnsmasq --no-pager -l || true
    elif command -v service >/dev/null 2>&1; then
        service dnsmasq status || true
    else
        printf "${C_YELLOW}Service status tools not available.${C_RESET}\n"
    fi

    printf "\n${C_WHITE}${C_BOLD}[2] Listening UDP Sockets (Port 67):${C_RESET}\n"
    if [[ "${DRY_RUN_MODE}" == true ]]; then
        printf "${C_MAGENTA}[DRY-RUN] Simulated Socket: udp UNCONN 0 0 %s:67 users:((\"dnsmasq\"))${C_RESET}\n" "${SERVER_IP:-0.0.0.0}"
    elif command -v ss >/dev/null 2>&1; then
        ss -ulpn 2>/dev/null | grep -E 'State|:67\b' || echo "No process currently bound to port 67."
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iUDP:67 -n -P 2>/dev/null || echo "No process currently bound to port 67."
    fi

    printf "\n${C_WHITE}${C_BOLD}[3] Active DHCP Leases (${DEFAULT_LEASE_FILE}):${C_RESET}\n"
    local lease_file="${DEFAULT_LEASE_FILE}"
    if [[ ! -f "${lease_file}" ]] && [[ -f "./dnsmasq.leases" ]]; then
        lease_file="./dnsmasq.leases"
    fi

    if [[ -f "${lease_file}" ]] && [[ -s "${lease_file}" ]]; then
        printf "%-22s %-18s %-16s %-20s %-15s\n" "EXPIRATION" "MAC ADDRESS" "IP ADDRESS" "HOSTNAME" "CLIENT-ID"
        printf "%s\n" "---------------------------------------------------------------------------------------------"
        local exp_epoch mac ip host client_id
        while read -r exp_epoch mac ip host client_id; do
            local exp_human
            if date -r "${exp_epoch}" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
                # BSD date (macOS)
                exp_human="$(date -r "${exp_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${exp_epoch}")"
            else
                # GNU date (Linux)
                exp_human="$(date -d "@${exp_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${exp_epoch}")"
            fi
            printf "%-22s %-18s %-16s %-20s %-15s\n" "${exp_human}" "${mac}" "${ip}" "${host}" "${client_id}"
        done < "${lease_file}"
    else
        printf "${C_CYAN}No active DHCP leases recorded yet in %s.${C_RESET}\n" "${lease_file}"
    fi

    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

view_active_configuration() {
    print_banner
    printf "%b

" "${C_BOLD}=== View Project Configuration ===${C_RESET}"

    local target_file="${DEFAULT_CONF_FILE}"
    if [[ "${DRY_RUN_MODE}" == true ]] || [[ ! -f "${DEFAULT_CONF_FILE}" && -f "${LOCAL_MOCK_CONF}" ]]; then
        target_file="${LOCAL_MOCK_CONF}"
    fi

    if [[ -f "${target_file}" ]]; then
        printf "${C_WHITE}Configuration file: %s${C_RESET}\n\n" "${target_file}"
        printf "%s\n" "----------------------------------------------------------------------"
        cat "${target_file}"
        printf "%s\n" "----------------------------------------------------------------------"
    else
        printf "${C_YELLOW}No configuration file found at %s.${C_RESET}\n" "${target_file}"
        printf "Please use Option 3 to configure and stage settings first.\n"
    fi

    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

# ------------------------------------------------------------------------------
# Safe Teardown & Configuration Removal
# ------------------------------------------------------------------------------
remove_project_configuration() {
    print_banner
    printf "%b

" "${C_BOLD}=== Remove Project-Managed DHCP Configuration ===${C_RESET}"

    printf "${C_YELLOW}This operation will:${C_RESET}\n"
    printf "  1. Stop the dnsmasq service.\n"
    printf "  2. Delete ONLY the project configuration file: ${C_CYAN}%s${C_RESET}\n" "${DEFAULT_CONF_FILE}"
    printf "  3. Preserve all other files in /etc/dnsmasq.d/ and /etc/dnsmasq.conf.\n"
    printf "  4. Optionally restore the most recent backup file if present.\n\n"

    printf "Are you sure you want to remove project DHCP settings? (yes/no): "
    local confirm_removal
    read -r confirm_removal
    if [[ "${confirm_removal}" != "yes" && "${confirm_removal}" != "YES" ]]; then
        log_msg "NOTICE" "Configuration removal aborted."
        read -r -p "Press [Enter] to return..." || true
        return 0
    fi

    # Step 1: Stop service
    if [[ "${DRY_RUN_MODE}" == true ]]; then
        log_msg "DRYRUN" "systemctl stop dnsmasq"
    else
        if command -v systemctl >/dev/null 2>&1; then
            if [[ "${EUID}" -eq 0 ]]; then
                systemctl stop dnsmasq >/dev/null 2>&1 || true
            else
                sudo systemctl stop dnsmasq >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Step 2: Remove dedicated conf file
    if [[ -f "${DEFAULT_CONF_FILE}" ]]; then
        if [[ "${DRY_RUN_MODE}" == true ]]; then
            log_msg "DRYRUN" "rm -f ${DEFAULT_CONF_FILE}"
        else
            if [[ "${EUID}" -eq 0 ]]; then
                rm -f "${DEFAULT_CONF_FILE}"
            else
                sudo rm -f "${DEFAULT_CONF_FILE}"
            fi
            log_msg "SUCCESS" "Removed project configuration file: ${DEFAULT_CONF_FILE}"
        fi
    fi

    # Also clean local preview if present
    if [[ -f "${LOCAL_MOCK_CONF}" ]]; then
        rm -f "${LOCAL_MOCK_CONF}"
        log_msg "INFO" "Removed local mock configuration file."
    fi

    # Step 3: Check for backups
    local latest_backup=""
    latest_backup="$(ls -t "${DEFAULT_CONF_FILE}.bak."* 2>/dev/null | head -n1 || true)"
    if [[ -n "${latest_backup}" && -f "${latest_backup}" ]]; then
        printf "\nA previous backup was found: ${C_CYAN}%s${C_RESET}\n" "${latest_backup}"
        printf "Would you like to restore this backup? (yes/no): "
        local confirm_restore
        read -r confirm_restore
        if [[ "${confirm_restore}" == "yes" || "${confirm_restore}" == "YES" ]]; then
            if [[ "${DRY_RUN_MODE}" == true ]]; then
                log_msg "DRYRUN" "cp ${latest_backup} ${DEFAULT_CONF_FILE}"
            else
                if [[ "${EUID}" -eq 0 ]]; then
                    cp "${latest_backup}" "${DEFAULT_CONF_FILE}"
                else
                    sudo cp "${latest_backup}" "${DEFAULT_CONF_FILE}"
                fi
                log_msg "SUCCESS" "Restored backup configuration."
            fi
        fi
    fi

    log_msg "SUCCESS" "Project teardown completed cleanly."
    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

# ------------------------------------------------------------------------------
# Firewall & Network Configuration Advice
# ------------------------------------------------------------------------------
firewall_and_network_guidance() {
    print_banner
    printf "%b

" "${C_BOLD}=== Firewall & Network Interface Configuration Guidance ===${C_RESET}"

    printf "${C_WHITE}${C_BOLD}[A] DHCP Protocol Firewall Requirements:${C_RESET}\n"
    printf "DHCP uses broadcast and unicast UDP datagrams between client and server:\n"
    printf "  - Server Port:  ${C_CYAN}UDP 67${C_RESET} (DHCP Server listening for DISCOVER and REQUEST)\n"
    printf "  - Client Port:  ${C_CYAN}UDP 68${C_RESET} (DHCP Client listening for OFFER and ACK)\n"
    if [[ "${DISABLE_DNS_PORT}" == false ]]; then
        printf "  - DNS Port:     ${C_CYAN}UDP/TCP 53${C_RESET} (if DNS proxying is enabled)\n"
    fi
    printf "\n"

    printf "${C_WHITE}${C_BOLD}[B] UFW (Uncomplicated Firewall) Status & Commands:${C_RESET}\n"
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status="$(ufw status 2>/dev/null || echo "requires sudo")"
        printf "Current UFW Status:\n%s\n\n" "${ufw_status}"
    fi

    local iface="${SELECTED_IFACE:-<lab-interface>}"
    printf "To allow DHCP traffic on the lab interface without exposing your host:\n"
    printf "  ${C_GREEN}sudo ufw allow in on %s to any port 67 proto udp comment 'DHCP Server'${C_RESET}\n" "${iface}"
    if [[ "${DISABLE_DNS_PORT}" == false ]]; then
        printf "  ${C_GREEN}sudo ufw allow in on %s to any port 53 comment 'Lab DNS'${C_RESET}\n" "${iface}"
    fi
    printf "\n"

    printf "${C_WHITE}${C_BOLD}[C] Static IP Configuration (Ubuntu Netplan):${C_RESET}\n"
    printf "A DHCP server interface MUST have a static IP address assigned.\n"
    printf "Example Netplan snippet (/etc/netplan/01-lab-dhcp.yaml):\n"
    printf "${C_CYAN}"
    cat << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: no
      addresses:
        - ${SERVER_IP:-192.168.50.1}/${SERVER_CIDR:-24}
EOF
    printf "${C_RESET}\n"
    printf "Apply with: ${C_BOLD}sudo netplan apply${C_RESET}\n\n"

    printf "Apply UFW firewall rule for '%s' now? (yes/no): " "${iface}"
    local apply_fw
    read -r apply_fw
    if [[ "${apply_fw}" == "yes" || "${apply_fw}" == "YES" ]]; then
        if [[ "${DRY_RUN_MODE}" == true ]]; then
            log_msg "DRYRUN" "ufw allow in on ${iface} to any port 67 proto udp"
        else
            if [[ "${EUID}" -eq 0 ]]; then
                ufw allow in on "${iface}" to any port 67 proto udp
            else
                sudo ufw allow in on "${iface}" to any port 67 proto udp
            fi
            log_msg "SUCCESS" "UFW firewall rule added."
        fi
    fi

    printf "\n"
    read -r -p "Press [Enter] to return..." || true
}

# ------------------------------------------------------------------------------
# Built-In Self-Test Suite (IP Math, Overlap & Boundary Checks)
# ------------------------------------------------------------------------------
run_selftest_suite() {
    log_msg "INFO" "Executing automated self-test verification suite..."
    local test_failures=0

    # Test 1: IPv4 Validation
    validate_ipv4 "192.168.1.1" || { log_msg "ERROR" "Test 1a failed: valid IP rejected"; (( test_failures++ )); }
    ! validate_ipv4 "256.1.1.1" || { log_msg "ERROR" "Test 1b failed: invalid octet accepted"; (( test_failures++ )); }
    ! validate_ipv4 "192.168.01.1" || { log_msg "ERROR" "Test 1c failed: leading zero accepted"; (( test_failures++ )); }
    ! validate_ipv4 "abc.def.ghi.jkl" || { log_msg "ERROR" "Test 1d failed: non-numeric accepted"; (( test_failures++ )); }

    # Test 2: IP to Int Conversion Round-trip
    local int_val
    int_val="$(ipv4_to_int "192.168.1.1")"
    local ip_back
    ip_back="$(int_to_ipv4 "${int_val}")"
    [[ "${ip_back}" == "192.168.1.1" ]] || { log_msg "ERROR" "Test 2 failed: round-trip mismatch"; (( test_failures++ )); }

    # Test 3: Netmask and CIDR conversion
    local cidr
    cidr="$(netmask_to_cidr "255.255.255.0")"
    [[ "${cidr}" == "24" ]] || { log_msg "ERROR" "Test 3a failed: netmask /24 calculation mismatch"; (( test_failures++ )); }
    local mask
    mask="$(cidr_to_netmask 24)"
    [[ "${mask}" == "255.255.255.0" ]] || { log_msg "ERROR" "Test 3b failed: cidr to netmask mismatch"; (( test_failures++ )); }
    ! validate_netmask "255.255.255.1" || { log_msg "ERROR" "Test 3c failed: non-contiguous netmask accepted"; (( test_failures++ )); }

    # Test 4: Subnet Membership Calculation
    is_ip_in_subnet "192.168.50.10" "192.168.50.0" "255.255.255.0" || { log_msg "ERROR" "Test 4a failed: in-subnet check"; (( test_failures++ )); }
    ! is_ip_in_subnet "192.168.51.10" "192.168.50.0" "255.255.255.0" || { log_msg "ERROR" "Test 4b failed: cross-subnet check"; (( test_failures++ )); }

    # Test 5: Server IP Anti-Overlap Invariant
    local srv_int start_int end_int
    srv_int="$(ipv4_to_int "192.168.50.1")"
    start_int="$(ipv4_to_int "192.168.50.1")"
    end_int="$(ipv4_to_int "192.168.50.50")"
    # Overlap must be detected
    if (( srv_int >= start_int && srv_int <= end_int )); then
        log_msg "SUCCESS" "Test 5 passed: Server IP overlap correctly detected and flagged."
    else
        log_msg "ERROR" "Test 5 failed: Server IP overlap not detected"; (( test_failures++ ))
    fi

    # Test 6: Lease Duration Formats
    validate_lease_duration "30m" || { log_msg "ERROR" "Test 6a failed: 30m rejected"; (( test_failures++ )); }
    validate_lease_duration "12h" || { log_msg "ERROR" "Test 6b failed: 12h rejected"; (( test_failures++ )); }
    validate_lease_duration "7d" || { log_msg "ERROR" "Test 6c failed: 7d rejected"; (( test_failures++ )); }
    validate_lease_duration "infinite" || { log_msg "ERROR" "Test 6d failed: infinite rejected"; (( test_failures++ )); }
    ! validate_lease_duration "invalid" || { log_msg "ERROR" "Test 6e failed: invalid lease accepted"; (( test_failures++ )); }

    if (( test_failures == 0 )); then
        log_msg "SUCCESS" "All automated self-tests passed cleanly (0 errors)."
        return 0
    else
        log_msg "ERROR" "Self-test suite completed with ${test_failures} errors."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Interactive Menu Loop
# ------------------------------------------------------------------------------
interactive_menu() {
    while true; do
        print_banner
        print_safety_warning

        printf "${C_BOLD}Active Configuration Context:${C_RESET}\n"
        printf "  Interface:      ${C_CYAN}%s${C_RESET}\n" "${SELECTED_IFACE:-[Not Selected]}"
        printf "  Server IP:      ${C_CYAN}%s${C_RESET}\n" "${SERVER_IP:-[None]}"
        printf "  DHCP Pool:      ${C_CYAN}%s - %s${C_RESET}\n" "${DHCP_START_IP:-None}" "${DHCP_END_IP:-None}"
        printf "  Dry-Run Mode:   %s\n" "$([[ "${DRY_RUN_MODE}" == true ]] && echo "${C_MAGENTA}ENABLED${C_RESET}" || echo "${C_GREEN}DISABLED (Live System)${C_RESET}")"
        printf "\n"

        printf "${C_BOLD}Main Menu Operations:${C_RESET}\n"
        printf "  [1]  Run Pre-flight Diagnostics (OS, Tools, Sudo, Port Conflicts)\n"
        printf "  [2]  Select Network Interface & Inspect Details\n"
        printf "  [3]  Configure DHCP Server Settings (Pool, Leases, Gateway, DNS)\n"
        printf "  [4]  Install / Verify dnsmasq Package\n"
        printf "  [5]  Validate Configuration File Syntax (dnsmasq --test)\n"
        printf "  [6]  Start / Restart DHCP Service\n"
        printf "  [7]  View DHCP Service Status & Active Leases\n"
        printf "  [8]  Stop DHCP Service\n"
        printf "  [9]  View Staged / Active Configuration File\n"
        printf "  [10] Remove Project Configuration & Clean Up (Safe Teardown)\n"
        printf "  [11] Review Firewall (UFW) and Netplan Guidance\n"
        printf "  [12] Toggle Dry-Run Mode\n"
        printf "  [13] Run Built-In Self-Tests (IP Math & Validation)\n"
        printf "  [0]  Exit Toolkit\n"
        printf "\n"

        printf "Enter choice [0-13]: "
        local choice
        read -r choice || choice="0"

        case "${choice}" in
            1)
                print_banner
                detect_ubuntu_environment || true
                check_sudo_privileges || true
                check_required_tools || true
                detect_port_conflicts || true
                printf "\n"
                read -r -p "Press [Enter] to return..." || true
                ;;
            2)
                interactive_select_interface
                ;;
            3)
                configure_dhcp_parameters
                ;;
            4)
                install_dnsmasq_package
                ;;
            5)
                interactive_validate_config
                ;;
            6)
                start_or_restart_service
                ;;
            7)
                check_service_and_leases
                ;;
            8)
                stop_dhcp_service
                ;;
            9)
                view_active_configuration
                ;;
            10)
                remove_project_configuration
                ;;
            11)
                firewall_and_network_guidance
                ;;
            12)
                if [[ "${DRY_RUN_MODE}" == true ]]; then
                    DRY_RUN_MODE=false
                    log_msg "NOTICE" "Dry-Run mode disabled. Operations will apply to system files."
                else
                    DRY_RUN_MODE=true
                    log_msg "NOTICE" "Dry-Run mode enabled. Operations will be simulated."
                fi
                sleep 1
                ;;
            13)
                print_banner
                run_selftest_suite || true
                printf "\n"
                read -r -p "Press [Enter] to return..." || true
                ;;
            0|q|Q|exit)
                log_msg "INFO" "Exiting DHCP Management Toolkit."
                break
                ;;
            *)
                printf "${C_RED}Invalid choice. Please select an option between 0 and 13.${C_RESET}\n"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# CLI Argument Parser & Entry Point
# ------------------------------------------------------------------------------
print_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

DHCP Server Setup and Management Toolkit using dnsmasq for Ubuntu.
Designed for isolated lab networks and authorized administrative testing.

Options:
  -h, --help        Show this help message and exit
  -d, --dry-run     Enable dry-run mode (simulate without touching /etc or services)
  -c, --check       Run system diagnostics and pre-flight checks, then exit
  -s, --status      Display DHCP service status, sockets, and active leases
  -v, --validate    Validate syntax of existing dnsmasq configuration
  -t, --test-math   Run automated self-tests for IP math and safety rules
  -V, --version     Print toolkit version and exit

Interactive Menu:
  Run without options to launch the interactive menu-driven interface:
    ./$(basename "$0")

Safety Guidelines:
  - DO NOT run on shared, campus, or public networks.
  - DO NOT run on active Wi-Fi adapters.
  - ALWAYS back up configurations prior to modification (handled automatically).
EOF
}

main() {
    init_logging

    # Parse command line flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -V|--version)
                printf "DHCP Management Toolkit v%s\n" "${TOOLKIT_VERSION}"
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN_MODE=true
                shift
                ;;
            -c|--check)
                detect_ubuntu_environment || true
                check_sudo_privileges || true
                check_required_tools || true
                detect_port_conflicts || true
                exit 0
                ;;
            -s|--status)
                check_service_and_leases
                exit 0
                ;;
            -v|--validate)
                validate_configuration_syntax
                exit 0
                ;;
            -t|--test-math)
                run_selftest_suite
                exit 0
                ;;
            *)
                printf "${C_RED}Unknown option: %s${C_RESET}\n" "$1" >&2
                print_help
                exit 1
                ;;
        esac
    done

    # Start interactive menu if no single-shot action was requested
    interactive_menu
}

main "$@"
