#!/usr/bin/perl
# Regression test for list_images() volume ownership.
#
# When a VM is destroyed with "purge unreferenced disks", qemu-server calls
# vdisk_list($cfg, undef, $vmid, ...) -> list_images(..., $vmid, ...) and frees
# every volume it returns. A volume whose LightOS name has no "vm-<vmid>-"
# prefix has no owner; it must therefore be reported with a *defined* vmid (0)
# and must NOT be attributed to — and thus deleted alongside — an unrelated VM.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $scfg  = { lb_project => 'default' };

# Mirrors a real cluster: a Proxmox-created disk for VM 100, another VM's disk,
# and a hand-created volume ("john") that does not follow the vm-<id>- naming.
my @cluster_volumes = (
    { UUID => '74754ae7-f30d-4e4d-8b7f-d7240cad6049', name => 'vm-100-disk',      size => 2147483648 },
    { UUID => '79e42785-5535-47f4-8c88-29e186127dff', name => 'vm-9999-test-vol', size => 4294967296 },
    { UUID => 'aed38be7-8d19-44e8-8627-b111079e8aa1', name => 'john',             size => 2040109465 },
);

# Run list_images offline against the fixture above.
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub { return { volumes => [@cluster_volumes] } };
use warnings 'redefine';

my $disk_100  = 'lb-storage:vm-100-74754ae7-f30d-4e4d-8b7f-d7240cad6049';
my $disk_9999 = 'lb-storage:vm-9999-79e42785-5535-47f4-8c88-29e186127dff';
my $john      = 'lb-storage:vm-0-aed38be7-8d19-44e8-8627-b111079e8aa1';

sub by_volid {
    my ($vmid) = @_;
    my $list = $class->list_images('lb-storage', $scfg, $vmid, undef, undef);
    return { map { $_->{volid} => $_ } @$list };
}

# --- Destroying VM 100 must only target VM 100's disk -----------------------
{
    my $owned = by_volid(100);
    ok( exists $owned->{$disk_100}, 'vm-100-disk is listed for vmid 100 (still cleaned up on destroy)' );
    ok( !exists $owned->{$john},    'john (no vm- prefix) is NOT listed for vmid 100 -> survives VM 100 destroy' );
    ok( !exists $owned->{$disk_9999}, "another VM's disk is NOT listed for vmid 100" );
    is( scalar keys %$owned, 1, 'exactly one volume attributed to vmid 100' );
}

# --- Destroying an unrelated VM (9999) must also leave john alone -----------
{
    my $owned = by_volid(9999);
    ok( exists $owned->{$disk_9999}, 'vm-9999-test-vol is listed for vmid 9999' );
    ok( !exists $owned->{$john},     'john is NOT swept up when destroying vmid 9999' );
    is( scalar keys %$owned, 1, 'exactly one volume attributed to vmid 9999' );
}

# --- Unfiltered listing: every vmid is defined (no uninit-value warning) ----
{
    my $all = by_volid(undef);
    is( scalar keys %$all, 3, 'all volumes listed when no vmid filter is given' );
    ok( defined $all->{$_}{vmid}, "vmid is defined for $_ (avoids uninitialized-value warning)" )
        for sort keys %$all;
    is( $all->{$john}{vmid},     0,    'unowned volume reports vmid 0' );
    is( $all->{$disk_100}{vmid}, 100,  'vm-100-disk reports vmid 100' );
    is( $all->{$disk_9999}{vmid}, 9999, 'vm-9999-test-vol reports vmid 9999' );
}

done_testing();
