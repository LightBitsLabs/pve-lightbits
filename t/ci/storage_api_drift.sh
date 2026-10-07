#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Storage API drift check: fails as soon as Proxmox publishes a libpve-storage-perl
# whose storage API version (APIVER) is newer than the plugin's validated maximum
# ($TESTED_APIVER in LightbitsPlugin.pm). Runs anywhere with curl, ar and tar — no
# Proxmox host needed.
#
# Why: the plugin's api() deliberately clamps to $TESTED_APIVER. When a PVE point
# release bumps APIVER past it, every pvesm call and GUI storage view on updated
# hosts logs
#     Plugin "PVE::Storage::Custom::LightbitsPlugin" is implementing an older
#     storage API, an upgrade is recommended
# (harmless but alarming), and once APIVER - APIAGE passes it the loader rejects
# the plugin outright. Users on the stock repos see this days before a mirror-fed
# lab node does, so check the upstream package index, not an installed host.
#
# For each component it downloads the newest libpve-storage-perl .deb, reads
# APIVER/APIAGE from PVE/Storage.pm and prints the changelog entries newer than
# the version that still matched, so the "plugin api: ... version bump" line is
# right there in the CI log.
#
# Usage:
#   t/ci/storage_api_drift.sh
#   PROXMOX_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve t/ci/storage_api_drift.sh
#
# Env: PROXMOX_MIRROR (default http://download.proxmox.com/debian/pve),
#      SUITE (trixie), COMPONENTS ("pve-no-subscription pvetest").
# Exit: 0 all components at or below $TESTED_APIVER; 1 a newer APIVER is out
#       (the warning shows on updated hosts); 2 the plugin would be REJECTED by
#       the loader (APIVER - APIAGE > $TESTED_APIVER); 3 the check itself failed.
set -euo pipefail

MIRROR="${PROXMOX_MIRROR:-http://download.proxmox.com/debian/pve}"
SUITE="${SUITE:-trixie}"
COMPONENTS="${COMPONENTS:-pve-no-subscription pvetest}"
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)/LightbitsPlugin.pm"

die() { echo "ERROR: $*" >&2; exit 3; }
for tool in curl ar tar sort; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done

# shellcheck disable=SC2016  # the $ is a literal in the sed pattern
tested="$(sed -nE 's/^my \$TESTED_APIVER = ([0-9]+);.*/\1/p' "$PLUGIN")"
[[ "$tested" =~ ^[0-9]+$ ]] || die "could not read \$TESTED_APIVER from $PLUGIN"
echo "plugin: \$TESTED_APIVER = $tested"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

worst=0
for comp in $COMPONENTS; do
    idx="$MIRROR/dists/$SUITE/$comp/binary-amd64/Packages"
    curl -4fsS --retry 3 --max-time 60 -o "$tmp/$comp.Packages" "$idx" \
        || die "cannot fetch $idx"
    # newest libpve-storage-perl in the index: "<version> <filename>" lines, sort -V on the version
    pick="$(awk '/^Package: libpve-storage-perl$/{p=1} p&&/^Version:/{v=$2} p&&/^Filename:/{print v, $2; p=0}' \
                "$tmp/$comp.Packages" | sort -V | tail -1)"
    [ -n "$pick" ] || die "no libpve-storage-perl in $idx"
    ver="${pick%% *}"; file="${pick#* }"
    d="$tmp/$comp"; mkdir -p "$d"
    curl -4fsS --retry 3 --max-time 120 -o "$d/pkg.deb" "$MIRROR/$file" || die "cannot fetch $MIRROR/$file"
    data="$(ar t "$d/pkg.deb" | grep '^data\.tar')"
    ( cd "$d" && ar x pkg.deb "$data" && tar -xaf "$data" \
        ./usr/share/perl5/PVE/Storage.pm ./usr/share/doc/libpve-storage-perl/changelog.gz ) \
        || die "cannot extract $data from $file"
    apiver="$(sed -nE 's/^use constant APIVER => ([0-9]+);.*/\1/p' "$d/usr/share/perl5/PVE/Storage.pm")"
    apiage="$(sed -nE 's/^use constant APIAGE => ([0-9]+);.*/\1/p' "$d/usr/share/perl5/PVE/Storage.pm")"
    [[ "$apiver" =~ ^[0-9]+$ && "$apiage" =~ ^[0-9]+$ ]] || die "could not read APIVER/APIAGE from $file"
    min=$(( apiver - apiage ))

    if (( apiver <= tested )); then
        echo "ok     $comp: libpve-storage-perl $ver APIVER=$apiver APIAGE=$apiage (tested $tested, no warning)"
        continue
    fi
    if (( tested < min )); then
        echo "not ok $comp: libpve-storage-perl $ver APIVER=$apiver APIAGE=$apiage -> plugin REJECTED (tested $tested < $min)"
        (( worst < 2 )) && worst=2
    else
        echo "not ok $comp: libpve-storage-perl $ver APIVER=$apiver APIAGE=$apiage -> 'older storage API' warning (tested $tested)"
        (( worst < 1 )) && worst=1
    fi
    echo "       changelog entries newer than the last matching API (look for 'plugin api'):"
    # print entries until the first one whose changelog mentions a version <= tested is irrelevant;
    # simpler and robust: print entries of the newest 3 versions, api-related lines highlighted
    zcat "$d/usr/share/doc/libpve-storage-perl/changelog.gz" \
        | awk '/^libpve-storage-perl \(/{n++} n<=3' \
        | grep -iE '^libpve-storage-perl|api|plugin' | sed 's/^/       | /'
done

exit "$worst"
