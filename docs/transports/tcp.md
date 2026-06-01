# NVMe-oF TCP Transport

This plugin connects Proxmox VE hosts to Lightbits LightOS volumes using NVMe-oF over TCP (`nvme-tcp` kernel module). No specialised hardware is required - any standard TCP/IP network interface works.

## Prerequisites

| Requirement | Notes |
|---|---|
| `nvme-cli` package | Provides the `nvme` command. Installed automatically by `scripts/install.sh`. |
| `nvme_tcp` kernel module | Loaded automatically by nvme-cli on modern Proxmox kernels. |
| Network access | TCP reachability to the Lightbits host on **port 4420**. |

## Configuration parameters

| Parameter | Description | Example |
|---|---|---|
| `lb_nvme_host` | Lightbits NVMe-oF endpoint (`host:port`) | `192.168.10.10:4420` |
| `lb_subsys_nqn` | Subsystem NQN of the Lightbits cluster | `nqn.2016-01.com.lightbitslabs:uuid:...` |

## Obtaining the subsystem NQN

From any Linux host with network access to the Lightbits cluster:

```bash
nvme discover -t tcp -a <lightbits-ip> -s 4420
```

Look for the `subnqn:` field in the output:

```
subnqn:  nqn.2016-01.com.lightbitslabs:uuid:4ec00692-4b2d-4278-8f72-0f6c290c69e8
```

## How the TCP connection is managed

- **VM start (`activate_volume`)** - calls `nvme connect -t tcp -a <host> -s <port> -n <subsys_nqn>` if no connection to the subsystem exists yet. Multiple volumes on the same subsystem share a single connection.
- **VM stop (`deactivate_volume`)** - calls `nvme disconnect -n <subsys_nqn>` only when the last active volume on that subsystem is deactivated, avoiding disruption to other running VMs.

## Verifying connectivity

```bash
# Discover available subsystems
nvme discover -t tcp -a <lightbits-ip> -s 4420

# After a VM starts, confirm the connection is active
nvme list

# Confirm the symlink was created
ls -la /dev/lightbits/<storeid>/
```

## Troubleshooting

**`nvme_tcp` module not loaded**
```bash
modprobe nvme_tcp
```

**Block device does not appear after connect**

The plugin polls sysfs for up to 30 seconds. If the cluster is under load it may take longer. Check:
```bash
lsmod | grep nvme_tcp
nvme list
```

**Port 4420 unreachable**

Verify firewall rules allow TCP 4420 from the Proxmox host to the Lightbits cluster nodes.
