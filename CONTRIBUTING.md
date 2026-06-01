# Contributing to pve-lightbits

Thanks for your interest in contributing. This document covers how to report issues, propose changes, and get your pull request merged.

## Reporting bugs

Open a [GitHub Issue](https://github.com/LightBitsLabs/pve-lightbits/issues) and include:

- Proxmox VE version (`pveversion -v`)
- Lightbits LightOS version
- Plugin version / commit hash
- Steps to reproduce
- Relevant logs (`journalctl -u pvedaemon -n 100 --no-pager`)

## Suggesting features

Open an issue describing the use case and the problem it solves. For anything touching the volume lifecycle or NVMe-oF connection handling, it helps to include context about your cluster topology.

## Making changes

### Prerequisites

Testing requires a real Proxmox VE node with network access to a Lightbits cluster. If you don't have access to one, you can still contribute - open a PR with your changes and a description of what you tested, and a Lightbits maintainer will validate on hardware.

For syntax-only checks you can run locally without hardware:

```bash
perl -c LightbitsPlugin.pm
shellcheck install.sh uninstall.sh
```

### Workflow

1. Fork the repository and create a branch from `main`.
2. Make your changes.
3. Test on a real Proxmox node if possible (see README for verification steps).
4. Commit with a `Signed-off-by` line (see DCO section below).
5. Open a pull request against `main`.

### Commit style

Keep commits focused - one logical change per commit. Write the subject line in the imperative mood:

```
Fix symlink not created when storeid contains uppercase letters
Add support for custom NVMe-oF port via lb_nvme_host
```

### Code style

Follow the existing Perl style in `LightbitsPlugin.pm`:
- 4-space indentation
- No trailing whitespace
- Untaint all external input (readdir, sysfs reads) via regex capture before use in filesystem operations

## Developer Certificate of Origin (DCO)

By contributing you certify that you have the right to submit the work under the Apache 2.0 license. Add a `Signed-off-by` line to each commit:

```
git commit -s -m "Your commit message"
```

This produces:

```
Signed-off-by: Your Name <your@email.com>
```

Full DCO text: https://developercertificate.org

## License

By submitting a pull request you agree that your contribution will be licensed under the [Apache License 2.0](LICENSE).
