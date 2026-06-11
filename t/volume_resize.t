#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for volume_resize: the LightOS PUT request shape and 4 KiB alignment.
#
# PVE hands volume_resize the new TOTAL size in bytes (already padded to a 1 KiB
# multiple). We 4 KiB-align it for LightOS, PUT it to the project-scoped volume
# endpoint, poll until the reported size catches up, and return the aligned size.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';

# ── _api stub: capture the PUT, and report the requested size back on GET so the
#    poll loop exits on the first attempt (no real sleeping). ─────────────────────
my %put;          # captured PUT (method/path/body)
my $reported = 0; # size the GET poll returns
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    if ($method eq 'PUT') {
        %put = (path => $path, body => $body);
        $reported = $body->{size};   # cluster now reports the new size
        return {};
    }
    return { size => $reported, state => 'Available' } if $method eq 'GET';
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $volname = 'vm-100-feedface-0000-4000-8000-000000000abc';
my $UUID    = 'feedface-0000-4000-8000-000000000abc';

# ── PUT request shape ───────────────────────────────────────────────────────────
my $ret = $class->volume_resize($scfg, 'lb-storage', $volname, 4096, 0);
is( $put{path}, "/api/v2/volumes/$UUID?projectName=default",
    'PUT targets the project-scoped volume UUID endpoint' );
is( $put{body}{projectName}, 'default', 'PUT body carries the project name' );
is( $put{body}{size}, '4096', 'PUT body size is a stringified byte count' );
is( $ret, 4096, 'returns the aligned byte size' );

# ── 4 KiB alignment across representative sizes ─────────────────────────────────
my %expect = (
    1          => 4096,           # rounds up to one block
    4096       => 4096,           # already aligned
    4097       => 8192,           # just over a block -> next block
    1073741824 => 1073741824,     # 1 GiB, already aligned
    1073741825 => 1073745920,     # 1 GiB + 1 byte -> next block
);
for my $in (sort { $a <=> $b } keys %expect) {
    my $got = $class->volume_resize($scfg, 'lb-storage', $volname, $in, 0);
    is( $got, $expect{$in}, "size $in aligns to $expect{$in}" );
    is( $put{body}{size}, "$expect{$in}", "  PUT body for $in is the aligned size" );
}

# ── resizes regardless of the running flag (network block storage) ──────────────
$class->volume_resize($scfg, 'lb-storage', $volname, 8192, 1);
is( $put{body}{size}, '8192', 'still issues the PUT when the guest is running' );

done_testing();
