#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests that alloc_image fails fast instead of returning success for a volume
# that never became usable. A volume that lands in a terminal cluster failure
# state (or never reaches Available) must raise an error at create time — not be
# returned as a valid volid and then blow up later in activate_volume with the
# unhelpful "Cannot determine NSID" message.

use strict;
use warnings;
use Test::More;
use FindBin;

# No real sleeping in the poll loop, so the timeout path runs instantly.
BEGIN { *CORE::GLOBAL::sleep = sub { }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-0000000000aa';

# Stub the cluster: POST creates, single-volume GET reports $get_state, the
# volume-list GET (used by _next_disk_index) is empty. DELETEs are recorded so
# the orphan-cleanup behaviour can be asserted, and can be made to fail.
my $get_state = 'Available';
my @deletes;
my $delete_fails = 0;
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.test:host' };
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    if ($method eq 'DELETE') {
        push @deletes, $path;
        die "Lightbits API DELETE $path failed: 503 Service Unavailable\n" if $delete_fails;
        return {};
    }
    return { UUID => $UUID }            if $method eq 'POST';
    return { state => $get_state }      if $method eq 'GET' && $path =~ m{/volumes/};
    return { volumes => [] }            if $method eq 'GET';
    return {};
};
use warnings 'redefine';

# Run alloc_image, returning ($died, $err, \@deletes_issued, \@warnings).
sub alloc {
    @deletes = ();
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $ok = eval { $class->alloc_image('lb-storage', $_[0], 100, 'raw', undef, 1048576); 1 };
    return (!$ok, $@, [@deletes], \@warnings);
}

my $scfg = { lb_project => 'default', lb_owner_id => 'node-a' };

# ── happy path: Available → returns the volid ──────────────────────────────────
$get_state = 'Available';
my $volid = eval { $class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576) };
is( $volid, "vm-100-$UUID", 'alloc_image returns the volid once the volume is Available' );

# ── terminal failure: Failed → die fast, with UUID and state in the message ────
$get_state = 'Failed';
my $ok = eval { $class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576); 1 };
ok( !$ok, 'alloc_image dies when the volume enters a Failed state' );
like( $@, qr/\Q$UUID\E/,        'failure error names the volume UUID' );
like( $@, qr/state 'Failed'/,   'failure error reports the Failed state' );

# ── other terminal states (Deleting/Deleted) also die fast ─────────────────────
for my $term ('Deleting', 'Deleted') {
    $get_state = $term;
    $ok = eval { $class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576); 1 };
    ok( !$ok, "alloc_image dies when the volume enters a $term state" );
    like( $@, qr/\Q$UUID\E/,         "$term failure error names the volume UUID" );
    like( $@, qr/state '\Q$term\E'/, "$term failure error reports the $term state" );
}

# ── never converges: stuck Creating → die on timeout ───────────────────────────
$get_state = 'Creating';
$ok = eval { $class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576); 1 };
ok( !$ok, 'alloc_image dies when the volume never becomes Available' );
like( $@, qr/did not become Available/, 'timeout error explains it never became Available' );
like( $@, qr/last state 'Creating'/,    'timeout error reports the last-seen state' );

# ── orphan cleanup ─────────────────────────────────────────────────────────────
#
# PVE only starts tracking a volume once alloc_image returns a volid, so a
# volume that was created on the cluster but never became usable has nothing
# left to reap it. It must be deleted here or it strands, holding its name
# (LightOS enforces per-project name uniqueness) and possibly its space.

# A volume stuck mid-creation is deleted before the timeout error is raised.
$get_state = 'Creating';
{
    my ($died, $err, $dels, $warns) = alloc($scfg);
    ok( $died, 'timeout still raises an error' );
    is( scalar(@$dels), 1, 'a volume that never converged is deleted' );
    like( $dels->[0], qr{^/api/v2/volumes/\Q$UUID\E\?projectName=default$},
        'the DELETE targets the project-scoped UUID of the volume just created' );
    like( $err, qr/did not become Available/,
        'the creation error is still what surfaces, not the cleanup' );
    is( scalar(@$warns), 0, 'a successful cleanup is silent' );
}

# A terminally Failed volume is likewise removed.
$get_state = 'Failed';
{
    my ($died, $err, $dels) = alloc($scfg);
    ok( $died, 'Failed state still raises an error' );
    is( scalar(@$dels), 1, 'a Failed volume is deleted' );
    like( $err, qr/state 'Failed'/, 'the Failed creation error still surfaces' );
}

# Deleting/Deleted need no DELETE - the cluster is already removing them.
for my $term ('Deleting', 'Deleted') {
    $get_state = $term;
    my ($died, $err, $dels) = alloc($scfg);
    ok( $died, "$term state still raises an error" );
    is( scalar(@$dels), 0, "no redundant DELETE is issued for a $term volume" );
}

# A cleanup that itself fails must not mask the creation error: the operator
# needs the reason the volume failed, plus a warning that an orphan is left.
$get_state    = 'Failed';
$delete_fails = 1;
{
    my ($died, $err, $dels, $warns) = alloc($scfg);
    ok( $died, 'a failed cleanup still raises the creation error' );
    like( $err, qr/state 'Failed'/,
        'the creation error is preserved, not replaced by the delete error' );
    is( scalar(@$warns), 1, 'the failed cleanup warns exactly once' );
    like( $warns->[0], qr/\Q$UUID\E/, 'the warning names the orphaned volume' );
    like( $warns->[0], qr/deleted manually/,
        'the warning tells the operator manual cleanup may be needed' );
}
$delete_fails = 0;

# A polling GET that throws must also clean up. This is a separate exit path
# from a bad state: a transport failure, every endpoint returning 5xx, or the
# volume vanishing out of band all raise rather than reporting a state, and
# letting that propagate would strand the volume just the same.
{
    my @deleted;
    my $get_dies = 1;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path) = @_;
        return { UUID => $UUID } if $method eq 'POST';
        return { volumes => [] } if $method eq 'GET' && $path =~ /volumes\?/;
        if ($method eq 'DELETE') { push @deleted, $path; return {} }
        die "Lightbits API GET $path failed via 10.0.0.1:443: 503 Service Unavailable\n"
            if $get_dies;
        return { state => 'Available' };
    };
    use warnings 'redefine';

    my $ok = eval { $class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576); 1 };
    ok( !$ok, 'alloc_image still raises when the status poll itself fails' );
    like( $@, qr/503 Service Unavailable/,
        'the underlying API error is re-raised unchanged, not summarised away' );
    unlike( $@, qr/did not become Available/,
        'a transport failure is not misreported as a convergence timeout' );
    is( scalar(@deleted), 1, 'the volume is deleted even though polling never returned a state' );
    like( $deleted[0], qr{^/api/v2/volumes/\Q$UUID\E\?projectName=default$},
        'the cleanup targets the volume that was just created' );
}

# The happy path must not delete anything.
$get_state = 'Available';
{
    my ($died, $err, $dels) = alloc($scfg);
    ok( !$died, 'a successful allocation does not raise' );
    is( scalar(@$dels), 0, 'a successful allocation deletes nothing' );
}

done_testing();
