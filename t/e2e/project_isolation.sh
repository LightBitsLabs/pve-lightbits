#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for cross-project isolation, run ON a Proxmox VE node
# that already has a configured Lightbits storage. It proves that plugin
# operations (create / snapshot / resize / delete) in one LightOS project can
# never touch volumes living in another project, in either direction:
#
#   1. Creates a scratch project with a "bystander" volume in it (directly via
#      the LightOS API, using the credentials of the already-configured
#      storage), runs a full volume lifecycle on $STORAGE, and asserts the
#      bystander's attributes are bit-identical afterwards.
#   2. Adds a second, temporary PVE storage bound to the scratch project, runs
#      a lifecycle there, and asserts the original project's volume set is
#      unchanged and that each storage only ever lists its own project.
#
# Like snapshots.sh, this script contains no cluster addresses or credentials:
# API host and JWT are read from the storage's own definition in
# /etc/pve/storage.cfg. Needs curl and python3 (both present on stock PVE).
#
# NOTE: the resize steps activate the volume. On hosts affected by the known
# discovery-client reconnect issue (daemon ignores config rewrites after a
# full subsystem disconnect), keep another volume on the same storage active
# for the duration of the run, or restart discovery-client first.
#
# Usage:
#   STORAGE=lb-storage VMID=9002 ./t/e2e/project_isolation.sh
#
# Defaults: STORAGE=lb-storage, VMID=9002, DISK_GB=1, ISO_PROJECT=lb-e2e-iso,
#           ISO_STORAGE=lb-e2e-iso.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9002}"
DISK_GB="${DISK_GB:-1}"
ISO_PROJECT="${ISO_PROJECT:-lb-e2e-iso}"
ISO_STORAGE="${ISO_STORAGE:-lb-e2e-iso}"
TEST_VM_NAME="lb-iso-e2e"      # ownership marker: we only ever destroy a VM with this name
BYSTANDER="iso-bystander-e2e"  # ownership marker: the only volume we delete by name
FAKE_NQN="nqn.2014-08.org.nvmexpress:uuid:00000000-fake-0000-0000-00000000beef"

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

# --- read the configured storage's connection details from storage.cfg -------
scfg_val() {   # scfg_val <storage-id> <key>
    awk -v s="$1" -v k="$2" '
        /^[a-z]+: /   { in_blk = ($0 == "lightbits: " s) ; next }
        in_blk && $1 == k { print $2; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
NVME_HOSTS="$(scfg_val "$STORAGE" lb_nvme_host)"
BASE_PROJECT="$(scfg_val "$STORAGE" lb_project)"; BASE_PROJECT="${BASE_PROJECT:-default}"
REPLICAS="$(scfg_val "$STORAGE" lb_replica_count)"; REPLICAS="${REPLICAS:-1}"
[ -n "$API_HOSTS" ] && [ -n "$JWT" ] || {
    echo "ABORT: storage '$STORAGE' not found in /etc/pve/storage.cfg (or missing lb_api_host/lb_jwt)." >&2
    exit 1
}

# --- minimal LightOS API client (first healthy endpoint wins) ----------------
api() {   # api <METHOD> <path> [json-body] -> body on stdout; rc 0 on 2xx
    local m="$1" p="$2" b="${3:-}" h out code
    local -a args=(-sk -m 20 -H "Authorization: Bearer $JWT" -X "$m")
    [ -n "$b" ] && args+=(-H "Content-Type: application/json" -d "$b")
    for h in ${API_HOSTS//,/ }; do
        out="$(curl "${args[@]}" -w $'\n%{http_code}' "https://$h$p" 2>/dev/null)" || continue
        code="${out##*$'\n'}"
        printf '%s' "${out%$'\n'*}"
        case "$code" in 2*) return 0 ;; *) return 1 ;; esac
    done
    return 1
}
# Stable-attribute fingerprint of the bystander volume (fails the run if absent).
fingerprint() {
    api GET "/api/v2/volumes/$BY_UUID?projectName=$ISO_PROJECT" | python3 -c '
import json,sys
v = json.load(sys.stdin)
print(json.dumps({k: v.get(k) for k in
    ("name","UUID","state","size","replicaCount","acl","projectName")}, sort_keys=True))'
}
proj_vol_uuids() {   # proj_vol_uuids <project> -> sorted UUID list
    api GET "/api/v2/volumes?projectName=$1" | python3 -c '
import json,sys
d = json.load(sys.stdin)
vols = d.get("volumes") or (d if isinstance(d, list) else [])
print("\n".join(sorted(v["UUID"] for v in vols)))'
}

is_our_vm() {
    local name
    name="$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')" || return 1
    [ "$name" = "$TEST_VM_NAME" ]
}
cleanup() {
    if is_our_vm; then qm destroy "$VMID" --purge 1 >/dev/null 2>&1 || true; fi
    pvesm remove "$ISO_STORAGE" >/dev/null 2>&1 || true
    if [ -n "${BY_UUID:-}" ]; then
        api DELETE "/api/v2/volumes/$BY_UUID?projectName=$ISO_PROJECT" >/dev/null 2>&1 || true
    fi
    # Volume deletion is async and deleted volumes can linger in the listing
    # for a while; the project can only be removed once its listing is empty.
    local n
    for _ in $(seq 1 60); do
        n="$(api GET "/api/v2/volumes?projectName=$ISO_PROJECT" 2>/dev/null | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
print(len(d.get("volumes") or []))' 2>/dev/null || echo -1)"
        [ "$n" = "0" ] && break
        sleep 2
    done
    # Even after the listing empties, LightOS drains deleted volume objects for
    # a while longer and refuses the project delete until then — retry it.
    local deleted=""
    for _ in $(seq 1 36); do
        if api DELETE "/api/v2/projects/$ISO_PROJECT" >/dev/null 2>&1; then deleted=1; break; fi
        sleep 5
    done
    [ -n "$deleted" ] \
        || echo "NOTE: could not delete scratch project '$ISO_PROJECT' within 3 minutes; remove it manually." >&2
}
trap cleanup EXIT

# --- setup: scratch project + bystander volume --------------------------------
echo "== setup: project '$ISO_PROJECT' + bystander volume (base project: '$BASE_PROJECT') =="
# Refuse to run against a project that already exists — we delete it at the end.
if api GET "/api/v2/projects/$ISO_PROJECT" >/dev/null 2>&1; then
    echo "ABORT: project '$ISO_PROJECT' already exists; refusing to reuse (it is deleted on cleanup). Set ISO_PROJECT to an unused name." >&2
    trap - EXIT
    exit 1
fi
api POST "/api/v2/projects" "{\"name\":\"$ISO_PROJECT\"}" >/dev/null || { echo "ABORT: could not create project '$ISO_PROJECT'." >&2; trap - EXIT; exit 1; }
BY_UUID="$(api POST "/api/v2/volumes" "{\"name\":\"$BYSTANDER\",\"size\":\"1073741824\",\"replicaCount\":$REPLICAS,\"projectName\":\"$ISO_PROJECT\",\"acl\":{\"values\":[\"$FAKE_NQN\"]}}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["UUID"])')"
for _ in $(seq 1 30); do
    state="$(api GET "/api/v2/volumes/$BY_UUID?projectName=$ISO_PROJECT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))')"
    [ "$state" = "Available" ] && break
    sleep 2
done
[ "$state" = "Available" ] || { echo "ABORT: bystander volume never became Available (state: $state)." >&2; exit 1; }
BASELINE="$(fingerprint)"
echo "   bystander: $BY_UUID ($ISO_PROJECT)"

if qm config "$VMID" >/dev/null 2>&1 && ! is_our_vm; then
    echo "ABORT: VM $VMID already exists and is not the test VM '$TEST_VM_NAME'; refusing to destroy it. Set VMID to an unused id." >&2
    exit 1
fi

# --- 1. lifecycle in the base project must not touch the bystander -----------
echo "== lifecycle on '$STORAGE' ($BASE_PROJECT) =="
qm create "$VMID" --memory 512 --scsihw virtio-scsi-single --name "$TEST_VM_NAME" >/dev/null
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_GB}" >/dev/null
qm snapshot "$VMID" s1 >/dev/null
qm resize "$VMID" scsi0 +1G >/dev/null
qm delsnapshot "$VMID" s1 >/dev/null
qm destroy "$VMID" --purge 1 >/dev/null
[ "$(fingerprint)" = "$BASELINE" ] \
    && ok "bystander volume untouched by a full lifecycle in '$BASE_PROJECT'" \
    || bad "bystander volume changed after lifecycle in '$BASE_PROJECT'"
SNAPS="$(api GET "/api/v2/projects/$ISO_PROJECT/snapshots" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("snapshots") or []))')"
[ "$SNAPS" = "0" ] \
    && ok "no foreign snapshots appear in '$ISO_PROJECT'" \
    || bad "'$ISO_PROJECT' gained $SNAPS snapshot(s) it should not have"

# --- 2. lifecycle in the scratch project must not touch the base project -----
echo "== lifecycle on '$ISO_STORAGE' ($ISO_PROJECT) =="
pvesm add lightbits "$ISO_STORAGE" \
    --lb_api_host "$API_HOSTS" --lb_jwt "$JWT" --lb_nvme_host "$NVME_HOSTS" \
    --lb_project "$ISO_PROJECT" --lb_replica_count "$REPLICAS" --content images >/dev/null
BASE_BEFORE="$(proj_vol_uuids "$BASE_PROJECT")"
qm create "$VMID" --memory 512 --scsihw virtio-scsi-single --name "$TEST_VM_NAME" >/dev/null
qm set "$VMID" --scsi0 "${ISO_STORAGE}:${DISK_GB}" >/dev/null
qm snapshot "$VMID" s1 >/dev/null
qm resize "$VMID" scsi0 +1G >/dev/null
qm delsnapshot "$VMID" s1 >/dev/null

# listing isolation, while the scratch volume exists: each storage sees only
# its own project
pvesm list "$ISO_STORAGE" | grep -q "vm-${VMID}-" \
    && ok "'$ISO_STORAGE' lists its own volume" \
    || bad "'$ISO_STORAGE' does not list its own volume"
pvesm list "$STORAGE" | grep -q "$BY_UUID\|vm-${VMID}-" \
    && bad "'$STORAGE' ($BASE_PROJECT) lists volumes of '$ISO_PROJECT'" \
    || ok "'$STORAGE' never lists '$ISO_PROJECT' volumes"

qm destroy "$VMID" --purge 1 >/dev/null
BASE_AFTER="$(proj_vol_uuids "$BASE_PROJECT")"
[ "$BASE_BEFORE" = "$BASE_AFTER" ] \
    && ok "'$BASE_PROJECT' volume set unchanged by a full lifecycle in '$ISO_PROJECT'" \
    || bad "'$BASE_PROJECT' volume set changed (before: $(echo "$BASE_BEFORE" | tr '\n' ' '); after: $(echo "$BASE_AFTER" | tr '\n' ' '))"
[ "$(fingerprint)" = "$BASELINE" ] \
    && ok "bystander volume also untouched by the '$ISO_PROJECT' lifecycle" \
    || bad "bystander volume changed after the '$ISO_PROJECT' lifecycle"

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
