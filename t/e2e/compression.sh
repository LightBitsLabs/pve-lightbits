#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for the lb_compression storage option (issue #70), run
# ON a Proxmox VE node that already has a configured Lightbits storage. It
# checks, against the volume as LightOS reports it:
#
#   1. unset: a new disk gets the cluster default (compression "false");
#   2. lb_compression 1: a new VM disk and a new cloud-init drive are created
#      with compression "true", and the disk works (VM starts and stops);
#   3. existing disks are not touched when the option changes;
#   4. lb_compression 0: a new disk is created with compression "false";
#   5. a resize keeps a disk's compression setting.
#
# The storage's original lb_compression value is restored on exit, and only
# VMs named lb-compression-e2e are ever destroyed. While it runs, the option
# on the storage entry changes, and any disk created on that entry by someone
# else picks the test value up: run it against an entry used for testing.
#
# A pass is exit code 0 with a last line "== N passed, 0 failed ==". The
# script stops at the first command that fails (set -e), so the absence of
# FAIL lines alone is not a pass.
#
# Usage:
#   STORAGE=lb-storage VMID=9010 ./t/e2e/compression.sh
#
# Defaults: STORAGE=lb-storage, VMID=9010, DISK_GB=1.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9010}"
DISK_GB="${DISK_GB:-1}"
TEST_VM_NAME="lb-compression-e2e"   # ownership marker: we only ever destroy VMs with this name

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

# --- storage credentials + API client (same approach as vanished_resource.sh) --
scfg_val() {
    awk -v s="$1" -v k="$2" '
        /^[a-z]+: /   { in_blk = ($0 == "lightbits: " s) ; next }
        in_blk && $1 == k { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); print; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
# lb_jwt is a sensitive property: once migrated it lives in /etc/pve/priv/storage/<storeid>.pw, not storage.cfg.
[ -n "$JWT" ] || JWT="$(head -n1 "/etc/pve/priv/storage/$STORAGE.pw" 2>/dev/null)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
[ -n "$API_HOSTS" ] && [ -n "$JWT" ] || {
    echo "ABORT: storage '$STORAGE' not found in /etc/pve/storage.cfg (or missing lb_api_host/lb_jwt)." >&2
    exit 1
}
api() {
    local m="$1" p="$2" h out code
    for h in ${API_HOSTS//,/ }; do
        out="$(curl -sk -m 20 -H "Authorization: Bearer $JWT" -X "$m" \
            -w $'\n%{http_code}' "https://$h$p" 2>/dev/null)" || continue
        code="${out##*$'\n'}"
        case "$code" in
            2*) printf '%s' "${out%$'\n'*}"; return 0 ;;
            4*) printf '%s' "${out%$'\n'*}"; return 1 ;;
        esac
    done
    return 1
}

# The volume's compression field as LightOS reports it ("true"/"false").
compression_of_uuid() {
    api GET "/api/v2/volumes/$1?projectName=$PROJECT" \
        | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("compression","")).lower())'
}
# Same for the VM's cloud-init drive: the Available volume named for this VM
# and its current vmgenid (a volume still being deleted from an earlier run
# with the same VM id must not be picked).
compression_of_cloudinit() {
    local gen
    gen="$(qm config "$1" | awk '/^vmgenid:/{print $2; exit}')"
    api GET "/api/v2/volumes?projectName=$PROJECT" | python3 -c '
import json,sys
want = "vm-'"$1"'-'"$gen"'-cloudinit"
vols = json.load(sys.stdin).get("volumes") or []
m = [v for v in vols if v.get("name") == want and v.get("state") == "Available"]
print(str(m[0].get("compression","")).lower() if len(m) == 1 else "")'
}
# Is the volume gone from the cluster? Only a 404, or a Deleting/Deleted state,
# counts: an API error is not evidence of anything.
vol_gone() {
    local h out code st
    for h in ${API_HOSTS//,/ }; do
        out="$(curl -sk -m 20 -H "Authorization: Bearer $JWT" -w $'\n%{http_code}' \
            "https://$h/api/v2/volumes/$1?projectName=$PROJECT" 2>/dev/null)" || continue
        code="${out##*$'\n'}"
        [ "$code" = 404 ] && return 0
        if [ "$code" = 200 ]; then
            st="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' <<<"${out%$'\n'*}")"
            case "$st" in Deleting|Deleted) return 0 ;; *) return 1 ;; esac
        fi
    done
    return 1
}

ORIG="$(scfg_val "$STORAGE" lb_compression)"
restore_option() {
    if [ -n "$ORIG" ]; then pvesm set "$STORAGE" --lb_compression "$ORIG" >/dev/null
    else pvesm set "$STORAGE" --delete lb_compression >/dev/null 2>&1 || true; fi
}
is_our_vm() {
    local name
    name="$(qm config "$1" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')" || return 1
    [ "$name" = "$TEST_VM_NAME" ]
}
cleanup() {
    if is_our_vm "$VMID"; then
        qm stop "$VMID" >/dev/null 2>&1 || true
        qm destroy "$VMID" --purge 1 >/dev/null 2>&1 || true
    fi
    restore_option
}
trap cleanup EXIT

if qm config "$VMID" >/dev/null 2>&1 && ! is_our_vm "$VMID"; then
    echo "ABORT: VM $VMID already exists and is not the test VM '$TEST_VM_NAME'; refusing to destroy it." >&2
    exit 1
fi
cleanup
trap cleanup EXIT

disk_uuid() {
    qm config "$VMID" | awk -F'[ ,]' -v d="$1:" '$1==d{print $2}' \
        | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}
expect() {   # expect <label> <want> <got>
    if [ "$3" = "$2" ]; then ok "$1: compression $3"; else bad "$1: compression '$3', expected '$2'"; fi
}

qm create "$VMID" --memory 512 --scsihw virtio-scsi-single --name "$TEST_VM_NAME" >/dev/null

# ── 1. option unset: cluster default ───────────────────────────────────────────
echo "== lb_compression unset =="
pvesm set "$STORAGE" --delete lb_compression >/dev/null 2>&1 || true
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_GB}" >/dev/null
U0="$(disk_uuid scsi0)"
expect "unset, new disk scsi0 (cluster default)" false "$(compression_of_uuid "$U0")"

# ── 2. option on: new VM disk and cloud-init drive are compressed ──────────────
echo "== lb_compression 1 =="
pvesm set "$STORAGE" --lb_compression 1 >/dev/null
if [ "$(scfg_val "$STORAGE" lb_compression)" = "1" ]; then
    ok "pvesm set stores lb_compression 1 in storage.cfg"
else
    bad "lb_compression 1 not found in the storage.cfg entry"
fi
qm set "$VMID" --scsi1 "${STORAGE}:${DISK_GB}" >/dev/null
U1="$(disk_uuid scsi1)"
expect "lb_compression 1, new disk scsi1" true "$(compression_of_uuid "$U1")"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" >/dev/null
expect "lb_compression 1, new cloud-init drive" true "$(compression_of_cloudinit "$VMID")"

if qm start "$VMID" >/dev/null 2>&1 && qm stop "$VMID" >/dev/null 2>&1; then
    ok "VM with a compressed disk starts and stops"
else
    bad "VM with a compressed disk failed to start or stop"
fi

# ── 3. existing disks untouched ────────────────────────────────────────────────
expect "existing disk scsi0 unchanged after enabling" false "$(compression_of_uuid "$U0")"

# ── 4. option off: explicit false ──────────────────────────────────────────────
echo "== lb_compression 0 =="
pvesm set "$STORAGE" --lb_compression 0 >/dev/null
qm set "$VMID" --scsi2 "${STORAGE}:${DISK_GB}" >/dev/null
U2="$(disk_uuid scsi2)"
expect "lb_compression 0, new disk scsi2" false "$(compression_of_uuid "$U2")"
expect "existing disk scsi1 unchanged after disabling" true "$(compression_of_uuid "$U1")"

# ── 5. resize keeps the setting ────────────────────────────────────────────────
qm disk resize "$VMID" scsi1 +1G >/dev/null
expect "disk scsi1 after a resize" true "$(compression_of_uuid "$U1")"

# ── cleanup: destroy leaves nothing behind ─────────────────────────────────────
qm destroy "$VMID" --purge 1 >/dev/null
left=0
for u in "$U0" "$U1" "$U2"; do
    vol_gone "$u" || left=$((left+1))
done
if [ "$left" = 0 ]; then ok "qm destroy removed all test volumes"; else bad "$left test volume(s) not confirmed gone from the cluster"; fi
restore_option
trap - EXIT

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
