#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests that alloc_image honours the lb_compression storage option (issue #70):
# unset sends no compression field (cluster default, as before), set sends the
# string "true"/"false" the LightOS API expects, for VM disks and cloud-init
# drives alike.

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
    return do { $posted = $body; { UUID => 'feedface-0000-4000-8000-0000000000cc' } } if $method eq 'POST';
    return { state => 'Available' } if $method eq 'GET' && $path =~ m{/volumes/};
    return { volumes => [] }        if $method eq 'GET';
    return {};
};
use warnings 'redefine';

sub alloc {
    my (%opt) = @_;
    my $name = delete $opt{name};
    undef $posted;
    $class->alloc_image('lb-storage', { lb_project => 'default', %opt }, 100, 'raw', $name, 1048576);
    return $posted;
}

# ── option is declared in the schema and accepted by pvesm add/set ─────────────
my $props = $class->properties();
is( $props->{lb_compression}{type}, 'boolean', 'lb_compression is a boolean property' );
is( $props->{lb_compression}{default}, 0, 'lb_compression defaults to off' );
ok( $class->options()->{lb_compression}{optional}, 'lb_compression is optional' );

# ── unset: request unchanged, no compression field ─────────────────────────────
my $b = alloc();
ok( !exists $b->{compression}, 'no compression field when lb_compression is unset' );

# ── set: sent as the API's string form ─────────────────────────────────────────
for my $case ([1, 'true'], ['1', 'true'], [0, 'false'], ['0', 'false']) {
    my ($val, $want) = @$case;
    $b = alloc(lb_compression => $val);
    is( $b->{compression}, $want, "lb_compression '$val' is sent as compression \"$want\"" );
}
# Spellings Proxmox accepts for a boolean, should one reach the plugin as is
# (for example from a hand-edited storage.cfg): no "off" form may compress.
for my $case (['on', 'true'], ['yes', 'true'], ['true', 'true'], ['TRUE', 'true'],
              ['off', 'false'], ['no', 'false'], ['false', 'false'], ['', 'false'], ['2', 'false']) {
    my ($val, $want) = @$case;
    $b = alloc(lb_compression => $val);
    is( $b->{compression}, $want, "lb_compression '$val' is sent as compression \"$want\"" );
}
like( encode_json({ compression => alloc(lb_compression => 1)->{compression} }),
    qr/"compression":"true"/, 'compression encodes as a JSON string' );

# ── the rest of the create body is untouched ───────────────────────────────────
$b = alloc(lb_compression => 1, lb_replica_count => 3);
is( $b->{replicaCount}, 3, 'replicaCount still sent alongside compression' );
is( $b->{projectName}, 'default', 'projectName still sent alongside compression' );

# ── cloud-init drives follow the same storage setting ──────────────────────────
$b = alloc(lb_compression => 1, name => 'vm-100-cloudinit');
is( $b->{compression}, 'true', 'cloud-init drive is created with compression too' );
like( $b->{name}, qr/-cloudinit$/, 'and is still created as a cloud-init volume' );

done_testing();
