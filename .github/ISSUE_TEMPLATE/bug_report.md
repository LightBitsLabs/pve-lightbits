---
name: Bug report
about: Something is not working as expected
labels: bug
---

## Description

A clear description of the problem.

## Environment

| Component | Version |
|---|---|
| Proxmox VE | <!-- output of: pveversion -v --> |
| Lightbits LightOS | |
| Plugin commit | <!-- output of: git -C /usr/share/perl5/PVE/Storage rev-parse HEAD, or the commit hash you installed from --> |
| nvme-cli | <!-- output of: nvme version --> |
| Linux kernel | <!-- output of: uname -r --> |

## Steps to reproduce

1.
2.
3.

## Expected behavior

## Actual behavior

## Relevant logs

<!-- journalctl -u pvedaemon -n 100 --no-pager -->

```
paste logs here
```
