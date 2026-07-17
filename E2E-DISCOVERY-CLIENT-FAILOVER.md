# Live e2e results — `feat/discovery-client-failover`

**Date:** 2026-07-17
**Lab:** `rack13-server79` (AlmaLinux 9.7 KVM host) → nested libvirt VM `pmx9-rack79`
(PVE 9.2.4, root/light), storage backed by `lb-cluster-redhotchilli` — a **5-node**
LightOS v3.19.2 cluster (`10.17.186.4/13/19/23/20`, mgmt `192.168.16.156/200/215`,
`192.168.21.148`, `192.168.24.164`). This is internal test documentation, not
user-facing — do not move or link this into `docs/`.

Covers the deployment + destructive/failure-injection e2e for this branch's two
main changes — delegating NVMe-oF connect to discovery-client, and REST API
failover — before opening its PR.

---

## 1. Deployment findings

### 1.1 `scripts/install.sh`'s discovery-client repo config was broken for Debian/Proxmox — REGRESSION FOUND AND FIXED SAME SESSION
Initial deployment hit a real bug: `install.sh` hardcoded `distro=debian`
(falling back to `bookworm` if `VERSION_CODENAME` is unset) when building the
discovery-client apt repo URL. Live result at the time: the `debian`-flavored
repo path at `dl.lightbitslabs.com/public/discovery-client/deb/debian/...`
**existed but was genuinely empty** (0-byte `Packages`/`Packages.gz` for both
`bookworm` and `bullseye`) — `apt-get update` succeeded, `apt-get install
discovery-client` failed with `Unable to locate package`, and that failure was
silently swallowed by the install script's `|| echo WARNING ...` wrapper.

The package **is** published, but only under `distro=ubuntu` (any codename —
`xenial` through `noble` all resolve to the same `.el8`-origin alien-converted
`.deb`, confirmed via direct `Packages` file fetch). Since Proxmox VE *is* a
Debian derivative, this needed `scripts/install.sh` to request the `ubuntu`
repo path even on native Debian/PVE hosts.

**Fixed same session** — `install.sh` now uses `distro=ubuntu`,
`codename=jammy` (any published codename works; the artifact is identical).
**Re-validated live** immediately after the fix: `apt-get install
discovery-client` succeeded, the service started cleanly, and every
subsequent test in this document (§2 onward) ran against that corrected
install.

### 1.2 Deployment otherwise clean
- `LightbitsPlugin.pm` from this branch: `perl -c` OK on the target host.
- `pvesm set lb-storage --lb_api_host <5 endpoints>` succeeded with no error —
  confirms dropping `fixed` on `lb_api_host`/`lb_nvme_host` actually works live,
  not just passes a unit test.
- discovery-client (once installed via the `ubuntu` repo workaround above)
  started cleanly, auto-created `/etc/discovery-client/{discovery.d,internal}/`.

---

## 2. Functional lifecycle (RF=3 volume)

Created VM 201 with a 5G→7G `lb-storage` disk, `lb_replica_count 3` (cluster-wide
default on this storage). All steps below ran against a **live 5-node cluster**,
not a mock:

| Step | Result |
|---|---|
| `qm start` (activate) | `discovery-client` conf written (`/etc/discovery-client/discovery.d/lightbits-lb-storage.conf`, one line per `lb_nvme_host` entry); discovery-client connected **all 5** configured data nodes; native multipath head device + `/dev/lightbits/lb-storage/<uuid>` symlink came up correctly. |
| `qm resize +2G` | Worked. |
| `qm snapshot` / `qm rollback` | Worked. Note: `qm rollback` on a *running* VM's snapshot stops the VM first (Proxmox's own semantics, not plugin-specific) — the symlink disappears and reappears across that stop/start, which is expected. |
| `qm destroy --purge` (free) | Volume + its snapshots deleted cluster-side (confirmed via `GET /api/v2/volumes` — no orphan; `GET /api/v2/snapshots` → 404/empty). `discovery-client` conf file correctly **left in place** and subsystem correctly **not disconnected**, because another storage volume (VM 100's boot disk) still shares the subsystem — the "don't disrupt other VMs" gate held under a real second consumer, not just the unit-test mock. |

---

## 3. `lb_api_host` REST failover

With the multi-endpoint `lb_api_host` live, blocked endpoints via `iptables -j DROP`
on the PVE host (simulates a silently-dead/partitioned node, worse-case than a
service that actively refuses):

- **2 of 5 blocked:** `pvesm status` still succeeded every time (round-robin
  skipped the dead ones), but runs that randomly started on a blocked endpoint
  cost **~5.7s extra** before falling through to a live one. This is a real
  latency tax proportional to how many configured endpoints are down — worth a
  callout in ops docs (frequent `pvestatd` polling could stack real delay if
  several management nodes are down at once), though it never hung.
- **All 5 blocked:** failed cleanly in ~26s (not a multi-minute hang), storage
  correctly reported `inactive` with a clear (if slightly incomplete — see below)
  error.
- **Minor observability gap:** `_api`'s die message only names the *last*
  endpoint tried, not a summary of all N failed attempts. An operator seeing
  `"...failed via 192.168.16.200:443..."` might reasonably (and wrongly) think
  only that one node is implicated, when actually every configured endpoint was
  down. Consider logging/including all attempted endpoints in the final error.

---

## 4. Node-failure / discovery-client behavior — the main event

### 4.1 Does `node-manager` down take out the data path too, or just control plane?
**Both, but not identically.** Stopping `node-manager` on a live node
(`systemctl stop node-manager`, ~30s graceful shutdown) took `duroslight`
(the actual NVMe-oF target / I/O engine) down with it — its systemd unit
disappeared entirely and port **4420 stopped listening**, confirmed both
server-side (`ss -tlnp` no longer shows 4420) and from the PVE host's own kernel
(`dmesg`: `failed to connect socket: -111`, repeating `Reconnecting in 10
seconds...`). **`api-service` (REST, port 443) stayed up and kept answering**
throughout — so a `node-manager`-down node is a **full data-path outage but only
a partial control-plane outage** (this specific cluster's REST layer is
apparently decoupled enough from `node-manager` to survive it). Only port 8009
(discovery) and 443 (API) remained reachable on the downed node.

### 4.2 Does a replica move to a different node automatically, and does discovery-client pick it up?
**Could not be fully exercised — and the premise doesn't hold the way we
expected.** `lbcli replace node` (the only mechanism found for relocating a
replica) requires the *target* node to be in `Unattached` state; all 5 nodes in
this cluster are `Active` (already members). With one node down and no spare
capacity standing by, the volume simply sat at `protectionState: Degraded`
indefinitely (10+ minutes polled, no automatic movement) rather than
self-healing onto another existing node. **LightOS does not appear to
auto-rebuild a replica onto other already-active cluster members just because
one node is down** — recovery requires either (a) the original node coming
back, or (b) an operator explicitly attaching a genuinely spare/unattached node
and running `lbcli replace node --src-node-uuid=<dead> --target-node-uuid=<spare>`.
This cluster had no spare, so the "does discovery-client auto-discover a
rebuilt replica's new, previously-unlisted node" question is **still open** —
it needs a 6th (spare) node to test properly. Recommend flagging this as a
follow-up requiring one extra physical/VM node in the lab.

### 4.3 What actually recovers automatically (confirmed)
Bringing the *same* node back (`systemctl start node-manager`) self-healed
completely with **zero manual intervention on the Proxmox side**:
node `Inactive → Activating → Active` in ~40s, volume
`Degraded → FullyProtected` in the same window, and the PVE host's kernel NVMe
controller for that node went from `connecting` back to `live` on its own
(the existing `--reconnect-delay=10 --ctrl-loss-tmo=-1`-equivalent behavior
`discovery-client` configures held up). No `nvme connect`, no plugin call, no
discovery-client restart needed.

### 4.4 Two-node failure (below `MIN_REPLICAS_COUNT=2`)
Killed 2 of the volume's 3 replica nodes simultaneously (only 1/3 replicas
survived). Result: `protectionState: ReadOnly`. Confirmed at the block-device
level, not just the API field — `dd` **reads** from the surviving path still
worked, but a **write's `fsync` failed with I/O error**. This is the correct,
safe behavior (no silent data-loss risk when durability can't be guaranteed) and
the kernel/multipath layer surfaced it as a real I/O error rather than hanging
or silently succeeding. Restoring both nodes fully healed the volume back to
`FullyProtected` the same way as the single-node case.

### 4.5 `lb_nvme_host` shrink via `pvesm set` (the "stale IP" question)
Shrank `lb_nvme_host` from 5 to 4 entries (dropped one node not hosting this
volume's replicas), then deactivated+reactivated the volume:
- The discovery-client conf file was correctly **rewritten with only 4 lines**
  on the next activation (`pvesm set` + reactivate is a working, if manual,
  path to update the seed list).
- The kernel NVMe controller to the **removed** node **stayed `live`** —
  shrinking the list does not proactively disconnect a node no longer listed.
  This matches the documented `discovery-client` caveat (stale, not
  torn-down, connections for removed endpoints) and confirms the plugin's
  explicit `nvme disconnect` on last-deactivate remains the only thing that
  will ever clean that up.
- Restored the full 5-entry list afterward; confirmed it reconnects/relists
  correctly.

### 4.6 discovery-client crash resilience
`kill -9` on the running `discovery-client` process: systemd's
`Restart=on-failure` brought it back within ~2s (own unit file, not something
this plugin controls). All existing kernel NVMe connections were completely
unaffected by the crash — they're independent of the daemon's process lifetime,
only *new* seed-file changes would have been missed while it was down.

---

## 5. Cleanup performed
- VM 201 destroyed, volume + snapshot confirmed gone cluster-side (no orphans).
- Both intentionally-stopped LightOS nodes restarted and confirmed back to
  `Active` / cluster `FullyProtected`.
- All `iptables` rules added during the API-failover test flushed.
- `lb_nvme_host` restored to the full 5-node list; `lb_api_host` left as the
  5-endpoint multi-node list (the intended new capability, not reverted).
- VM 100 (pre-existing) was never stopped or modified.

---

## 6. Open items for follow-up
1. ~~Fix `scripts/install.sh`'s discovery-client repo distro/codename~~ — fixed
   same session, see §1.1.
2. **Six-node (1 spare) lab test** needed to properly answer "does
   discovery-client auto-pick-up a replica rebuilt onto a previously-unlisted
   node" (§4.2) — the actual trigger for that (`lbcli replace node`) couldn't
   be exercised with only 5 nodes and none spare.
3. Consider **logging all attempted endpoints**, not just the last, in
   `_api`'s failure message (§3).
4. ACL-on-activate and TLS verification hardening remain unimplemented and
   were not in scope for this branch's e2e — untouched by this pass.

## 7. Post-review fixes (CodeRabbit, PR #19)
Two correctness issues raised on the PR were fixed after this e2e round, covered
by new/extended unit tests, and (the per-storeid one) re-validated live:
- **`_api` no longer retries a non-idempotent mutation (POST) across
  endpoints on a 5xx** — only GET/HEAD are retried now. A 5xx can arrive after
  a POST (`alloc_image`, snapshot create) already committed server-side (e.g.
  a proxy timeout past a successful backend write); retrying it against a
  different endpoint risked an orphaned/duplicate resource. Covered by a new
  `t/api_failover.t` case; not re-exercised live (fabricating a genuine
  "committed-then-5xx" condition safely against the real cluster isn't
  practical — the unit-level mock is the appropriate level for this one).
- **`deactivate_volume` now removes a storage's own `discovery-client` conf
  file as soon as none of *that* storage's volumes are active**, instead of
  waiting on the global (all-storages) `_nqn_still_in_use` check — the global
  check remains, but only gates the actual subsystem-wide `nvme disconnect`.
  Previously, storage A's conf file lingered indefinitely as long as any
  other storage sharing the same cluster/subsystem (e.g. storage B) still had
  an active volume. **Re-validated live** on `pmx9-rack79`: with `lb-storage`
  (VM100) and a second temporary storage both active on the same subsystem,
  deactivating the temporary storage's only volume now removes its conf file
  immediately, while `lb-storage`'s connection and VM100 stay untouched.
