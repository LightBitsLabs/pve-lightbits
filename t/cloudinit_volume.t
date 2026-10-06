#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# A VM's cloud-init drive on Lightbits storage (pve-lightbits issue #41).
#
# qemu-server recognises a cloud-init drive only by its volume name,
# "vm-<vmid>-cloudinit" (Drive::drive_is_cloudinit), allocates it by passing
# that exact $name to alloc_image, and writes the generated ISO into path() of
# the returned volid. The plugin used to ignore $name and return
# "vm-<vmid>-<uuid>", so PVE never wrote the ISO, the guest booted without
# user-data and `qm destroy --purge` leaked the 4 MiB volume.
#
# Covered here: alloc_image honours the cloud-init name (LightOS name, role
# label, one per VM, vmid must match), parse_volname / path / list_images use
# the PVE name, every volname-taking method resolves the LightOS UUID through
# the labels, a vanished cloud-init volume is idempotent for free_image and
# volume_snapshot_delete and an error for everything else, and regular disks
# are untouched.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { no warnings 'once'; *CORE::GLOBAL::sleep = sub { 1 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $P     = 'PVE::Storage::Custom::LightbitsPlugin';
my $scfg  = { lb_project => 'default', lb_owner_id => 'lbpve3' };

my $linkdir = tempdir(CLEANUP => 1);
{ no warnings 'once'; $PVE::Storage::Custom::LightbitsPlugin::SYMLINK_DIR = $linkdir; }

my $GENID = '02b26b1b-0d41-4d3e-bd40-2970bc13db80';
my %U = (
    ci100   => 'c1000000-0000-4000-8000-000000000100',   # VM 100's cloud-init volume
    disk100 => 'd1000000-0000-4000-8000-000000000100',   # VM 100's root disk
    ci200   => 'c2000000-0000-4000-8000-000000000200',   # VM 200's cloud-init, on another PVE cluster
    ci300   => 'c3000000-0000-4000-8000-000000000300',   # VM 300's cloud-init, being deleted
);
sub lbl { my %l = @_; [ map { { key => $_, value => $l{$_} } } sort keys %l ] }
my %VOL = (
    $U{ci100}   => { UUID => $U{ci100}, name => "vm-100-$GENID-cloudinit", size => 4194304, nsid => 7, state => 'Available',
                     acl => { values => ['nqn.host.local'] },
                     labels => lbl(pveVmid => '100', pveVmgenid => $GENID, pveNode => 'lbpve3', pveRole => 'cloudinit') },
    $U{disk100} => { UUID => $U{disk100}, name => "vm-100-$GENID-disk-0", size => 2147483648, nsid => 8, state => 'Available',
                     acl => { values => ['nqn.host.local'] },
                     labels => lbl(pveVmid => '100', pveVmgenid => $GENID, pveNode => 'lbpve3') },
    $U{ci200}   => { UUID => $U{ci200}, name => "vm-200-$GENID-cloudinit", size => 4194304, nsid => 9, state => 'Available',
                     labels => lbl(pveVmid => '200', pveNode => 'other-cluster', pveRole => 'cloudinit') },
    $U{ci300}   => { UUID => $U{ci300}, name => "vm-300-$GENID-cloudinit", size => 4194304, nsid => 10, state => 'Deleting',
                     labels => lbl(pveVmid => '300', pveNode => 'lbpve3', pveRole => 'cloudinit') },
);

my @calls;      # [method, path, body] of every call
my $posted;     # last POST body
my @snaps;      # snapshots the listing returns
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.host.local' };
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    push @calls, [ $method, $path, $body ];
    if ($method eq 'POST' && $path eq '/api/v2/volumes') {
        $posted = $body;
        return { UUID => 'feedface-0000-4000-8000-00000000c1d1' };
    }
    return { volumes => [ values %VOL ] } if $method eq 'GET' && $path =~ m{^/api/v2/volumes\?};
    return { snapshots => [@snaps] }      if $method eq 'GET' && $path =~ m{/snapshots$};
    if ($method eq 'GET' && $path =~ m{^/api/v2/volumes/([0-9a-f-]+)\?}) {
        return $VOL{$1} // ($1 eq 'feedface-0000-4000-8000-00000000c1d1' ? { state => 'Available' } : {});
    }
    return {};
};
use warnings 'redefine';
my $confdir = tempdir(CLEANUP => 1);
{ no warnings 'once'; $PVE::Storage::Custom::LightbitsPlugin::QEMU_CONF_DIR = $confdir; }
open(my $fh, '>', "$confdir/100.conf") or die $!; print $fh "vmgenid: $GENID\n"; close $fh;
open($fh, '>', "$confdir/101.conf") or die $!; print $fh "vmgenid: $GENID\n"; close $fh;

sub mutating { grep { $_->[0] ne 'GET' } @calls }

# ── parse_volname ───────────────────────────────────────────────────────────────
{
    my @r = $class->parse_volname('vm-100-cloudinit');
    is_deeply( [@r[0..2], $r[4], $r[5], $r[6]], ['images', 'vm-100-cloudinit', 100, undef, 0, 'raw'],
        'parse_volname: vm-<vmid>-cloudinit is an image owned by <vmid>, raw' );
    my @s = $class->parse_volname('vm-100-cloudinit@snap1');
    is( $s[1], 'vm-100-cloudinit', 'parse_volname: @snap-qualified cloud-init name keeps the base name' );
    is( $s[4], 'snap1',            'parse_volname: ... and reports the snapshot' );
    eval { $class->parse_volname('vm-100-cloudinit-extra') };
    like( $@, qr/unable to parse/, 'parse_volname: only the exact PVE name is a cloud-init volume' );
    is( $P->can('_cloudinit_vmid')->('vm-42-cloudinit'), 42, '_cloudinit_vmid extracts the vmid' );
    is( $P->can('_cloudinit_vmid')->("vm-42-$U{disk100}"), undef, '_cloudinit_vmid is undef for a UUID volname' );
}

# ── path / link name: no API call needed ───────────────────────────────────────
{
    @calls = ();
    my ($path, $owner, $vtype) = $class->path($scfg, 'vm-100-cloudinit', 'lb', undef);
    is( $path, "$linkdir/lb/vm-100-cloudinit", 'path: cloud-init symlink is keyed on the PVE volname' );
    is( $owner, 100, 'path: owner is the vmid (so destroy frees the drive)' );
    is( scalar @calls, 0, 'path: resolving a cloud-init volname needs no API call' );
    my ($dpath) = $class->path($scfg, "vm-100-$U{disk100}", 'lb', undef);
    is( $dpath, "$linkdir/lb/$U{disk100}", 'path: regular disks are still keyed on the UUID' );
}

# ── _resolve_uuid: by labels, this storage only, not a deleting one ───────────
{
    is( $P->can('_resolve_uuid')->($scfg, 'vm-100-cloudinit'), $U{ci100}, '_resolve_uuid finds VM 100\'s cloud-init volume by labels' );
    is( $P->can('_resolve_uuid')->($scfg, 'vm-200-cloudinit'), undef, 'another PVE cluster\'s cloud-init volume is not ours' );
    is( $P->can('_resolve_uuid')->($scfg, 'vm-300-cloudinit'), undef, 'a cloud-init volume in state Deleting no longer resolves' );
    is( $P->can('_resolve_uuid')->($scfg, "vm-100-$U{disk100}"), $U{disk100}, 'a UUID volname resolves without a lookup' );
    eval { $P->can('_resolve_existing_uuid')->($scfg, 'vm-999-cloudinit') };
    like( $@, qr/vm-999-cloudinit no longer exists/, '_resolve_existing_uuid dies naming the volume when it is gone' );

    # two candidates: refuse rather than guess
    local $VOL{dup} = { UUID => 'dup00000-0000-4000-8000-000000000100', name => 'vm-100-x-cloudinit', state => 'Available',
                        labels => lbl(pveVmid => '100', pveNode => 'lbpve3', pveRole => 'cloudinit') };
    eval { $P->can('_resolve_uuid')->($scfg, 'vm-100-cloudinit') };
    like( $@, qr/VM 100 has 2 cloud-init volumes/, 'two cloud-init volumes for one VM is reported, never guessed' );
}

# ── list_images: the cloud-init volume is listed under PVE's name ──────────────
{
    my %by = map { $_->{volid} => $_ } @{ $class->list_images('lb', $scfg, undef, undef, undef) };
    ok( exists $by{'lb:vm-100-cloudinit'}, 'list_images: cloud-init volume listed as vm-<vmid>-cloudinit' );
    is( $by{'lb:vm-100-cloudinit'}{vmid}, 100, 'list_images: ... owned by the vmid' );
    is( $by{'lb:vm-100-cloudinit'}{size}, 4194304, 'list_images: ... with its size' );
    ok( !(grep { /\Q$U{ci100}\E/ } keys %by), 'list_images: the same volume is NOT also listed under its UUID' );
    ok( exists $by{"lb:vm-100-$U{disk100}"}, 'list_images: regular disks keep the UUID volid' );
    ok( !(grep { /vm-200-/ } keys %by), 'list_images: another cluster\'s cloud-init volume is not listed' );
    my %only100 = map { $_->{volid} => 1 } @{ $class->list_images('lb', $scfg, 100, undef, undef) };
    is_deeply( [sort keys %only100], ['lb:vm-100-cloudinit', "lb:vm-100-$U{disk100}"],
        'list_images(vmid=100): both of VM 100\'s volumes, nothing else (what destroy --purge frees)' );
}

# ── alloc_image: honours PVE's cloud-init name ─────────────────────────────────
{
    @calls = (); $posted = undef;
    my $volname = $class->alloc_image('lb', $scfg, 101, 'raw', 'vm-101-cloudinit', 4096);
    is( $volname, 'vm-101-cloudinit', 'alloc_image returns the exact name PVE asked for' );
    is( $posted->{name}, "vm-101-$GENID-cloudinit", 'LightOS volume name is vm-<vmid>-<vmgenid>-cloudinit' );
    is( $posted->{size}, '4194304', '4 MiB (PVE passes 4096 KiB)' );
    my %lbl = map { $_->{key} => $_->{value} } @{ $posted->{labels} };
    is( $lbl{pveRole}, 'cloudinit', 'pveRole=cloudinit label written' );
    is( $lbl{pveVmid}, '101', 'ownership labels still written' );
    is( $lbl{pveNode}, 'lbpve3', '... including pveNode' );

    @calls = (); $posted = undef;
    my $disk = $class->alloc_image('lb', $scfg, 101, 'raw', undef, 1048576);
    like( $disk, qr/^vm-101-feedface-/, 'alloc_image without a name: UUID volid as before' );
    like( $posted->{name}, qr/^vm-101-\Q$GENID\E-disk-\d+$/, '... LightOS disk name as before' );
    ok( !(grep { $_->{key} eq 'pveRole' } @{ $posted->{labels} }), '... and no role label on a regular disk' );

    @calls = (); $posted = undef;
    my $named = $class->alloc_image('lb', $scfg, 101, 'raw', 'vm-101-disk-3', 1048576);
    like( $named, qr/^vm-101-feedface-/, 'a non-cloud-init $name is advisory: UUID scheme kept' );

    eval { $class->alloc_image('lb', $scfg, 101, 'raw', 'vm-100-cloudinit', 4096) };
    like( $@, qr/does not belong to VM 101/, 'a cloud-init name for a different vmid is refused' );

    @calls = (); $posted = undef;
    eval { $class->alloc_image('lb', $scfg, 100, 'raw', 'vm-100-cloudinit', 4096) };
    like( $@, qr/VM 100 already has a cloud-init volume .* \Q$U{ci100}\E/, 'a second cloud-init volume for a VM is refused, naming the existing one' );
    ok( !defined $posted, '... and nothing was created' );
}

# ── volume_size_info / activate: resolve through the labels ────────────────────
{
    is( scalar $class->volume_size_info($scfg, 'lb', 'vm-100-cloudinit'), 4194304,
        'volume_size_info resolves the cloud-init volume and returns its size' );
    eval { $class->volume_size_info($scfg, 'lb', 'vm-999-cloudinit') };
    like( $@, qr/vm-999-cloudinit no longer exists/, 'volume_size_info on a missing cloud-init volume dies (PVE then re-allocates it)' );
}

# ── free_image: deletes the resolved volume; idempotent when gone ──────────────
{
    make_path("$linkdir/lb");
    symlink('/dev/null', "$linkdir/lb/vm-100-cloudinit");
    @calls = ();
    $class->free_image('lb', $scfg, 'vm-100-cloudinit', 0);
    my @del = grep { $_->[0] eq 'DELETE' } @calls;
    is( scalar @del, 1, 'free_image issues one DELETE' );
    like( $del[0][1], qr{^/api/v2/volumes/\Q$U{ci100}\E\?}, '... for the UUID resolved from the labels' );
    ok( !-l "$linkdir/lb/vm-100-cloudinit", '... and removes the volname-keyed symlink' );

    symlink('/dev/null', "$linkdir/lb/vm-999-cloudinit");
    @calls = ();
    my $r = eval { $class->free_image('lb', $scfg, 'vm-999-cloudinit', 0); 1 };
    ok( $r, 'free_image on a vanished cloud-init volume succeeds (idempotent)' ) or diag $@;
    is( scalar(mutating()), 0, '... with no mutating API call' );
    ok( !-l "$linkdir/lb/vm-999-cloudinit", '... and a leftover symlink is removed' );
}

# ── snapshots / resize use the same resolution ─────────────────────────────────
{
    @snaps = ( { name => "snap-$U{ci100}-s1", UUID => 'sa', sourceVolumeUUID => $U{ci100} } );
    my $info = $class->volume_snapshot_info($scfg, 'lb', 'vm-100-cloudinit');
    is_deeply( [keys %$info], ['s1'], 'volume_snapshot_info lists the resolved volume\'s snapshots' );

    @calls = ();
    my $r = eval { $class->volume_snapshot_delete($scfg, 'lb', 'vm-999-cloudinit', 's1', 0); 1 };
    ok( $r, 'volume_snapshot_delete on a vanished cloud-init volume is a no-op' ) or diag $@;
    is( scalar(mutating()), 0, '... with no mutating API call' );

    eval { $class->volume_resize($scfg, 'lb', 'vm-999-cloudinit', 8388608, 0) };
    like( $@, qr/vm-999-cloudinit no longer exists/, 'volume_resize on a vanished cloud-init volume dies' );
}

# ── deactivate_volume: link by volname, no API resolution ──────────────────────
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_subsys_nqn   = sub { 'nqn.test' };
    local *PVE::Storage::Custom::LightbitsPlugin::_is_connected = sub { 0 };
    symlink('/dev/null', "$linkdir/lb/vm-100-cloudinit");
    @calls = ();
    $class->deactivate_volume('lb', $scfg, 'vm-100-cloudinit', undef, {});
    ok( !-l "$linkdir/lb/vm-100-cloudinit", 'deactivate_volume removes the volname-keyed symlink' );
    is( scalar @calls, 0, '... without any API call' );
}

done_testing();
