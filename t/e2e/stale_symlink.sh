#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for stale volume-symlink recovery in activate_volume,
# run ON a Proxmox VE node that already has a configured Lightbits storage.
#
# NVMe controller numbering is not stable across a disconnect/reconnect or a
# path flap, so a symlink under /dev/lightbits/<storeid>/ left by an earlier
# activation can end up (1) dangling — pointing at a device name that no
# longer exists — which used to kill re-activation with EEXIST, or (2) worse,
# pointing at a device name that now belongs to a DIFFERENT namespace, which
# used to hand QEMU the wrong disk silently. This suite manufactures both
# states with two live volumes and asserts activate_volume repairs the link
# to the volume's real namespace (validated against /sys nsid + subsysnqn)
# instead of trusting it.
#
# Like snapshots.sh, this script contains no cluster addresses or credentials:
# it operates through the storage already configured on this node.
#
# Usage:
#   STORAGE=lb-storage VMID_A=9003 VMID_B=9004 ./t/e2e/stale_symlink.sh
#
# Defaults: STORAGE=lb-storage, VMID_A=9003, VMID_B=9004, DISK_GB=1.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID_A="${VMID_A:-9003}"
VMID_B="${VMID_B:-9004}"
DISK_GB="${DISK_GB:-1}"
TEST_VM_NAME="lb-sym-e2e"   # ownership marker: we only ever destroy VMs with this name

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

# Gate: the unit suite must pass before any live e2e runs (same as snapshots.sh).
T_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if command -v prove >/dev/null 2>&1 && ls "$T_DIR"/*.t >/dev/null 2>&1; then
    echo "== running unit tests before e2e =="
    if ! prove -I "$T_DIR/stubs" "$T_DIR"/*.t; then
        echo "ABORT: unit tests failed — not running e2e." >&2
        exit 1
    fi
else
    echo "NOTE: unit tests not found next to this script; skipping the unit gate." >&2
fi

is_our_vm() {   # is_our_vm <vmid>
    local name
    name="$(qm config "$1" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')" || return 1
    [ "$name" = "$TEST_VM_NAME" ]
}
cleanup() {
    for id in "$VMID_A" "$VMID_B"; do
        if is_our_vm "$id"; then qm destroy "$id" --purge 1 >/dev/null 2>&1 || true; fi
    done
}
trap cleanup EXIT

volid() { qm config "$1" | awk -F'[ ,]' '/^scsi0:/{print $2}'; }
activate() {   # activate <volid> -> prints the volume's /dev/lightbits path; rc from activation
    perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); PVE::Storage::activate_volumes($c,[$ARGV[0]]);' "$1" \
        || return 1
    perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); my ($p)=PVE::Storage::path($c,$ARGV[0]); print "$p\n";' "$1"
}
# The nsid (or subsysnqn) of the namespace a link currently resolves to.
ns_of()      { basename "$(readlink "$1")"; }
nsid_of()    { cat "/sys/block/$(ns_of "$1")/nsid" 2>/dev/null; }
subnqn_of()  {
    local ns; ns="$(ns_of "$1")"
    cat "/sys/block/$ns/device/subsysnqn" 2>/dev/null || cat "/sys/block/$ns/subsysnqn" 2>/dev/null
}

echo "== setup: VMs $VMID_A + $VMID_B, ${DISK_GB}G disks on $STORAGE =="
for id in "$VMID_A" "$VMID_B"; do
    if qm config "$id" >/dev/null 2>&1 && ! is_our_vm "$id"; then
        echo "ABORT: VM $id already exists and is not the test VM '$TEST_VM_NAME'; refusing to destroy it." >&2
        exit 1
    fi
done
cleanup
for id in "$VMID_A" "$VMID_B"; do
    qm create "$id" --memory 512 --scsihw virtio-scsi-single --name "$TEST_VM_NAME" >/dev/null
    qm set "$id" --scsi0 "${STORAGE}:${DISK_GB}" >/dev/null
done
VOL_A="$(volid "$VMID_A")"; VOL_B="$(volid "$VMID_B")"

# ── 1. fresh activation: link resolves to this volume's namespace ─────────────
LINK_A="$(activate "$VOL_A")" || { bad "fresh activation of volume A"; echo "== $pass passed, $((fail+1)) failed =="; exit 1; }
LINK_B="$(activate "$VOL_B")"
NSID_A="$(nsid_of "$LINK_A")"; NSID_B="$(nsid_of "$LINK_B")"
SUBNQN_A="$(subnqn_of "$LINK_A")"
DEV_A="$(readlink "$LINK_A")"; DEV_B="$(readlink "$LINK_B")"
if [ -n "$NSID_A" ] && [ -n "$NSID_B" ] && [ "$NSID_A" != "$NSID_B" ] && [ -b "$DEV_A" ]; then
    ok "fresh activations map two distinct namespaces (nsid $NSID_A vs $NSID_B)"
else
    bad "fresh activation devices are unusable or not distinct (A=$DEV_A/$NSID_A B=$DEV_B/$NSID_B)"
fi

# ── 2. valid link is reused untouched ──────────────────────────────────────────
activate "$VOL_A" >/dev/null
[ "$(readlink "$LINK_A")" = "$DEV_A" ] \
    && ok "re-activation leaves a valid link untouched" \
    || bad "re-activation rewrote a valid link ($(readlink "$LINK_A") != $DEV_A)"

# ── 3. dangling link (controller renumbered away) → repaired, not EEXIST ──────
rm -f "$LINK_A"
ln -s /dev/nvme97n42 "$LINK_A"    # deliberately nonexistent device name
if activate "$VOL_A" >/dev/null 2>&1; then
    if [ "$(nsid_of "$LINK_A")" = "$NSID_A" ] && [ -b "$(readlink "$LINK_A")" ]; then
        ok "dangling link is repaired to the volume's live namespace (nsid $NSID_A)"
    else
        bad "activation succeeded but the link is wrong ($(readlink "$LINK_A"))"
    fi
else
    bad "activation died on a dangling link (the pre-fix EEXIST failure mode)"
fi

# ── 4. link pointing at ANOTHER volume's device → repaired, not trusted ───────
rm -f "$LINK_A"
ln -s "$DEV_B" "$LINK_A"          # volume A's link now names volume B's device
if activate "$VOL_A" >/dev/null 2>&1; then
    if [ "$(nsid_of "$LINK_A")" = "$NSID_A" ]; then
        ok "wrong-volume link is repaired to nsid $NSID_A (was pointing at nsid $NSID_B)"
    else
        bad "activation reused a link to the WRONG volume (nsid $(nsid_of "$LINK_A"), expected $NSID_A) — silent data corruption"
    fi
else
    bad "activation died repairing a wrong-volume link"
fi
[ "$(subnqn_of "$LINK_A")" = "$SUBNQN_A" ] \
    && ok "repaired link stays within the storage's subsystem" \
    || bad "repaired link resolves outside the expected subsystem"

# ── 5. teardown removes the links ──────────────────────────────────────────────
qm destroy "$VMID_A" --purge 1 >/dev/null
qm destroy "$VMID_B" --purge 1 >/dev/null
trap - EXIT
if [ ! -e "$LINK_A" ] && [ ! -e "$LINK_B" ]; then
    ok "destroy removes both volume links"
else
    bad "volume links left behind after destroy"
fi

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
