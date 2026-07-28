#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Lightbits Proxmox Storage Plugin — Uninstaller
set -euo pipefail

PLUGIN_DST="/usr/share/perl5/PVE/Storage/Custom/LightbitsPlugin.pm"
STORAGE_CFG="/etc/pve/storage.cfg"
DSC_CONF_DIR="/etc/discovery-client/discovery.d"
FORCE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--force] [-h|--help]

Remove the Lightbits storage plugin from this Proxmox VE node. Run once per node,
as root.

Options:
  --force      Also remove any 'lightbits' storage entries still configured in
               $STORAGE_CFG, by running 'pvesm remove' for each.
               Without this, the script refuses to do anything while such an
               entry exists and prints the commands to remove them yourself.
               This detaches the storage from Proxmox; it does NOT delete any
               volume or snapshot on the Lightbits cluster.
  -h, --help   Show this help and exit.

What it does:
  1. Removes this plugin's discovery-client config files
     ($DSC_CONF_DIR/lightbits-*.conf), so
     discovery-client stops maintaining connections for them.
  2. Removes $PLUGIN_DST
  3. Restarts pvedaemon and pvestatd, which have the plugin loaded in memory and
     would otherwise keep serving the 'lightbits' storage type until restarted.

What it deliberately leaves alone:
  - Volumes and snapshots on the Lightbits cluster. Nothing here touches your
    data; delete volumes from the cluster side if you want them gone.
  - The nvme-cli and discovery-client packages, which other software may use.
    Remove them with apt-get if you are sure nothing else needs them.
  - Existing NVMe-oF connections. Deactivating the storage's last volume
    disconnects the subsystem; otherwise use 'nvme disconnect -n <nqn>'.

Exit status:
  0  plugin removed
  1  not run as root, or lightbits storage entries still exist (without --force)
  2  invalid command line

Full documentation: https://github.com/LightBitsLabs/pve-lightbits
EOF
}

# Parsed before the root check below, so --help works as an ordinary user.
for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '$arg'." >&2
            echo "" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Detect active lightbits storage entries before touching anything.
LB_IDS=()
if [[ -f "$STORAGE_CFG" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^lightbits:[[:space:]]+(.+)$ ]] && LB_IDS+=("${BASH_REMATCH[1]}")
    done < "$STORAGE_CFG"
fi

if [[ ${#LB_IDS[@]} -gt 0 ]]; then
    if [[ $FORCE -eq 0 ]]; then
        echo "ERROR: The following lightbits storage entries still exist in $STORAGE_CFG:" >&2
        for id in "${LB_IDS[@]}"; do
            echo "         pvesm remove $id" >&2
        done
        echo "" >&2
        echo "  Remove them first, then re-run uninstall.sh." >&2
        echo "  Or run:  $0 --force  to remove them automatically." >&2
        exit 1
    else
        echo "[0/3] Removing lightbits storage entries (--force)..."
        for id in "${LB_IDS[@]}"; do
            pvesm remove "$id"
            echo "      -> Removed storage '$id'."
        done
    fi
fi

# By this point no lightbits storage entries remain in $STORAGE_CFG (the
# non-force branch above exits before here otherwise), so it's always safe to
# sweep every lightbits discovery-client config regardless of whether this
# script did the `pvesm remove` itself just now or the operator did it
# manually beforehand per the error message above — either path left this
# step un-run before, orphaning the config file.
echo "[1/3] Removing discovery-client config files..."
shopt -s nullglob
DSC_CONFS=("$DSC_CONF_DIR"/lightbits-*.conf)
shopt -u nullglob
if [[ ${#DSC_CONFS[@]} -gt 0 ]]; then
    for conf in "${DSC_CONFS[@]}"; do
        rm -f "$conf"
        echo "      -> Removed $conf"
    done
else
    echo "      -> None present, skipping."
fi

echo "[2/3] Removing plugin file..."
if [[ -f "$PLUGIN_DST" ]]; then
    rm -f "$PLUGIN_DST"
    echo "      -> Removed $PLUGIN_DST"
else
    echo "      -> Not present, skipping."
fi

echo "[3/3] Restarting PVE services..."
systemctl restart pvedaemon pvestatd
echo "      -> Done."

echo ""
echo "Uninstall complete."
