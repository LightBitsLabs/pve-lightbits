#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for TLS verification of the LightOS API connection
# (lb_fingerprint / lb_ssl_verify / lb_ca_file), run ON a Proxmox VE node that
# already has a configured Lightbits storage. A temporary storage entry is
# cloned from that storage's settings (own owner id, so nothing it allocates is
# visible to the real storage) and driven through the real PVE stack:
#
#   1. default: no verification options -> active (today's behaviour),
#   2. lb_ssl_verify=1 with no CA -> inactive, "certificate verify failed"
#      (a LightOS cluster's certificate comes from its own CA),
#   3. lb_fingerprint = the cluster certificate's SHA-256 (read with openssl)
#      -> active, and a volume can be allocated and freed over the pinned
#      connection,
#   4. a wrong fingerprint -> inactive, "certificate verify failed",
#   5. options cleared -> active again.
#
# The fingerprint is read from the first lb_api_host endpoint and must match
# every other endpoint (LightOS presents one certificate cluster-wide).
#
# Usage:
#   STORAGE=lb-storage ./t/e2e/api_tls.sh
#
# Defaults: STORAGE=lb-storage, VMID=9008 (only used as the owner of the probe
# volume, no VM is created).
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
VMID="${VMID:-9008}"
TLS_STORAGE="lb-tls-e2e"

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

T_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if command -v prove >/dev/null 2>&1 && ls "$T_DIR"/*.t >/dev/null 2>&1; then
    echo "== running unit tests before e2e =="
    prove -I "$T_DIR/stubs" "$T_DIR"/*.t || { echo "ABORT: unit tests failed - not running e2e." >&2; exit 1; }
fi
command -v openssl >/dev/null || { echo "ABORT: openssl not installed" >&2; exit 1; }

scfg_val() {
    awk -v s="$1" -v k="$2" '
        $0 ~ "^lightbits: " s "$" { in_blk = 1; next }
        /^[a-z]+: / { in_blk = 0 }
        in_blk && $1 == k { print $2; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
NVME_HOSTS="$(scfg_val "$STORAGE" lb_nvme_host)"
if [ -z "$API_HOSTS" ] || [ -z "$JWT" ]; then echo "ABORT: storage '$STORAGE' not in /etc/pve/storage.cfg" >&2; exit 1; fi

fingerprint_of() {   # host[:port] -> colon-separated SHA-256
    local h="$1"; [[ "$h" == *:* ]] || h="$h:443"
    echo | timeout 10 openssl s_client -connect "$h" 2>/dev/null | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | cut -d= -f2
}
FIRST="${API_HOSTS%%,*}"
FP="$(fingerprint_of "$FIRST")"
[ -n "$FP" ] || { echo "ABORT: could not read the certificate fingerprint from $FIRST" >&2; exit 1; }
echo "   cluster certificate: $FP (from $FIRST)"
SAME=1
for h in ${API_HOSTS//,/ }; do f="$(fingerprint_of "$h")"; [ "$f" = "$FP" ] || { echo "   NOTE: $h presents a different certificate ($f)"; SAME=0; }; done
[ "$SAME" = 1 ] && ok "every lb_api_host endpoint presents the same certificate (one fingerprint covers the cluster)"

cleanup() { pvesm remove "$TLS_STORAGE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# Status of the temp storage through the real stack: "active"/"inactive" plus
# any warning the plugin printed (pvesm status prints the plugin's warn()).
status_of() { pvesm status --storage "$1" 2>&1 | awk -v s="$1" '$1==s{print $3}'; }
status_err() { pvesm status --storage "$1" 2>&1 | grep -v "^Name\|^$1 " || true; }

echo "== 1. default: no verification options =="
pvesm add lightbits "$TLS_STORAGE" --lb_api_host "$API_HOSTS" --lb_jwt "$JWT" \
    --lb_nvme_host "$NVME_HOSTS" --lb_project "$PROJECT" --lb_owner_id "$TLS_STORAGE" --content images >/dev/null
if [ "$(status_of "$TLS_STORAGE")" = active ]; then ok "default (verification off) -> storage active"; else bad "default: $(status_err "$TLS_STORAGE")"; fi

echo "== 2. lb_ssl_verify=1 without a CA: must fail closed =="
pvesm set "$TLS_STORAGE" --lb_ssl_verify 1
ST="$(status_of "$TLS_STORAGE")"; ERR="$(status_err "$TLS_STORAGE")"
if [ "$ST" = inactive ] && grep -qi 'certificate verify failed' <<<"$ERR"; then ok "lb_ssl_verify=1 vs the cluster CA -> inactive with 'certificate verify failed'"; else bad "lb_ssl_verify=1: status=$ST err=$(head -c 200 <<<"$ERR")"; fi
if pvesm alloc "$TLS_STORAGE" "$VMID" x 1G >/dev/null 2>&1; then bad "allocation succeeded over an unverified connection"; pvesm list "$TLS_STORAGE" --vmid "$VMID" | awk 'NR>1{print $1}' | xargs -r -n1 pvesm free; else ok "allocation refused while verification fails"; fi
pvesm set "$TLS_STORAGE" --delete lb_ssl_verify

echo "== 3. lb_fingerprint pinned to the cluster certificate =="
pvesm set "$TLS_STORAGE" --lb_fingerprint "$FP"
if [ "$(status_of "$TLS_STORAGE")" = active ]; then ok "pinned fingerprint -> storage active"; else bad "pinned fingerprint: $(status_err "$TLS_STORAGE")"; fi
if VOL="$(pvesm alloc "$TLS_STORAGE" "$VMID" x 1G 2>&1 | grep -o "${TLS_STORAGE}:vm-${VMID}-[0-9a-f-]*")" && [ -n "$VOL" ]; then
    ok "volume allocated over the pinned connection ($VOL)"
    if pvesm free "$VOL" >/dev/null; then ok "volume freed over the pinned connection"; else bad "pvesm free $VOL failed"; fi
else
    bad "allocation over the pinned connection failed"
fi

echo "== 4. wrong fingerprint: must fail closed =="
WRONG="00${FP:2}"
pvesm set "$TLS_STORAGE" --lb_fingerprint "$WRONG"
ST="$(status_of "$TLS_STORAGE")"; ERR="$(status_err "$TLS_STORAGE")"
if [ "$ST" = inactive ] && grep -qi 'certificate verify failed' <<<"$ERR"; then ok "wrong fingerprint -> inactive with 'certificate verify failed'"; else bad "wrong fingerprint: status=$ST err=$(head -c 200 <<<"$ERR")"; fi
if pvesm set "$TLS_STORAGE" --lb_fingerprint "DD:89:8D" 2>/dev/null; then bad "schema accepted a malformed fingerprint"; pvesm set "$TLS_STORAGE" --lb_fingerprint "$WRONG"; else ok "schema rejects a malformed fingerprint"; fi

echo "== 5. options cleared: default again =="
pvesm set "$TLS_STORAGE" --delete lb_fingerprint
if [ "$(status_of "$TLS_STORAGE")" = active ]; then ok "fingerprint cleared -> storage active again"; else bad "after clearing: $(status_err "$TLS_STORAGE")"; fi

echo "== 6. the real storage was never touched =="
if ! grep -A12 "^lightbits: $STORAGE$" /etc/pve/storage.cfg | grep -q 'lb_fingerprint\|lb_ssl_verify'; then ok "$STORAGE still has no verification options"; else bad "$STORAGE was modified"; fi
LEFT="$(pvesm list "$TLS_STORAGE" --vmid "$VMID" 2>/dev/null | awk 'NR>1' | wc -l)"
if [ "$LEFT" = 0 ]; then ok "no probe volume left on the cluster"; else bad "$LEFT probe volume(s) left"; fi

cleanup; trap - EXIT
echo
echo "== api_tls e2e: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
