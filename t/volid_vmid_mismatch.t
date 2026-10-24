#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# The VM id in a volume name must match the volume's pveVmid label. The plugin
# resolves a volume by its LightOS UUID alone, while Proxmox takes the owning VM
# (and the permissions it checks) from the VM id in the name. Before this guard
# a hand-made volid such as "vm-9313-<uuid of VM 9312's disk>" was accepted:
# `qm set 9313 --scsi1 <it>` attached VM 9312's disk to VM 9313 and
# `pvesm free <it>` deleted VM 9312's disk (found by fuzzing, PVE 9.2.21 /
# LightOS 3.21.1).
#
# Every entry point that hands out or changes a volume must refuse such a name
# before it calls the API with anything but GET; the volume's own name keeps
# working.

use strict;
use warnings;
use Test::More;
use FindBin;

BEGIN { no warnings 'once'; *CORE::GLOBAL::sleep = sub { 1 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $scfg  = { lb_project => 'default', lb_owner_id => 'lbpve4', lb_subsys_nqn => 'nqn.2016-01.com.lightbitslabs:uuid:test' };

my $U    = '9a1b2c3d-1111-4111-8111-111111111111';   # VM 9312's disk
my $PADU = '9a1b2c3d-2222-4222-8222-222222222222';   # labelled pveVmid=0009314
my %VOL = (
    $U    => { UUID => $U, size => 1073741824, nsid => 7, name => "vm-9312-$U-disk-0",
               acl => { values => ['nqn.host.local'] },
               labels => [ { key => 'pveVmid', value => '9312' }, { key => 'pveVmgenid', value => 'g' },
                           { key => 'pveNode', value => 'lbpve4' } ] },
    $PADU => { UUID => $PADU, size => 1073741824, nsid => 8, name => "vm-9314-$PADU-disk-0",
               acl => { values => ['nqn.host.local'] },
               labels => [ { key => 'pveVmid', value => '0009314' }, { key => 'pveNode', value => 'lbpve4' } ] },
);
my $SNAP = { UUID => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name => "snap-$U-s1", sourceVolumeUUID => $U, size => 1073741824, state => 'Available' };

my @writes;          # every non-GET API call: [method, path]
my $gone = 0;        # GET of $U returns {} (volume deleted out of band)
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    push @writes, [ $method, $path ] if $method ne 'GET';
    return { volumes => [ values %VOL ] } if $method eq 'GET' && $path =~ m{^/api/v2/volumes\?};
    return { snapshots => [$SNAP] }       if $method eq 'GET' && $path =~ m{/snapshots$};
    return $SNAP                          if $method eq 'GET' && $path =~ m{/snapshots/};
    if ($method eq 'GET' && $path =~ m{^/api/v2/volumes/([0-9a-f-]+)\?}) {
        return {} if $gone && $1 eq $U;
        return $VOL{$1} // {};
    }
    return { UUID => $SNAP->{UUID}, state => 'Available' };
};
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.host.local' };
use warnings 'redefine';

my $own   = "vm-9312-$U";
my $thief = "vm-9313-$U";

# ── every guarded entry point refuses the mismatched name, before any write ────
my %entry = (
    'volume_size_info (attach)' => sub { $class->volume_size_info($scfg, 'lb', $_[0]) },
    'activate_volume'           => sub { $class->activate_volume('lb', $scfg, $_[0]) },
    'free_image'                => sub { $class->free_image('lb', $scfg, $_[0]) },
    'volume_resize'             => sub { $class->volume_resize($scfg, 'lb', $_[0], 2147483648, 0) },
    'volume_snapshot'           => sub { $class->volume_snapshot($scfg, 'lb', $_[0], 's2') },
    'volume_snapshot_delete'    => sub { $class->volume_snapshot_delete($scfg, 'lb', $_[0], 's1', 0) },
    'volume_snapshot_rollback'  => sub { $class->volume_snapshot_rollback($scfg, 'lb', $_[0], 's1') },
);
for my $what (sort keys %entry) {
    @writes = ();
    eval { $entry{$what}->($thief) };
    like($@, qr/names VM 9313, but the volume belongs to VM 9312/, "$what refuses a name with another VM's id");
    is(scalar(@writes), 0, "$what made no API write for it");
}

# bare UUID (names no guest) and snapshot-qualified variants are refused too
@writes = ();
eval { $class->free_image('lb', $scfg, $U) };
like($@, qr/names VM 0, but the volume belongs to VM 9312/, 'bare UUID refused for a guest-owned volume');
eval { $class->volume_size_info($scfg, 'lb', "$thief\@s1") };
like($@, qr/names VM 9313/, 'snapshot-qualified mismatched name refused');
is(scalar(@writes), 0, 'no API write for either');

# ── the volume's own name still works ──────────────────────────────────────────
my $size = eval { $class->volume_size_info($scfg, 'lb', $own) };
is($@, '', 'size info with the right VM id');
is($size, 1073741824, 'returns the size');
@writes = ();
eval { $class->volume_snapshot($scfg, 'lb', $own, 's2') };
is($@, '', 'snapshot with the right VM id');
ok((grep { $_->[0] eq 'POST' && $_->[1] =~ m{/snapshots$} } @writes), 'snapshot POSTed');

# leading zeros in the label (or the name) do not matter, other digits do
is(eval { $class->volume_size_info($scfg, 'lb', "vm-9314-$PADU") } // $@, 1073741824, 'label 0009314 matches name 9314');
is(eval { $class->volume_size_info($scfg, 'lb', "vm-0009314-$PADU") } // $@, 1073741824, 'label 0009314 matches name 0009314');
eval { $class->volume_size_info($scfg, 'lb', "vm-93140-$PADU") };
like($@, qr/names VM 93140/, 'label 0009314 does not match name 93140');

# free with the right name deletes; a vanished volume stays an idempotent no-op
@writes = ();
eval { $class->free_image('lb', $scfg, $own) };
is($@, '', 'free with the right VM id');
ok((grep { $_->[0] eq 'DELETE' && $_->[1] =~ m{/volumes/$U} } @writes), 'volume DELETEd');
$gone = 1; @writes = ();
eval { $class->free_image('lb', $scfg, $thief) };
is($@, '', 'free of an already vanished volume is a no-op, whatever the name');
is(scalar(@writes), 0, 'and writes nothing');

done_testing();
