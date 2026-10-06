#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for get_identity (storage API 14), run ON a Proxmox VE
# node that already has a configured Lightbits storage. It registers a second
# storage entry pointing at the SAME cluster but spelled differently — endpoint
# order reversed, hostnames uppercased, an implicit :443 where the original was
# explicit — plus a third entry differing in something that genuinely matters
# (the project), and asserts through the real PVE storage stack that:
#
#   1. the same cluster gets the same identity regardless of spelling;
#   2. the identity is in canonical form (lowercase, explicit ports, sorted);
#   3. an entry that really is a different backend (another project) keeps a
#      distinct identity.
#
# No volumes are created; the test only adds and removes storage definitions.
#
# Usage:
#   STORAGE=lb-storage ./t/e2e/get_identity.sh
#
# Defaults: STORAGE=lb-storage.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
TWIN_STORAGE="lb-ident-e2e"        # same cluster, different spelling
OTHER_STORAGE="lb-ident-e2e-other" # same cluster, different project

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

scfg_val() {
    awk -v s="$1" -v k="$2" '
        /^[a-z]+: /   { in_blk = ($0 == "lightbits: " s) ; next }
        in_blk && $1 == k { print $2; exit }' /etc/pve/storage.cfg
}
API_HOSTS="$(scfg_val "$STORAGE" lb_api_host)"
JWT="$(scfg_val "$STORAGE" lb_jwt)"
PROJECT="$(scfg_val "$STORAGE" lb_project)"; PROJECT="${PROJECT:-default}"
NVME_HOSTS="$(scfg_val "$STORAGE" lb_nvme_host)"
[ -n "$API_HOSTS" ] && [ -n "$JWT" ] || {
    echo "ABORT: storage '$STORAGE' not found in /etc/pve/storage.cfg (or missing lb_api_host/lb_jwt)." >&2
    exit 1
}

for s in "$TWIN_STORAGE" "$OTHER_STORAGE"; do
    if pvesm status --storage "$s" >/dev/null 2>&1; then
        echo "ABORT: a storage named '$s' already exists; refusing to touch it." >&2
        exit 1
    fi
done
cleanup() {
    pvesm remove "$TWIN_STORAGE"  >/dev/null 2>&1 || true
    pvesm remove "$OTHER_STORAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A different spelling of the same endpoint set: reverse the order, uppercase,
# and drop one explicit :443 (the plugin always speaks HTTPS, so a bare host
# and host:443 are the same endpoint).
TWIN_HOSTS="$(python3 - "$API_HOSTS" <<'EOF'
import sys
eps = [e.strip() for e in sys.argv[1].split(",") if e.strip()]
eps.reverse()
eps = [e.upper() for e in eps]
for i, e in enumerate(eps):
    if e.endswith(":443") and not e.startswith("["):
        eps[i] = e[: -len(":443")]
        break
print(",".join(eps))
EOF
)"
echo "== twin spelling: $TWIN_HOSTS =="

pvesm add lightbits "$TWIN_STORAGE" \
    --lb_api_host "$TWIN_HOSTS" --lb_jwt "$JWT" \
    --lb_nvme_host "$NVME_HOSTS" --lb_project "$PROJECT" --content images >/dev/null
pvesm add lightbits "$OTHER_STORAGE" \
    --lb_api_host "$API_HOSTS" --lb_jwt "$JWT" \
    --lb_nvme_host "$NVME_HOSTS" --lb_project "lb-ident-e2e-project" --content images >/dev/null

# Ask the real PVE storage stack (not the plugin file in this repo checkout).
identity() {
    perl -MPVE::Storage -MPVE::Storage::Plugin -e '
        my $cfg  = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $ARGV[0]);
        my $pl   = PVE::Storage::Plugin->lookup($scfg->{type});
        print $pl->get_identity($scfg, $ARGV[0]);' "$1" 2>/dev/null
}

ID_MAIN="$(identity "$STORAGE")"
ID_TWIN="$(identity "$TWIN_STORAGE")"
ID_OTHER="$(identity "$OTHER_STORAGE")"
echo "   $STORAGE -> $ID_MAIN"
echo "   $TWIN_STORAGE -> $ID_TWIN"
echo "   $OTHER_STORAGE -> $ID_OTHER"

[ -n "$ID_MAIN" ] \
    && ok "get_identity answers through the live PVE stack" \
    || bad "get_identity returned nothing for '$STORAGE'"

if [ "$ID_MAIN" = "$ID_TWIN" ] && [ -n "$ID_MAIN" ]; then
    ok "same cluster, different spelling -> same identity"
else
    bad "spellings of the same cluster diverged: '$ID_MAIN' vs '$ID_TWIN'"
fi

# Canonical form: lightbits://ep1,ep2,.../project with each endpoint lowercase
# and port-explicit, and the list sorted.
if python3 - "$ID_MAIN" <<'EOF'
import re, sys
m = re.fullmatch(r"lightbits://([^/]+)/(.+)", sys.argv[1])
assert m, "identity shape"
eps = m.group(1).split(",")
assert eps == sorted(eps), "endpoints not sorted"
for e in eps:
    assert e == e.lower(), f"not lowercase: {e}"
    assert re.search(r":\d+$", e), f"port not explicit: {e}"
EOF
then
    ok "identity is canonical (lowercase, explicit ports, sorted)"
else
    bad "identity '$ID_MAIN' is not in canonical form"
fi

if [ "$ID_MAIN" != "$ID_OTHER" ] && [ -n "$ID_OTHER" ]; then
    ok "a different project keeps a distinct identity"
else
    bad "different projects share an identity: '$ID_MAIN' vs '$ID_OTHER'"
fi

trap - EXIT
cleanup

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
