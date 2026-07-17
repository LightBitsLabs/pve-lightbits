# NVMe-oF TCP Transport

This plugin connects Proxmox VE hosts to Lightbits LightOS volumes using NVMe-oF over TCP (`nvme-tcp` kernel module). No specialised hardware is required - any standard TCP/IP network interface works.

## Prerequisites

| Requirement | Notes |
|---|---|
| `nvme-cli` package | Provides the `nvme` command. Installed automatically by `scripts/install.sh`. |
| [`discovery-client`](https://github.com/LightBitsLabs/discovery-client) package | Lightbits' NVMe-oF connection manager. The plugin seeds it instead of calling `nvme connect` itself. Installed automatically by `scripts/install.sh`. |
| `nvme_tcp` kernel module | Loaded automatically by nvme-cli on modern Proxmox kernels. |
| Network access | TCP reachability to the Lightbits host on **port 4420** (I/O) and **port 8009** (discovery). |

## Configuration parameters

| Parameter | Description | Example |
|---|---|---|
| `lb_nvme_host` | Lightbits data-node address(es), comma-separated for a multi-node cluster. Seeds `discovery-client`. | `192.168.10.10:4420,192.168.10.11:4420` |
| `lb_subsys_nqn` | Subsystem NQN of the Lightbits cluster | `nqn.2016-01.com.lightbitslabs:uuid:...` |

## Obtaining the subsystem NQN

The plugin fetches this automatically from the cluster API; you normally don't need it. To look it up manually, from any Linux host with network access to the Lightbits cluster's discovery port:

```bash
nvme discover -t tcp -a <lightbits-ip> -s 8009
```

Look for the `subnqn:` field in the output:

```
subnqn:  nqn.2016-01.com.lightbitslabs:uuid:4ec00692-4b2d-4278-8f72-0f6c290c69e8
```

## How the TCP connection is managed

The plugin does not call `nvme connect`/`nvme disconnect` directly — it delegates to Lightbits' `discovery-client` daemon, mirroring how Lightbits' own OpenStack (Cinder/os-brick) integration manages connections:

- **VM start (`activate_volume`)** - writes `/etc/discovery-client/discovery.d/lightbits-<storeid>.conf` (one `-t tcp -a <host> -s 8009 -q <hostnqn> -n <subsys_nqn>` line per `lb_nvme_host` entry) if no connection to the subsystem exists yet. `discovery-client` watches that directory and connects every listed data node itself. Multiple volumes on the same subsystem share the resulting connections.
- **VM stop (`deactivate_volume`)** - removes this storage's conf file and calls `nvme disconnect -n <subsys_nqn>` only when the last active volume on that subsystem is deactivated, avoiding disruption to other running VMs. The explicit disconnect stays necessary because `discovery-client` does not proactively tear down connections on its own (unless the cluster has `ctrlLossTMO` configured, LightOS 3.19.1+).

## Verifying connectivity

```bash
# Is discovery-client installed and running?
systemctl status discovery-client

# Discover available subsystems
nvme discover -t tcp -a <lightbits-ip> -s 8009

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

**`discovery-client` not installed or not running**
```bash
systemctl status discovery-client
# see https://github.com/LightBitsLabs/discovery-client for manual install steps
```

**Block device does not appear after connect**

The plugin polls sysfs for up to 30 seconds. If the cluster is under load it may take longer. Check:
```bash
lsmod | grep nvme_tcp
cat /etc/discovery-client/discovery.d/lightbits-<storeid>.conf
nvme list
```

**Port 4420 or 8009 unreachable**

Verify firewall rules allow TCP 4420 (I/O) and 8009 (discovery) from the Proxmox host to the Lightbits cluster nodes.
