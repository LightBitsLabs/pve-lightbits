#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for vanished-resource handling, run ON a Proxmox VE
# node that already has a configured Lightbits storage. It deletes a volume
# and a snapshot behind Proxmox's back (directly via the LightOS API, using
# the credentials of the configured storage) and asserts the plugin:
#
#   1. reports a vanished volume as GONE — volume_size_info dies naming the
#      missing resource instead of reporting a 0-byte disk;
#   2. refuses a rollback to a vanished snapshot with an error naming the
#      missing snapshot, instead of comparing two bogus sizes and either
#      allowing it or blaming a "resize";
#   3. still treats "already gone" as success on the idempotent delete paths —
#      destroying a VM whose volume vanished, and deleting a snapshot config
#      whose cluster snapshot vanished, must both succeed.
#
# Timing matters too: the failures in (1) and (2) must be immediate, not the
# outcome of a 30-60 iteration polling timeout.
#
# Usage:
#   STORAGE=lb-storage VMID_A=9005 VMID_B=9006 ./t/e2e/vanished_resource.sh
#
# Defaults: STORAGE=lb-storage, VMID_A=9005, VMID_B=9006, DISK_GB=1.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID_A="${VMID_A:-9005}"
VMID_B="${VMID_B:-9006}"
DISK_GB="${DISK_GB:-1}"
TEST_VM_NAME="lb-vanish-e2e"   # ownership marker: we only ever destroy VMs with this name

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

# --- storage credentials + API client (same approach as project_isolation.sh) --
scfg_val() {
    awk -v s="$1" -v k="$2" '
        /^[a-z]+: /   { in_blk = ($0 == "lightbits: " s) ; next }
        in_blk && $1 == k { print $2; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
[ -n "$API_HOSTS" ] && [ -n "$JWT" ] || {
    echo "ABORT: storage '$STORAGE' not found in /etc/pve/storage.cfg (or missing lb_api_host/lb_jwt)." >&2
    exit 1
}
api() {
    local m="$1" p="$2" b="${3:-}" h out code
    local -a args=(-sk -m 20 -H "Authorization: Bearer $JWT" -X "$m")
    [ -n "$b" ] && args+=(-H "Content-Type: application/json" -d "$b")
    for h in ${API_HOSTS//,/ }; do
        out="$(curl "${args[@]}" -w $'\n%{http_code}' "https://$h$p" 2>/dev/null)" || continue
        code="${out##*$'\n'}"
        case "$code" in
            2*) printf '%s' "${out%$'\n'*}"; return 0 ;;
            4*) printf '%s' "${out%$'\n'*}"; return 1 ;;
        esac
    done
    return 1
}

is_our_vm() {
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

volid()    { qm config "$1" | awk -F'[ ,]' '/^scsi0:/{print $2}'; }
vol_uuid() { grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' <<<"$1"; }
mkvm() {
    qm create "$1" --memory 512 --scsihw virtio-scsi-single --name "$TEST_VM_NAME" >/dev/null
    qm set "$1" --scsi0 "${STORAGE}:${DISK_GB}" >/dev/null
}
for id in "$VMID_A" "$VMID_B"; do
    if qm config "$id" >/dev/null 2>&1 && ! is_our_vm "$id"; then
        echo "ABORT: VM $id already exists and is not the test VM '$TEST_VM_NAME'; refusing to destroy it." >&2
        exit 1
    fi
done
cleanup

# ── 1+2. volume vanishes out of band ───────────────────────────────────────────
echo "== volume deleted outside Proxmox =="
mkvm "$VMID_A"
VOL_A="$(volid "$VMID_A")"; UUID_A="$(vol_uuid "$VOL_A")"
api DELETE "/api/v2/volumes/$UUID_A?projectName=$PROJECT" >/dev/null \
    || { echo "ABORT: could not delete volume $UUID_A out of band." >&2; exit 1; }
# The deletion is async on the cluster; wait until a GET really 404s so the
# assertions below measure the plugin, not the deletion's own progress.
for _ in $(seq 1 30); do
    api GET "/api/v2/volumes/$UUID_A?projectName=$PROJECT" >/dev/null 2>&1 || break
    sleep 2
done

start=$SECONDS
ERR="$(perl -MPVE::Storage -e '
    my $c = PVE::Storage::config();
    my $s = PVE::Storage::volume_size_info($c, $ARGV[0], 15);
    print "SIZE=$s\n";' "$VOL_A" 2>&1)" || true
took=$(( SECONDS - start ))
if grep -q "no longer exists" <<<"$ERR"; then
    ok "volume_size_info reports the vanished volume as gone (in ${took}s)"
elif grep -q "SIZE=0" <<<"$ERR"; then
    bad "volume_size_info reported a vanished volume as a 0-byte disk (the pre-fix failure mode)"
else
    bad "volume_size_info failed for the wrong reason: $(head -1 <<<"$ERR")"
fi
[ "$took" -lt 30 ] \
    && ok "the vanished-volume failure is immediate, not a polling timeout (${took}s)" \
    || bad "vanished-volume handling took ${took}s — looks like a polling timeout"

# Idempotent path preserved: destroying the VM whose volume vanished succeeds.
if qm destroy "$VMID_A" --purge 1 >/dev/null 2>&1; then
    ok "qm destroy still succeeds when the volume is already gone (free_image tolerance)"
else
    bad "qm destroy failed on an already-deleted volume — 404 tolerance regressed"
fi

# ── 3+4. snapshot vanishes out of band ─────────────────────────────────────────
echo "== snapshot deleted outside Proxmox =="
mkvm "$VMID_B"
VOL_B="$(volid "$VMID_B")"; UUID_B="$(vol_uuid "$VOL_B")"
qm snapshot "$VMID_B" s1 >/dev/null
SNAP_UUID="$(api GET "/api/v2/projects/$PROJECT/snapshots" | python3 -c '
import json,sys
d = json.load(sys.stdin)
snaps = d.get("snapshots") or []
m = [s["UUID"] for s in snaps if s.get("name") == "snap-'"$UUID_B"'-s1"]
print(m[0] if m else "")')"
[ -n "$SNAP_UUID" ] || { echo "ABORT: could not find the cluster snapshot for s1." >&2; exit 1; }
api DELETE "/api/v2/projects/$PROJECT/snapshots/$SNAP_UUID" >/dev/null \
    || { echo "ABORT: could not delete snapshot $SNAP_UUID out of band." >&2; exit 1; }
for _ in $(seq 1 30); do
    api GET "/api/v2/projects/$PROJECT/snapshots/$SNAP_UUID" >/dev/null 2>&1 || break
    sleep 2
done

start=$SECONDS
ERR="$(qm rollback "$VMID_B" s1 2>&1)" && RB_RC=0 || RB_RC=$?
took=$(( SECONDS - start ))
# Either accurate refusal is acceptable: snapshot-name resolution fires first
# when the snapshot is long gone ("not found for volume"), and _get_existing
# covers the narrower race where it vanishes after resolution ("no longer
# exists"). What must never happen is the pre-fix pair: a green-lit rollback,
# or a refusal blaming a "resize" because two bogus sizes were compared.
if [ "$RB_RC" = "0" ]; then
    bad "rollback to a vanished snapshot was allowed (the pre-fix green-light failure mode)"
elif grep -qE "no longer exists|not found for volume" <<<"$ERR"; then
    ok "rollback to a vanished snapshot is refused, naming the missing snapshot (in ${took}s)"
elif grep -qi "resized" <<<"$ERR"; then
    bad "rollback refused with the misleading pre-fix 'resized' message: $(head -1 <<<"$ERR")"
else
    bad "rollback refused for the wrong reason: $(head -1 <<<"$ERR")"
fi

# Idempotent path preserved: deleting the snapshot config whose cluster
# snapshot vanished succeeds and clears the PVE-side entry.
if qm delsnapshot "$VMID_B" s1 >/dev/null 2>&1 && ! qm listsnapshot "$VMID_B" | grep -q s1; then
    ok "qm delsnapshot still succeeds when the snapshot is already gone (_delete_snapshot tolerance)"
else
    bad "qm delsnapshot failed on an already-deleted snapshot — 404 tolerance regressed"
fi

qm destroy "$VMID_B" --purge 1 >/dev/null
trap - EXIT

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
