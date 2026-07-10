# assisted-spoke Role

Deploys a spoke TNF (Two-Node with Fencing) cluster on a hub via the assisted installer and BareMetalHost resources.

## Description

This role creates and installs a spoke TNF cluster on an existing hub that has ACM/MCE and the assisted service configured (via the `acm-install` role). It:

1. Optionally cleans up existing spoke resources (when `force_cleanup=true`)
2. Creates a dedicated libvirt network for the spoke cluster
3. Creates spoke VMs with the specified resources
4. Verifies sushy-tools (Redfish BMC simulator) is running
5. Creates cluster resources on the hub (ClusterDeployment, AgentClusterInstall, InfraEnv, ClusterImageSet)
6. Creates BareMetalHost resources to trigger agent-based installation
7. Monitors agent registration, cluster installation, and agent completion
8. Retrieves spoke cluster credentials (kubeconfig, admin password)

## Requirements

- Hub cluster with ACM/MCE and assisted service configured (run `acm-install` role first)
- Hub kubeconfig accessible at `~/auth/kubeconfig`
- libvirt/KVM available on the hypervisor
- sushy-tools installed for Redfish BMC simulation
- `oc` and `virsh` CLIs available on the hypervisor

## Role Variables

### Spoke Cluster Identity

- `spoke_cluster_name`: Cluster name, must be DNS-safe (default: `"spoke-tnf"`)
- `spoke_base_domain`: Base domain for the spoke cluster (default: `"example.com"`)
- `spoke_release_image`: Release image - `"auto"` uses the hub release image (default: `"auto"`)

### VM Specifications

- `spoke_vm_memory`: Memory per node in MB (default: `32768`)
- `spoke_vm_vcpus`: CPU cores per node (default: `4`)
- `spoke_vm_disk_size`: Disk size per node in GB (default: `120`)
- `spoke_ctlplanes`: Number of control plane nodes, must be 2 for TNF (default: `2`)

### Network Configuration

- `spoke_network_cidr`: Spoke cluster network CIDR (default: `"192.168.125.0/24"`)
- `spoke_api_vip`: API VIP address (default: `"192.168.125.5"`)
- `spoke_ingress_vip`: Ingress VIP address (default: `"192.168.125.10"`)
- `spoke_cluster_network_cidr`: Pod network CIDR (default: `"10.132.0.0/14"`)
- `spoke_service_network_cidr`: Service network CIDR (default: `"172.31.0.0/16"`)
- `hub_network_cidr`: Hub network CIDR for cross-bridge nftables rules (default: `"192.168.111.0/24"`)

### BMC / sushy-tools

- `spoke_bmc_user`: BMC username (default: `"admin"`)
- `spoke_bmc_password`: BMC password (default: `"password"`)
- `spoke_ksushy_ip`: sushy-tools listen IP (default: `"192.168.111.1"`)
- `spoke_ksushy_port`: sushy-tools port (default: `8000`)

### Deployment Options

- `force_cleanup`: Remove existing spoke resources before deployment (default: `false`)

### Timeout Variables

- `spoke_install_timeout`: Cluster installation timeout in seconds (default: `3600`)
- `spoke_agent_register_timeout`: Agent registration timeout (default: `900`)
- `spoke_credentials_timeout`: Credential retrieval timeout (default: `1800`)

### Computed Variables (vars/main.yml)

These are derived automatically and should not be overridden:

- `spoke_network_gateway`: First IP in spoke CIDR
- `spoke_dhcp_start` / `spoke_dhcp_end`: DHCP range within spoke CIDR
- `spoke_network_name`: Libvirt network name (matches `spoke_cluster_name`)
- `spoke_vm_image_dir`: VM disk image directory (`/var/lib/libvirt/images`)
- `spoke_auth_dir`: Credential output directory (`~/<spoke_cluster_name>/auth`)

## Task Flow

1. **cleanup.yml** - Removes existing spoke namespace, VMs, network, credentials (when `force_cleanup=true`)
2. **create-spoke-network.yml** - Creates dedicated libvirt network with DHCP for spoke VMs
3. **create-spoke-vms.yml** - Creates spoke VM disk images and defines libvirt domains
4. **setup-ksushy.yml** - Verifies sushy-tools is running for Redfish BMC
5. **create-cluster-resources.yml** - Creates ClusterDeployment, AgentClusterInstall, InfraEnv, ClusterImageSet on hub
6. **create-bmh.yml** - Creates BareMetalHost resources that trigger spoke installation
7. **wait-for-install.yml** - Monitors agent registration, installation progress, and agent completion
8. **retrieve-credentials.yml** - Extracts kubeconfig and admin password, configures DNS, verifies access

## Usage

This role is not called directly. It is invoked via `assisted-install.yml`:

```bash
make deploy fencing-assisted
# or
ansible-playbook assisted-install.yml -i inventory.ini
```

### Configuration

Copy and customize the variables template in the central `config/` folder at the repository root:

```bash
cp config/assisted.yml.template config/assisted.yml
# Edit config/assisted.yml with desired spoke configuration
```

The make targets sync it to `vars/assisted.yml`, where the playbook reads it (creating `vars/assisted.yml` directly still works).

### Accessing the Spoke Cluster

After deployment:

```bash
source proxy.env
KUBECONFIG=~/spoke-tnf/auth/kubeconfig oc get nodes
```

### Redeployment

To redeploy with cleanup of existing resources:

```bash
ansible-playbook assisted-install.yml -i inventory.ini -e "force_cleanup=true"
```

## Troubleshooting

- Check spoke VMs: `sudo virsh list --all | grep spoke`
- Check agents: `oc get agents -n <spoke_cluster_name>`
- Check BMH status: `oc get bmh -n <spoke_cluster_name>`
- Check installation progress: `oc get agentclusterinstall <spoke_cluster_name> -n <spoke_cluster_name> -o yaml`
- Check spoke events: `oc get events -n <spoke_cluster_name> --sort-by='.lastTimestamp'`
- Check sushy-tools: `sudo systemctl status ksushy`
- Check spoke network: `sudo virsh net-list | grep <spoke_cluster_name>`