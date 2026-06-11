# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial release of the Lightbits Storage Plugin for Proxmox VE 9.x.
- Installs into the official `PVE::Storage::Custom` third-party namespace, auto-loaded by Proxmox without patching PVE's own files.
- Dynamic storage API version negotiation: `api()` reports the running host's `APIVER` (clamped to the validated maximum), so the plugin loads cleanly without the "older storage API" warning across Proxmox VE 9.x point releases. Implements `get_identity()` (storage API 14).
- Full VM disk lifecycle via the Lightbits REST API: create, attach, detach, delete.
- Volume resize (grow), online and offline, via `qm resize` / the Proxmox UI: the Lightbits volume is grown and an `nvme ns-rescan` makes the new capacity visible to the host deterministically.
- NVMe-oF TCP transport for block-device access (`nvme-tcp`).
- Storage capacity reporting in the Proxmox dashboard.
- Per-VM ownership labels (`pveVmid`, `pveVmgenid`, `pveNode`) and node-aware filtering so that destroying a VM never deletes another hypervisor's volumes in a shared Lightbits project.
- Auto-fetched subsystem NQN from the cluster API, with explicit override available via `--lb_subsys_nqn`.
- Stable per-volume symlinks under `/dev/lightbits/<storeid>/<uuid>`.
- `install.sh` / `uninstall.sh` scripts for each Proxmox node.
- CI workflow: Perl syntax check, taint-mode check, unit tests via `prove`, and `shellcheck` on installer scripts.

### Changed

- `alloc_image` now fails fast with a clear error if a new volume reports a terminal `Failed` state or never becomes `Available`, instead of returning a volid for an unusable volume (which previously surfaced later as a confusing "Cannot determine NSID" error at attach time).
