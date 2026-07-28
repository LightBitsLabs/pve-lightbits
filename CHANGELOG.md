# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `scripts/install.sh` and `scripts/uninstall.sh` accept `-h` / `--help` and print full usage: what the script does step by step, its options, requirements, exit codes, and — for the uninstaller — what it deliberately leaves in place (your Lightbits volumes and snapshots, the `nvme-cli`/`discovery-client` packages, and live NVMe-oF connections). Arguments are parsed before the root check, so `--help` works as an unprivileged user.
- CI asserts that both scripts print usage for `-h`/`--help` and reject an unknown option with exit status 2 without writing to stdout.

### Changed

- Both scripts now reject unrecognised arguments with an error and exit status 2 instead of ignoring them. Previously `install.sh` ignored every argument, and `uninstall.sh` only looked for an exact `--force`, so a typo such as `--forse` was silently discarded and the script carried on in non-forcing mode while the operator believed otherwise.

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
