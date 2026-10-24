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
| **Live-migrate a VM** | `qm migrate --online` moves a running VM to another node of the PVE cluster without copying its disks: the target node is granted access to the same Lightbits volume and connects to it |
| **HA failover** | With the VM managed by `ha-manager`, a failed node's VMs restart on a surviving node, which connects to the same volumes |
| **Storage capacity** | Proxmox dashboard shows total / available / used space from the Lightbits cluster |

### Why use Lightbits instead of local storage?

- **Performance**: NVMe-oF delivers near-native NVMe latency - the TCP transport requires no FC HBAs or iSCSI initiator complexity.
- **Capacity pooling**: All Proxmox nodes share the same Lightbits storage pool. Disks are not tied to a single host.
- **Thin provisioning**: Volumes only consume physical space as data is written.
- **Enterprise durability**: Lightbits replicates data across drives and nodes (configurable replica count).
- **Operational simplicity**: Create, resize, and delete volumes through the existing Proxmox UI or CLI.

---

## Demo

Video walkthrough: [Deployment Guide: NVMe/TCP Block Storage for Proxmox VE](https://www.youtube.com/watch?v=OmA8aSOxlPU&t=6s) on the Lightbits Labs YouTube channel.

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
| Proxmox VE **9.x** | Tested on 9.2 up to `libpve-storage-perl` 9.1.13 (storage API 16). Requires the PVE 9 storage API (`-blockdev`). |
| `nvme-cli` package | Provides the `nvme` command used for connect/disconnect. Ubuntu/Debian: `apt-get install -y nvme-cli`. RHEL/Rocky: `dnf install -y nvme-cli`. |
| [`discovery-client`](https://github.com/LightBitsLabs/discovery-client) package | Lightbits' NVMe-oF connection manager. The plugin seeds it with this cluster's discovery endpoints instead of running `nvme connect` itself, so it discovers nodes added to the cluster later on its own (removed nodes still need the plugin's own disconnect — see the note below). `scripts/install.sh` attempts to install and start it automatically, best-effort (it warns and continues rather than aborting if that fails, e.g. no internet access — install and start it manually in that case; see [Verify NVMe-oF connectivity](#verify-nvme-of-connectivity-optional-pre-check) to check its status). |
| `nvme_tcp` kernel module | Loaded automatically by nvme-cli on modern Proxmox kernels. |
| Perl modules | `LWP::Protocol::https` and `JSON` - both included in stock Proxmox. |
| Network access | TCP reachability to the Lightbits host on **port 443** (REST), **port 4420** (NVMe-oF I/O), and **port 8009** (NVMe-oF discovery). |

### On the Lightbits side

You need to collect three values before installation:

| Value | Where to find it |
|---|---|
| **API endpoint(s)** | IP or hostname of one or more Lightbits nodes, port 443. Example: `192.168.10.10:443`. List every management node you want failover across as a comma-separated `lb_api_host` (e.g. `192.168.10.10:443,192.168.10.11:443`) — the plugin tries each one on a connection failure or 5xx, so the storage keeps working even if one node is down. A call that only succeeds after skipping an endpoint logs a one-line warning naming the skipped endpoint (in every task log it affects; in the `pvestatd`/`pvedaemon` journal at most once per endpoint every 10 minutes) (see [Troubleshooting](#lightbits-api--succeeded-via--after-failing-via-)), so a degraded node is visible before every endpoint fails. Failover only advances to the next endpoint for retryable failures: a 4xx is treated as a definitive answer (every endpoint fronts the same cluster state) and stops there. Reads (GET/HEAD) fail over on any transport failure or 5xx. Mutating calls (create/update/delete) fail over only when the request provably never reached the endpoint (connection refused, connect timeout, unresolvable name, failed TLS handshake); a 5xx, a read timeout or a reset after sending stays a single attempt, since the change may already have taken effect. |
| **JWT token** | Found at `/etc/lbcli/lbcli.yaml` on the cluster management node, or generated with `lbcli create jwt`. |
| **NVMe-oF data endpoint(s)** | Same IP(s) as the API nodes, port 4420. Example: `192.168.10.10:4420`. List **every data node** on a multi-node cluster as a comma-separated `lb_nvme_host` — this seeds `discovery-client` (see below), which then discovers nodes added to the cluster later on its own. It does **not** proactively drop the connection to a node removed from this list (see the note below) — shrinking the list only fully takes effect once this storage's own connection is cleared, on its next full deactivation. |
| **Project name** | Optional. Default is `default`. A dedicated project per Proxmox cluster is the cleanest setup, but sharing a project with other consumers is safe — see [Volumes the plugin does not own](#volumes-the-plugin-does-not-own). |

**Recommended: enable TRIM on the Lightbits cluster.** LightOS ships with `EnableTrim` off, and while it is off the discards a Proxmox guest sends do not free space on the cluster. Enable it once per cluster on a management node (LightOS 3.16 or later); the plugin does not change this setting. Once enabled it cannot be disabled. See [Lightbits TRIM Support](https://documentation.lightbitslabs.com/lightbits-private-cloud/lightbits--trim-support) in the Lightbits documentation.

```bash
lbcli update cluster-config --parameter=EnableTrim --value=true
lbcli list cluster-config          # shows EnableTrim true
```

Then set `discard=on` on the VM disks that should pass discards to the cluster (for example `qm set <vmid> --scsi0 <storage>:<volume>,discard=on`).

The subsystem NQN is fetched automatically from the cluster API — you no longer need to look it up manually. If you prefer to pin it explicitly (e.g. for air-gapped environments where the API may be unreachable at connect time), you can still supply `--lb_subsys_nqn`.

> **Note on discovery:** LightOS exposes a standard NVMe-oF Discovery Controller (port 8009), and this plugin uses Lightbits' official [`discovery-client`](https://github.com/LightBitsLabs/discovery-client) daemon to manage NVMe-oF connections rather than calling `nvme connect` itself. On volume activation, the plugin writes `lb_nvme_host`'s endpoints into a `discovery-client` config file (`/etc/discovery-client/discovery.d/lightbits-<storeid>.conf`); `discovery-client` then connects every data node and — unlike a static one-shot connect — keeps that current as cluster nodes are added later, with no config change needed on this host. It does **not** proactively remove connections for *removed* nodes on its own (they go stale) unless the cluster has `ctrlLossTMO` configured (LightOS 3.19.1+), so the plugin still runs an explicit `nvme disconnect` on the last deactivation of a subsystem.

#### Volumes the plugin does not own

The plugin labels every volume it creates with `pveVmid`, `pveVmgenid` and `pveNode` (the node hostname, or `lb_owner_id` if set — set it to the cluster name on a PVE cluster). **Ownership is decided by those labels alone.** A volume in the same LightOS project that does not carry a numeric `pveVmid` *and* a `pveNode` equal to this storage's owner id — one created with `lbcli`, by an application server, by another hypervisor or another PVE cluster — is

- never listed by `pvesm list` or shown in the storage's *VM Disks* view (so it can never appear as an "unused disk" with a *Remove* button),
- refused by `pvesm free` (the delete task fails with `refusing to delete Lightbits volume … not created by this Proxmox storage`), and
- refused when attached to a VM by volid (`qm set … --scsiN <storage>:vm-0-<uuid>`), so its ACL is never modified.

Manage such volumes with `lbcli`. Volume names are *not* consulted: an unlabelled volume called `vm-100-…` is still foreign. If a plugin-created volume lost its labels (for example because `lbcli update volume --labels` replaced them — LightOS replaces the whole label set on update), re-adopt it by restoring them:

```bash
lbcli update volume --project-name <project> --uuid <volume-uuid> \
  --labels pveVmid=<vmid>,pveNode=<owner-id>      # owner-id = lb_owner_id, or the node hostname if unset
```

This also means a LightOS project can be shared between Proxmox and other workloads: the plugin cannot touch what it did not create. Validated end-to-end on a pre-populated 3-node LightOS 3.20.1 cluster (`t/e2e/foreign_volumes.sh`).

> **Caution: snapshots and clones of a Proxmox disk made outside Proxmox.**
>
> - **Snapshots are deleted with the disk.** When Proxmox frees a disk (destroying the VM, removing the disk, `pvesm free`), the plugin first deletes **every** Lightbits snapshot of that volume, including snapshots taken with `lbcli` or by a backup tool, so that no orphaned snapshots keep holding capacity. If you need such a snapshot after the VM is gone, clone it to a separate volume first (see the next point).
> - **A clone inherits the disk's ownership labels unless you give it its own.** A volume created from a snapshot of a Proxmox disk (`lbcli create volume --source-snapshot-uuid ...`) copies the snapshot's labels, which are the Proxmox disk's `pveVmid` and `pveNode`. Proxmox then treats the clone as a disk of that VM: it appears in the VM's storage content, `qm disk rescan` adds it to the VM as an unused disk, and it is **deleted together with the VM** once it is referenced as an unused disk or when the VM is destroyed with *Destroy unreferenced disks owned by guest*. Always create such clones with labels of your own, which replace the inherited ones:
>
>   ```bash
>   lbcli create volume --project-name <project> --name <clone-name> --size <size> --replica-count <n> \
>     --acl <host-nqn> --source-snapshot-uuid <snapshot-uuid> --labels owner=<your-tool>
>   ```

#### Getting a JWT token

Tokens are usually created during initial cluster deployment and can be found on the Lightbits cluster management node at:

```
/etc/lbcli/lbcli.yaml
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

#### Where the token is stored

Since 1.0.2, `lb_jwt` is a Proxmox **sensitive property**. Proxmox does not write it to `/etc/pve/storage.cfg` (mode `0640`, readable by the `www-data` group that runs the web interface) and does not return it from the storage API (`pvesh get /storage/<storeid>`). The plugin keeps it in `/etc/pve/priv/storage/<storeid>.pw`, root-only `0600`, which the Proxmox cluster file system replicates to every node; Proxmox's own Backup Server and ESXi storages keep their secrets in the same place. You set and rotate it exactly as before:

```bash
pvesm set lb-storage --lb_jwt '<new-jwt-token>'
```

Removing the storage (`pvesm remove`) deletes the file. Upgrading from 1.0.1 or earlier needs care, see [Upgrading to 1.0.2](#upgrading-to-102-breaking-change).

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
- Restarts every Proxmox daemon that loads storage plugins (`pvedaemon`, `pvestatd`, `pvescheduler`, `pveproxy`, and `pve-ha-lrm`/`pve-ha-crm` where they run), so all of them use the new version. Running VMs are not affected; restarting the HA services does not stop or move HA-managed VMs

Run `./scripts/install.sh --help` for the full description, requirements, and exit codes. Re-running the installer is safe and is how you upgrade to a newer plugin version.

#### Upgrading to 1.0.2 (breaking change)

1.0.2 moves the API token (`lb_jwt`) out of `/etc/pve/storage.cfg` into a root-only file (see [Where the token is stored](#where-the-token-is-stored)). The file is shared by the whole Proxmox cluster, but **1.0.1 and earlier only look in `storage.cfg`**. Once a storage's token has moved, a node still on 1.0.1 or earlier **no longer has that storage at all**: those versions require `lb_jwt` in the storage's section, so it skips the section (`pvesm status` logs `skip section '<storeid>': missing value for required option 'lb_jwt'` and the storage does not exist on that node). VM starts, migrations to that node and HA restarts on it fail for every VM with a disk on the storage; VMs already running there keep their I/O. The same happens if you downgrade a node to 1.0.1 or earlier after the move.

The move happens on the first `pvesm set` (any option, from any node, or an edit in the web interface) after the node that runs it is on 1.0.2. Until then the existing inline token keeps working on old and new versions alike, so the upgrade itself is safe as long as you follow this order:

1. **Upgrade every node of the cluster first** (`git pull` + `./scripts/install.sh` on each node), with no `pvesm set` on a Lightbits storage in between. Check every node:

   ```bash
   perl -MPVE::Storage::Custom::LightbitsPlugin -e 'print PVE::Storage::Custom::LightbitsPlugin->plugindata->{"sensitive-properties"}{lb_jwt} ? "1.0.2 or later\n" : "OLDER - upgrade this node\n"'
   ```

2. **Then move the token**, once per Lightbits storage, from any node:

   ```bash
   pvesm set <storeid> --lb_jwt '<token>'               # or any other pvesm set on the storage
   awk -v s=<storeid> '$0=="lightbits: " s {f=1; next} /^[a-z]+: /{f=0} f && $1=="lb_jwt"' /etc/pve/storage.cfg   # expect no output
   ls -l /etc/pve/priv/storage/<storeid>.pw                                  # -rw------- root
   pvesm status --storage <storeid>                                          # active, on every node
   ```

3. **Rotate the token** on the Lightbits cluster afterwards if `storage.cfg` has been copied anywhere (configuration backups, support bundles): the old copies still contain it.

**Recovering a node that lost the storage after the move** (`skip section '<storeid>': missing value for required option 'lb_jwt'`): upgrade that node to 1.0.2 with `./scripts/install.sh`; it reads the token from the shared file at once, with no VM restart or further configuration needed. Earlier installers restarted only `pvedaemon` and `pvestatd`: on a node upgraded with one of them, `pve-ha-lrm` and `pvescheduler` still run the old module and HA restarts on that node fail with the same message: run `systemctl restart pvescheduler pve-ha-lrm pve-ha-crm` and `systemctl reload-or-restart pveproxy` on it.

**Rolling back to 1.0.1 after the move:** 1.0.1 and earlier need the token back in `storage.cfg`. Before downgrading any node, put it back inline for **every** Lightbits storage, from a node still on 1.0.2 (1.0.2 accepts an inline token, so this is safe while nodes are mixed), then downgrade the nodes:

```bash
TAB=$(printf '\t')
inline() { awk -v s="$1" '$0=="lightbits: " s {f=1; next} /^[a-z]+: /{f=0} f && $1=="lb_jwt" {print "yes"}' /etc/pve/storage.cfg; }
for ST in $(awk '/^lightbits: /{print $2}' /etc/pve/storage.cfg); do
    [ -n "$(inline "$ST")" ] && continue   # this storage's own section already has the token inline
    TOKEN=$(head -n1 /etc/pve/priv/storage/$ST.pw)
    RE=$(printf '%s' "$ST" | sed 's/[.]/\\./g')   # storage ids may contain '.', which a sed address treats as "any character"
    sed -i "/^lightbits: $RE\$/a\\${TAB}lb_jwt $TOKEN" /etc/pve/storage.cfg
done
grep -c "^${TAB}lb_jwt " /etc/pve/storage.cfg   # expect the number of Lightbits storages
```

Do not run `pvesm set` on these storages from a 1.0.2 node afterwards, or the tokens move again.

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
  --lb_api_host      192.168.10.10:443,192.168.10.11:443,192.168.10.12:443 \
  --lb_jwt           'eyJhbGci...' \
  --lb_nvme_host     192.168.10.10:4420,192.168.10.11:4420,192.168.10.12:4420 \
  --lb_project       default \
  --lb_replica_count 3 \
  --lb_owner_id      pve-cluster1 \
  --shared           1 \
  --content          images
```

**On a Proxmox VE cluster of two or more nodes, always add `--shared 1` and `--lb_owner_id`**, whatever the size of the Lightbits cluster. The storage definition in `/etc/pve/storage.cfg` is cluster-wide, so one `pvesm add` on any node covers every node.

- `--shared 1` tells Proxmox that every node sees the same volumes. Without it, Proxmox treats the storage as local to each node: live migration tries to copy the disks instead of handing the volume over, and HA cannot restart a VM on another node.
- `--lb_owner_id` is the owner name the plugin writes on every volume it creates (see [Volumes the plugin does not own](#volumes-the-plugin-does-not-own)). It defaults to the node's hostname, which makes a volume created on one node invisible to the others. Set it to one name for the whole PVE cluster, such as the cluster name, **before the first volume is created**. Changing it later hides the volumes created under the old name until their labels are updated.
- `--lb_replica_count 3` keeps three copies of each volume on a cluster of three or more nodes (see below).

On a single-node Lightbits cluster there's only one IP to give, so both endpoint options
collapse to one endpoint each (on a multi-node Proxmox VE cluster, still add `--shared 1` and `--lb_owner_id` as above):

```bash
pvesm add lightbits lb-storage \
  --lb_api_host  192.168.10.10:443 \
  --lb_jwt       'eyJhbGci...' \
  --lb_nvme_host 192.168.10.10:4420 \
  --lb_project   default \
  --content      images
```

`--lb_replica_count` sets how many copies of each volume the cluster keeps: `3` on a cluster of three or more nodes, `2` or `3` on a multi-node cluster in general. It defaults to `1`, and the value must be supported by the cluster — a single-node cluster only accepts `1`.

**Security note:** as added above, the storage entry does not verify the cluster's TLS certificate (verification is off by default in this release, see the next section). Pinning the cluster certificate is one more `pvesm set` line and is the recommended follow-up for any entry that carries a production JWT.

#### TLS verification for the API connection

The plugin talks to the LightOS cluster API over HTTPS. Certificate verification is **off by default**, because a LightOS cluster serves its API with a certificate issued by its own per-cluster CA, and enabling verification unconditionally would break existing storage entries.

Turn it on. Every API request carries the `lb_jwt` bearer token in an `Authorization` header, and with verification off an on-path attacker can present any certificate, terminate the connection, and capture a token that grants full control of the project's volumes.

**Recommended for a LightOS cluster: pin the certificate's fingerprint.** The cluster's API certificate is issued to the name `api.service` (no subject alternative names) by the cluster's internal CA, which the cluster does not hand out, so CA-based verification of an endpoint addressed by IP cannot succeed. Every node of a cluster presents the same certificate, so one fingerprint covers every `lb_api_host` entry. Read it from any API endpoint and pin it, the same way Proxmox's own Proxmox Backup Server storage does:

```bash
echo | openssl s_client -connect 10.10.10.1:443 2>/dev/null | openssl x509 -fingerprint -sha256 -noout
# SHA256 Fingerprint=DD:89:8D:65:...:FA:F9
pvesm set lb-storage --lb_fingerprint DD:89:8D:65:...:FA:F9
```

From then on a connection to any endpoint whose certificate does not match fails with `certificate verify failed` and the storage shows as inactive, with the error in `pvesm status` and the task log.

**Certificate rotation.** A pin identifies one exact certificate, so when the cluster's certificate is replaced (a certificate rotation, or a cluster re-install) the pin must follow. `lb_fingerprint` accepts a comma-separated list for exactly this: before the rotation, add the new certificate's fingerprint next to the current one; after the rotation, remove the old one. Do this on every Proxmox cluster that uses the storage.

```bash
pvesm set lb-storage --lb_fingerprint "<current>,<new>"     # before the rotation
pvesm set lb-storage --lb_fingerprint "<new>"               # after it
```

What a mismatched pin affects: only the control plane. The NVMe/TCP data path carries no TLS, so running guests keep their I/O whatever happens to the API certificate. Everything that needs the API stops until the pin is corrected: the storage shows inactive, no new volumes, snapshots or resizes, and no VM starts or HA restarts on that storage (activation reads the volume's namespace and ACL from the API). Treat the pin update as part of the rotation runbook, not as an afterthought.

**Alternatively, verify against a CA.** For a cluster fronted by a properly issued certificate (a load balancer or proxy), or addressed by a hostname that matches its certificate, enable regular peer and hostname verification against the host's trust store:

```bash
pvesm set lb-storage --lb_ssl_verify 1
```

If the signing CA is not in the Proxmox host's system trust store, point the plugin at it:

```bash
pvesm set lb-storage --lb_ssl_verify 1 --lb_ca_file /etc/pve/lightbits-ca.pem
```

`lb_ca_file` is only consulted when verification is enabled, and an unreadable path fails the API call loudly rather than silently falling back to an unverified connection. `lb_fingerprint` and `lb_ssl_verify` can be combined: a matching fingerprint is accepted outright, anything else must pass the CA and hostname check.

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

Run `./scripts/uninstall.sh --help` for the full description, including what the
uninstaller deliberately leaves in place (your Lightbits volumes and snapshots,
the `nvme-cli`/`discovery-client` packages, and any live NVMe-oF connections).

The uninstaller then removes, in order:
- Every `discovery-client` config file this plugin wrote
  (`/etc/discovery-client/discovery.d/lightbits-*.conf`) — this runs
  unconditionally once no `lightbits` storage remains, regardless of whether
  you removed the storage entries yourself or used `--force`, so nothing is
  left seeded for a storage that no longer exists.
- The plugin file itself
  (`/usr/share/perl5/PVE/Storage/Custom/LightbitsPlugin.pm`).

It then restarts the same Proxmox daemons as the installer.

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
  --scsihw virtio-scsi-single \
  --scsi0  lb-storage:4 \
  --ostype l26
```

**Recommended: use VirtIO SCSI as the SCSI controller** for VMs with disks on Lightbits storage: `--scsihw virtio-scsi-single` (*VirtIO SCSI single* in the GUI's *Hardware → SCSI Controller*). The GUI's VM wizard selects it by default, but a VM created with `qm create` or the API without `--scsihw` gets Proxmox's default emulated `lsi` controller. To switch an existing VM, run `qm set <vmid> --scsihw virtio-scsi-single`; the change takes effect at the next VM start.

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

If it is missing, re-run `scripts/install.sh` (it restarts the Proxmox daemons that load the plugin).

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

**Cold node (first VM start after the last Lightbits volume on this node was deactivated):** the plugin disconnects the subsystem on the last deactivation and discovery-client did not reliably act on the re-created config file afterwards. Since the version carrying this note, `activate_volume` restarts discovery-client itself when no connection appears within 10 s and logs `discovery-client has not connected … restarting discovery-client` in the task; a start that still fails after that points at a real connectivity or ACL problem. Keeping one always-on VM with a Lightbits disk per node (a "keeper") is no longer required to avoid this, but still avoids the ~10 s restart delay on the first start.

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

### `Lightbits API ... succeeded via ... after failing via ...`

```
Lightbits API GET /api/v2/... succeeded via 192.168.10.11:443 after failing via 192.168.10.10:443 (500 Can't connect to 192.168.10.10:443 (Connection refused)); check those lb_api_host endpoints
```

The operation worked, but at least one endpoint in `lb_api_host` did not answer and the plugin failed over to the next one. Inside a task (VM start, migration, clone, resize) it is always written to that task's log. Background calls, mainly `pvestatd`'s status polling, write it to their journal (`journalctl -u pvestatd -u pvedaemon | grep 'after failing via'`, usually the first place it appears) at most once per endpoint every 10 minutes while it stays down (`pvestatd` polls every few seconds, so without that limit one dead node would flood the journal; the state is a small stamp file per endpoint under `/run/pve-lightbits/`, cleared when that endpoint answers again or on reboot). The storage keeps working as long as one endpoint answers, so treat it as an early warning: check the named node's management API (`curl -k https://<endpoint>/api/v2/cluster` from the Proxmox node, the node's api-service, the network path), or remove a decommissioned node from the list with `pvesm set <storeid> --lb_api_host ...`.

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

### `certificate verify failed` / storage inactive after enabling TLS verification

`pvesm status` prints `Lightbits API GET /api/v2/cluster failed via <host>: 500 Can't connect to <host>:443 (certificate verify failed)` and the storage is inactive. The entry has `lb_fingerprint` or `lb_ssl_verify` set and the certificate the cluster presents does not pass:

- **After a certificate rotation or a cluster re-install** with `lb_fingerprint` set: the pin still names the old certificate. Read the new fingerprint (`echo | openssl s_client -connect <host>:443 2>/dev/null | openssl x509 -fingerprint -sha256 -noout`) and update it with `pvesm set <storeid> --lb_fingerprint <new>`. Next time, stage the new fingerprint next to the old one before the rotation (see "TLS verification for the API connection").
- **`lb_ssl_verify 1` against a LightOS cluster addressed by IP:** this cannot pass; the cluster's certificate is issued to `api.service` by a CA the cluster does not hand out. Use `lb_fingerprint` instead.
- Running guests are not affected (the NVMe/TCP data path carries no TLS); VM starts and HA restarts on the storage are blocked until the entry verifies again. To get going immediately, clear the options (`pvesm set <storeid> --delete lb_fingerprint,lb_ssl_verify`) and re-pin afterwards.

### `Plugin "PVE::Storage::Custom::LightbitsPlugin" is implementing an older storage API, an upgrade is recommended`

Logged by every `pvesm` call and GUI storage view after a Proxmox update raised the storage plugin API version (`APIVER` in `/usr/share/perl5/PVE/Storage.pm`) above the highest version this plugin release has been validated against. The plugin still loads and works; the message is PVE asking for a plugin release that declares the new version. Check the two numbers:

```bash
perl -MPVE::Storage -e 'print PVE::Storage::APIVER(), " ", PVE::Storage::Custom::LightbitsPlugin->api(), "\n"'
```

If the first is higher, install the latest plugin release (each release tracks the current `libpve-storage-perl`; see the changelog for the API version it validates), then restart `pvedaemon`, `pveproxy` and `pvestatd` so the GUI picks it up. `t/e2e/plugin_load.sh` checks all of this on a node, and CI runs `t/ci/storage_api_drift.sh` weekly against the Proxmox package index so a bump is caught before users see it.

---

### Storage shows 0 capacity / not active

The REST API call to `/api/v2/cluster` failed silently. Check Proxmox logs:

```bash
journalctl -u pvestatd -n 50 --no-pager
```

Also verify the API endpoint is correct (it must include the port):

```bash
pvesm config lb-storage | grep lb_api_host
```

If the journal shows `GET /api/v2/cluster failed ... 403`, the JWT is scoped to a project. The plugin reads the cluster's capacity and subsystem NQN from `/api/v2/cluster`, which needs a cluster-level token, so the storage shows inactive with a project-scoped token. Use a cluster-admin token (`/etc/lbcli/lbcli.yaml` on the management node).

---

## How It Works (Technical Detail)

### Volume lifecycle

1. **`alloc_image`** - Called when Proxmox allocates a new disk.
   - Reads the host NQN from `/etc/nvme/hostnqn`.
   - POSTs to `/api/v2/volumes` with the volume name (`vm-<vmid>-<vmgenid>-disk-<n>`), size (bytes, 4096-aligned), replica count, project, and the host NQN in the ACL so only this host can access it.
   - Polls until the volume reaches `Available` state.
   - Returns the volid `lb-storage:vm-<vmid>-<uuid>` (the embedded vmid lets Proxmox identify the owning guest), which is stored in the VM config.
   - **Cloud-init drive:** qemu-server recognises a VM's cloud-init drive only by the volume name `vm-<vmid>-cloudinit` and asks the storage for exactly that name, so for this one volume the plugin honours it: the volid is `lb-storage:vm-<vmid>-cloudinit`, the LightOS volume is named `vm-<vmid>-<vmgenid>-cloudinit` and carries an extra `pveRole=cloudinit` label, through which the plugin finds its UUID again (a VM has at most one). Proxmox writes the generated cloud-init ISO straight into the Lightbits volume, so `qm clone --full --storage lb-storage`, `qmrestore --storage lb-storage` and HA failover all work with the cloud-init drive on Lightbits.

2. **`activate_volume`** - Called when a VM starts.
   - GETs the volume to retrieve its NVMe namespace ID (NSID).
   - Writes (or rewrites) `/etc/discovery-client/discovery.d/lightbits-<storeid>.conf` (one `-t tcp -a <host> -s 8009 -q <hostnqn> -n <subsys_nqn>` line per `lb_nvme_host` entry) whenever this volume isn't already active on this host — not only when no connection exists yet — `discovery-client` (not the plugin) then performs the actual `nvme connect` against every data node.
   - Scans `/sys/block/` to find the block device with matching NSID (the kernel names namespaces sequentially regardless of the NSID value).
   - Creates a stable symlink at `/dev/lightbits/<storeid>/<uuid>` → `/dev/nvmeXnY` (`/dev/lightbits/<storeid>/vm-<vmid>-cloudinit` for a cloud-init drive).

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

- **Snapshots are not readable as a block device**: snapshots are native Lightbits snapshots (create, roll back, delete). A snapshot cannot be attached or read on its own, so operations that read a snapshot directly, such as backing up or cloning a VM *from* a snapshot, are not supported; roll back to it, or back up or clone the VM from its current state.
- **No linked clones from templates**: a VM can be converted to a template, but its disks stay ordinary Lightbits volumes, so clones of it are full clones (`qm clone <template> <newid> --full`, or *Full Clone* mode in the GUI), each an independent copy of the template's disks. Linked clones, which share the template's base volume, are not supported.
- **TLS verification off by default**: the API connection does not verify the cluster's certificate unless `lb_fingerprint` or `lb_ssl_verify` is set (see "TLS verification for the API connection"), because a LightOS cluster presents a certificate from its own cluster CA. Pinning the fingerprint is a one-line change per storage.
- **Cluster-level JWT required**: a token scoped to a single project cannot read `/api/v2/cluster`, so the storage shows inactive (see [Storage shows 0 capacity / not active](#storage-shows-0-capacity--not-active)).
- **Bursts of allocations can hit the storage lock timeout**: Proxmox serializes volume allocation per storage behind a cluster-wide lock. Creating many disks at once (for example an infrastructure-as-code run creating dozens of VMs in parallel) can fail some of them with `got lock timeout`; retry those or limit the parallelism.
- **Internet access used for the automatic `discovery-client` install**: `scripts/install.sh` fetches `discovery-client` from Lightbits' hosted package repository. Without internet access the installer warns and continues; install and start the `discovery-client` package manually before using the storage. A fully offline installation path is on the Roadmap below.

---

## Roadmap

### 1.0 (current)

- Single Lightbits cluster per storage entry
- Full volume lifecycle for VM disks: create, attach, detach, delete
- Volume resize (grow), online and offline
- Volume snapshots and rollback (native server-side rollback)
- Live migration and HA failover across the nodes of a Proxmox VE cluster
- API failover across management nodes, TLS certificate pinning
- Cloud-init drives on Lightbits storage
- Per-VM ownership labels and node-aware filtering (multi-hypervisor safety)
- NVMe-oF TCP transport
- Storage capacity reporting

### Beyond 1.0

On the horizon:

- Volume clones (including file-level recovery from a snapshot)
- Linked clones from VM templates
- Multi-tenancy and multi-cluster support
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
| Proxmox VE | 9.x (tested on 9.2, `libpve-storage-perl` up to 9.1.13, storage API 16) |
| Lightbits LightOS | 3.x (tested on 3.18.4, 3.20.1 and 3.21.1) |
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
