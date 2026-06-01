#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# The volid encodes the owning vmid (vm-<vmid>-<uuid>) so that parse_volname and
# path() can report the owner. That owner is what qemu-server's destroy_vm uses
# to free a VM's *referenced* disks — without it, destroying a VM leaks its
# Lightbits volumes (PVE's "referenced disks will always be destroyed" relies on
# path() returning owner == vmid).

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $U     = '6cfb3b59-2fab-4c6e-914b-6d7b1193caac';

# ── parse_volname: owner vmid is the 3rd return value ───────────────────────────
{
    my ($vtype, $name, $vmid) = $class->parse_volname("vm-100-$U");
    is( $vtype, 'images', 'parse_volname: vtype images' );
    is( $name,  "vm-100-$U", 'parse_volname: name is the full volname' );
    is( $vmid,  100, 'parse_volname: owner vmid extracted from vm-<vmid>-<uuid>' );

    my (undef, undef, $vmid0) = $class->parse_volname($U);   # bare UUID
    is( $vmid0, 0, 'parse_volname: bare UUID -> owner 0 (unowned)' );

    eval { $class->parse_volname('not-a-volume') };
    like( $@, qr/unable to parse/, 'parse_volname rejects a non-volume name' );
}

# ── path(): returns ( <uuid symlink>, <owner vmid>, 'images' ) ──────────────────
{
    my ($path, $owner, $vtype) = $class->path({ lb_project => 'default' }, "vm-100-$U", 'lb-storage', undef);
    is( $path,  "/dev/lightbits/lb-storage/$U", 'path: symlink keyed on the UUID' );
    is( $owner, 100, 'path: owner vmid returned (so destroy frees the disk)' );
    is( $vtype, 'images', 'path: vtype images' );
}

# ── _vol_uuid: recovers the Lightbits UUID from either form ─────────────────────
is( PVE::Storage::Custom::LightbitsPlugin::_vol_uuid("vm-9999-$U"), $U, '_vol_uuid from vm-<vmid>-<uuid>' );
is( PVE::Storage::Custom::LightbitsPlugin::_vol_uuid($U),           $U, '_vol_uuid from a bare UUID' );

# ── volume_size_info: query size from the API (needed to attach an existing disk)
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        return { size => '2147483648', statistics => { logicalUsedStorage => '1048576' } };
    };
    my $size = $class->volume_size_info({ lb_project => 'default' }, 'lb-storage', "vm-100-$U");
    is( $size, 2147483648, 'volume_size_info (scalar) returns the size' );
    my @info = $class->volume_size_info({ lb_project => 'default' }, 'lb-storage', "vm-100-$U");
    is( $info[0], 2147483648, 'volume_size_info (list): size' );
    is( $info[1], 'raw',       'volume_size_info (list): format is raw' );
}

done_testing();
