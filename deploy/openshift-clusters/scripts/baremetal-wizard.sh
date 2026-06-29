#!/usr/bin/bash
#
# Interactive wizard for creating a baremetal node inventory.
#
# Collects BMC credentials and network info for each node, validates input,
# displays a summary for confirmation, and writes inventory_baremetal.ini.
#
# Usage:
#   baremetal-wizard.sh [options]
#
# Options:
#   --output FILE   Inventory output path (default: inventory_baremetal.ini)
#   -h, --help      Show this help message

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT="${OC_DIR}/inventory_baremetal.ini"

##############################################################################
# Helpers
##############################################################################

die() { echo "Error: $*" >&2; exit 1; }

info() { echo "==> $*"; }

##############################################################################
# Argument parsing
##############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output)
                OUTPUT="$2"
                shift 2
                ;;
            -h|--help)
                head -14 "$0" | tail -9
                exit 0
                ;;
            *)
                die "Unknown option: $1. Run '$0 --help' for usage."
                ;;
        esac
    done
}

##############################################################################
# Validators
##############################################################################

valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets
    read -ra octets <<< "${ip}"
    [[ ${#octets[@]} -ne 4 ]] && return 1
    local octet
    for octet in "${octets[@]}"; do
        [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
        (( octet > 255 )) && return 1
    done
    return 0
}

valid_mac() {
    local mac="$1"
    [[ "${mac}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]
}

valid_hostname() {
    local name="$1"
    [[ -n "${name}" ]] && [[ "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]
}

valid_bmc_address() {
    local addr="$1"
    valid_ipv4 "${addr}" || valid_hostname "${addr}"
}

##############################################################################
# Prompt functions
#
# Each loops until valid input is received. Values go to stdout (for capture
# with val=$(...)), prompts and errors go to stderr (displayed on terminal).
##############################################################################

prompt_node_count() {
    local count
    while true; do
        read -rp "Number of baremetal nodes [2]: " count
        count="${count:-2}"
        if ! [[ "${count}" =~ ^[0-9]+$ ]]; then
            echo "  Error: must be a number" >&2
            continue
        fi
        if (( count < 2 )); then
            echo "  Error: TNF requires at least 2 nodes" >&2
            continue
        fi
        echo "${count}"
        return
    done
}

prompt_hostname() {
    local default_name="$1"
    local name
    while true; do
        read -rp "  Hostname [${default_name}]: " name
        name="${name:-${default_name}}"
        if ! valid_hostname "${name}"; then
            echo "  Error: invalid hostname (use alphanumeric, hyphens, dots)" >&2
            continue
        fi
        echo "${name}"
        return
    done
}

prompt_bmc_address() {
    local addr
    while true; do
        read -rp "  BMC address (IP or hostname): " addr
        if [[ -z "${addr}" ]]; then
            echo "  Error: BMC address is required" >&2
            continue
        fi
        if ! valid_bmc_address "${addr}"; then
            echo "  Error: invalid address (expected IPv4 or FQDN)" >&2
            continue
        fi
        echo "${addr}"
        return
    done
}

prompt_bmc_user() {
    local user
    read -rp "  BMC username [admin]: " user
    user="${user:-admin}"
    echo "${user}"
}

prompt_bmc_pass() {
    local pass
    while true; do
        read -rsp "  BMC password: " pass
        echo "" >&2
        if [[ -z "${pass}" ]]; then
            echo "  Error: BMC password is required" >&2
            continue
        fi
        echo "${pass}"
        return
    done
}

prompt_boot_mac() {
    local mac
    while true; do
        read -rp "  Boot MAC address (Enter to auto-discover): " mac
        if [[ -z "${mac}" ]]; then
            echo "${mac}"
            return
        fi
        if ! valid_mac "${mac}"; then
            echo "  Error: invalid MAC (expected XX:XX:XX:XX:XX:XX)" >&2
            continue
        fi
        echo "${mac}"
        return
    done
}

##############################################################################
# Summary display
##############################################################################

show_summary() {
    echo ""
    echo "=================================="
    echo "  BAREMETAL NODE SUMMARY"
    echo "=================================="
    printf "  %-4s %-14s %-40s %-10s %-10s %-19s\n" \
        "#" "HOSTNAME" "BMC ADDRESS" "BMC USER" "PASSWORD" "BOOT MAC"
    printf "  %-4s %-14s %-40s %-10s %-10s %-19s\n" \
        "---" "------------" "--------------------------------------" "--------" "--------" "-----------------"

    local i
    for ((i = 0; i < ${#WIZ_NAMES[@]}; i++)); do
        local display_mac="${WIZ_MACS[$i]:-auto-discover}"
        printf "  %-4s %-14s %-40s %-10s %-10s %-19s\n" \
            "$((i + 1))" \
            "${WIZ_NAMES[$i]}" \
            "${WIZ_IPS[$i]}" \
            "${WIZ_USERS[$i]}" \
            "********" \
            "${display_mac}"
    done

    echo "=================================="
}

##############################################################################
# Wizard flow
##############################################################################

run_wizard() {
    info "Baremetal node inventory wizard"
    echo ""

    while true; do
        local node_count
        node_count=$(prompt_node_count)

        WIZ_NAMES=()
        WIZ_IPS=()
        WIZ_USERS=()
        WIZ_PASSES=()
        WIZ_MACS=()

        local i
        for ((i = 0; i < node_count; i++)); do
            local default_name="master-${i}"
            echo ""
            echo "--- Node $((i + 1)) of ${node_count} ---"

            WIZ_NAMES+=("$(prompt_hostname "${default_name}")")
            WIZ_IPS+=("$(prompt_bmc_address)")
            WIZ_USERS+=("$(prompt_bmc_user)")
            WIZ_PASSES+=("$(prompt_bmc_pass)")
            WIZ_MACS+=("$(prompt_boot_mac)")
        done

        show_summary

        local confirm
        read -rp "Proceed with this configuration? [Y/n/q]: " confirm
        confirm="${confirm:-Y}"

        case "${confirm}" in
            [Yy]|[Yy]es)
                break
                ;;
            [Qq]|[Qq]uit)
                die "Wizard cancelled by user"
                ;;
            *)
                echo ""
                info "Starting over — re-enter node information"
                echo ""
                continue
                ;;
        esac
    done

    write_inventory
}

##############################################################################
# Inventory writer
##############################################################################

write_inventory() {
    local tmp_inventory
    tmp_inventory=$(mktemp)

    {
        echo "# Generated by baremetal-wizard.sh"
        echo ""
        echo "[baremetal_nodes]"
    } > "${tmp_inventory}"

    local i
    for ((i = 0; i < ${#WIZ_NAMES[@]}; i++)); do
        local line="${WIZ_NAMES[$i]} bmc_address=${WIZ_IPS[$i]} bmc_user=${WIZ_USERS[$i]} bmc_pass=${WIZ_PASSES[$i]}"
        if [[ -n "${WIZ_MACS[$i]}" ]]; then
            line+=" boot_mac=${WIZ_MACS[$i]}"
        fi
        echo "${line}" >> "${tmp_inventory}"
    done

    {
        echo ""
        echo "[baremetal_nodes:vars]"
        echo "bmc_driver=redfish"
        echo "bmc_verify_ca=False"
        echo "cpu_arch=x86_64"
    } >> "${tmp_inventory}"

    mv "${tmp_inventory}" "${OUTPUT}"
    echo ""
    info "Inventory written to ${OUTPUT}"
}

##############################################################################
# Main
##############################################################################

declare -a WIZ_NAMES=()
declare -a WIZ_IPS=()
declare -a WIZ_USERS=()
declare -a WIZ_PASSES=()
declare -a WIZ_MACS=()

parse_args "$@"
run_wizard
