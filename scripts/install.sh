#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Lightbits Proxmox Storage Plugin — Installer
set -euo pipefail

PLUGIN_SRC="$(dirname "$0")/../LightbitsPlugin.pm"
CUSTOM_DIR="/usr/share/perl5/PVE/Storage/Custom"
PLUGIN_DST="$CUSTOM_DIR/LightbitsPlugin.pm"
STORAGE_PM="/usr/share/perl5/PVE/Storage.pm"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [[ ! -f "$STORAGE_PM" ]]; then
    echo "ERROR: $STORAGE_PM not found. Is this a Proxmox VE host?" >&2
    exit 1
fi

echo "[1/3] Installing plugin (auto-loaded from the Custom namespace)..."
mkdir -p "$CUSTOM_DIR"
cp "$PLUGIN_SRC" "$PLUGIN_DST"
chmod 644 "$PLUGIN_DST"
echo "      -> $PLUGIN_DST"

echo "[2/3] Installing dependencies..."
# nvme-cli for NVMe-oF connect/disconnect
if ! command -v nvme &>/dev/null; then
    apt-get install -y nvme-cli 2>/dev/null || \
        apt-get install -y -o Dir::Etc::sourcelist=/etc/apt/sources.list \
                           -o Dir::Etc::sourceparts=/dev/null nvme-cli 2>/dev/null || \
        echo "      WARNING: could not install nvme-cli — install it manually before use."
else
    echo "      -> nvme-cli already present."
fi

# Perl HTTP/JSON modules (present on stock Proxmox, listed for completeness)
perl -e 'use LWP::Protocol::https; use JSON;' 2>/dev/null || \
    apt-get install -y liblwp-protocol-https-perl libjson-perl 2>/dev/null || true

echo "[3/3] Restarting PVE services..."
systemctl restart pvedaemon pvestatd
echo "      -> Done."

echo ""
echo "Installation complete. The 'lightbits' storage type is now available."
echo ""
echo "Add the storage with pvesm (replace values for your environment):"
echo ""
echo "  pvesm add lightbits lb-storage \\"
echo "    --lb_api_host  <lightbits-ip>:443 \\"
echo "    --lb_jwt       '<jwt-token>' \\"
echo "    --lb_nvme_host <lightbits-ip>:4420 \\"
echo "    --lb_project   default \\"
echo "    --content      images"
echo ""
echo "The subsystem NQN is fetched automatically from the cluster API."
echo "Supply --lb_subsys_nqn '<nqn>' only if you need to override it."
echo ""
echo "See README.md for how to obtain these values from your Lightbits cluster."
