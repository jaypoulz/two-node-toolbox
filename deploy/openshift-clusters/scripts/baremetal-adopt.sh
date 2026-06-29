#!/usr/bin/bash
#
# Adopt existing baremetal nodes for TNF deployment.
#
# Parses inventory_baremetal.ini, validates BMC credentials via Redfish,
# and generates ironic_nodes.json + config_baremetal_fencing.sh for dev-scripts.
#
# Usage:
#   adopt-baremetal.sh [options]
#
# Options:
#   --cluster-name NAME   Cluster name for output directory (default: ostest)
#   --skip-verify         Skip BMC credential verification
#   --verify-only         Only verify BMC credentials, don't generate artifacts
#   --config-base FILE    Base config to derive baremetal config from
#   -h, --help            Show this help message

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
SKIP_VERIFY=false
VERIFY_ONLY=false
CONFIG_BASE=""
INVENTORY="${OC_DIR}/inventory_baremetal.ini"

# Node data arrays — populated by parse_inventory
declare -a NODE_NAMES=()
declare -a NODE_BMC_ADDRS=()
declare -a NODE_BMC_USERS=()
declare -a NODE_BMC_PASSES=()
declare -a NODE_BOOT_MACS=()

# Group defaults
BMC_VERIFY_CA="False"
CPU_ARCH="x86_64"

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
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            --config-base)
                CONFIG_BASE="$2"
                shift 2
                ;;
            -h|--help)
                head -17 "$0" | tail -12
                exit 0
                ;;
            *)
                die "Unknown option: $1. Run '$0 --help' for usage."
                ;;
        esac
    done
}

##############################################################################
# INI parser
##############################################################################

parse_inventory() {
    [[ -f "${INVENTORY}" ]] || die "Inventory file not found: ${INVENTORY}"

    local in_nodes=false
    local in_vars=false

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip comments and leading/trailing whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue

        if [[ "${line}" == "[baremetal_nodes]" ]]; then
            in_nodes=true
            in_vars=false
            continue
        elif [[ "${line}" == "[baremetal_nodes:vars]" ]]; then
            in_nodes=false
            in_vars=true
            continue
        elif [[ "${line}" =~ ^\[.*\] ]]; then
            in_nodes=false
            in_vars=false
            continue
        fi

        if ${in_vars}; then
            local key val
            key="${line%%=*}"
            val="${line#*=}"
            case "${key}" in
                bmc_verify_ca) BMC_VERIFY_CA="${val}" ;;
                cpu_arch)      CPU_ARCH="${val}" ;;
            esac
            continue
        fi

        if ${in_nodes}; then
            local name rest
            name="${line%% *}"
            rest="${line#* }"

            local bmc_address="" bmc_user="" bmc_pass="" boot_mac=""
            for pair in ${rest}; do
                local key val
                key="${pair%%=*}"
                val="${pair#*=}"
                case "${key}" in
                    bmc_address)   bmc_address="${val}" ;;
                    bmc_user) bmc_user="${val}" ;;
                    bmc_pass) bmc_pass="${val}" ;;
                    boot_mac) boot_mac="${val}" ;;
                esac
            done

            [[ -z "${bmc_address}" ]] && die "Node '${name}': missing bmc_address"
            [[ -z "${bmc_user}" ]] && die "Node '${name}': missing bmc_user"
            [[ -z "${bmc_pass}" ]] && die "Node '${name}': missing bmc_pass"

            NODE_NAMES+=("${name}")
            NODE_BMC_ADDRS+=("${bmc_address}")
            NODE_BMC_USERS+=("${bmc_user}")
            NODE_BMC_PASSES+=("${bmc_pass}")
            NODE_BOOT_MACS+=("${boot_mac}")
        fi
    done < "${INVENTORY}"

    [[ ${#NODE_NAMES[@]} -eq 0 ]] && die "No nodes found in inventory"
    info "Parsed ${#NODE_NAMES[@]} node(s) from inventory"
}

##############################################################################
# BMC verification via Redfish
##############################################################################

discover_redfish_system_id() {
    local bmc_address="$1" bmc_user="$2" bmc_pass="$3"

    local systems_json
    systems_json=$(curl -sk --connect-timeout 5 --max-time 10 \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}/redfish/v1/Systems/" 2>/dev/null) || return 1

    echo "${systems_json}" | jq -r '.Members[0]."@odata.id"' 2>/dev/null
}

discover_boot_mac() {
    local bmc_address="$1" bmc_user="$2" bmc_pass="$3" system_id="$4"

    # Get boot order from the system resource
    local boot_order
    boot_order=$(curl -sk --connect-timeout 5 --max-time 10 \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}/${system_id}" 2>/dev/null \
        | jq -r '.Boot.BootOrder[]' 2>/dev/null) || return 1

    # Fetch all boot options and index by BootOptionReference
    local options_json
    options_json=$(curl -sk --connect-timeout 5 --max-time 10 \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}/${system_id}BootOptions/" 2>/dev/null) || return 1

    local option_paths
    option_paths=$(echo "${options_json}" | jq -r '.Members[]."@odata.id"' 2>/dev/null) || return 1

    # Build associative arrays: ref → display_name, ref → uefi_path
    declare -A opt_display opt_path
    for option_url in ${option_paths}; do
        local option
        option=$(curl -sk --connect-timeout 5 --max-time 10 \
            -u "${bmc_user}:${bmc_pass}" \
            "https://${bmc_address}${option_url}" 2>/dev/null) || continue

        local ref
        ref=$(echo "${option}" | jq -r '.BootOptionReference // empty' 2>/dev/null)
        [[ -z "${ref}" ]] && continue
        opt_display["${ref}"]=$(echo "${option}" | jq -r '.DisplayName // empty' 2>/dev/null)
        opt_path["${ref}"]=$(echo "${option}" | jq -r '.UefiDevicePath // empty' 2>/dev/null)
    done

    # Walk boot order, find the first PXE IPv4 entry
    for boot_ref in ${boot_order}; do
        local display_name="${opt_display[${boot_ref}]:-}"
        local uefi_path="${opt_path[${boot_ref}]:-}"

        if [[ "${display_name}" == *"PXE IPv4"* ]] && [[ "${uefi_path}" == *MAC* ]]; then
            local raw_mac
            raw_mac=$(echo "${uefi_path}" | grep -oP 'MAC\(\K[0-9A-Fa-f]+' 2>/dev/null) || continue
            echo "${raw_mac}" | sed 's/\(..\)/\1:/g; s/:$//' | tr '[:lower:]' '[:upper:]'
            return 0
        fi
    done
    return 1
}

verify_bmc() {
    local name="$1" bmc_address="$2" bmc_user="$3" bmc_pass="$4"
    local rc=0

    printf "  %-12s %-20s " "${name}" "${bmc_address}"

    # Verify Redfish root is reachable and credentials work
    local http_code
    http_code=$(curl -sk --connect-timeout 5 --max-time 10 \
        -o /dev/null -w '%{http_code}' \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}/redfish/v1/" 2>/dev/null) || http_code="000"

    if [[ "${http_code}" == "200" ]]; then
        echo "OK (HTTP ${http_code})"
    elif [[ "${http_code}" == "401" ]]; then
        echo "FAIL — bad credentials (HTTP 401)"
        rc=1
    elif [[ "${http_code}" == "000" ]]; then
        echo "FAIL — unreachable"
        rc=1
    else
        echo "FAIL (HTTP ${http_code})"
        rc=1
    fi

    return ${rc}
}

verify_all_bmcs() {
    info "Verifying BMC credentials via Redfish"
    echo ""

    local failed=0
    for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
        if ! verify_bmc "${NODE_NAMES[$i]}" "${NODE_BMC_ADDRS[$i]}" \
                "${NODE_BMC_USERS[$i]}" "${NODE_BMC_PASSES[$i]}"; then
            failed=$((failed + 1))
        fi
    done
    echo ""

    if [[ ${failed} -gt 0 ]]; then
        die "${failed} node(s) failed BMC verification"
    fi
    info "All BMC endpoints verified"
}

##############################################################################
# Artifact generation
##############################################################################

generate_ironic_nodes_json() {
    local output_file="$1"

    info "Generating ironic_nodes.json"

    local nodes_json='{"nodes":['
    local first=true

    for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
        local name="${NODE_NAMES[$i]}"
        local bmc_address="${NODE_BMC_ADDRS[$i]}"
        local bmc_user="${NODE_BMC_USERS[$i]}"
        local bmc_pass="${NODE_BMC_PASSES[$i]}"
        local boot_mac="${NODE_BOOT_MACS[$i]}"

        # Discover the Redfish system path from the BMC, fall back to standard
        local system_id
        system_id=$(discover_redfish_system_id "${bmc_address}" "${bmc_user}" "${bmc_pass}" 2>/dev/null) || true
        system_id="${system_id:-/redfish/v1/Systems/1}"
        # Strip leading slash for URL construction
        system_id="${system_id#/}"

        # Auto-discover boot MAC via Redfish if not provided
        if [[ -z "${boot_mac}" ]]; then
            info "  ${name}: boot_mac not set, attempting Redfish discovery..."
            boot_mac=$(discover_boot_mac "${bmc_address}" "${bmc_user}" "${bmc_pass}" "${system_id}" 2>/dev/null) || true
            if [[ -n "${boot_mac}" ]]; then
                info "  ${name}: discovered boot MAC ${boot_mac}"
            else
                echo "  WARNING: ${name}: could not discover boot MAC — set boot_mac in inventory" >&2
                boot_mac="DISCOVERY_FAILED"
            fi
        fi

        ${first} || nodes_json+=","
        first=false

        nodes_json+=$(cat <<NODEJSON
{
    "name": "${name}",
    "driver": "redfish",
    "driver_info": {
      "address": "redfish://${bmc_address}/${system_id}",
      "username": "${bmc_user}",
      "password": "${bmc_pass}",
      "redfish_verify_ca": "${BMC_VERIFY_CA}"
    },
    "ports": [
      {"address": "${boot_mac}"}
    ],
    "properties": {
      "cpu_arch": "${CPU_ARCH}"
    }
  }
NODEJSON
        )
    done

    nodes_json+=']}'

    echo "${nodes_json}" | jq . > "${output_file}"
    info "  → ${output_file}"
}

generate_baremetal_config() {
    local output_file="$1"
    local nodes_file_path="$2"

    info "Generating config_baremetal_fencing.sh"

    # Find the base config to derive from
    local base_config="${CONFIG_BASE}"
    if [[ -z "${base_config}" ]]; then
        local files_dir="${OC_DIR}/roles/dev-scripts/install-dev/files"
        if [[ -f "${files_dir}/config_fencing.sh" ]]; then
            base_config="${files_dir}/config_fencing.sh"
        elif [[ -f "${files_dir}/config_fencing_example.sh" ]]; then
            base_config="${files_dir}/config_fencing_example.sh"
        else
            die "No base config found. Provide one with --config-base."
        fi
    fi

    [[ -f "${base_config}" ]] || die "Base config not found: ${base_config}"
    info "  Base config: ${base_config}"

    {
        cat "${base_config}"
        echo ""
        echo "# Baremetal adoption overrides (generated by adopt-baremetal.sh)"
        echo "export NODES_PLATFORM=baremetal"
        echo "export NODES_FILE=\"${nodes_file_path}\""
    } > "${output_file}"

    info "  → ${output_file}"
}

##############################################################################
# Main
##############################################################################

main() {
    parse_args "$@"

    # Launch interactive wizard if no inventory exists
    if [[ ! -f "${INVENTORY}" ]]; then
        "${SCRIPT_DIR}/baremetal-wizard.sh" --output "${INVENTORY}"
    fi

    parse_inventory

    # BMC verification
    if ! ${SKIP_VERIFY}; then
        verify_all_bmcs
    fi

    if ${VERIFY_ONLY}; then
        info "Verification complete (--verify-only). No artifacts generated."
        exit 0
    fi

    # Create output directory
    local output_dir="${OC_DIR}/clusters/${CLUSTER_NAME}"
    mkdir -p "${output_dir}"

    # Generate artifacts
    local nodes_file="${output_dir}/ironic_nodes.json"
    generate_ironic_nodes_json "${nodes_file}"

    # NODES_FILE path on the hypervisor — resolves when dev-scripts sources the config
    local remote_nodes_path="\${PWD}/ironic_nodes.json"
    generate_baremetal_config "${output_dir}/config_baremetal_fencing.sh" "${remote_nodes_path}"

    echo ""
    info "Adoption complete. Generated artifacts:"
    echo "    ${nodes_file}"
    echo "    ${output_dir}/config_baremetal_fencing.sh"
    echo ""
    echo "  Next: deploy to hypervisor with the baremetal install workflow (OCPEDGE-2775)"
}

main "$@"
