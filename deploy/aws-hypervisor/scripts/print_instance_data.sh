#!/bin/bash
SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../common.sh"

node_dir="$(get_node_dir)"
echo "Stack: $(cat "${node_dir}/rhel_host_stack_name")"
echo "Host: $(cat "${node_dir}/public_address")"
echo "User: $(cat "${node_dir}/ssh_user")"
echo "Cockpit URL: http://$(cat "${node_dir}/public_address"):9090"
