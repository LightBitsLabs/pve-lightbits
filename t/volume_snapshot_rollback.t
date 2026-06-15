#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_snapshot_rollback: it resolves the snapshot by its UUID-embedded
# name and issues the native server-side rollback (PUT .../rollback with
# srcSnapshotUUID), then waits for the volume to return to Available — failing
# fast on a timeout rather than assuming success.

use strict;
use warnings;
use Test::More;
use FindBin;

BEGIN { *CORE::GLOBAL::sleep = sub { }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-000000000abc';
my $SUUID = 'aaaaaaaa-0000-4000-8000-000000000001';

my %put;                       # captured PUT
my $vol_state = 'Available';
no warnings 'redefine';
# No symlink exists on the test host, so the real _rescan_controller is a no-op
# today; stub it so the test stays hermetic regardless of the host's /dev state.
*PVE::Storage::Custom::LightbitsPlugin::_rescan_controller = sub { };
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    # snapshot listing -> resolve the name to a UUID
    if ($method eq 'GET' && $path =~ m{/snapshots$}) {
        return { snapshots => [
            { name => "snap-$UUID-snap1", UUID => $SUUID, sourceVolumeUUID => $UUID },
        ] };
    }
    if ($method eq 'PUT' && $path =~ m{/rollback$}) {
        %put = (path => $path, body => $body);
        return {};
    }
    return { state => $vol_state } if $method eq 'GET' && $path =~ m{/volumes/};
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $volname = "vm-100-$UUID";

# ── PUT request shape ──────────────────────────────────────────────────────────
$vol_state = 'Available';
my $ret = eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1') };
is( $@, '', 'rollback succeeds when the volume returns to Available' );
is( $ret, undef, 'returns undef' );
is( $put{path}, "/api/v2/projects/default/volumes/$UUID/rollback",
    'PUT targets the project-scoped volume rollback endpoint' );
is( $put{body}{srcSnapshotUUID}, $SUUID, 'body carries srcSnapshotUUID (resolved from the name)' );

# ── unknown snapshot name dies cleanly ─────────────────────────────────────────
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'nope'); 1 },
    'dies when the snapshot name is not found' );
like( $@, qr/not found/, 'error reports the missing snapshot' );

# ── never-Available dies on timeout ────────────────────────────────────────────
$vol_state = 'Updating';
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'dies when the volume never returns to Available' );
like( $@, qr/did not complete/, 'error reports the timeout' );

# ── terminal failure state fails fast ──────────────────────────────────────────
$vol_state = 'Failed';
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'dies when the volume enters a terminal failure state' );
like( $@, qr/rollback to 'snap1' failed/, 'error reports the failed rollback' );

done_testing();
