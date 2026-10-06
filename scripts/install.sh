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

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Install the Lightbits storage plugin on this Proxmox VE node. Run once per node,
as root. The script takes no options other than --help; everything it needs is
either already on the host or fetched automatically.

What it does:
  1. Copies LightbitsPlugin.pm to
     $CUSTOM_DIR/
     Proxmox auto-loads third-party plugins from that namespace, so no PVE file
     is patched.
  2. Installs nvme-cli (for NVMe-oF connect/disconnect) and the Perl HTTP/JSON
     modules, if they are missing.
  3. Installs and starts discovery-client, Lightbits' NVMe-oF connection
     manager, which the plugin seeds instead of running 'nvme connect' itself.
     This step needs internet access to Lightbits' package repository; it is
     best-effort and warns rather than aborting if it fails.
  4. Restarts pvedaemon and pvestatd so the new plugin is picked up.

It finishes with a health check for nvme-cli and discovery-client, then prints a
'pvesm add' example. Re-running it is safe: it overwrites the plugin file and
skips anything already present, which is how you upgrade to a newer version.

Requirements:
  - Proxmox VE 9.x (verified by the presence of $STORAGE_PM)
  - root privileges

Exit status:
  0  plugin installed (check the health output for ACTION REQUIRED items)
  1  not run as root, or this is not a Proxmox VE host
  2  invalid command line

To remove the plugin again, use uninstall.sh (see 'uninstall.sh --help').
Full documentation: https://github.com/LightBitsLabs/pve-lightbits
EOF
}

# Parsed before the root check below, so --help works as an ordinary user.
for arg in "$@"; do
    case "$arg" in
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

if [[ ! -f "$STORAGE_PM" ]]; then
    echo "ERROR: $STORAGE_PM not found. Is this a Proxmox VE host?" >&2
    exit 1
fi

echo "[1/4] Installing plugin (auto-loaded from the Custom namespace)..."
mkdir -p "$CUSTOM_DIR"
cp "$PLUGIN_SRC" "$PLUGIN_DST"
chmod 644 "$PLUGIN_DST"
echo "      -> $PLUGIN_DST"

echo "[2/4] Installing dependencies..."
# nvme-cli for NVMe-oF connect/disconnect
if ! command -v nvme &>/dev/null; then
    apt-get install -y nvme-cli 2>/dev/null || \
        apt-get install -y -o Dir::Etc::sourcelist=/etc/apt/sources.list \
                           -o Dir::Etc::sourceparts=/dev/null nvme-cli 2>/dev/null || \
        echo "      WARNING: could not install nvme-cli - install it manually before use."
else
    echo "      -> nvme-cli already present."
fi

# Perl HTTP/JSON modules (present on stock Proxmox, listed for completeness)
perl -e 'use LWP::Protocol::https; use JSON;' 2>/dev/null || \
    apt-get install -y liblwp-protocol-https-perl libjson-perl 2>/dev/null || true

echo "[3/4] Installing discovery-client (Lightbits NVMe-oF connection manager)..."
# The plugin seeds discovery-client instead of running `nvme connect` itself,
# so it can keep this host's connections in sync as cluster nodes are added or
# removed later — see the "discovery-client integration" note in
# LightbitsPlugin.pm. Best-effort, matching the nvme-cli install above: if the
# repo setup fails (e.g. no internet access, unsupported codename), warn and
# let the operator install it manually rather than aborting the whole install.
# mktemp (not a fixed path) so a local unprivileged user can't pre-create this
# path as a symlink and have our root-owned redirect truncate an arbitrary file.
DSC_INSTALL_LOG=$(mktemp /tmp/lb-discovery-client-install.XXXXXX.log)
if ! command -v discovery-client &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        (
            set -e
            apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
            # Write both downloaded files to a staging temp file first and mv into
            # place only on success, so a transient curl/gpg failure can't truncate
            # an existing, working repo config (a plain `>` redirect opens/truncates
            # the destination before the pipeline's success is known).
            key_tmp=$(mktemp /usr/share/keyrings/.lightbits-discovery-client-keyring.XXXXXX)
            source_tmp=$(mktemp /etc/apt/sources.list.d/.lightbits-discovery-client.XXXXXX)
            trap 'rm -f "$key_tmp" "$source_tmp"' EXIT
            curl -1sLf 'https://dl.lightbitslabs.com/public/discovery-client/gpg.014E5C7FAFD89AEE.key' \
                | gpg --dearmor > "$key_tmp"
            # Lightbits only publishes discovery-client's .deb under the "ubuntu" repo path
            # (confirmed live: the "debian" path exists but is an empty repo for every
            # codename). Proxmox is a Debian derivative, but the package itself is a generic
            # alien-converted static binary (only libc6 dependency) identical across every
            # published ubuntu codename, so this works regardless of the host's actual distro.
            distro=ubuntu
            codename=jammy
            curl -1sLf "https://dl.lightbitslabs.com/public/discovery-client/config.deb.txt?distro=${distro}&codename=${codename}" \
                > "$source_tmp"
            chmod 0644 "$key_tmp" "$source_tmp"
            mv "$key_tmp" /usr/share/keyrings/lightbits-discovery-client-archive-keyring.gpg
            mv "$source_tmp" /etc/apt/sources.list.d/lightbits-discovery-client.list
            trap - EXIT
            apt-get update -q
            apt-get install -y discovery-client
        ) >"$DSC_INSTALL_LOG" 2>&1 || echo "      WARNING: could not install discovery-client automatically - " \
            "see $DSC_INSTALL_LOG for details, or https://github.com/LightBitsLabs/discovery-client for manual install steps."
    else
        echo "      WARNING: no apt-get found - install discovery-client manually, see " \
            "https://github.com/LightBitsLabs/discovery-client"
    fi
else
    echo "      -> discovery-client already present."
fi
if command -v discovery-client &>/dev/null; then
    systemctl enable --now discovery-client 2>/dev/null || \
        echo "      WARNING: discovery-client installed but could not be started - " \
            "check 'systemctl status discovery-client'."
fi

echo "[4/4] Restarting PVE services..."
systemctl restart pvedaemon pvestatd
echo "      -> Done."

HEALTH_OK=1
echo ""
if command -v nvme &>/dev/null; then
    echo "nvme-cli: OK (installed)"
else
    echo "nvme-cli: ACTION REQUIRED - not installed; volume activate/deactivate will fail."
    HEALTH_OK=0
fi
if command -v discovery-client &>/dev/null && systemctl is-active --quiet discovery-client; then
    echo "discovery-client: OK (installed and running)"
else
    echo "discovery-client: ACTION REQUIRED - not installed/running. Every volume"
    echo "  activation depends on it; see $DSC_INSTALL_LOG (if present) or"
    echo "  https://github.com/LightBitsLabs/discovery-client for manual install steps,"
    echo "  then 'systemctl enable --now discovery-client'."
    HEALTH_OK=0
fi

echo ""
if [[ $HEALTH_OK -eq 1 ]]; then
    echo "Installation complete. The 'lightbits' storage type is now available."
else
    echo "Plugin files installed, but resolve the ACTION REQUIRED item(s) above"
    echo "before using this storage - volume activation will fail without them."
fi
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
