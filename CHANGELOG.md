# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.5] - 2026-10-05 - Tech Preview

Tech Preview release. Three control-plane fixes found by a two-day reliability validation on a 2-node Proxmox VE 9.2.21 cluster against a 3-node LightOS 3.20.1 cluster (live migration, HA fencing, node power-cut, data-leg partition, LightOS node stop and rolling restart, 5 h of lifecycle churn): a node whose last Lightbits volume was deactivated can start its next VM again without operator help, parallel full clones from one template no longer race on the shared source volume, and mutating REST calls fail over to another `lb_api_host` endpoint when a LightOS API node is down. The data path recorded zero `fio --verify` errors through every fault, before and after the fixes. Still ahead of production readiness.

### Fixed

- **First VM start on a "cold" node no longer fails.** When the last Lightbits volume on a node is deactivated the plugin disconnects the NVMe subsystem and removes its discovery-client config; on the next activation it rewrites the config and waits for discovery-client to connect — which, after such a full teardown, discovery-client did not do (LightOS 3.20.1 `discovery-client 3.20.1b29846522522-1`, validated 2026-10-04: no reconnect for 9+ minutes, every `qm start` failing with `Block device for volume … did not appear` after the 60 s wait, while a `systemctl restart discovery-client` made the next start succeed at once). `activate_volume` now restarts discovery-client if no connection appears within 10 s of writing the config (`$DSC_NUDGE_AFTER`), once, and keeps waiting up to 45 s in total (`$DSC_CONNECT_WAIT`), logging why. The restart is harmless for running guests: NVMe connections are owned by the kernel and survive even `kill -9` of the daemon. Affects the first VM start after maintenance, an HA evacuation or a reboot without `onboot` guests — anywhere a keeper VM is not kept running.
- **Concurrent activations of the same volume no longer fail with `Cannot create symlink …: File exists`.** Parallel full clones from one template activate the shared source volume at the same time; `activate_volume` checked "symlink already current", unlinked, then called `symlink()` with no tolerance for a racing creator, so the loser died although the link now pointed at the right namespace (1 of 3 parallel clones failed live on 2026-10-04). An `EEXIST` whose link resolves to the correct namespace is now success; a link to a different device is still an error.
- **REST calls now fail over to the next `lb_api_host` endpoint when the connection could not be established, for every method, mutations included.** `_api` chose a random start endpoint and let POST/PUT/DELETE die on the first failure of any kind, including LWP's synthetic "Internal response" for *connection refused / timeout / TLS error* — a failure that never reached the cluster and is therefore safe to retry elsewhere. Only connect-level failures (`Can't connect to …`, TLS handshake) qualify for mutating calls; a read timeout or a reset after the request was written may already have taken effect and stays single-shot, as does any real 5xx. Reproduced live on 2026-10-04 during a single-node LightOS API outage on a 3-node cluster: with two of six configured endpoints on the dead node, about a third of all snapshot, rollback and snapshot-delete calls failed with `500 Can't connect to <host>:443 (Connection refused)`, each one leaving its VM locked (`lock=snapshot-delete` / `lock=rollback`) until an operator ran `qm unlock`. The rule that a *genuine* 5xx from the cluster is not retried for mutating calls (it may arrive after the mutation took effect) is unchanged.

### Added

- `t/activate_volume_cold_node.t`, `t/activate_volume_race.t` and the extended `t/api_failover.t` (unit): no nudge while discovery-client connects on its own, exactly one nudge then success, unchanged failure when nothing helps; a racing creator of the correct symlink is tolerated and a wrong one is not; connect-level failures fail over for every method while read timeouts, resets and genuine 5xx stay single-shot for mutations.

## [0.9.4] - 2026-10-04 - Tech Preview

Tech Preview release. Makes the plugin safe to point at a LightOS project that already holds other consumers' volumes: everything the plugin lists, sizes, activates, resizes, snapshots or deletes must carry its own ownership labels, so a shared project can no longer lose a foreign volume to a `pvesm free` or have its ACL rewritten by an attach. Validated end-to-end on a 2-node Proxmox VE 9.2.21 cluster against a pre-populated 3-node LightOS 3.20.1 cluster, including the upstream Storage Plugin Test Suite (20 validated, 0 failed), but still ahead of production readiness.

### Fixed

- **The plugin no longer lists, activates or deletes volumes it did not create.** `list_images` treated every volume in the project *without* a `pveNode` label as this node's, so on a LightOS project that is shared with other consumers — volumes created with `lbcli`, by an application server, or by another hypervisor — every foreign volume showed up in `pvesm list` and in the storage's *VM Disks* view as an unowned (`vm-0-<uuid>`) "unused disk". From there a single `pvesm free` (or the UI's *Remove*) deleted the foreign volume together with its snapshots, because `free_image` had no ownership check; and attaching a foreign volid to a VM made `activate_volume` rewrite the foreign volume's ACL to add this host's NQN, which was never reverted. Both were reproduced live on a pre-populated 3-node LightOS 3.20.1 cluster (2026-10-04). Ownership is now decided in one place (`_is_owned_volume`) and is **strictly label-based**: a volume is this storage's only when it carries the plugin's `pveVmid` and `pveNode` labels with `pveNode` equal to the storage's owner id. Everything else — no labels, a `pveNode` label alone, a different `pveNode` — is invisible to `list_images`, and every path that takes a volid (`volume_size_info`, `activate_volume`, `free_image`, `volume_resize`, `volume_snapshot`, `volume_snapshot_delete`, `volume_snapshot_rollback`) refuses it before any mutating API call — `volume_size_info` included, so a foreign volid cannot even be written into a stopped VM's config with `qm set` — with an error naming the volume, the project and the storage's owner id (recorded as a failed task in PVE). A volume that no longer exists is still an idempotent no-op for `free_image`. Volumes PVE created itself and the existing per-node isolation (`lb_owner_id`) are unaffected.
- `alloc_image` now deletes a volume that was created on the cluster but never became usable, instead of leaving it stranded. Proxmox only starts tracking a volume once `alloc_image` returns a volid, so when the volume entered a terminal `Failed` state or never reached `Available`, the function raised an error and left an orphan behind that nothing would ever reap — holding its name (LightOS enforces per-project name uniqueness, so a retry for the same VM collided on the same disk index) and, depending on the failure, its space. Cleanup is best-effort: a cleanup that itself fails warns and names the volume for manual removal rather than masking the original creation error.
- `LICENSE` is now the verbatim Apache License 2.0 text from apache.org. The previous file was headed "Apache License, Version 2.0" but its wording had drifted from the official text in a number of clauses (among them the definitions of "Contribution" and "Contributor", the redistribution terms in section 4, and sections 8 and 9), and it carried a copyright line above the license body. The official text has no per-project edits, so GitHub could not identify the license and showed it as "Other". The copyright notice stays in `NOTICE` and in the `SPDX-License-Identifier: Apache-2.0` header of every source file; the license terms of the project are unchanged.

### Changed

- **No more name-based ownership.** Earlier versions also treated an *unlabelled* volume as this node's when its name started with `vm-<vmid>-`. That fallback is gone: every release of this plugin has written the ownership labels on `alloc_image`, so the only volumes affected are ones that were created by hand to look like plugin volumes or that had their labels replaced out of band. Such a volume can be re-adopted with `lbcli update volume --labels pveVmid=<vmid>,pveNode=<owner-id>` (see README, "Volumes the plugin does not own").

### Added

- `t/foreign_volume_guard.t` (unit) and `t/e2e/foreign_volumes.sh` (live, on a real node): a volume created outside the plugin in the storage's project is never listed, `pvesm free` and attaching it by volid are refused with the volume and its ACL byte-identical afterwards, and plugin-created volumes on the same storage keep working. Variants cover an unlabelled volume, a decoy carrying only a `pveNode` label, another PVE cluster's volume and an `ALLOW_ANY` volume.

## [0.9.2] - 2026-07-28 - Tech Preview

Tech Preview release. Three reliability fixes for volumes shared between hosts or managed outside Proxmox, plus a live end-to-end regression suite covering each of them.

### Fixed

- `activate_volume` now grants the activating host's NQN on the volume's ACL, additively and idempotently. `alloc_image` only ACLs the creating host, so a volume activated on a *different* host — offline migration, HA failover, or `shared=1` multi-node access — never saw its namespace appear and activation timed out with no hint that the cause was ACL rather than connectivity. Existing ACL entries are preserved (concurrent hosts each keep access) and no API call is made when the host is already present (the common case). Validated live: a volume whose ACL was stripped to a foreign NQN activates correctly, with the ACL extended, not replaced.
- A volume or snapshot deleted outside Proxmox is now reported as gone instead of being read as an empty resource. `_api` maps a 404 to an empty hash so idempotent deletes can treat "already gone" as success, but callers that read fields out of the result saw an empty hash as "present, just not converged yet". A volume deleted out of band mid-operation therefore made `alloc_image`, `volume_resize`, `volume_snapshot`, and `volume_snapshot_rollback` poll out their full 30-60 iteration timeout and then blame a cluster convergence problem; `volume_rollback_is_possible` compared two zero sizes and allowed a rollback that could not work; and `volume_size_info` reported the disk as 0 bytes. These paths now fail immediately with an error naming the missing resource. The idempotent delete paths (`free_image`, `_delete_snapshot`) are unchanged.
- `activate_volume` now re-validates an existing `/dev/lightbits/<storeid>/<uuid>` symlink against the volume's subsystem NQN and NSID instead of trusting any block device found at that path. NVMe controller numbering is not stable across a disconnect/reconnect or path flap, so a symlink left by an earlier activation could dangle — making every later activation fail with `Cannot create symlink ...: File exists` until it was removed by hand — or, worse, resolve to a namespace that now belongs to a different volume, in which case activation reported success and handed QEMU the wrong disk. A symlink that no longer matches is replaced.

### Added

- Live end-to-end regression suites under `t/e2e/`, run against a real Proxmox node with a configured Lightbits storage: `project_isolation.sh` (operations in one LightOS project can never touch volumes in another, in either direction), `stale_symlink.sh` (dangling and wrong-volume symlinks are repaired on activation, validated against `/sys` nsid and subsystem NQN), and `vanished_resource.sh` (out-of-band deletions fail accurately and immediately where read, while the idempotent delete paths keep treating "already gone" as success). All validated on a 3-node LightOS 3.20.1 cluster alongside the existing `snapshots.sh`.

## [0.9.1] - 2026-07-26 - Tech Preview

Tech Preview release. Feature-complete for the documented lifecycle (create, attach, resize, snapshot, rollback, detach, delete) and validated end-to-end on live multi-node clusters, but not yet recommended for production workloads.

### Fixed

- Operator-facing error strings are now plain ASCII. A Unicode em-dash in the REST API error message and in the `lb_nvme_host` property description was double-encoded by Proxmox's task-log layer, so the Proxmox GUI, `journalctl`, and task logs showed garbled bytes instead of the actual error text — hiding the real cause of a failure exactly when an operator needed it.
- `scripts/install.sh` no longer discards the output of the `discovery-client` install step, so a failed install reports its root cause instead of failing silently. The captured output goes to a `mktemp`-generated log file rather than a fixed, predictable path.
- Corrected a stale step counter in `scripts/install.sh` that still read `[1/3]` after the `discovery-client` step was added.

### Changed

- `scripts/install.sh` ends with an explicit per-component health check for `nvme-cli` and `discovery-client` (`OK` / `ACTION REQUIRED`) instead of unconditionally reporting "Installation complete."

### Documentation

- README: installation currently requires internet access to fetch `discovery-client` from Lightbits' hosted package repository. Air-gapped installation is on the roadmap.

## [0.9.0] - 2026-07-19 - Beta

Beta pre-release.

### Added

- REST API failover: `lb_api_host` accepts a comma-separated list of cluster management nodes; the plugin tries each one (random start, stateless per call) so the storage keeps working if any single node is down, mirroring the failover behavior of Lightbits' own Cinder driver.
- `lb_api_host`, `lb_jwt`, and `lb_nvme_host` can now be updated in place with `pvesm set` instead of requiring a hand-edit of `/etc/pve/storage.cfg`.

### Changed

- Multipath NVMe-oF: `lb_nvme_host`'s comma-separated `host:port` data endpoints now seed Lightbits' [`discovery-client`](https://github.com/LightBitsLabs/discovery-client) daemon (installed by `scripts/install.sh`) instead of the plugin connecting to each one directly. `discovery-client` connects every data node on volume activation, and because it (not the plugin) owns the connections, it also keeps itself in sync as cluster nodes are added later, with no config change needed on Proxmox hosts. On a multi-node (ANA) cluster this still ensures the volume's optimized path is always present and node failures transparently fail over to another replica, as before. Validated end-to-end on a 3-node cluster including a live node reboot.

## [0.8.0] - 2026-07-16

First tagged pre-release.

### Added

- Initial release of the Lightbits Storage Plugin for Proxmox VE 9.x.
- Installs into the official `PVE::Storage::Custom` third-party namespace, auto-loaded by Proxmox without patching PVE's own files.
- Dynamic storage API version negotiation: `api()` reports the running host's `APIVER` (clamped to the validated maximum), so the plugin loads cleanly without the "older storage API" warning across Proxmox VE 9.x point releases. Implements `get_identity()` (storage API 14).
- Full VM disk lifecycle via the Lightbits REST API: create, attach, detach, delete.
- Volume resize (grow), online and offline, via `qm resize` / the Proxmox UI: the Lightbits volume is grown and an `nvme ns-rescan` makes the new capacity visible to the host deterministically.
- Volume snapshots and rollback via `qm snapshot` / `qm rollback` and the Proxmox UI, backed by Lightbits snapshots. Snapshots are point-in-time and project-scoped; online snapshots of a running guest are crash-consistent (filesystem-consistent when the guest runs `qemu-guest-agent`). Rollback uses the cluster's native server-side rollback — near-instant, with no host-side data copy, and preserving the volume's thin-provisioned allocation. A rollback that would shrink a volume grown after the snapshot was taken is refused, keeping the device and the VM config size consistent. Freeing a volume also deletes its snapshots on a best-effort basis (a snapshot that cannot be deleted is logged but does not block freeing the volume).
- NVMe-oF TCP transport for block-device access (`nvme-tcp`).
- Multipath NVMe-oF: `lb_nvme_host` accepts a comma-separated list of `host:port` data endpoints and the plugin connects to all of them on volume activation. On a multi-node (ANA) cluster this ensures the volume's optimized path is always present (a single connection can land on a non-optimized path and never surface the device), and node failures transparently fail over to another replica. Validated end-to-end on a 3-node cluster including a live node reboot.
- Storage capacity reporting in the Proxmox dashboard.
- Configurable replica count per storage via `lb_replica_count` (default 1); the requested count must be supported by the cluster (a single-node cluster requires 1).
- Per-VM ownership labels (`pveVmid`, `pveVmgenid`, `pveNode`) and node-aware filtering so that destroying a VM never deletes another hypervisor's volumes in a shared Lightbits project.
- Auto-fetched subsystem NQN from the cluster API, with explicit override available via `--lb_subsys_nqn`.
- Stable per-volume symlinks under `/dev/lightbits/<storeid>/<uuid>`.
- `install.sh` / `uninstall.sh` scripts for each Proxmox node.
- CI workflow: Perl syntax check, taint-mode check, unit tests via `prove`, and `shellcheck` on installer scripts.

### Changed

- `alloc_image` now fails fast with a clear error if a new volume reports a terminal `Failed` state or never becomes `Available`, instead of returning a volid for an unusable volume (which previously surfaced later as a confusing "Cannot determine NSID" error at attach time).
- NVMe device discovery (`_find_nvme_device`) now resolves the multipath **head** namespace device (`/dev/nvme<C>n<N>`) instead of building a name from a path controller. Under native NVMe multipath (the kernel default) a namespace also appears as a per-path `nvme<C>c<P>n<N>` device with no `/dev` node; the previous logic could return that path-derived name and fail to find the device when more than one path exists. Volume attach is now multipath-safe.
- `deactivate_volume` disconnects the NVMe subsystem only when no volume of **any** storage on the host still uses it — determined from local symlinks rather than the REST API. This prevents a second storage entry that shares the same cluster/subsystem from losing its live volumes (the disconnect is subsystem-wide and drops every path), and stops a transient API error from triggering a destructive disconnect.
- Bumped the validated storage API maximum from 14 to 15 (`libpve-storage-perl` 9.1.6's additive bump for `volume_resize`'s optional `snapname` parameter and `volume_snapshot_info`'s `virtual-size` field) — clears a spurious "older storage API" load warning on current PVE 9.2.x hosts. No plugin behavior change; both new fields are optional and unused by this plugin.
