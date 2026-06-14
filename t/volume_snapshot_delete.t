#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_snapshot_delete idempotency. A concurrent or repeated delete can
# fail in several ways (the snapshot is already 'Deleting', a delete task is in
# flight, or a racing delete leaves an etag/precondition mismatch). Rather than
# match error strings, the plugin re-checks after a failure: if the snapshot is
# now absent or already being deleted, the delete succeeded; a snapshot still
# present and Available means a genuine refusal, which is surfaced.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-000000000abc';
my $SUUID = 'aaaaaaaa-0000-4000-8000-000000000001';

my $present  = 1;       # is the snapshot in the listing? (drives _snap_uuid)
my $delete_err;         # if set, DELETE dies with this
my $recheck  = 'gone';  # GET /snapshots/{uuid} after a delete error: gone|Deleting|Available
my $deleted;            # captured DELETE path
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    if ($method eq 'GET' && $path =~ m{/snapshots$}) {
        return { snapshots => $present
            ? [ { name => "snap-$UUID-snap1", UUID => $SUUID, sourceVolumeUUID => $UUID } ]
            : [] };
    }
    if ($method eq 'GET' && $path =~ m{/snapshots/\Q$SUUID\E$}) {
        return {} if $recheck eq 'gone';          # _api maps 404 -> {}
        return { state => $recheck };
    }
    if ($method eq 'DELETE') {
        $deleted = $path;
        die $delete_err if $delete_err;
        return {};
    }
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $volname = "vm-100-$UUID";

# ── present snapshot: deleted via the project-scoped endpoint ──────────────────
($present, $delete_err, $deleted) = (1, undef, undef);
is( eval { $class->volume_snapshot_delete($scfg, 'lb-storage', $volname, 'snap1') }, undef,
    'delete returns undef on success' );
is( $deleted, "/api/v2/projects/default/snapshots/$SUUID", 'DELETEs the resolved snapshot UUID' );

# ── already gone (not in listing): idempotent, no DELETE issued ────────────────
($present, $delete_err, $deleted) = (0, undef, undef);
is( eval { $class->volume_snapshot_delete($scfg, 'lb-storage', $volname, 'snap1') }, undef,
    'already-gone snapshot is a no-op success' );
is( $deleted, undef, 'no DELETE issued when the snapshot is already gone' );

# ── concurrent delete, etag mismatch, snapshot gone on re-check: success ───────
($present, $delete_err, $recheck) =
    (1, "DELETE failed: 500 ... provided etag 1 ... don't match current etag 0 code:412\n", 'gone');
is( eval { $class->volume_snapshot_delete($scfg, 'lb-storage', $volname, 'snap1') }, undef,
    'etag-mismatch from a racing delete is success once the snapshot is gone' );

# ── concurrent delete, snapshot mid-delete (Deleting) on re-check: success ─────
($present, $delete_err, $recheck) =
    (1, "DELETE failed: 412 ... there is another ongoing task for resource $SUUID\n", 'Deleting');
is( eval { $class->volume_snapshot_delete($scfg, 'lb-storage', $volname, 'snap1') }, undef,
    'a snapshot still in Deleting on re-check is success' );

# ── genuine refusal: snapshot still present/Available on re-check -> surfaced ──
($present, $delete_err, $recheck) = (1, "DELETE failed: 403 ... permission denied\n", 'Available');
ok( !eval { $class->volume_snapshot_delete($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'a refusal that leaves the snapshot present is surfaced' );
like( $@, qr/permission denied/, 'the original error is propagated to the caller' );

done_testing();
