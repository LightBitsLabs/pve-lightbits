#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for alloc_image's orphan cleanup, run ON a Proxmox VE
# node that already has a configured Lightbits storage.
#
# A healthy cluster gives alloc_image no window to fail: unsatisfiable
# creations are rejected up front (replica count, size caps) and everything
# else converges to Available in tens of milliseconds — before the plugin's
# first status poll, and before any out-of-band actor can even see the volume
# in a listing (measured: ~37ms from POST to Available, size-independent). So
# the failure is injected at the API boundary instead: a loopback reverse
# proxy (alloc_orphan_cleanup.py) fronts the real LightOS API for a temporary
# storage definition, forwarding everything verbatim except the single-volume
# status GET, which it fails deterministically. Creation and deletion still
# hit the real cluster; only the poll lies. The plugin must, on both a 503
# (transport/5xx path) and a 404 (vanished-volume path):
#
#   1. fail the allocation — never hand PVE a volid it could not verify;
#   2. fail it accurately — re-raising the real API error (503) or naming the
#      missing volume (404), not blaming a convergence timeout;
#   3. delete the very volume its POST created (asserted from the proxy's
#      request log: one POST -> uuid, one DELETE -> same uuid) — this is the
#      orphan cleanup, observable against the real cluster;
#   4. leave the cluster clean and retries unimpeded — no vm-<vmid>-* volume
#      survives, and a subsequent allocation on the untampered storage
#      succeeds and frees cleanly.
#
# The remaining branches (volume stuck in Creating, terminal Failed state,
# cleanup DELETE itself failing) are covered by the unit suite
# (t/alloc_failfast.t), which this script runs as a gate before touching the
# cluster.
#
# Usage:
#   STORAGE=lb-storage VMID=9007 ./t/e2e/alloc_orphan_cleanup.sh
#
# Defaults: STORAGE=lb-storage, VMID=9007, DISK_GB=1, PROXY_PORT=18443.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9007}"
DISK_GB="${DISK_GB:-1}"
PROXY_PORT="${PROXY_PORT:-18443}"
TMP_STORAGE="lb-orphan-e2e"    # ownership marker: created and removed by this script

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

# Gate: the unit suite must pass before any live e2e runs (same as snapshots.sh).
T_DIR="$(cd "$(dirname "$0")/.." && pwd)"
E2E_DIR="$(cd "$(dirname "$0")" && pwd)"
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
NVME_HOSTS="$(scfg_val "$STORAGE" lb_nvme_host)"
REPLICAS="$(scfg_val "$STORAGE" lb_replica_count)"
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

# Volumes of this test's VMID currently on the cluster (via the real API, not
# the proxy), one "UUID state" per line. Everything this script creates (and
# everything it may delete) carries the vm-<VMID>- name prefix.
our_volumes() {
    api GET "/api/v2/volumes?projectName=$PROJECT" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for v in d.get("volumes") or []:
    if (v.get("name") or "").startswith("vm-'"$VMID"'-"):
        print(v["UUID"], v.get("state", ""))'
}

# The cluster drains deleted volume objects asynchronously; poll until no
# non-Deleting vm-$VMID-* volume remains. Prints the residue (empty = clean).
residue_after_drain() {
    local left=""
    for _ in $(seq 1 45); do
        left="$(our_volumes | awk '$2 != "Deleting" && $2 != "Deleted"')"
        [ -z "$left" ] && break
        sleep 2
    done
    printf '%s' "$left"
}

# Refuse to run over someone else's state.
if [ -n "$(our_volumes)" ]; then
    echo "ABORT: volumes named vm-$VMID-* already exist on the cluster; refusing to touch them." >&2
    echo "       (pick another VMID via VMID=... or clean them up first)" >&2
    exit 1
fi
if pvesm status --storage "$TMP_STORAGE" >/dev/null 2>&1; then
    echo "ABORT: a storage named '$TMP_STORAGE' already exists; refusing to touch it." >&2
    exit 1
fi

TMPD="$(mktemp -d)"
PROXY_LOG="$TMPD/proxy.log"
PROXY_PID=""
cleanup() {
    pvesm remove "$TMP_STORAGE" >/dev/null 2>&1 || true
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
    # Anything named vm-$VMID-* was created by this run (the pre-check above
    # guarantees the namespace was empty) — best-effort removal.
    our_volumes | while read -r uuid state; do
        case "$state" in Deleting|Deleted) continue ;; esac
        api DELETE "/api/v2/volumes/$uuid?projectName=$PROJECT" >/dev/null 2>&1 || true
    done
    rm -rf "$TMPD"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" \
    -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1

start_proxy() {    # $1 = HTTP code to inject on single-volume status GETs
    [ -n "$PROXY_PID" ] && { kill "$PROXY_PID" 2>/dev/null || true; wait "$PROXY_PID" 2>/dev/null || true; }
    python3 "$E2E_DIR/alloc_orphan_cleanup.py" \
        --listen-port "$PROXY_PORT" --upstream "${API_HOSTS%%,*}" \
        --cert "$TMPD/cert.pem" --key "$TMPD/key.pem" \
        --inject "$1" --log "$PROXY_LOG" &
    PROXY_PID=$!
    for _ in $(seq 1 50); do
        (echo > "/dev/tcp/127.0.0.1/$PROXY_PORT") 2>/dev/null && return 0
        sleep 0.1
    done
    echo "ABORT: fault-injection proxy did not come up on port $PROXY_PORT." >&2
    exit 1
}

# One failed allocation through the tampered storage. $1 = injected code,
# $2 = regex the plugin's error must match, $3 = human label for that error.
run_scenario() {
    local inject="$1" want_err="$2" err_label="$3"
    local ERR RC took start created deleted residue

    echo "== status poll fails with an injected $inject =="
    : > "$PROXY_LOG"
    start=$SECONDS
    ERR="$(pvesm alloc "$TMP_STORAGE" "$VMID" '' "${DISK_GB}G" 2>&1)" && RC=0 || RC=$?
    took=$(( SECONDS - start ))

    if [ "$RC" = "0" ]; then
        bad "allocation succeeded although every status poll returned $inject: $(head -1 <<<"$ERR")"
        return
    fi
    if grep -qE "$want_err" <<<"$ERR"; then
        ok "allocation fails $err_label (in ${took}s)"
    elif grep -q "did not become Available" <<<"$ERR"; then
        bad "allocation blamed a convergence timeout instead of $err_label: $(head -1 <<<"$ERR")"
    else
        bad "allocation failed for the wrong reason: $(head -1 <<<"$ERR")"
    fi
    [ "$took" -lt 25 ] \
        && ok "the failure is immediate, not a polling timeout (${took}s)" \
        || bad "the failed allocation took ${took}s — looks like a polling timeout"

    # The proxy log pins down what the plugin actually did: one volume created,
    # and the plugin's own DELETE aimed at that exact volume.
    created="$(awk '/^POST \/api\/v2\/volumes(\?| )/ && / -> 2/ { for (i=1;i<=NF;i++) if ($i ~ /^uuid=/) { sub(/^uuid=/,"",$i); print $i } }' "$PROXY_LOG")"
    deleted="$(awk '/^DELETE \/api\/v2\/volumes\// && / -> 2/ { if (match($2, /[0-9a-f-]{36}/)) print substr($2, RSTART, RLENGTH) }' "$PROXY_LOG")"
    if [ "$(wc -l <<<"$created")" = "1" ] && [ -n "$created" ] \
       && [ "$deleted" = "$created" ]; then
        ok "the plugin deleted the very volume its POST created ($created)"
    else
        bad "cleanup mismatch — created: [$(tr '\n' ' ' <<<"$created")], deleted: [$(tr '\n' ' ' <<<"$deleted")] (see proxy log)"
    fi

    residue="$(residue_after_drain)"
    [ -z "$residue" ] \
        && ok "no vm-$VMID-* volume survives on the real cluster" \
        || bad "orphan volume(s) left behind: $residue"
}

# The temporary storage must exist before the proxy dies and vice versa: the
# plugin fetches the subsystem NQN through lb_api_host when the storage is
# added, so the proxy has to be up first (that GET passes through untouched).
start_proxy 503
pvesm add lightbits "$TMP_STORAGE" \
    --lb_api_host "127.0.0.1:$PROXY_PORT" --lb_jwt "$JWT" \
    --lb_nvme_host "$NVME_HOSTS" --lb_project "$PROJECT" \
    ${REPLICAS:+--lb_replica_count "$REPLICAS"} --content images >/dev/null

# 503: the poll's transport/5xx failure must surface unchanged after cleanup.
run_scenario 503 "injected by alloc_orphan_cleanup|503" "re-raising the injected API error"

# 404: a volume that vanishes mid-poll must be reported as gone, after cleanup.
start_proxy 404
run_scenario 404 "no longer exists" "naming the vanished volume"

pvesm remove "$TMP_STORAGE" >/dev/null
kill "$PROXY_PID" 2>/dev/null || true; wait "$PROXY_PID" 2>/dev/null || true; PROXY_PID=""

# ── the untampered storage is unimpeded ─────────────────────────────────────────
echo "== allocation on the untampered storage still works =="
VOLID="$(pvesm alloc "$STORAGE" "$VMID" '' "${DISK_GB}G" 2>&1 | grep -oE "$STORAGE:vm-$VMID-[0-9a-f-]+" | head -1)" || true
if [ -n "${VOLID:-}" ]; then
    ok "allocation for VMID $VMID succeeds after the failed attempts"
else
    bad "allocation for VMID $VMID failed after the failed attempts"
fi

state="$(our_volumes | awk 'NR==1{print $2}')"
[ "$state" = "Available" ] \
    && ok "the volume is Available on the cluster" \
    || bad "the volume is in state '${state:-<missing>}', expected Available"

[ -n "${VOLID:-}" ] && pvesm free "$VOLID" >/dev/null 2>&1
residue="$(residue_after_drain)"
[ -z "$residue" ] \
    && ok "freeing the volume leaves the cluster clean" \
    || bad "volume(s) still present after pvesm free: $residue"

trap - EXIT
cleanup

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
