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

for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=1
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
