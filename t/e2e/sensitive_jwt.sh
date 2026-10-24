#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for lb_jwt as a Proxmox sensitive property, run ON a
# Proxmox VE node that already has a configured Lightbits storage. A temporary
# storage entry is created from that storage's settings (own owner id, so
# nothing it allocates is visible to the real storage) and driven through the
# real PVE stack:
#
#   1. `pvesm add ... --lb_jwt` keeps the token out of /etc/pve/storage.cfg and
#      out of `pvesh get /storage/<id>`, and stores it in
#      /etc/pve/priv/storage/<id>.pw, root-only 0600, unreadable by www-data;
#   2. the storage is active and a volume can be allocated and freed with the
#      token read from the private file;
#   3. `pvesm set --lb_jwt` rotates the private file;
#   4. a legacy entry (token in plaintext in storage.cfg, as written by
#      releases before this change) keeps working, and any `pvesm set` moves
#      the token to the private file and removes it from storage.cfg;
#   5. `pvesm remove` deletes the private file.
#
# Like the other e2e scripts this contains no addresses or credentials: they
# are read from the existing storage's definition.
#
# Usage:
#   STORAGE=lb-storage ./t/e2e/sensitive_jwt.sh
#
# Defaults: STORAGE=lb-storage, VMID=9009 (owner of the probe volume only).
set -uo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9009}"
TMP="lb-jwt-e2e"
PRIV=/etc/pve/priv/storage

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

T_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if command -v prove >/dev/null 2>&1 && ls "$T_DIR"/*.t >/dev/null 2>&1; then
    echo "== running unit tests before e2e =="
    prove -I "$T_DIR/stubs" "$T_DIR"/*.t || { echo "ABORT: unit tests failed - not running e2e." >&2; exit 1; }
fi

scfg_val() {
    awk -v s="$1" -v k="$2" '
        $0 ~ "^lightbits: " s "$" { in_blk = 1; next }
        /^[a-z]+: / { in_blk = 0 }
        in_blk && $1 == k { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); print; exit }' /etc/pve/storage.cfg
}
block_has_jwt() { awk -v s="$1" '$0 ~ "^lightbits: " s "$" {f=1; next} /^[a-z]+: /{f=0} f && $1=="lb_jwt"{print "yes"; exit}' /etc/pve/storage.cfg; }
status_of() { pvesm status --storage "$1" 2>/dev/null | awk -v s="$1" '$1==s {print $3}'; }

API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
NVME_HOSTS="$(scfg_val "$STORAGE" lb_nvme_host)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
FP="$(scfg_val "$STORAGE" lb_fingerprint)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
[ -n "$JWT" ] || JWT="$(head -n1 "$PRIV/$STORAGE.pw" 2>/dev/null)"
[ -n "$API_HOSTS" ] && [ -n "$JWT" ] || { echo "ABORT: storage '$STORAGE' not configured (lb_api_host / token)" >&2; exit 1; }

cleanup() { pvesm remove "$TMP" >/dev/null 2>&1 || true; rm -f "$PRIV/$TMP.pw"; }
trap cleanup EXIT
cleanup

FPOPT=(); [ -n "$FP" ] && FPOPT=(--lb_fingerprint "$FP")
add_tmp() {
    pvesm add lightbits "$TMP" --lb_api_host "$API_HOSTS" --lb_jwt "$1" --lb_nvme_host "$NVME_HOSTS" \
        --lb_project "$PROJECT" --lb_owner_id lb-jwt-e2e --content images --nodes "$(hostname)" "${FPOPT[@]}" >/dev/null
}
alloc_free() {
    local out vol
    out=$(pvesm alloc "$TMP" "$VMID" '' 1G 2>&1); vol=$(printf '%s' "$out" | sed -n "s/.*'\(.*\)'.*/\1/p")
    [ -n "$vol" ] || { echo "$out"; return 1; }
    pvesm free "$vol" >/dev/null 2>&1
    [ "$(pvesm list "$TMP" --vmid "$VMID" 2>/dev/null | awk 'NR>1' | wc -l)" = 0 ]
}

echo "== 1. add: token kept out of storage.cfg and the API, stored privately =="
add_tmp "$JWT" || { bad "pvesm add failed"; exit 1; }
[ -z "$(block_has_jwt "$TMP")" ] && ok "storage.cfg block of $TMP has no lb_jwt" || bad "lb_jwt written to storage.cfg"
if pvesh get "/storage/$TMP" --output-format json | grep -q '"lb_jwt"'; then bad "GET /storage/$TMP returns lb_jwt"; else ok "GET /storage/$TMP does not return lb_jwt"; fi
if [ -f "$PRIV/$TMP.pw" ]; then
    ok "token stored in $PRIV/$TMP.pw"
    [ "$(stat -c '%a %U' "$PRIV/$TMP.pw")" = "600 root" ] && ok "private file is 0600 root" || bad "private file is $(stat -c '%a %U' "$PRIV/$TMP.pw")"
    [ "$(head -n1 "$PRIV/$TMP.pw")" = "$JWT" ] && ok "private file holds the token" || bad "private file content differs"
    if su -s /bin/sh www-data -c "cat '$PRIV/$TMP.pw'" >/dev/null 2>&1; then bad "www-data can read the private file"; else ok "www-data cannot read the private file"; fi
else
    bad "no private file $PRIV/$TMP.pw"
fi

echo "== 2. the storage works with the token from the private file =="
[ "$(status_of "$TMP")" = active ] && ok "$TMP active" || bad "$TMP not active: $(pvesm status --storage "$TMP" 2>&1 | tail -1)"
alloc_free && ok "volume allocated and freed" || bad "alloc/free failed"

echo "== 3. rotation =="
pvesm set "$TMP" --lb_jwt "$JWT" >/dev/null 2>&1 && ok "pvesm set --lb_jwt accepted" || bad "pvesm set --lb_jwt failed"
[ "$(head -n1 "$PRIV/$TMP.pw" 2>/dev/null)" = "$JWT" ] && ok "private file rewritten" || bad "private file not rewritten"
[ -z "$(block_has_jwt "$TMP")" ] && ok "still nothing in storage.cfg" || bad "token appeared in storage.cfg after set"

echo "== 4. migration of a legacy (plaintext) entry =="
pvesm remove "$TMP" >/dev/null 2>&1; rm -f "$PRIV/$TMP.pw"
# What an entry created by an earlier release looks like: token inline in storage.cfg.
{ printf '\nlightbits: %s\n\tlb_api_host %s\n\tlb_jwt %s\n\tlb_nvme_host %s\n\tlb_project %s\n\tlb_owner_id lb-jwt-e2e\n\tcontent images\n\tnodes %s\n' \
      "$TMP" "$API_HOSTS" "$JWT" "$NVME_HOSTS" "$PROJECT" "$(hostname)"; [ -n "$FP" ] && printf '\tlb_fingerprint %s\n' "$FP"; } >> /etc/pve/storage.cfg
[ -n "$(block_has_jwt "$TMP")" ] && ok "legacy entry written with an inline token" || bad "could not write the legacy entry"
[ "$(status_of "$TMP")" = active ] && ok "legacy entry works (inline token used)" || bad "legacy entry not active"
pvesm set "$TMP" --content images >/dev/null 2>&1 && ok "unrelated pvesm set accepted" || bad "pvesm set failed"
[ -z "$(block_has_jwt "$TMP")" ] && ok "inline token removed from storage.cfg" || bad "inline token still in storage.cfg"
[ "$(head -n1 "$PRIV/$TMP.pw" 2>/dev/null)" = "$JWT" ] && ok "token migrated to the private file" || bad "token not migrated"
[ "$(status_of "$TMP")" = active ] && ok "still active after migration" || bad "inactive after migration"
alloc_free && ok "alloc/free after migration" || bad "alloc/free failed after migration"

echo "== 5. remove =="
pvesm remove "$TMP" >/dev/null 2>&1
[ ! -e "$PRIV/$TMP.pw" ] && ok "private file removed with the storage" || bad "private file left behind"

trap - EXIT; cleanup
echo
echo "== sensitive_jwt e2e: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
