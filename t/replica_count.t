#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests that alloc_image honours the lb_replica_count storage option, defaulting
# to 1 (single replica) when it is not set.

use strict;
use warnings;
use Test::More;
use FindBin;
use JSON qw(encode_json);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';

# Capture the POST body; report Available immediately and an empty volume list.
my $posted;
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.test:host' };
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    return do { $posted = $body; { UUID => 'feedface-0000-4000-8000-0000000000bb' } } if $method eq 'POST';
    return { state => 'Available' } if $method eq 'GET' && $path =~ m{/volumes/};
    return { volumes => [] }        if $method eq 'GET';
    return {};
};
use warnings 'redefine';

# ── default: no lb_replica_count → replicaCount 1 ──────────────────────────────
$class->alloc_image('lb-storage', { lb_project => 'default' }, 100, 'raw', undef, 1048576);
is( $posted->{replicaCount}, 1, 'defaults to replicaCount 1 when lb_replica_count is unset' );

# ── explicit values flow through to the create body ────────────────────────────
for my $rc (1, 2, 3) {
    $class->alloc_image('lb-storage', { lb_project => 'default', lb_replica_count => $rc },
        100, 'raw', undef, 1048576);
    is( $posted->{replicaCount}, $rc, "lb_replica_count $rc is sent as replicaCount $rc" );
}

# ── a string value (as parsed from storage.cfg) serialises as a JSON number ─────
$class->alloc_image('lb-storage', { lb_project => 'default', lb_replica_count => '2' },
    100, 'raw', undef, 1048576);
is( $posted->{replicaCount}, 2, 'string lb_replica_count is accepted' );
like( encode_json({ replicaCount => $posted->{replicaCount} }), qr/"replicaCount":2(?!")/,
    'replicaCount encodes as a JSON number, not a quoted string' );

done_testing();
