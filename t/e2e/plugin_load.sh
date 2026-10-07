#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Live end-to-end test for plugin loading, run ON a Proxmox VE node that has the
# plugin installed. Asserts through the real PVE storage stack that the plugin
# loads silently and at the host's storage API version:
#
#   1. `pvesm status` emits neither
#        Plugin "PVE::Storage::Custom::LightbitsPlugin" is implementing an older
#        storage API, an upgrade is recommended
#      nor `Error loading storage plugin "PVE::Storage::Custom::LightbitsPlugin"`;
#   2. the plugin's api() equals PVE::Storage::APIVER() on this host (an api()
#      below APIVER is what produces the warning above; below APIVER - APIAGE the
#      loader rejects the plugin);
#   3. the 'lightbits' type is registered and the storage is active;
#   4. the long-running PVE daemons (pvedaemon, pveproxy, pvestatd) have not
#      logged the warning since the installed plugin file was last changed —
#      they load the plugin once at start, so an upgrade only takes effect for
#      the GUI after they are restarted.
#
# Nothing is created or modified.
#
# Usage:
#   STORAGE=lb-storage ./t/e2e/plugin_load.sh
#
# Defaults: STORAGE=lb-storage.
set -euo pipefail

STORAGE="${STORAGE:-lb-storage}"
INSTALLED=/usr/share/perl5/PVE/Storage/Custom/LightbitsPlugin.pm
WARN='is implementing an older storage API'
LOADERR='Error loading storage plugin "PVE::Storage::Custom::LightbitsPlugin"'

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

[ -r "$INSTALLED" ] || { echo "ABORT: $INSTALLED not installed." >&2; exit 1; }

# 1. loader messages on a plain pvesm call (stderr only; stdout is the table)
err="$(pvesm status 2>&1 >/dev/null || true)"
if grep -q "$WARN" <<<"$err"; then
    bad "pvesm status warns: $(grep "$WARN" <<<"$err" | head -1)"
elif grep -q "$LOADERR" <<<"$err"; then
    bad "pvesm status fails to load the plugin: $(grep -A1 "$LOADERR" <<<"$err" | tr '\n' ' ')"
else
    ok "pvesm status loads the plugin without an API warning or load error"
fi

# 2. api() == APIVER on this host
read -r apiver apiage api < <(perl -MPVE::Storage -e '
    print PVE::Storage::APIVER(), " ", PVE::Storage::APIAGE(), " ",
          PVE::Storage::Custom::LightbitsPlugin->api(), "\n";' 2>/dev/null) || true
echo "   host APIVER=$apiver APIAGE=$apiage plugin api()=$api"
if [ -z "${api:-}" ]; then
    bad "could not query PVE::Storage::APIVER / plugin api()"
elif [ "$api" = "$apiver" ]; then
    ok "plugin api() matches the host storage API version $apiver"
elif (( api < apiver - apiage )); then
    bad "plugin api() $api is below the host's compatibility window ($((apiver - apiage))..$apiver): the loader rejects it"
else
    bad "plugin api() $api is below host APIVER $apiver: PVE logs the 'older storage API' warning — bump \$TESTED_APIVER"
fi

# 3. type registered, storage active
if perl -MPVE::Storage -MPVE::Storage::Plugin -e 'exit(PVE::Storage::Plugin->lookup("lightbits") ? 0 : 1)' 2>/dev/null; then
    ok "'lightbits' storage type is registered"
else
    bad "'lightbits' storage type is not registered"
fi
if pvesm status --storage "$STORAGE" 2>/dev/null | awk 'NR==2 && $3=="active"{f=1} END{exit !f}'; then
    ok "storage '$STORAGE' is active"
else
    bad "storage '$STORAGE' is not active: $(pvesm status --storage "$STORAGE" 2>&1 | tail -1)"
fi

# 4. daemons: no warning logged since the installed plugin file changed
since="$(date -d "@$(stat -c %Y "$INSTALLED")" '+%Y-%m-%d %H:%M:%S')"
hits="$(journalctl -q --since "$since" -u pvedaemon -u pveproxy -u pvestatd 2>/dev/null | grep -c "$WARN" || true)"
if [ "${hits:-0}" -eq 0 ]; then
    ok "no 'older storage API' warning from pvedaemon/pveproxy/pvestatd since $since"
else
    bad "$hits 'older storage API' warning(s) from the PVE daemons since $since — restart pvedaemon pveproxy pvestatd after upgrading the plugin"
fi

echo "== $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
