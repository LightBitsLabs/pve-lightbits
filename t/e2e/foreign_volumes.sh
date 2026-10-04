#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for the foreign-volume ownership guard, run ON a Proxmox
# VE node that already has a configured Lightbits storage. It proves that a
# volume living in the storage's project but NOT created by the plugin (think:
# an application server's volume created with lbcli) is
#
#   1. never listed by `pvesm list $STORAGE` (so PVE never shows it as an
#      "unused disk" with a Remove button),
#   2. refused by `pvesm free` -- the volume still exists afterwards,
#   3. refused when attached to a VM by volid (`qm set --scsiN`) -- its ACL is
#      byte-identical afterwards (activation used to append this host's NQN),
#
# while a plugin-created volume on the same storage still allocates and frees
# normally. A "decoy" variant carrying only a pveNode label equal to this
# storage's owner id is covered too (the plugin never writes that label alone).
#
# Like the other e2e scripts this contains no addresses or credentials: API
# host and JWT are read from the storage's definition in /etc/pve/storage.cfg.
# Needs curl and python3 (both present on stock PVE).
#
# Usage:
#   STORAGE=lb-storage VMID=9003 ./t/e2e/foreign_volumes.sh
#
# Defaults: STORAGE=lb-storage, VMID=9003 (a throwaway VM is created and
# destroyed; the script refuses to touch an existing VM with another name).
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9003}"
TEST_VM_NAME="lb-foreign-e2e"
FOREIGN_NAME="foreign-e2e-$$"
DECOY_NAME="foreign-decoy-e2e-$$"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

T_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if command -v prove >/dev/null 2>&1 && ls "$T_DIR"/*.t >/dev/null 2>&1; then
    echo "== running unit tests before e2e =="
    prove -I "$T_DIR/stubs" "$T_DIR"/*.t || { echo "ABORT: unit tests failed — not running e2e." >&2; exit 1; }
fi

scfg_val() {
    awk -v s="$1" -v k="$2" '
        /^[a-z]+: /   { in_blk = ($0 == "lightbits: " s) ; next }
        in_blk && $1 == k { print $2; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
OWNER="$(scfg_val "$STORAGE" lb_owner_id)"; OWNER="${OWNER:-$(hostname)}"
[ -n "$API_HOSTS" ] && [ -n "$JWT" ] || { echo "ABORT: storage '$STORAGE' not in /etc/pve/storage.cfg" >&2; exit 1; }

api() {   # api <METHOD> <path> [json-body]
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
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
vol_fp() {   # stable fingerprint incl. ACL of a volume by uuid; empty if gone
    api GET "/api/v2/volumes/$1?projectName=$PROJECT" 2>/dev/null | python3 -c '
import json,sys
try: v=json.load(sys.stdin)
except Exception: raise SystemExit
if not v.get("UUID"): raise SystemExit
print(json.dumps({k: v.get(k) for k in ("name","UUID","size","replicaCount","acl","labels","state")}, sort_keys=True))'
}
wait_available() { for _ in $(seq 1 60); do [ "$(api GET "/api/v2/volumes/$1?projectName=$PROJECT" | jget 'd.get("state")')" = Available ] && return 0; sleep 1; done; return 1; }

is_our_vm() { [ "$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')" = "$TEST_VM_NAME" ]; }
FOREIGN_UUID=""; DECOY_UUID=""
cleanup() {
    if is_our_vm; then qm destroy "$VMID" --purge 1 >/dev/null 2>&1 || true; fi
    for u in "$FOREIGN_UUID" "$DECOY_UUID"; do
        [ -n "$u" ] && api DELETE "/api/v2/volumes/$u?projectName=$PROJECT" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT
if qm config "$VMID" >/dev/null 2>&1 && ! is_our_vm; then
    echo "ABORT: VMID $VMID exists and is not ours; pick another VMID." >&2; exit 1
fi

REPLICAS="$(scfg_val "$STORAGE" lb_replica_count)"; REPLICAS="${REPLICAS:-1}"
echo "== creating foreign volumes in project '$PROJECT' (outside the plugin) =="
FOREIGN_UUID="$(api POST "/api/v2/volumes" "{\"projectName\":\"$PROJECT\",\"name\":\"$FOREIGN_NAME\",\"size\":\"1073741824\",\"replicaCount\":$REPLICAS,\"acl\":{\"values\":[\"nqn.2014-08.org.nvmexpress:uuid:00000000-e2e0-4000-8000-00000000f0e1\"]}}" | jget 'd["UUID"]')"
DECOY_UUID="$(api POST "/api/v2/volumes" "{\"projectName\":\"$PROJECT\",\"name\":\"$DECOY_NAME\",\"size\":\"1073741824\",\"replicaCount\":$REPLICAS,\"acl\":{\"values\":[\"ALLOW_NONE\"]},\"labels\":[{\"key\":\"pveNode\",\"value\":\"$OWNER\"}]}" | jget 'd["UUID"]')"
[ -n "$FOREIGN_UUID" ] && [ -n "$DECOY_UUID" ] || { echo "ABORT: could not create test volumes" >&2; exit 1; }
wait_available "$FOREIGN_UUID" && wait_available "$DECOY_UUID" || { echo "ABORT: test volumes never became Available" >&2; exit 1; }
FP_FOREIGN="$(vol_fp "$FOREIGN_UUID")"; FP_DECOY="$(vol_fp "$DECOY_UUID")"
echo "foreign: $FOREIGN_UUID  decoy: $DECOY_UUID"

# 1. not listed
LISTED="$(pvesm list "$STORAGE" | awk 'NR>1 {print $1}')"
grep -q "$FOREIGN_UUID" <<<"$LISTED" && bad "foreign volume appears in pvesm list" || ok "foreign volume is not listed by pvesm list"
grep -q "$DECOY_UUID"   <<<"$LISTED" && bad "decoy (pveNode-only label) appears in pvesm list" || ok "decoy volume is not listed by pvesm list"
grep -q ":vm-0-" <<<"$LISTED" && bad "listing still contains vm-0 (unowned) volids" || ok "listing contains no vm-0 volids"

# 2. pvesm free refused
for pair in "$FOREIGN_UUID foreign" "$DECOY_UUID decoy"; do set -- $pair
    # pvesm prints the plugin's error but may still exit 0 (the free runs as a
    # task), so judge by the message and by the volume's continued existence.
    out="$(pvesm free "$STORAGE:vm-0-$1" 2>&1)" || true
    grep -q "refusing to delete" <<<"$out" && ok "pvesm free of the $2 volume is refused with the ownership error" || bad "pvesm free of the $2 volume did not report the ownership refusal: $out"
    [ -n "$(vol_fp "$1")" ] && ok "  $2 volume still exists" || bad "  $2 volume is GONE"
done

# 3. attach by volid refused, ACL untouched
qm create "$VMID" --name "$TEST_VM_NAME" --memory 256 --cores 1 --scsihw virtio-scsi-pci >/dev/null
if out="$(qm set "$VMID" --scsi1 "$STORAGE:vm-0-$FOREIGN_UUID" 2>&1)"; then bad "attaching the foreign volume by volid succeeded: $out"
else grep -q "refusing to activate" <<<"$out" && ok "attaching the foreign volume by volid is refused with the ownership error" || bad "attach failed for another reason: $out"; fi
[ "$(vol_fp "$FOREIGN_UUID")" = "$FP_FOREIGN" ] && ok "foreign volume (incl. ACL) is byte-identical after the attach attempt" || bad "foreign volume changed: $(vol_fp "$FOREIGN_UUID")"
[ "$(vol_fp "$DECOY_UUID")" = "$FP_DECOY" ] && ok "decoy volume unchanged" || bad "decoy volume changed"
qm config "$VMID" | grep -q '^scsi1:' && bad "foreign volid ended up in the VM config" || ok "VM config does not reference the foreign volume"

# 4. the plugin's own volumes still work on the same storage
if qm set "$VMID" --scsi0 "$STORAGE:1" >/dev/null 2>&1; then ok "plugin-created volume allocates on the same storage"
    OWN_VOLID="$(qm config "$VMID" | awk -F'[ ,]' '/^scsi0:/{print $2}')"
    grep -q "$OWN_VOLID" <<<"$(pvesm list "$STORAGE" | awk 'NR>1 {print $1}')" && ok "  ...and is listed" || bad "  ...but is not listed"
    qm destroy "$VMID" --purge 1 >/dev/null 2>&1 && ok "  ...and is freed by qm destroy --purge" || bad "  ...qm destroy --purge failed"
    grep -q "$OWN_VOLID" <<<"$(pvesm list "$STORAGE" | awk 'NR>1 {print $1}')" && bad "  own volume still listed after purge" || ok "  own volume gone after purge"
else bad "could not allocate a plugin volume on $STORAGE"; fi

echo; echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
