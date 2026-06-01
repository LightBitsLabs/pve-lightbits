#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Lightbits Proxmox Storage Plugin — Uninstaller
set -euo pipefail

PLUGIN_DST="/usr/share/perl5/PVE/Storage/Custom/LightbitsPlugin.pm"
STORAGE_CFG="/etc/pve/storage.cfg"
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
        echo "[0/2] Removing lightbits storage entries (--force)..."
        for id in "${LB_IDS[@]}"; do
            pvesm remove "$id"
            echo "      -> Removed storage '$id'."
        done
    fi
fi

echo "[1/2] Removing plugin file..."
if [[ -f "$PLUGIN_DST" ]]; then
    rm -f "$PLUGIN_DST"
    echo "      -> Removed $PLUGIN_DST"
else
    echo "      -> Not present, skipping."
fi

echo "[2/2] Restarting PVE services..."
systemctl restart pvedaemon pvestatd
echo "      -> Done."

echo ""
echo "Uninstall complete."
