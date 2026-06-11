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
| `nvme_tcp` kernel module | Loaded automatically by nvme-cli on modern Proxmox kernels. |
| Perl modules | `LWP::Protocol::https` and `JSON` - both included in stock Proxmox. |
| Network access | TCP reachability to the Lightbits host on **port 443** (REST) and **port 4420** (NVMe-oF). |

### On the Lightbits side

You need to collect three values before installation:

| Value | Where to find it |
|---|---|
| **API endpoint** | IP or hostname of any Lightbits node, port 443. Example: `192.168.10.10:443` |
| **JWT token** | Found at `/etc/lbcli/lbcli.yml` on the cluster management node, or generated with `lbcli create jwt`. |
| **NVMe-oF endpoint** | Same IP as API, port 4420. Example: `192.168.10.10:4420` |
| **Project name** | Optional. Default is `default`. Use a specific project to isolate Proxmox volumes. |

The subsystem NQN is fetched automatically from the cluster API — you no longer need to look it up manually. If you prefer to pin it explicitly (e.g. for air-gapped environments where the API may be unreachable at connect time), you can still supply `--lb_subsys_nqn`.

> **Note:** `nvme discover` does not work with Lightbits — the cluster does not expose an NVMe-oF Discovery Controller. The plugin connects directly using `nvme connect`, using the NQN retrieved from the cluster API.

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
- Restarts `pvedaemon` and `pvestatd`

### 3. Add the storage

#### Via CLI (recommended for scripted/multi-node setups)

```bash
pvesm add lightbits lb-storage \
  --lb_api_host  192.168.10.10:443 \
  --lb_jwt       'eyJhbGci...' \
  --lb_nvme_host 192.168.10.10:4420 \
  --lb_project   default \
  --content      images
```

The subsystem NQN is fetched automatically from the cluster. To override it explicitly:

```bash
pvesm add lightbits lb-storage \
  --lb_api_host   192.168.10.10:443 \
  --lb_jwt        'eyJhbGci...' \
  --lb_nvme_host  192.168.10.10:4420 \
  --lb_subsys_nqn 'nqn.2016-01.com.lightbitslabs:uuid:4ec00692-4b2d-4278-8f72-0f6c290c69e8' \
  --lb_project    default \
  --content       images
```

#### A note on the Web UI

Third-party storage plugins are **not** listed in **Datacenter → Storage → Add** — that menu is hardcoded in the Proxmox web interface for the storage types shipped with Proxmox itself (Ceph/RBD, ZFS, NFS, …). Add the `lightbits` storage with the `pvesm` command above (or by editing `/etc/pve/storage.cfg`).

Once added, the storage **does** appear in the GUI storage tree and is usable from the web UI for supported operations (for example creating/deleting VM disks and viewing capacity). Only the initial "Add Storage" wizard is CLI/config-only.

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

Check that TCP port 4420 is reachable from the Proxmox host:

```bash
nc -zv <lightbits-ip> 4420
```

A successful connection confirms the network path is open. The actual NVMe-oF session is established by the plugin when a VM starts — `nvme discover` does not work with Lightbits and should not be used.

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

The NVMe-oF connect succeeded but the block device didn't show up. Check:

```bash
# Did the connect succeed?
nvme list

# Are nvme modules loaded?
lsmod | grep nvme_tcp

# Load the module manually if needed
modprobe nvme_tcp
```

If `nvme list` shows the device but the plugin still fails, there may be a kernel/sysfs timing issue - the plugin polls for 30 seconds; a slow cluster might need a longer timeout.

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
   - Calls `nvme connect -t tcp -a <host> -s <port> -n <subsys_nqn>` if not already connected.
   - Scans `/sys/class/nvme/` to find the block device with matching NSID (the kernel names namespaces sequentially regardless of the NSID value).
   - Creates a stable symlink at `/dev/lightbits/<storeid>/<uuid>` → `/dev/nvmeXnY`.

3. **`deactivate_volume`** - Called when a VM stops.
   - Removes the symlink.
   - Lists remaining active volumes; calls `nvme disconnect` only when the last volume is deactivated (avoids disrupting other running VMs on the same subsystem).

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

- **Single NVMe-oF endpoint**: The plugin connects to one `lb_nvme_host`. Multi-path is not yet implemented.
- **No snapshots**: Proxmox snapshot operations are not supported by this plugin version.
- **No live migration**: VM live migration requires shared storage visibility on both source and destination hosts. Multi-node deployment with a shared Lightbits cluster works structurally, but the per-host ACL in `alloc_image` currently restricts volume access to the allocating host's NQN. This needs to be addressed for migration support.
- **Single replica**: Volumes are created with `replicaCount: 1`. Change this in `alloc_image` if your Lightbits cluster is configured for replication.
- **Self-signed TLS**: SSL hostname verification is disabled to accommodate Lightbits clusters with self-signed certificates.

---

## Roadmap

### Phase 1 — Single cluster, volume CRUD (current)

- Single Lightbits cluster per storage entry
- Full volume lifecycle for VM disks: create, attach, detach, delete
- Per-VM ownership labels and node-aware filtering (multi-hypervisor safety)
- NVMe-oF TCP transport
- Storage capacity reporting

### Phase 2 and beyond

On the horizon:

- Snapshots and clones
- Volume resize
- Multi-tenancy and multi-cluster support
- Configurable replica count and multi-path NVMe-oF
- Live migration support
- Broader Proxmox feature coverage (containers, ISO, vTPM, backups)
- Debian packaging
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
