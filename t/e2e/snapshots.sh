#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for Lightbits volume snapshots, run ON a Proxmox VE node
# that already has a configured Lightbits storage. It drives the real PVE
# snapshot flow (qm snapshot / qm rollback) plus direct device I/O to verify data
# actually reverts, then checks the resize-rollback guard and snapshot cleanup.
#
# This script contains no cluster addresses or credentials: it operates through
# the storage already configured on this node. Cluster-side cross-checks (lbcli)
# are out of scope here; the unit suite (t/*.t) covers request shapes.
#
# Usage:
#   STORAGE=lb-storage VMID=9001 ./t/e2e/snapshots.sh
#
# Defaults: STORAGE=lb-storage, VMID=9001, DISK_GB=2, WRITE_MB=400.
# Keep DISK_GB small — these runs target low-memory lab VMs.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9001}"
DISK_GB="${DISK_GB:-2}"
WRITE_MB="${WRITE_MB:-400}"

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

# Gate: the unit suite must pass before any live e2e runs. Skip only if the unit
# tests aren't present alongside this script (e.g. script copied out of the repo)
# or `prove` is unavailable.
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

cleanup() { qm destroy "$VMID" --purge 1 >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Resolve this VM's disk volid and the device path (activating the volume).
volid() { qm config "$VMID" | awk -F'[ ,]' '/^scsi0:/{print $2}'; }
activate() {
    perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); PVE::Storage::activate_volumes($c,[$ARGV[0]]);' "$1" >/dev/null 2>&1
    perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); my ($p)=PVE::Storage::path($c,$ARGV[0]); print "$p\n";' "$1" 2>/dev/null
}
deactivate() {
    perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); PVE::Storage::deactivate_volumes($c,[$ARGV[0]]);' "$1" >/dev/null 2>&1
}
md5_head() { dd if="$1" bs=1M count="$WRITE_MB" iflag=direct status=none | md5sum | cut -d' ' -f1; }

echo "== setup: VM $VMID, ${DISK_GB}G disk on $STORAGE =="
cleanup
qm create "$VMID" --memory 512 --scsihw virtio-scsi-single --name lb-snap-e2e >/dev/null
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_GB}" >/dev/null
VOL="$(volid)"
echo "   disk: $VOL"

# 1. snapshot create (offline) drives the plugin and is tracked by PVE
qm snapshot "$VMID" snap1 >/dev/null
qm listsnapshot "$VMID" | grep -q snap1 && ok "snapshot create (qm snapshot)" || bad "snapshot create"

# 2. data revert: write A -> snapshot -> overwrite B -> rollback -> expect A
DEV="$(activate "$VOL")"
dd if=/dev/urandom of="$DEV" bs=1M count="$WRITE_MB" oflag=direct conv=fsync status=none
A="$(md5_head "$DEV")"; deactivate "$VOL"
qm snapshot "$VMID" snapA >/dev/null
DEV="$(activate "$VOL")"
dd if=/dev/urandom of="$DEV" bs=1M count="$WRITE_MB" oflag=direct conv=fsync status=none
B="$(md5_head "$DEV")"; deactivate "$VOL"
qm rollback "$VMID" snapA >/dev/null
DEV="$(activate "$VOL")"; AFTER="$(md5_head "$DEV")"; deactivate "$VOL"
if [ "$AFTER" = "$A" ] && [ "$A" != "$B" ]; then ok "rollback reverts data to the snapshot"; else bad "rollback data revert (A=$A B=$B after=$AFTER)"; fi

# 3. resize-rollback guard: grow the disk, then rollback must be refused
qm resize "$VMID" scsi0 +1G >/dev/null
if qm rollback "$VMID" snapA >/dev/null 2>/tmp/lb_e2e_rb_err; then
    bad "resize-rollback guard (rollback should have been refused)"
else
    grep -qi "resized" /tmp/lb_e2e_rb_err && ok "resize-rollback guard refuses a shrinking rollback" \
        || bad "resize-rollback guard (refused, but unexpected error)"
fi

# 4. orphan cleanup: destroying the VM removes its snapshots too
SNAPS_BEFORE="$(qm listsnapshot "$VMID" | grep -c snap || true)"
qm destroy "$VMID" --purge 1 >/dev/null
trap - EXIT
# the volume and its snapshots should be gone from the storage listing
if pvesm list "$STORAGE" | grep -q "vm-${VMID}-"; then bad "volume not freed on destroy"; else ok "volume freed on destroy"; fi
echo "   (had $SNAPS_BEFORE snapshot config entries before destroy)"

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
