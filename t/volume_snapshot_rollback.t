#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_snapshot_rollback: it resolves the snapshot by its UUID-embedded
# name and issues the native server-side rollback (PUT .../rollback with
# srcSnapshotUUID), then waits for the rollback to finish — failing fast on a
# timeout rather than assuming success. The volume is already Available before
# the PUT, so finishing means Available after the ETag moved or after the
# Rollback state was seen; only a volume without an ETag falls back to the
# first Available.

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
my $etag      = '3';           # ETag of the pre-PUT read (ownership guard)
my @after;                     # volume GETs after the PUT: [state, ETag] each;
                               # the last one repeats once the list runs out
my $gets_after = 0;
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
    if ($method eq 'GET' && $path =~ m{/volumes/}) {
        my ($state, $tag) = ($vol_state, $etag);
        if (%put) {
            $gets_after++;
            ($state, $tag) = @{ @after > 1 ? shift @after : $after[0] } if @after;
        }
        my %v = (state => $state, labels => [ { key => 'pveVmid', value => '100' }, { key => 'pveNode', value => 'node-a' } ]);
        $v{ETag} = $tag if defined $tag;
        return \%v;
    }
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default', lb_owner_id => 'node-a' };
my $volname = "vm-100-$UUID";

sub reset_run { my ($tag, @seq) = @_; %put = (); $etag = $tag; @after = @seq; $gets_after = 0; }

# ── PUT request shape ──────────────────────────────────────────────────────────
$vol_state = 'Available';
reset_run('3', ['Rollback', '4'], ['Available', '4']);
my $ret = eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1') };
is( $@, '', 'rollback succeeds when the volume returns to Available' );
is( $ret, undef, 'returns undef' );
is( $put{path}, "/api/v2/projects/default/volumes/$UUID/rollback",
    'PUT targets the project-scoped volume rollback endpoint' );
is( $put{body}{srcSnapshotUUID}, $SUUID, 'body carries srcSnapshotUUID (resolved from the name)' );

# ── Available on the first poll is not completion ─────────────────────────────
# LightOS applies the rollback asynchronously: the first poll can still see the
# pre-rollback volume (Available, old ETag).
reset_run('3', ['Available', '3'], ['Available', '3'], ['Rollback', '4'], ['Available', '4']);
is( eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 }, 1,
    'rollback succeeds once applied' ) or diag $@;
is( $gets_after, 4, 'keeps polling past the pre-rollback Available until the rollback ran' );

# ── ETag moved without a visible Rollback state ───────────────────────────────
reset_run('3', ['Available', '3'], ['Available', '4']);
ok( eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'a fast rollback (only the ETag moved) completes' ) or diag $@;
is( $gets_after, 2, 'returns on the first Available with the new ETag' );

# ── Rollback state seen, ETag unchanged ───────────────────────────────────────
reset_run('3', ['Rollback', '3'], ['Available', '3']);
ok( eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'seeing the Rollback state counts as started' ) or diag $@;
is( $gets_after, 2, 'returns on the Available after Rollback' );

# ── rollback never applied: timeout ───────────────────────────────────────────
reset_run('3', ['Available', '3']);
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'dies when the cluster never applies the rollback' );
like( $@, qr/did not complete.*rollback not yet applied/, 'error says the rollback was not applied' );

# ── no ETag (older API): first Available, as before ───────────────────────────
reset_run(undef, ['Available', undef]);
ok( eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'without an ETag the first Available completes' ) or diag $@;
is( $gets_after, 1, 'falls back to the first Available' );

# ── unknown snapshot name dies cleanly ─────────────────────────────────────────
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'nope'); 1 },
    'dies when the snapshot name is not found' );
like( $@, qr/not found/, 'error reports the missing snapshot' );

# ── never-Available dies on timeout ────────────────────────────────────────────
reset_run('3', ['Updating', '4']);
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'dies when the volume never returns to Available' );
like( $@, qr/did not complete/, 'error reports the timeout' );

# ── terminal failure state fails fast ──────────────────────────────────────────
reset_run('3', ['Failed', '4']);
ok( !eval { $class->volume_snapshot_rollback($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'dies when the volume enters a terminal failure state' );
like( $@, qr/rollback to 'snap1' failed/, 'error reports the failed rollback' );

done_testing();
