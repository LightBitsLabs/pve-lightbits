# Lightbits Storage Plugin for Proxmox VE

A native Proxmox VE storage plugin that integrates [Lightbits LightOS](https://www.lightbitslabs.com/) as a block storage backend. VM disks are created as Lightbits volumes and connected to Proxmox hosts via **NVMe-oF**, delivering NVMe-class latency and throughput. The currently supported transport is **NVMe-oF TCP** - no specialised hardware required.

> **Open-source, community-driven project.** Maintained by Lightbits Labs and the community on a best-effort basis via GitHub. See [Project Status and Support](#project-status-and-support) for the support model and how this relates to Lightbits LightOS commercial offerings.

---

## What This Plugin Does

Proxmox VE manages VM disks through a pluggable storage layer. This plugin teaches Proxmox how to:

| Operation | What happens |
|---|---|
| **Add storage** | Proxmox recognises `lightbits` as a storage type |
| **Create a VM disk** | A volume is provisioned via the Lightbits REST API |
| **Start a VM** | An NVMe-oF connection is established; the volume appears as a block device |
| **Stop a VM** | The NVMe-oF connection is torn down when no volumes remain active |
| **Delete a VM disk** | The volume is deleted from Lightbits via the REST API |
| **Resize a VM disk** | The Lightbits volume is grown online or offline (`qm resize`); a running VM sees the new capacity immediately, no downtime |
| **Snapshot a VM disk** | A point-in-time Lightbits snapshot is created (`qm snapshot`), project-scoped and crash-consistent for a running guest |
| **Roll back a VM disk** | The volume is restored to a prior snapshot via the cluster's native server-side rollback (`qm rollback`) — near-instant, no host-side data copy |
| **Storage capacity** | Proxmox dashboard shows total / available / used space from the Lightbits cluster |

### Why use Lightbits instead of local storage?

- **Performance**: NVMe-oF delivers near-native NVMe latency - the TCP transport requires no FC HBAs or iSCSI initiator complexity.
- **Capacity pooling**: All Proxmox nodes share the same Lightbits storage pool. Disks are not tied to a single host.
- **Thin provisioning**: Volumes only consume physical space as data is written.
- **Enterprise durability**: Lightbits replicates data across drives and nodes (configurable replica count).
- **Operational simplicity**: Create, resize, and delete volumes through the existing Proxmox UI or CLI.

---

## Demo

![Lightbits Proxmox VE plugin demo](docs/Proxmox-lb-plugin-demo.gif)

---

## Architecture

```
 ┌─────────────────────────────────┐       ┌──────────────────────────────┐
 │         Proxmox Host            │       │      Lightbits Cluster       │
 │                                 │       │                              │
 │  pvedaemon                      │       │  LightOS REST API  :443      │
 │    └─ LightbitsPlugin.pm ───────┼──────>│  (volume CRUD)               │
 │                                 │       │                              │
 │  QEMU (VM)                      │       │  NVMe-oF target    :4420     │
 │    └─ /dev/lightbits/           │       │  (block device I/O)          │
 │         └─ <uuid> ──────────────┼──────>│                              │
 │              (symlink)          │       └──────────────────────────────┘
 │              ↓                  │
 │         /dev/nvme0n1            │
 └─────────────────────────────────┘
```

The plugin has two communication paths to the Lightbits cluster:

1. **REST API** (`https://<host>:443`) - used by the Proxmox daemon to manage volume lifecycle (create, list, delete). Authenticated with a JWT bearer token.
2. **NVMe-oF** (`<host>:4420`) - used at VM start/stop to connect the volume as a block device. Currently uses TCP transport (`nvme-tcp` kernel module). See [`docs/transports/tcp.md`](docs/transports/tcp.md) for details.

---

## Prerequisites

### On the Proxmox side

| Requirement | Notes |
|---|---|
| Proxmox VE **9.x** | Tested on 9.2. Requires the PVE 9 storage API (`-blockdev`). |
| `nvme-cli` package | Provides the `nvme` command used for connect/disconnect. Ubuntu/Debian: `apt-get install -y nvme-cli`. RHEL/Rocky: `dnf install -y nvme-cli`. |
| [`discovery-client`](https://github.com/LightBitsLabs/discovery-client) package | Lightbits' NVMe-oF connection manager. The plugin seeds it with this cluster's discovery endpoints instead of running `nvme connect` itself, so it discovers nodes added to the cluster later on its own (removed nodes still need the plugin's own disconnect — see the note below). `scripts/install.sh` attempts to install and start it automatically, best-effort (it warns and continues rather than aborting if that fails, e.g. no internet access — install and start it manually in that case; see [Verify NVMe-oF connectivity](#verify-nvme-of-connectivity-optional-pre-check) to check its status). |
| `nvme_tcp` kernel module | Loaded automatically by nvme-cli on modern Proxmox kernels. |
| Perl modules | `LWP::Protocol::https` and `JSON` - both included in stock Proxmox. |
| Network access | TCP reachability to the Lightbits host on **port 443** (REST), **port 4420** (NVMe-oF I/O), and **port 8009** (NVMe-oF discovery). |

### On the Lightbits side

You need to collect three values before installation:

| Value | Where to find it |
|---|---|
| **API endpoint(s)** | IP or hostname of one or more Lightbits nodes, port 443. Example: `192.168.10.10:443`. List every management node you want failover across as a comma-separated `lb_api_host` (e.g. `192.168.10.10:443,192.168.10.11:443`) — the plugin tries each one on a connection failure or 5xx, so the storage keeps working even if one node is down. Failover only advances to the next endpoint for these retryable failures: a 4xx is treated as a definitive answer (every endpoint fronts the same cluster state) and stops there, and mutating calls (create/update/delete) are only tried against one endpoint per call, since a 5xx from those can arrive after the request already took effect. |
| **JWT token** | Found at `/etc/lbcli/lbcli.yml` on the cluster management node, or generated with `lbcli create jwt`. |
| **NVMe-oF data endpoint(s)** | Same IP(s) as the API nodes, port 4420. Example: `192.168.10.10:4420`. List **every data node** on a multi-node cluster as a comma-separated `lb_nvme_host` — this seeds `discovery-client` (see below), which then discovers nodes added to the cluster later on its own. It does **not** proactively drop the connection to a node removed from this list (see the note below) — shrinking the list only fully takes effect once this storage's own connection is cleared, on its next full deactivation. |
| **Project name** | Optional. Default is `default`. Use a specific project to isolate Proxmox volumes. |

The subsystem NQN is fetched automatically from the cluster API — you no longer need to look it up manually. If you prefer to pin it explicitly (e.g. for air-gapped environments where the API may be unreachable at connect time), you can still supply `--lb_subsys_nqn`.

> **Note on discovery:** LightOS exposes a standard NVMe-oF Discovery Controller (port 8009), and this plugin uses Lightbits' official [`discovery-client`](https://github.com/LightBitsLabs/discovery-client) daemon to manage NVMe-oF connections rather than calling `nvme connect` itself. On volume activation, the plugin writes `lb_nvme_host`'s endpoints into a `discovery-client` config file (`/etc/discovery-client/discovery.d/lightbits-<storeid>.conf`); `discovery-client` then connects every data node and — unlike a static one-shot connect — keeps that current as cluster nodes are added later, with no config change needed on this host. It does **not** proactively remove connections for *removed* nodes on its own (they go stale) unless the cluster has `ctrlLossTMO` configured (LightOS 3.19.1+), so the plugin still runs an explicit `nvme disconnect` on the last deactivation of a subsystem.

#### Getting a JWT token

Tokens are usually created during initial cluster deployment and can be found on the Lightbits cluster management node at:

```
/etc/lbcli/lbcli.yml
```

To generate a new token (LightOS 2.1 and above):

```bash
lbcli create jwt
```

To decode and inspect an existing token (LightOS 3.12.2 and above):

```bash
lbcli parse jwt
```

If your cluster uses an external identity provider (e.g. ADFS), run `lbcli login` instead - this generates an `idp-session.yaml` file that takes precedence over other stored tokens until it expires or you run `lbcli logout`.

For full reference see the [lbcli create jwt documentation](https://documentation.lightbitslabs.com/lightbits-cli-reference-guide/lbcli-create-jwt--2-1-and-above-).

---

## Installation

> **Data-loss warning.** This plugin provisions and manages VM disks as volumes on a remote Lightbits cluster. Misconfiguration — wrong project name, wrong storage ID at destroy time, ACL collisions when multiple Proxmox clusters share a project, or a stale JWT pointing at the wrong cluster — can result in **permanent loss of VM disk data**. Test in a non-production environment first, keep independent backups of any data you cannot afford to lose, and double-check the cluster, project, and storage ID before any destructive `pvesm` / `qm destroy` operation.

Run these commands on **each Proxmox node** that will access Lightbits storage.

### 1. Clone the repository

```bash
git clone https://github.com/LightBitsLabs/pve-lightbits.git
cd pve-lightbits
```

### 2. Run the installer

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

The installer:
- Installs `LightbitsPlugin.pm` into the official third-party namespace at `/usr/share/perl5/PVE/Storage/Custom/`, where Proxmox **auto-loads** it — no patching of PVE's own files
- Installs `nvme-cli` if not present
- Installs and starts `discovery-client` if not present (best-effort — if the repo setup fails, e.g. no internet access, it warns and continues; install it manually before use in that case)
- Restarts `pvedaemon` and `pvestatd`

### 3. Add the storage

#### Via CLI (recommended for scripted/multi-node setups)

**On a multi-node cluster, list every node's IP** in both `--lb_api_host` and
`--lb_nvme_host` — one `host:port` per cluster node, comma-separated, for
*every* node, not just one:

- `--lb_api_host` needs every management node so the plugin can fail over
  REST calls if any single one is down (see [On the Lightbits
  side](#on-the-lightbits-side) above).
- `--lb_nvme_host` needs every data node so `discovery-client` (see the [note
  on discovery](#on-the-lightbits-side) above) can reach every node's
  ANA-optimized path and the volume's namespace is never stuck behind a
  connection to only part of the cluster.

Leaving a node's IP out of either list means that node is invisible to the
plugin for that purpose — it won't be tried for API failover, and its data
path won't be seeded for discovery-client — even though the cluster itself
knows about it.

```bash
pvesm add lightbits lb-storage \
  --lb_api_host  192.168.10.10:443,192.168.10.11:443,192.168.10.12:443 \
  --lb_jwt       'eyJhbGci...' \
  --lb_nvme_host 192.168.10.10:4420,192.168.10.11:4420,192.168.10.12:4420 \
  --lb_project   default \
  --content      images
```

On a single-node cluster there's only one IP to give, so both options
collapse to one endpoint each:

```bash
pvesm add lightbits lb-storage \
  --lb_api_host  192.168.10.10:443 \
  --lb_jwt       'eyJhbGci...' \
  --lb_nvme_host 192.168.10.10:4420 \
  --lb_project   default \
  --content      images
```

To create volumes with more than one replica (on a multi-node cluster), add `--lb_replica_count 2` (or `3`). It defaults to `1`, and the value must be supported by the cluster — a single-node cluster only accepts `1`.

#### TLS verification for the API connection

The plugin talks to the LightOS cluster API over HTTPS. Certificate verification is **off by default**, because a cluster commonly serves its API with a self-signed or internal-CA certificate and enabling verification unconditionally would break those deployments.

Turn it on wherever your certificate chain allows. Every API request carries the `lb_jwt` bearer token in an `Authorization` header, and with verification off an on-path attacker can present any certificate, terminate the connection, and capture a token that grants full control of the project's volumes:

```bash
pvesm set lb-storage --lb_ssl_verify 1
```

If the CA that signed the cluster's certificate is not in the Proxmox host's system trust store, point the plugin at it:

```bash
pvesm set lb-storage --lb_ssl_verify 1 --lb_ca_file /etc/pve/lightbits-ca.pem
```

`lb_ca_file` is only consulted when `lb_ssl_verify` is enabled, and an unreadable path fails the API call loudly rather than silently falling back to an unverified connection.

The subsystem NQN is fetched automatically from the cluster. To override it explicitly (same "list every node" rule applies to `lb_api_host`/`lb_nvme_host` here too):

```bash
pvesm add lightbits lb-storage \
  --lb_api_host   192.168.10.10:443,192.168.10.11:443,192.168.10.12:443 \
  --lb_jwt        'eyJhbGci...' \
  --lb_nvme_host  192.168.10.10:4420,192.168.10.11:4420,192.168.10.12:4420 \
  --lb_subsys_nqn 'nqn.2016-01.com.lightbitslabs:uuid:4ec00692-4b2d-4278-8f72-0f6c290c69e8' \
  --lb_project    default \
  --content       images
```

`lb_api_host` and `lb_nvme_host` can be updated in place at any time (e.g. after scaling the LightOS cluster — append the new node's IP to *both* options) with `pvesm set`:

```bash
pvesm set lb-storage --lb_api_host  192.168.10.10:443,192.168.10.11:443,192.168.10.12:443,192.168.10.13:443
pvesm set lb-storage --lb_nvme_host 192.168.10.10:4420,192.168.10.11:4420,192.168.10.12:4420,192.168.10.13:4420
```

Both `pvesm set` commands update `storage.cfg` immediately, but they take effect differently for an already-active storage: `lb_api_host` changes apply to the very next REST API call, with no volume activation needed. `lb_nvme_host` changes are only picked up the next time a volume on this storage is activated (its `discovery-client` config is rewritten then, not immediately) — and *removing* an endpoint still leaves its existing connection in place until the subsystem's last active volume across every storage on this host is deactivated (see the note above).

#### A note on the Web UI

Third-party storage plugins are **not** listed in **Datacenter → Storage → Add** — that menu is hardcoded in the Proxmox web interface for the storage types shipped with Proxmox itself (Ceph/RBD, ZFS, NFS, …). Add the `lightbits` storage with the `pvesm` command above (or by editing `/etc/pve/storage.cfg`).

Once added, the storage **does** appear in the GUI storage tree and is usable from the web UI for supported operations (for example creating/deleting VM disks and viewing capacity). Only the initial "Add Storage" wizard is CLI/config-only.

---

## Uninstalling

```bash
sudo ./scripts/uninstall.sh
```

If any `lightbits` storage entries still exist in `/etc/pve/storage.cfg`, the
script refuses to proceed and lists the `pvesm remove <storeid>` command for
each one — remove them first (or pass `--force` to have the script do it for
you) and re-run.

The uninstaller then removes, in order:
- Every `discovery-client` config file this plugin wrote
  (`/etc/discovery-client/discovery.d/lightbits-*.conf`) — this runs
  unconditionally once no `lightbits` storage remains, regardless of whether
  you removed the storage entries yourself or used `--force`, so nothing is
  left seeded for a storage that no longer exists.
- The plugin file itself
  (`/usr/share/perl5/PVE/Storage/Custom/LightbitsPlugin.pm`).

It then restarts `pvedaemon`/`pvestatd`.

**Not removed by the uninstaller** (deliberately, since other things on the
host may still depend on them): the `discovery-client` and `nvme-cli`
packages, and any live NVMe-oF connections/kernel controllers — a connection
that's still in use by another storage sharing the same subsystem is never
torn down automatically (see [How the TCP connection is
managed](docs/transports/tcp.md)). If you're fully decommissioning Lightbits
access from this host, disconnect manually afterward:
```bash
nvme disconnect -n <subsys_nqn>
sudo apt-get remove discovery-client nvme-cli   # optional
```

---

## Verifying the Installation

### Check the storage is visible and active

```bash
pvesm status
```

Expected output includes a line for `lb-storage` showing total and available capacity:

```
Name             Type     Status           Total            Used       Available
lb-storage       lightbits  active      107374182400      4294967296   103079215104
local            dir      active        ...
local-lvm        lvmthin  active        ...
```

### Check the Lightbits API is reachable

```bash
pvesm list lb-storage
```

This calls `GET /api/v2/volumes` and lists all volumes in the configured project. An empty list with no error means the API connection is working.

### Verify NVMe-oF connectivity (optional pre-check)

Check that TCP ports 4420 (I/O) and 8009 (discovery) are reachable from the Proxmox host:

```bash
nc -zv <lightbits-ip> 4420
nc -zv <lightbits-ip> 8009
```

Also confirm `discovery-client` is installed and running:

```bash
systemctl status discovery-client
```

A successful connection confirms the network path is open. The actual NVMe-oF session is established by `discovery-client` when a VM starts, seeded by the plugin's config file at `/etc/discovery-client/discovery.d/lightbits-<storeid>.conf` (see the note in [On the Lightbits side](#on-the-lightbits-side)).

---

## Testing End-to-End

### 1. Allocate a volume directly

```bash
pvesm alloc lb-storage 9999 test-vol 4G
```

Expected output: `lb-storage:vm-9999-<uuid>` (the volid embeds the owning VM id).

Check it appeared in Lightbits:
```bash
pvesm list lb-storage
```

Clean up:
```bash
pvesm free lb-storage:vm-9999-<uuid>
```

### 2. Create a VM with a Lightbits disk

Via CLI:

```bash
pvesh create /nodes/$(hostname)/qemu \
  --vmid 200 \
  --name  test-lb-vm \
  --memory 512 \
  --cores  1 \
  --scsi0  lb-storage:4 \
  --ostype l26
```

Confirm the disk was created and its volid:

```bash
pvesh get /nodes/$(hostname)/qemu/200/config | grep scsi
```

### 3. Start the VM and verify the NVMe connection

```bash
pvesh create /nodes/$(hostname)/qemu/200/status/start
```

After a few seconds:

```bash
# NVMe controller should be connected
nvme list

# Symlink should exist pointing to the block device
ls -la /dev/lightbits/lb-storage/
```

Expected symlink:

```
lrwxrwxrwx 1 root root 12 /dev/lightbits/lb-storage/<uuid> -> /dev/nvme0n1
```

### 4. Stop the VM and verify cleanup

```bash
pvesh create /nodes/$(hostname)/qemu/200/status/stop
```

The NVMe connection is automatically disconnected when the last volume is deactivated:

```bash
nvme list   # should show no Lightbits devices
```

### 5. Delete the VM and its disk

```bash
pvesh delete /nodes/$(hostname)/qemu/200 \
  --destroy-unreferenced-disks 1 \
  --purge 1
```

Verify the volume is gone from Lightbits:

```bash
pvesm list lb-storage   # volume should no longer appear
```

---

## Troubleshooting

### `storage 'lb-storage' does not exist` during VM creation

This means the `lightbits` storage type isn't registered. The plugin is auto-loaded from the Custom namespace, so verify the file is present:

```bash
ls /usr/share/perl5/PVE/Storage/Custom/LightbitsPlugin.pm   # should exist
```

If it is missing, re-run `scripts/install.sh` and restart the services:

```bash
systemctl restart pvedaemon pvestatd
```

### `Cannot read /etc/nvme/hostnqn`

`nvme-cli` is not installed or was never initialised. Install it:

```bash
# Ubuntu/Debian (including Proxmox VE)
apt-get install -y nvme-cli

# RHEL/Rocky/AlmaLinux
dnf install -y nvme-cli

cat /etc/nvme/hostnqn   # should print a nqn.* string
```

### `Block device for volume <uuid> (nsid=N) did not appear`

The NVMe-oF connect never happened or the block device didn't show up. Check:

```bash
# Is discovery-client installed and running?
systemctl status discovery-client

# Did the plugin write a config file for this storage?
cat /etc/discovery-client/discovery.d/lightbits-<storeid>.conf

# Did discovery-client connect?
nvme list

# Are nvme modules loaded?
lsmod | grep nvme_tcp

# Load the module manually if needed
modprobe nvme_tcp
```

If `nvme list` shows the device but the plugin still fails, there may be a kernel/sysfs timing issue - the plugin polls for 30 seconds; a slow cluster might need a longer timeout. If this host's NQN isn't in the volume's ACL, the connection succeeds but the namespace never appears — check `/etc/nvme/hostnqn` against the volume's ACL via the Lightbits API/`lbcli`.

### `Lightbits API ... failed: 401 Unauthorized`

The JWT token has expired or lacks the required permissions. Generate a new token on the cluster management node:

```bash
lbcli create jwt
```

Then update the storage config:

```bash
pvesm set lb-storage --lb_jwt '<new token>'
```

### `Lightbits API ... failed: 403 Forbidden` on volume create

The Lightbits project may not exist, or the token does not have access to it. Verify:

```bash
curl -sk -H "Authorization: Bearer <jwt>" \
  https://<lightbits-ip>:443/api/v2/projects | python3 -m json.tool
```

### Storage shows 0 capacity / not active

The REST API call to `/api/v2/cluster` failed silently. Check Proxmox logs:

```bash
journalctl -u pvestatd -n 50 --no-pager
```

Also verify the API endpoint is correct (it must include the port):

```bash
pvesm config lb-storage | grep lb_api_host
```

---

## How It Works (Technical Detail)

### Volume lifecycle

1. **`alloc_image`** - Called when Proxmox allocates a new disk.
   - Reads the host NQN from `/etc/nvme/hostnqn`.
   - POSTs to `/api/v2/volumes` with the volume name (`vm-<vmid>-<vmgenid>-disk-<n>`), size (bytes, 4096-aligned), replica count, project, and the host NQN in the ACL so only this host can access it.
   - Polls until the volume reaches `Available` state.
   - Returns the volid `lb-storage:vm-<vmid>-<uuid>` (the embedded vmid lets Proxmox identify the owning guest), which is stored in the VM config.

2. **`activate_volume`** - Called when a VM starts.
   - GETs the volume to retrieve its NVMe namespace ID (NSID).
   - Writes (or rewrites) `/etc/discovery-client/discovery.d/lightbits-<storeid>.conf` (one `-t tcp -a <host> -s 8009 -q <hostnqn> -n <subsys_nqn>` line per `lb_nvme_host` entry) whenever this volume isn't already active on this host — not only when no connection exists yet — `discovery-client` (not the plugin) then performs the actual `nvme connect` against every data node.
   - Scans `/sys/block/` to find the block device with matching NSID (the kernel names namespaces sequentially regardless of the NSID value).
   - Creates a stable symlink at `/dev/lightbits/<storeid>/<uuid>` → `/dev/nvmeXnY`.

3. **`deactivate_volume`** - Called when a VM stops.
   - Removes the symlink.
   - Removes this storage's own `discovery-client` config file once none of its own volumes are still active (independent of other storages sharing the same cluster).
   - Directly calls `nvme disconnect` once the last active volume for that subsystem, across *every* storage on this host, is deactivated (discovery-client does not proactively tear down connections on its own, so this stays necessary — avoids disrupting other running VMs on the same subsystem in the meantime).

4. **`free_image`** - Called when a disk is deleted.
   - DELETEs the volume via the REST API.
   - Removes the symlink if it still exists.

### Sysfs namespace mapping

Linux numbers NVMe namespaces sequentially (`nvme0n1`, `nvme0n2`, ...) regardless of the Lightbits NSID. To find the correct block device, the plugin iterates `/sys/class/nvme/<ctrl>/` looking for entries that contain a `nsid` file matching the Lightbits-assigned NSID:

```
/sys/class/nvme/nvme0/nvme0c0n1/nsid  →  "2"
                                           ↓
                              maps to /dev/nvme0n1
```

---

## Limitations

- **No live migration**: VM live migration requires shared storage visibility on both source and destination hosts. Multi-node deployment with a shared Lightbits cluster works structurally, but the per-host ACL in `alloc_image` currently restricts volume access to the allocating host's NQN. This needs to be addressed for migration support.
- **Self-signed TLS**: SSL hostname verification is disabled to accommodate Lightbits clusters with self-signed certificates.
- **Internet access required during install**: `scripts/install.sh` fetches `discovery-client` from Lightbits' hosted package repository. Air-gapped/offline environments aren't supported yet — see the Roadmap below.

---

## Roadmap

### Phase 1 — Single cluster, volume CRUD (current)

- Single Lightbits cluster per storage entry
- Full volume lifecycle for VM disks: create, attach, detach, delete
- Volume resize (grow), online and offline
- Volume snapshots and rollback (native server-side rollback)
- Per-VM ownership labels and node-aware filtering (multi-hypervisor safety)
- NVMe-oF TCP transport
- Storage capacity reporting

### Phase 2 and beyond

On the horizon:

- Volume clones (including file-level recovery from a snapshot)
- Multi-tenancy and multi-cluster support
- Live migration support
- Broader Proxmox feature coverage (containers, ISO, vTPM, backups)
- Debian packaging
- Air-gapped/offline installation support
- and more

Contributions welcome at any phase — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Files

```
pve-lightbits/
├── LightbitsPlugin.pm        # The Proxmox storage plugin (Perl)
├── scripts/
│   ├── install.sh            # Installer - run on each Proxmox node
│   └── uninstall.sh          # Uninstaller
├── docs/
│   └── transports/
│       └── tcp.md            # NVMe-oF TCP setup and configuration
└── README.md                 # This file
```

---

## Compatibility

| Component | Version |
|---|---|
| Proxmox VE | 9.x (tested on 9.2) |
| Lightbits LightOS | 3.x |
| Perl | 5.36+ |
| Linux kernel | 5.0+ (nvme_tcp module required) |

---

## Project Status and Support

This is an **open-source, community-driven project** maintained by Lightbits Labs together with the broader community of Proxmox VE and LightOS users. We actively welcome bug reports, pull requests, and feature suggestions — the project grows through community contribution.

### Getting help

- **Bug reports, questions, and feature requests** — open a [GitHub Issue](https://github.com/LightBitsLabs/pve-lightbits/issues). Lightbits engineers and community contributors monitor the tracker and respond on a best-effort basis.
- **Security vulnerabilities** — please report privately; see [SECURITY.md](SECURITY.md).
- **Contributing code** — see [CONTRIBUTING.md](CONTRIBUTING.md).

### Relationship to Lightbits commercial offerings

This plugin is distributed under the [Apache License 2.0](LICENSE) and is provided **"as is"**, without warranty of any kind (Apache 2.0 §7) and subject to the limitation of liability in Apache 2.0 §8. It is **not part of the Lightbits LightOS commercial product** and is **not covered by Lightbits LightOS support agreements or SLAs** unless a separate written agreement explicitly states otherwise. Customers with active Lightbits support contracts are still encouraged to engage here — the LightOS engineering team participates directly in this project — but response times, fixes, and feature delivery follow the open-source community model rather than any commercial support tier.
