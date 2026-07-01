#!/usr/bin/bash
#
# Deploy a TNF fencing cluster on adopted baremetal nodes via dev-scripts ABI.
#
# If [provisioning_host] is configured in inventory_baremetal.ini, syncs
# artifacts and executes on the remote host via SSH. Otherwise runs locally.
# Expects adoption artifacts from 'make baremetal-adopt'.
#
# Usage:
#   deploy-baremetal.sh [options]
#
# Options:
#   --cluster-name NAME         Cluster name matching adoption artifacts (default: ostest)
#   --dev-scripts-path PATH     Path to dev-scripts checkout (default: ~/openshift-metal3/dev-scripts)
#   --dev-scripts-repo URL      Git repo for dev-scripts (default: upstream openshift-metal3)
#   --dev-scripts-branch BRANCH Git branch to checkout (default: repo's current branch)
#   -h, --help                  Show this help message

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
DEV_SCRIPTS_PATH="${DEV_SCRIPTS_PATH:-${HOME}/openshift-metal3/dev-scripts}"
DEV_SCRIPTS_REPO="${DEV_SCRIPTS_REPO:-https://github.com/openshift-metal3/dev-scripts}"
DEV_SCRIPTS_BRANCH="${DEV_SCRIPTS_BRANCH:-}"

##############################################################################
# Helpers
##############################################################################

die() { echo "Error: $*" >&2; exit 1; }

info() { echo "==> $*"; }

warn() { echo "  WARNING: $*" >&2; }

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
            --dev-scripts-path)
                DEV_SCRIPTS_PATH="$2"
                shift 2
                ;;
            --dev-scripts-repo)
                DEV_SCRIPTS_REPO="$2"
                shift 2
                ;;
            --dev-scripts-branch)
                DEV_SCRIPTS_BRANCH="$2"
                shift 2
                ;;
            -h|--help)
                head -15 "$0" | tail -10
                exit 0
                ;;
            *)
                die "Unknown option: $1. Run '$0 --help' for usage."
                ;;
        esac
    done
}

##############################################################################
# Pre-flight validation
##############################################################################

validate_sudo() {
    if ! sudo -n true 2>/dev/null; then
        die "Dev-scripts requires sudo access (package installs, network config, ironic dirs).\nRun this script from an interactive terminal, or configure passwordless sudo."
    fi
}

validate_artifacts() {
    local cluster_dir="${OC_DIR}/clusters/${CLUSTER_NAME}"

    [[ -d "${cluster_dir}" ]] || \
        die "Cluster directory not found: ${cluster_dir}\nRun 'make baremetal-adopt' first."

    CONFIG_FILE="${cluster_dir}/config_baremetal_fencing.sh"
    NODES_FILE="${cluster_dir}/ironic_nodes.json"

    [[ -f "${CONFIG_FILE}" ]] || \
        die "Config not found: ${CONFIG_FILE}\nRun 'make baremetal-adopt' first."
    [[ -f "${NODES_FILE}" ]] || \
        die "Nodes file not found: ${NODES_FILE}\nRun 'make baremetal-adopt' first."

    info "Adoption artifacts found in ${cluster_dir}"
}

validate_pull_secret() {
    PULL_SECRET="${OC_DIR}/roles/dev-scripts/install-dev/files/pull-secret.json"

    [[ -f "${PULL_SECRET}" ]] || \
        die "Pull secret not found: ${PULL_SECRET}\nCopy your pull secret to this path."

    if ! jq empty "${PULL_SECRET}" 2>/dev/null; then
        die "Invalid JSON in ${PULL_SECRET}\nValidate with: python3 -m json.tool ${PULL_SECRET}"
    fi
}

validate_config() {
    local config_content
    config_content=$(<"${CONFIG_FILE}")

    # AGENT_E2E_TEST_SCENARIO must be set
    if ! grep -qE '^export AGENT_E2E_TEST_SCENARIO=' <<<"${config_content}"; then
        die "AGENT_E2E_TEST_SCENARIO not set in ${CONFIG_FILE}.\nThis should have been added by 'make baremetal-adopt'. Re-run adoption."
    fi

    # CI token validation (if using CI registry)
    local ci_token=""
    ci_token=$(grep -oP '^export CI_TOKEN="\K[^"]+' <<<"${config_content}" || true)

    if [[ -n "${ci_token}" ]]; then
        local release_registry=""
        release_registry=$(grep -oP '^export OPENSHIFT_RELEASE_IMAGE="?\K[^/"]+' <<<"${config_content}" || true)

        if [[ "${release_registry}" == "registry.ci.openshift.org" ]]; then
            info "Validating CI token against ${release_registry}..."
            local http_code
            http_code=$(curl -s -o /dev/null -w '%{http_code}' \
                -H "Authorization: Bearer ${ci_token}" \
                "https://${release_registry}/v2/" 2>/dev/null) || http_code="000"

            if [[ "${http_code}" != "200" ]]; then
                die "CI token is invalid or expired for ${release_registry} (HTTP ${http_code}).\nUpdate CI_TOKEN in your base config and re-run 'make baremetal-adopt'."
            fi
            info "CI token valid"
        fi
    fi

    # CI registry in pull-secret check
    if grep -q 'registry.ci.openshift.org' <<<"${config_content}"; then
        if ! jq -e '.auths["registry.ci.openshift.org"]' "${PULL_SECRET}" >/dev/null 2>&1; then
            die "Config uses CI registry but pull secret lacks registry.ci.openshift.org credentials."
        fi
    fi

    # BAREMETAL_ISO_SERVER warning
    if ! grep -qE '^export BAREMETAL_ISO_SERVER=' <<<"${config_content}"; then
        warn "BAREMETAL_ISO_SERVER not set in config."
        warn "You must set this in dev-scripts config before running 'make agent'."
        warn "The ISO server must be reachable from BMC networks (not the provisioning host)."
    fi
}

##############################################################################
# Dev-scripts setup
##############################################################################

setup_dev_scripts() {
    if [[ ! -d "${DEV_SCRIPTS_PATH}" ]]; then
        info "Cloning dev-scripts from ${DEV_SCRIPTS_REPO}${DEV_SCRIPTS_BRANCH:+ (branch: ${DEV_SCRIPTS_BRANCH})}..."
        local clone_args=("${DEV_SCRIPTS_REPO}" "${DEV_SCRIPTS_PATH}")
        if [[ -n "${DEV_SCRIPTS_BRANCH}" ]]; then
            clone_args=(-b "${DEV_SCRIPTS_BRANCH}" "${clone_args[@]}")
        fi
        git clone "${clone_args[@]}"
    else
        info "Using dev-scripts at ${DEV_SCRIPTS_PATH}"
        if [[ -n "${DEV_SCRIPTS_BRANCH}" ]]; then
            local current_branch
            current_branch=$(git -C "${DEV_SCRIPTS_PATH}" rev-parse --abbrev-ref HEAD)
            if [[ "${current_branch}" != "${DEV_SCRIPTS_BRANCH}" ]]; then
                info "Switching dev-scripts from ${current_branch} to ${DEV_SCRIPTS_BRANCH}..."
                git -C "${DEV_SCRIPTS_PATH}" fetch --all --quiet
                git -C "${DEV_SCRIPTS_PATH}" checkout "${DEV_SCRIPTS_BRANCH}"
            fi
        fi
    fi

    [[ -f "${DEV_SCRIPTS_PATH}/Makefile" ]] || \
        die "Invalid dev-scripts checkout: ${DEV_SCRIPTS_PATH} (no Makefile found)"

    local ds_user
    ds_user=$(whoami)

    # Set WORKING_DIR in config if not already present — avoids sudo for /opt/dev-scripts
    local working_dir="${WORKING_DIR:-${HOME}/dev-scripts-workdir}"
    if ! grep -qE '^export WORKING_DIR=' "${CONFIG_FILE}"; then
        info "Setting WORKING_DIR=${working_dir}"
    fi
    mkdir -p "${working_dir}"

    info "Deploying config to dev-scripts"
    {
        cat "${CONFIG_FILE}"
        if ! grep -qE '^export WORKING_DIR=' "${CONFIG_FILE}"; then
            echo ""
            echo "# Working directory (set by deploy-baremetal.sh)"
            echo "export WORKING_DIR=\"${working_dir}\""
        fi
    } > "${DEV_SCRIPTS_PATH}/config_${ds_user}.sh"
    cp "${PULL_SECRET}" "${DEV_SCRIPTS_PATH}/pull_secret.json"
    cp "${NODES_FILE}" "${DEV_SCRIPTS_PATH}/ironic_nodes.json"

    # REGISTRY_CREDS defaults to ~/private-mirror-<cluster>.json — the local
    # mirror registry credentials. Baremetal deploys don't run a local registry,
    # so create an empty auth file to prevent jq merge failures in write_pull_secret().
    local registry_creds="${HOME}/private-mirror-${CLUSTER_NAME}.json"
    if [[ ! -f "${registry_creds}" ]]; then
        echo '{"auths":{}}' > "${registry_creds}"
        info "  mirror  → ${registry_creds} (empty — no local registry)"
    fi

    info "  config  → config_${ds_user}.sh"
    info "  secret  → pull_secret.json"
    info "  nodes   → ironic_nodes.json"
}

##############################################################################
# Remote execution (provisioning host)
##############################################################################

parse_provisioning_host() {
    local inventory="${OC_DIR}/inventory_baremetal.ini"
    PROV_SSH_TARGET=""
    PROV_SSH_KEY=""
    PROV_DEV_SCRIPTS_PATH=""
    PROV_DEV_SCRIPTS_REPO=""
    PROV_DEV_SCRIPTS_BRANCH=""
    PROV_WORKING_DIR="tnt-baremetal"

    [[ -f "${inventory}" ]] || return 0

    local in_section=false
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue

        if [[ "${line}" == "[provisioning_host]" ]]; then
            in_section=true
            continue
        elif [[ "${line}" =~ ^\[.*\] ]]; then
            in_section=false
            continue
        fi

        if ${in_section}; then
            local key="${line%%=*}"
            local val="${line#*=}"
            case "${key}" in
                ssh_target)       PROV_SSH_TARGET="${val}" ;;
                ssh_key)          PROV_SSH_KEY="${val}" ;;
                dev_scripts_path)   PROV_DEV_SCRIPTS_PATH="${val}" ;;
                dev_scripts_repo)   PROV_DEV_SCRIPTS_REPO="${val}" ;;
                dev_scripts_branch) PROV_DEV_SCRIPTS_BRANCH="${val}" ;;
                working_dir)        PROV_WORKING_DIR="${val}" ;;
            esac
        fi
    done < "${inventory}"
}

build_ssh_opts() {
    SSH_OPTS=(-o "ServerAliveInterval=30" -o "ServerAliveCountMax=120")
    if [[ -n "${PROV_SSH_KEY:-}" ]]; then
        SSH_OPTS+=(-i "${PROV_SSH_KEY}")
    fi
}

validate_ssh_connectivity() {
    info "Validating SSH access to ${PROV_SSH_TARGET}..."

    local opts=(-o "ConnectTimeout=10" -o "BatchMode=yes")
    if [[ -n "${PROV_SSH_KEY:-}" ]]; then
        opts+=(-i "${PROV_SSH_KEY}")
    fi

    if ! ssh "${opts[@]}" "${PROV_SSH_TARGET}" "true" 2>/dev/null; then
        die "Cannot SSH to provisioning host: ${PROV_SSH_TARGET}
Ensure:
  1. SSH key-based auth is configured
  2. The host is reachable from this machine
  3. ssh_key is set in inventory_baremetal.ini if using a non-default key"
    fi

    if ! ssh "${opts[@]}" "${PROV_SSH_TARGET}" "command -v rsync" &>/dev/null; then
        die "rsync not found on provisioning host.
Install with: ssh ${PROV_SSH_TARGET} 'sudo dnf install -y rsync'"
    fi

    info "SSH connectivity OK"
}

sync_to_remote() {
    local remote_dir="${PROV_WORKING_DIR}"

    info "Syncing artifacts to ${PROV_SSH_TARGET}:~/${remote_dir}"

    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${PROV_SSH_TARGET}" \
        "mkdir -p ~/${remote_dir}/{scripts,clusters/${CLUSTER_NAME},roles/dev-scripts/install-dev/files}"

    rsync -az -e "ssh ${SSH_OPTS[*]}" \
        "${SCRIPT_DIR}/deploy-baremetal.sh" \
        "${PROV_SSH_TARGET}:~/${remote_dir}/scripts/"

    rsync -az -e "ssh ${SSH_OPTS[*]}" \
        "${OC_DIR}/clusters/${CLUSTER_NAME}/config_baremetal_fencing.sh" \
        "${OC_DIR}/clusters/${CLUSTER_NAME}/ironic_nodes.json" \
        "${PROV_SSH_TARGET}:~/${remote_dir}/clusters/${CLUSTER_NAME}/"

    rsync -az -e "ssh ${SSH_OPTS[*]}" \
        "${PULL_SECRET}" \
        "${PROV_SSH_TARGET}:~/${remote_dir}/roles/dev-scripts/install-dev/files/pull-secret.json"

    rsync -az -e "ssh ${SSH_OPTS[*]}" \
        "${OC_DIR}/inventory_baremetal.ini" \
        "${PROV_SSH_TARGET}:~/${remote_dir}/inventory_baremetal.ini"

    info "Sync complete"
}

exec_on_remote() {
    # shellcheck disable=SC2088 # tilde expands on the remote shell via SSH
    local remote_script="~/${PROV_WORKING_DIR}/scripts/deploy-baremetal.sh"
    local remote_args="--cluster-name ${CLUSTER_NAME}"
    if [[ -n "${PROV_DEV_SCRIPTS_PATH:-}" ]]; then
        remote_args+=" --dev-scripts-path ${PROV_DEV_SCRIPTS_PATH}"
    fi
    if [[ -n "${PROV_DEV_SCRIPTS_REPO:-}" ]]; then
        remote_args+=" --dev-scripts-repo ${PROV_DEV_SCRIPTS_REPO}"
    fi
    if [[ -n "${PROV_DEV_SCRIPTS_BRANCH:-}" ]]; then
        remote_args+=" --dev-scripts-branch ${PROV_DEV_SCRIPTS_BRANCH}"
    fi

    info "Executing deploy on ${PROV_SSH_TARGET}..."
    info "Remote output follows:"
    echo "=========================================="

    # shellcheck disable=SC2029
    ssh -tt "${SSH_OPTS[@]}" "${PROV_SSH_TARGET}" \
        "TNT_REMOTE_EXEC=1 bash ${remote_script} ${remote_args}"
}

fetch_credentials() {
    local remote_home
    remote_home=$(ssh "${SSH_OPTS[@]}" "${PROV_SSH_TARGET}" 'echo ${HOME}')
    local remote_ds="${PROV_DEV_SCRIPTS_PATH:-${remote_home}/openshift-metal3/dev-scripts}"
    local remote_auth="${remote_ds}/ocp/${CLUSTER_NAME}/auth"
    local local_auth="${OC_DIR}/clusters/${CLUSTER_NAME}/auth"

    info "Fetching cluster credentials from provisioning host..."
    mkdir -p "${local_auth}"

    rsync -az -e "ssh ${SSH_OPTS[*]}" \
        "${PROV_SSH_TARGET}:${remote_auth}/" \
        "${local_auth}/"

    info "Kubeconfig: ${local_auth}/kubeconfig"
    info "Password:   ${local_auth}/kubeadmin-password"
}

##############################################################################
# Main
##############################################################################

main() {
    parse_args "$@"

    # Remote execution: if [provisioning_host] is configured and we're not
    # already running on the remote side, sync artifacts and SSH in.
    if [[ -z "${TNT_REMOTE_EXEC:-}" ]]; then
        parse_provisioning_host
        if [[ -n "${PROV_SSH_TARGET}" ]]; then
            build_ssh_opts
            info "Baremetal TNF deployment — cluster: ${CLUSTER_NAME}"
            info "Provisioning host: ${PROV_SSH_TARGET}"
            echo ""

            # Validate artifacts locally (fast, catches errors before SSH)
            validate_artifacts
            validate_pull_secret
            validate_config
            echo ""

            validate_ssh_connectivity
            sync_to_remote
            echo ""
            exec_on_remote
            echo ""
            echo "=========================================="
            fetch_credentials
            echo ""
            info "Baremetal TNF cluster deployed via provisioning host!"
            exit 0
        fi
    fi

    # Local execution (on provisioning host or standalone)
    info "Baremetal TNF deployment — cluster: ${CLUSTER_NAME}"
    echo ""

    validate_sudo
    validate_artifacts
    validate_pull_secret
    validate_config
    echo ""

    setup_dev_scripts
    echo ""

    # Run dev-scripts ABI pipeline. Includes 'requirements' to install system
    # dependencies (nmstate, netaddr, ansible, etc.). Skips 'configure'
    # (02_configure_host.sh) which creates libvirt networks and VMs.
    info "Starting dev-scripts ABI pipeline..."
    info "This will take 30-60 minutes on baremetal nodes."
    echo ""

    if make -C "${DEV_SCRIPTS_PATH}" requirements agent_requirements agent_build_installer agent_prepare_release agent_configure agent_create_cluster; then
        echo ""
        info "Baremetal TNF cluster deployed successfully!"
        info "Kubeconfig: ${DEV_SCRIPTS_PATH}/ocp/${CLUSTER_NAME}/auth/kubeconfig"
        info "Console:    https://console-openshift-console.apps.${CLUSTER_NAME}.$(grep -oP 'BASE_DOMAIN="\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || echo '<base_domain>')/"
    else
        echo ""
        echo "=========================================="
        echo "  DEPLOYMENT FAILED"
        echo "=========================================="
        echo ""
        echo "  To recover:"
        echo "    1. Power off baremetal nodes via BMC"
        echo "    2. Clean dev-scripts state:"
        echo "       make -C ${DEV_SCRIPTS_PATH} clean"
        echo "    3. Fix the issue and re-run:"
        echo "       make baremetal-fencing-agent"
        echo ""
        exit 1
    fi
}

main "$@"
