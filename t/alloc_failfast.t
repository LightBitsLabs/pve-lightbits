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
# volume-list GET (used by _next_disk_index) is empty.
my $get_state = 'Available';
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.test:host' };
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    return { UUID => $UUID }            if $method eq 'POST';
    return { state => $get_state }      if $method eq 'GET' && $path =~ m{/volumes/};
    return { volumes => [] }            if $method eq 'GET';
    return {};
};
use warnings 'redefine';

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

done_testing();
