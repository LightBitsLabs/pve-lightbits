#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests that a resource deleted out of band is reported as gone rather than
# silently read as an empty one.
#
# _api maps a 404 to an empty hash so the idempotent delete paths can treat
# "already gone" as success. Callers that then read fields out of the result
# need the opposite: an empty hash has no `state` and no `size`, so a volume or
# snapshot deleted behind Proxmox's back looks like "present, just not converged
# yet". The polling loops would spin out their full 30-60 iteration timeout and
# then blame a convergence problem, and volume_rollback_is_possible would
# compare two zero sizes and allow a rollback that cannot work.

use strict;
use warnings;
use Test::More;
use FindBin;
use HTTP::Response;

# No real sleeping, so a loop that wrongly runs to its timeout finishes fast.
BEGIN { *CORE::GLOBAL::sleep = sub { }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $P     = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-0000000000aa';
my $SNAP  = 'abcdef01-0000-4000-8000-0000000000bb';
my $scfg  = { lb_project => 'default', lb_api_host => '10.0.0.1:443', lb_jwt => 't' };

# ── _api: a 404 stays an empty hash by default, undef only when asked ──────────
{
    no warnings qw(redefine once);
    local *LWP::UserAgent::request = sub { HTTP::Response->new(404, 'Not Found', [], '') };
    use warnings qw(redefine once);

    is_deeply( PVE::Storage::Custom::LightbitsPlugin::_api($scfg, 'GET', '/x'), {},
        '_api still maps 404 to an empty hash by default (idempotent delete paths)' );
    is( PVE::Storage::Custom::LightbitsPlugin::_api($scfg, 'GET', '/x', undef, missing_is_undef => 1),
        undef, '_api returns undef for a 404 when missing_is_undef is set' );
    is_deeply( PVE::Storage::Custom::LightbitsPlugin::_api($scfg, 'DELETE', '/x'), {},
        'a DELETE of an already-absent resource is still a success' );
}

# ── _get_existing: names the resource and does not return an empty hash ────────
{
    my @seen;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, undef, undef, undef, %o) = @_;
        push @seen, \%o;
        return undef;
    };
    use warnings 'redefine';

    my $ok = eval { PVE::Storage::Custom::LightbitsPlugin::_get_existing($scfg, '/x', 'Volume abc'); 1 };
    ok( !$ok, '_get_existing dies when the resource is gone' );
    like( $@, qr/Volume abc no longer exists/, 'the error names the missing resource' );
    like( $@, qr/deleted outside Proxmox/, 'the error suggests the likely cause' );
    ok( $seen[0]{missing_is_undef}, '_get_existing asks _api for the strict behaviour' );
}
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub { return { size => 5 } };
    use warnings 'redefine';
    is_deeply( PVE::Storage::Custom::LightbitsPlugin::_get_existing($scfg, '/x', 'Volume abc'),
        { size => 5 }, '_get_existing passes a present resource straight through' );
}

# Drive the public methods with a cluster where everything 404s. Counting the
# calls is the point: the old code polled 30-60 times before giving up.
my $calls;
sub with_absent_cluster {
    my ($code) = @_;
    $calls = 0;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path, undef, %o) = @_;
        $calls++;
        return { UUID => $UUID }  if $method eq 'POST' && $path !~ /snapshots/;
        return { UUID => $SNAP }  if $method eq 'POST';
        return { volumes => [] }  if $method eq 'GET' && $path =~ /volumes\?/;
        # Everything else is a 404.
        return $o{missing_is_undef} ? undef : {};
    };
    local *PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.test:host' };
    local *PVE::Storage::Custom::LightbitsPlugin::_snap_uuid = sub { $SNAP };
    local *PVE::Storage::Custom::LightbitsPlugin::_rescan_controller = sub { };
    use warnings 'redefine';
    my $ok = eval { $code->(); 1 };
    return (!$ok, $@, $calls);
}

# ── volume_size_info: a vanished volume is an error, not a 0-byte disk ─────────
{
    my ($died, $err) = with_absent_cluster(sub {
        $class->volume_size_info($scfg, 'lb', "vm-100-$UUID");
    });
    ok( $died, 'volume_size_info dies rather than reporting a vanished volume as 0 bytes' );
    like( $err, qr/\Q$UUID\E no longer exists/, 'the error names the volume' );
}

# ── alloc_image: fails on the first poll, not after the full timeout ───────────
{
    my ($died, $err, $n) = with_absent_cluster(sub {
        $class->alloc_image('lb', $scfg, 100, 'raw', undef, 1048576);
    });
    ok( $died, 'alloc_image dies when the new volume vanishes mid-poll' );
    like( $err, qr/no longer exists/, 'the error says the volume is gone' );
    unlike( $err, qr/did not become Available/,
        'it does not misreport a vanished volume as a convergence timeout' );
    cmp_ok( $n, '<', 10, "gives up promptly instead of polling 30 times (took $n calls)" );
}

# ── volume_resize ──────────────────────────────────────────────────────────────
{
    my ($died, $err, $n) = with_absent_cluster(sub {
        $class->volume_resize($scfg, 'lb', "vm-100-$UUID", 2 * 1024 * 1024 * 1024, 0);
    });
    ok( $died, 'volume_resize dies when the volume vanishes mid-poll' );
    like( $err, qr/no longer exists/, 'the error says the volume is gone' );
    unlike( $err, qr/resize did not complete/,
        'it does not misreport a vanished volume as a stalled resize' );
    cmp_ok( $n, '<', 10, "gives up promptly instead of polling 60 times (took $n calls)" );
}

# ── volume_snapshot ────────────────────────────────────────────────────────────
{
    my ($died, $err, $n) = with_absent_cluster(sub {
        $class->volume_snapshot($scfg, 'lb', "vm-100-$UUID", 'snap1');
    });
    ok( $died, 'volume_snapshot dies when the new snapshot vanishes mid-poll' );
    like( $err, qr/no longer exists/, 'the error says the snapshot is gone' );
    cmp_ok( $n, '<', 10, "gives up promptly instead of polling 30 times (took $n calls)" );
}

# ── volume_snapshot_rollback ───────────────────────────────────────────────────
{
    my ($died, $err, $n) = with_absent_cluster(sub {
        $class->volume_snapshot_rollback($scfg, 'lb', "vm-100-$UUID", 'snap1');
    });
    ok( $died, 'volume_snapshot_rollback dies when the volume vanishes mid-poll' );
    like( $err, qr/no longer exists/, 'the error says the volume is gone' );
    cmp_ok( $n, '<', 10, "gives up promptly instead of polling 60 times (took $n calls)" );
}

# ── volume_rollback_is_possible: must not green-light a rollback ───────────────
{
    my ($died, $err) = with_absent_cluster(sub {
        $class->volume_rollback_is_possible($scfg, 'lb', "vm-100-$UUID", 'snap1', {});
    });
    ok( $died, 'volume_rollback_is_possible refuses when the volume or snapshot is gone' );
    like( $err, qr/no longer exists/, 'the error says which resource is gone' );
}

# ── the idempotent delete paths keep treating "already gone" as success ────────
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path, undef, %o) = @_;
        return { snapshots => [] } if $method eq 'GET' && $path =~ /snapshots$/;
        return $o{missing_is_undef} ? undef : {};
    };
    use warnings 'redefine';

    my $ok = eval { PVE::Storage::Custom::LightbitsPlugin::_delete_snapshot($scfg, 'default', $SNAP); 1 };
    ok( $ok, '_delete_snapshot still succeeds for an already-absent snapshot' );

    $ok = eval { $class->free_image('lb', $scfg, "vm-100-$UUID", 0); 1 };
    ok( $ok, 'free_image still succeeds for an already-absent volume' );
}

done_testing();
