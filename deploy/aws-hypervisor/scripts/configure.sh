#!/bin/bash
# shellcheck source=/dev/null
source ~/profile.env

RHEL_MAJOR_VERSION=$(. /etc/os-release && echo "${VERSION_ID%%.*}")

sudo hostnamectl set-hostname "aws-${STACK_NAME}"

function get_ocp_version() {
    local latest_ga_ocp_version
    local default_version="${DEFAULT_OCP_VERSION:-}"
    if [[ -z "${default_version}" ]]; then
        case "${RHEL_MAJOR_VERSION}" in
            10) default_version="4.23" ;;
            *)  default_version="4.22" ;;
        esac
    fi
    if latest_ga_ocp_version="$(curl -sL https://sippy.dptools.openshift.org/api/releases | jq -re '.ga_dates | to_entries | max_by(.value) | .key')";
    then
        echo "${latest_ga_ocp_version:-$default_version}"
    else
        echo "$default_version"
    fi
}

user=${1:-pitadmin}
if id "$user" >/dev/null 2>&1; then
    echo "user $user found"
else
    echo "user $user not found, creating"
    sudo useradd -m "$user"
    # Generate a random secure password
    random_password=$(openssl rand -base64 12)
    echo "${random_password}" | sudo passwd --stdin "$user"
    echo "========================================"
    echo "User: $user"
    echo "Password: $random_password"
    echo "========================================"
    echo -e "${user}\tALL=(ALL)\tNOPASSWD: ALL" | sudo tee "/etc/sudoers.d/${user}"
fi

sudo rm -rf /etc/yum.repos.d/*
sudo subscription-manager config --rhsm.manage_repos=1 --rhsmcertd.disable=redhat-access-insights

# Use activation key for non-interactive registration if available
if [ -n "${RHSM_ACTIVATION_KEY}" ] && [ -n "${RHSM_ORG}" ]; then
    echo "Using activation key for RHSM registration"
    sudo subscription-manager register --activationkey="${RHSM_ACTIVATION_KEY}" --org="${RHSM_ORG}"
else
    echo "No activation key found, falling back to interactive registration"
    sudo subscription-manager register
fi

sudo subscription-manager attach --pool=8a85f99c7d76f2fd017d96c411c70667
sudo subscription-manager repos \
--enable "rhel-${RHEL_MAJOR_VERSION}-for-$(uname -m)-appstream-rpms" \
--enable "rhel-${RHEL_MAJOR_VERSION}-for-$(uname -m)-baseos-rpms" \
--enable "rhocp-$(get_ocp_version)-for-rhel-${RHEL_MAJOR_VERSION}-$(uname -m)-rpms"

# Enable CodeReady Builder (CRB) repo for -devel packages (e.g. libvirt-devel).
# On RHUI instances (like AWS), subscription-manager repos --enable doesn't work
# for CRB because repos are managed by RHUI configuration. The 'crb' command
# handles both RHUI and non-RHUI environments correctly.
enable_crb_repo() {
    if command -v crb &>/dev/null; then
        sudo crb enable
    else
        sudo subscription-manager repos --enable "codeready-builder-for-rhel-${RHEL_MAJOR_VERSION}-$(uname -m)-rpms"
    fi
}

echo "Enabling CRB repository..."
if ! enable_crb_repo; then
    echo "ERROR: Failed to enable CRB repository. libvirt-devel will be unavailable."
    exit 1
fi
