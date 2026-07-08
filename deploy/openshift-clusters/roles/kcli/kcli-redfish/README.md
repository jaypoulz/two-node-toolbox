# kcli-redfish Role

Starts the ksushy BMC simulator for kcli-deployed OpenShift clusters with fencing topology.

## Description

The kcli-redfish role manages the ksushy BMC simulator, which provides Redfish endpoints for virtual machines deployed via kcli. The cluster-etcd-operator (CEO) uses these endpoints to auto-configure STONITH fencing during installation.

This role:
1. Installs required Python dependencies
2. Creates the ksushy systemd service on the hypervisor
3. Configures firewall rules to allow BMC access from VMs
4. Validates BMC endpoint accessibility

## Requirements

- kcli command available on the hypervisor host
- Sudo privileges on the hypervisor for firewall configuration and Python package installation

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `test_cluster_name` | `tnt-cluster` | kcli cluster name |
| `ksushy_ip` | `192.168.122.1` | Hypervisor IP (libvirt default gateway) |
| `ksushy_port` | `9000` | BMC simulator port |
| `bmc_user` | `admin` | BMC username |
| `bmc_password` | `admin123` | BMC password |

## Usage

This role runs automatically as part of `kcli-install.yml` before cluster installation. It does not need to be invoked manually.

## Troubleshooting

**ksushy not accessible:**
```bash
systemctl --user status ksushy.service
curl -sk https://192.168.122.1:9000/redfish/v1/
```

**Firewall blocking BMC access:**
```bash
firewall-cmd --list-ports --zone=libvirt
```
