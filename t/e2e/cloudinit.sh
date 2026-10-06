#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for a VM's cloud-init drive on Lightbits storage
# (pve-lightbits issue #41), run ON a Proxmox VE node that already has a
# configured Lightbits storage. It drives the real qemu-server flows:
#
#   1. `qm create ... --ide2 <lb>:cloudinit` allocates the drive under the
#      name PVE recognises (vm-<vmid>-cloudinit) as a blank 4 MiB device,
#   2. `qm cloudinit update` writes the NoCloud ISO into the Lightbits volume
#      (read back from the device with isoinfo) and regenerates it in place,
#   3. the storage listing shows the drive once, under that name, and a
#      `qm rescan` adds no "unused" duplicate,
#   4. `qm clone --full --storage <lb>` gives the clone a cloud-init drive on
#      the Lightbits storage that PVE recognises; starting the clone activates
#      it (symlink keyed on the volname), stopping deactivates it,
#   5. `vzdump` + `qmrestore --storage <lb>` does the same for a restore
#      (skipped when no backup-capable storage is available),
#   6. `qm destroy --purge` leaves no volume behind for any of the VMs,
#      cluster-side (API) as well as in the storage listing.
#
# API host and JWT are read from the storage's definition in
# /etc/pve/storage.cfg for the cluster-side leak check. The check talks to
# the same API endpoints the plugin uses; set LB_CACERT=<pem> to verify the
# cluster's certificate, otherwise verification is skipped as the plugin
# itself does today (self-signed LightOS certificates). Needs curl, python3
# and isoinfo (genisoimage), all present on a stock PVE node.
#
# Usage:
#   STORAGE=lb-storage VMID=9004 ./t/e2e/cloudinit.sh
#
# Defaults: STORAGE=lb-storage, VMID=9004 (source VM), CLONE_VMID=VMID+1,
# RESTORE_VMID=VMID+2, BACKUP_STORAGE=local, DISK_GB=1.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9004}"
CLONE_VMID="${CLONE_VMID:-$((VMID + 1))}"
RESTORE_VMID="${RESTORE_VMID:-$((VMID + 2))}"
BACKUP_STORAGE="${BACKUP_STORAGE:-local}"
DISK_GB="${DISK_GB:-1}"
TEST_VM_NAME="lb-cloudinit-e2e"   # ownership marker: we only ever destroy VMs with this name
BACKUP_VOLID=""   # backup volume created by this run, freed at the end

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

# Gate: the unit suite must pass before any live e2e runs.
T_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if command -v prove >/dev/null 2>&1 && ls "$T_DIR"/*.t >/dev/null 2>&1; then
    echo "== running unit tests before e2e =="
    if ! prove -I "$T_DIR/stubs" "$T_DIR"/*.t; then
        echo "ABORT: unit tests failed - not running e2e." >&2
        exit 1
    fi
else
    echo "NOTE: unit tests not found next to this script; skipping the unit gate." >&2
fi
command -v isoinfo >/dev/null 2>&1 || { echo "ABORT: isoinfo (genisoimage) not installed" >&2; exit 1; }

# ── storage.cfg + API helpers (cluster-side leak check) ───────────────────────
scfg_val() {
    awk -v s="$1" -v k="$2" '
        $0 ~ "^lightbits: " s "$" { in_blk = 1; next }
        /^[a-z]+: / { in_blk = 0 }
        in_blk && $1 == k { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); print; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
if [ -z "$API_HOSTS" ] || [ -z "$JWT" ]; then echo "ABORT: storage '$STORAGE' not in /etc/pve/storage.cfg" >&2; exit 1; fi
CURL_TLS=(-k); [ -n "${LB_CACERT:-}" ] && CURL_TLS=(--cacert "$LB_CACERT")
api_get() {
    local p="$1" out code h
    for h in ${API_HOSTS//,/ }; do
        out="$(curl -s "${CURL_TLS[@]}" -m 20 -H "Authorization: Bearer $JWT" -w $'\n%{http_code}' "https://$h$p" 2>/dev/null)" || continue
        code="${out##*$'\n'}"; out="${out%$'\n'*}"
        [ "$code" = 200 ] && { printf '%s' "$out"; return 0; }
    done
    return 1
}
# UUID + name of every volume in the project carrying pveVmid=<vmid>.
cluster_vols_of() {
    api_get "/api/v2/volumes?projectName=$PROJECT" | python3 -c '
import json, sys
want = sys.argv[1]
for v in json.load(sys.stdin).get("volumes", []):
    labels = {l.get("key"): l.get("value") for l in v.get("labels") or []}
    if labels.get("pveVmid") == want and v.get("state") not in ("Deleting", "Deleted"):
        print(v["UUID"], v.get("name", ""), labels.get("pveRole", "-"))' "$1"
}

# Backup volids of VM $1 on $BACKUP_STORAGE, one per line (PVE's own listing,
# whatever directory the storage uses). The archive this run creates is the
# one present after vzdump that was not present before.
backups_of() { pvesm list "$BACKUP_STORAGE" --content backup --vmid "$1" 2>/dev/null | awk 'NR>1{print $1}' | sort; }
rm_backup() {
    [ -n "$BACKUP_VOLID" ] || return 0
    pvesm free "$BACKUP_VOLID" >/dev/null 2>&1 || true   # removes archive, .log and .notes
}

# ── VM ownership guards + cleanup ─────────────────────────────────────────────
is_our_vm() {
    local name
    name="$(qm config "$1" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')" || return 1
    [ "$name" = "$TEST_VM_NAME" ]
}
cleanup() {
    for v in "$VMID" "$CLONE_VMID" "$RESTORE_VMID"; do
        if is_our_vm "$v"; then
            qm stop "$v" >/dev/null 2>&1 || true
            qm destroy "$v" --purge 1 >/dev/null 2>&1 || true
        fi
    done
    rm_backup
}
trap cleanup EXIT
for v in "$VMID" "$CLONE_VMID" "$RESTORE_VMID"; do
    if qm config "$v" >/dev/null 2>&1 && ! is_our_vm "$v"; then
        echo "ABORT: VM $v already exists and is not the test VM '$TEST_VM_NAME'; refusing to destroy it. Set VMID to an unused range." >&2
        exit 1
    fi
done
cleanup

ci_volid()  { qm config "$1" | awk -F'[ ,]' '/^ide2:/{print $2}'; }
activate()  { perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); PVE::Storage::activate_volumes($c,[$ARGV[0]]); my ($p)=PVE::Storage::path($c,$ARGV[0]); print "$p\n";' "$1"; }
deactivate(){ perl -MPVE::Storage -e 'my $c=PVE::Storage::config(); PVE::Storage::deactivate_volumes($c,[$ARGV[0]]);' "$1"; }
# user-data of the NoCloud ISO on a block device (Rock Ridge name).
iso_userdata() { isoinfo -R -i "$1" -x /user-data 2>/dev/null; }

echo "== 1. create VM $VMID with a Lightbits disk and a Lightbits cloud-init drive =="
qm create "$VMID" --name "$TEST_VM_NAME" --memory 512 --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK_GB}" --ide2 "${STORAGE}:cloudinit" \
    --ciuser e2e-first --cipassword 'e2e-pass' --ipconfig0 ip=dhcp >/dev/null
CI="$(ci_volid "$VMID")"
echo "   ide2: $CI"
if [ "$CI" = "${STORAGE}:vm-${VMID}-cloudinit" ]; then ok "cloud-init drive allocated under PVE's name (vm-<vmid>-cloudinit)"; else bad "cloud-init volid is '$CI'"; fi
if qm cloudinit dump "$VMID" user 2>/dev/null | grep -q 'e2e-first'; then ok "PVE recognises the drive as cloud-init (qm cloudinit dump works)"; else bad "qm cloudinit dump does not see the drive"; fi
DEV="$(activate "$CI")"
if [ -b "$DEV" ] && [ -L "/dev/lightbits/$STORAGE/vm-${VMID}-cloudinit" ]; then ok "activation creates the volname-keyed symlink ($DEV)"; else bad "no block device / symlink for the cloud-init drive (path=$DEV)"; fi
# PVE generates the ISO on first start or `qm cloudinit update`, not on create:
# a fresh drive is a blank 4 MiB device (4096 KiB requested by qemu-server).
SZ="$(blockdev --getsize64 "$DEV")"
if [ "$SZ" = 4194304 ]; then ok "fresh cloud-init volume is the 4 MiB device PVE asked for"; else bad "cloud-init device size is $SZ"; fi

echo "== 2. qm cloudinit update writes the ISO into the Lightbits volume =="
qm cloudinit update "$VMID" >/dev/null
if iso_userdata "$DEV" | grep -q 'e2e-first'; then ok "NoCloud ISO with the user-data was written INTO the Lightbits volume"; else bad "no user-data readable from the cloud-init volume after cloudinit update"; fi
qm set "$VMID" --ciuser e2e-second >/dev/null
qm cloudinit update "$VMID" >/dev/null
UD="$(iso_userdata "$DEV")"
if grep -q 'e2e-second' <<<"$UD" && ! grep -q 'e2e-first' <<<"$UD"; then ok "a second update regenerates the ISO in place"; else bad "ISO not regenerated (user-data: $(echo "$UD" | head -c 200))"; fi
deactivate "$CI"
if [ -L "/dev/lightbits/$STORAGE/vm-${VMID}-cloudinit" ]; then bad "symlink still present after deactivation"; else ok "deactivation removes the symlink"; fi

echo "== 3. listing shows the drive once, under PVE's name; rescan adds no duplicate =="
LIST="$(pvesm list "$STORAGE" --vmid "$VMID")"
N_CI="$(grep -c "vm-${VMID}-cloudinit" <<<"$LIST" || true)"
N_ALL="$(grep -c "^${STORAGE}:" <<<"$LIST" || true)"
if [ "$N_CI" = 1 ] && [ "$N_ALL" = 2 ]; then ok "pvesm list: scsi0 + vm-${VMID}-cloudinit, nothing else"; else bad "pvesm list for $VMID: $LIST"; fi
if ! qm rescan --vmid "$VMID" >/dev/null 2>&1; then bad "qm rescan --vmid $VMID failed"
elif qm config "$VMID" | grep -q '^unused'; then bad "qm rescan added an unused disk: $(qm config "$VMID" | grep '^unused')"
else ok "qm rescan adds no unused duplicate of the cloud-init drive"; fi
CL="$(cluster_vols_of "$VMID")"
if [ "$(wc -l <<<"$CL")" = 2 ] && grep -q ' cloudinit$' <<<"$CL" && grep -q -- "-${VMID}-.*-cloudinit cloudinit" <<<"$CL"; then ok "cluster-side: two volumes for $VMID, the cloud-init one labelled pveRole=cloudinit"; else bad "cluster-side volumes for $VMID: $CL"; fi

echo "== 4. full clone onto $STORAGE: the clone gets a recognised cloud-init drive =="
qm clone "$VMID" "$CLONE_VMID" --full --storage "$STORAGE" --name "$TEST_VM_NAME" >/dev/null
CCI="$(ci_volid "$CLONE_VMID")"
echo "   clone ide2: $CCI"
if [ "$CCI" = "${STORAGE}:vm-${CLONE_VMID}-cloudinit" ]; then ok "clone: cloud-init drive relocated onto $STORAGE under PVE's name"; else bad "clone cloud-init volid is '$CCI'"; fi
if qm cloudinit dump "$CLONE_VMID" user 2>/dev/null | grep -q 'e2e-second'; then ok "clone: PVE recognises its cloud-init drive"; else bad "clone: qm cloudinit dump fails"; fi
qm start "$CLONE_VMID" >/dev/null
sleep 3
if [ "$(qm status "$CLONE_VMID" | awk '{print $2}')" = running ] && [ -L "/dev/lightbits/$STORAGE/vm-${CLONE_VMID}-cloudinit" ]; then
    ok "clone starts; cloud-init volume activated (symlink present)"
    CDEV="$(readlink -f "/dev/lightbits/$STORAGE/vm-${CLONE_VMID}-cloudinit")"
    if iso_userdata "$CDEV" | grep -q 'e2e-second'; then ok "clone: ISO generated into its own Lightbits volume on start"; else bad "clone: no user-data on its cloud-init volume"; fi
else
    bad "clone did not start with its cloud-init volume activated"
fi
qm stop "$CLONE_VMID" >/dev/null
sleep 2
if [ -L "/dev/lightbits/$STORAGE/vm-${CLONE_VMID}-cloudinit" ]; then bad "clone: symlink still present after stop"; else ok "clone: stop deactivates the cloud-init volume"; fi

echo "== 5. backup + restore onto $STORAGE =="
if pvesm status --content backup 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$BACKUP_STORAGE"; then
    BEFORE="$(backups_of "$VMID")"
    vzdump "$VMID" --storage "$BACKUP_STORAGE" --mode stop --compress zstd --quiet 1 >/dev/null
    BACKUP_VOLID="$(comm -13 <(echo "$BEFORE") <(backups_of "$VMID") | head -1)"
    if [ -n "$BACKUP_VOLID" ]; then
        echo "   backup: $BACKUP_VOLID"
        qmrestore "$(pvesm path "$BACKUP_VOLID")" "$RESTORE_VMID" --storage "$STORAGE" >/dev/null 2>&1
        RCI="$(ci_volid "$RESTORE_VMID")"
        echo "   restored ide2: $RCI"
        if [ "$RCI" = "${STORAGE}:vm-${RESTORE_VMID}-cloudinit" ]; then ok "restore: cloud-init drive on $STORAGE under PVE's name"; else bad "restore cloud-init volid is '$RCI'"; fi
        if qm cloudinit dump "$RESTORE_VMID" user 2>/dev/null | grep -q 'e2e-second'; then ok "restore: PVE recognises its cloud-init drive"; else bad "restore: qm cloudinit dump fails"; fi
        # The restored volume itself must take the regenerated ISO, as the clone's did.
        qm cloudinit update "$RESTORE_VMID" >/dev/null
        RDEV="$(activate "$RCI")"
        if iso_userdata "$RDEV" | grep -q 'e2e-second'; then ok "restore: ISO regenerated into the restored Lightbits volume"; else bad "restore: no user-data on the restored cloud-init volume"; fi
        deactivate "$RCI"
    else
        bad "vzdump produced no new backup of $VMID on $BACKUP_STORAGE"
    fi
else
    echo "SKIP: storage '$BACKUP_STORAGE' has no backup content; restore path not tested"
fi

echo "== 6. destroy --purge leaves nothing behind =="
for v in "$VMID" "$CLONE_VMID" "$RESTORE_VMID"; do
    is_our_vm "$v" || continue
    qm destroy "$v" --purge 1 >/dev/null
    if pvesm list "$STORAGE" | grep -q "vm-${v}-"; then bad "destroy $v: volumes still listed"; else ok "destroy $v: nothing left in the storage listing"; fi
    LEFT="$(cluster_vols_of "$v")"
    if [ -z "$LEFT" ]; then ok "destroy $v: no volume labelled pveVmid=$v left on the cluster"; else bad "destroy $v: leaked on the cluster: $LEFT"; fi
    if [ -L "/dev/lightbits/$STORAGE/vm-${v}-cloudinit" ]; then bad "destroy $v: dangling cloud-init symlink"; fi
done
trap - EXIT
rm_backup

echo
echo "== cloud-init e2e: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
