# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased

### Added

- Initial release of the Lightbits Storage Plugin for Proxmox VE.
- Installs into the official `PVE::Storage::Custom` third-party namespace, auto-loaded by Proxmox without patching PVE's own files.
- Full VM disk lifecycle via the Lightbits REST API: create, attach, detach, delete.
- NVMe-oF TCP transport for block-device access (`nvme-tcp`).
- Storage capacity reporting in the Proxmox dashboard.
- Per-VM ownership labels (`pveVmid`, `pveVmgenid`, `pveNode`) and node-aware filtering so that destroying a VM never deletes another hypervisor's volumes in a shared Lightbits project.
- Auto-fetched subsystem NQN from the cluster API, with explicit override available via `--lb_subsys_nqn`.
- Stable per-volume symlinks under `/dev/lightbits/<storeid>/<uuid>`.
- `install.sh` / `uninstall.sh` scripts for each Proxmox node.
- CI workflow: Perl syntax check, taint-mode check, unit tests via `prove`, and `shellcheck` on installer scripts.

[Unreleased]: https://github.com/LightBitsLabs/pve-lightbits/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LightBitsLabs/pve-lightbits/releases/tag/v0.1.0
