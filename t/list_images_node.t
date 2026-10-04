#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Node-aware ownership: when several Proxmox hypervisors share one Lightbits
# project, list_images must only ever return volumes owned by THIS node, so a
# VM destroy here can never delete another hypervisor's same-numbered VM disks.
# Volumes are scoped via the pveNode label; a volume without the plugin's
# labels is not ours at all, however it is named.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';

my @vols = (
    # this node's VM 100 disk
    { UUID => '11111111-1111-1111-1111-111111111111', size => 1,
      name => 'vm-100-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa-disk-0',
      labels => [ { key => 'pveVmid', value => '100' },
                  { key => 'pveNode', value => 'node-a' } ] },
    # ANOTHER node's VM 100 disk (must never be seen here)
    { UUID => '22222222-2222-2222-2222-222222222222', size => 1,
      name => 'vm-100-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb-disk-0',
      labels => [ { key => 'pveVmid', value => '100' },
                  { key => 'pveNode', value => 'node-b' } ] },
    # unlabeled volume that merely LOOKS like a VM 100 disk -> not ours
    { UUID => '33333333-3333-3333-3333-333333333333', size => 1, name => 'vm-100-disk' },
);

no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub { return { volumes => [@vols] } };
use warnings 'redefine';

my $scfg = { lb_project => 'default', lb_owner_id => 'node-a' };
my $A = 'lb-storage:vm-100-11111111-1111-1111-1111-111111111111';
my $B = 'lb-storage:vm-100-22222222-2222-2222-2222-222222222222';
my $L = 'lb-storage:vm-100-33333333-3333-3333-3333-333333333333';

sub vols {
    my ($vmid) = @_;
    my $l = $class->list_images('lb-storage', $scfg, $vmid, undef, undef);
    return { map { $_->{volid} => $_ } @$l };
}

# --- Destroying VM 100 on node-a must not reach node-b's volume ----------------
{
    my $o = vols(100);
    ok(  exists $o->{$A}, "this node's vm-100 disk is listed" );
    ok( !exists $o->{$B}, "another node's vm-100 disk is NOT listed (no cross-hypervisor delete)" );
    ok( !exists $o->{$L}, "an unlabeled vm-100-named volume is NOT listed (no name-based ownership)" );
    is( scalar keys %$o, 1, "only this node's labelled vm-100 volume is returned" );
}

# --- Full listing never exposes another node's volumes -------------------------
{
    my $o = vols(undef);
    ok( !exists $o->{$B}, "another node's volume never appears in this node's listing" );
    is( $o->{$A}{vmid}, 100, 'vmid taken from the pveVmid label' );
    ok( !exists $o->{$L}, 'the unlabeled look-alike never appears in the full listing either' );
}

done_testing();
