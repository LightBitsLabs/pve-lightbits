#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Ownership guard for volumes the plugin did not create. A LightOS project that
# is shared with other consumers (lbcli users, another hypervisor, application
# servers) holds volumes PVE must never see or touch:
#
#   - list_images must not return them (PVE would otherwise present them as
#     "unused disks" with a Remove button),
#   - free_image must refuse them (an operator can hand any volid to
#     `pvesm free`; this used to delete the foreign volume and its snapshots),
#   - activate_volume must refuse them before its ACL grant (attaching a
#     foreign volid used to rewrite the foreign volume's ACL and never revert it).
#
# Ownership is strictly label-based: an unlabelled volume is foreign however
# it is named (a "legacy" look-alike below). A volume that no longer exists is
# still an idempotent no-op for free_image. Reproduces what was observed live on
# 2026-10-04 against a pre-populated 3-node LightOS 3.20.1 cluster.

use strict;
use warnings;
use Test::More;
use FindBin;

BEGIN { no warnings 'once'; *CORE::GLOBAL::sleep = sub { 1 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $scfg  = { lb_project => 'default', lb_owner_id => 'lbpve3' };

my %U = (
    ours      => '11111111-1111-4111-8111-111111111111',
    legacy    => '22222222-2222-4222-8222-222222222222',   # unlabelled, plugin-like name
    other_pve => '33333333-3333-4333-8333-333333333333',
    foreign   => '44444444-4444-4444-8444-444444444444',   # lbcli-created, no labels
    decoy     => '55555555-5555-4555-8555-555555555555',   # hand-labelled pveNode only
    allowany  => '66666666-6666-4666-8666-666666666666',   # foreign, ACL ALLOW_ANY
);
my %VOL = (
    $U{ours}      => { UUID => $U{ours}, size => 1, nsid => 11, name => "vm-100-$U{ours}-disk-0",
                       acl => { values => ['nqn.host.local'] },
                       labels => [ { key => 'pveVmid', value => '100' }, { key => 'pveVmgenid', value => 'g' },
                                   { key => 'pveNode', value => 'lbpve3' } ] },
    $U{legacy}    => { UUID => $U{legacy}, size => 1, nsid => 12, name => 'vm-101-legacy-disk-0',
                       acl => { values => ['nqn.host.local'] } },
    $U{other_pve} => { UUID => $U{other_pve}, size => 1, nsid => 13, name => "vm-100-$U{other_pve}-disk-0",
                       labels => [ { key => 'pveVmid', value => '100' }, { key => 'pveNode', value => 'other-cluster' } ] },
    $U{foreign}   => { UUID => $U{foreign}, size => 4294967296, nsid => 2, name => 'pre-def-r3-host',
                       acl => { values => ['nqn.consumer'] } },
    $U{decoy}     => { UUID => $U{decoy}, size => 1, nsid => 5, name => 'pre-def-decoy',
                       acl => { values => ['nqn.consumer'] },
                       labels => [ { key => 'pveNode', value => 'lbpve3' }, { key => 'origin', value => 'pre-existing' } ] },
    $U{allowany}  => { UUID => $U{allowany}, size => 1, nsid => 3, name => 'pre-def-r2-any',
                       acl => { values => ['ALLOW_ANY'] } },
);

my @calls;   # every non-GET API call: [method, path]
my $gone = {};   # uuid => 1 : GET returns {} (deleted out of band)
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    push @calls, [ $method, $path ] if $method ne 'GET';
    return { volumes => [ values %VOL ] } if $method eq 'GET' && $path =~ m{^/api/v2/volumes\?};
    return { snapshots => [] }            if $method eq 'GET' && $path =~ m{/snapshots$};
    if ($method eq 'GET' && $path =~ m{^/api/v2/volumes/([0-9a-f-]+)\?}) {
        return {} if $gone->{$1};
        return $VOL{$1} // {};
    }
    return {};
};
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.host.local' };
use warnings 'redefine';

sub volid { "lb-storage:vm-$_[0]-$_[1]" }

# ── list_images: only this storage's volumes, foreign ones never appear ────────
{
    my $l = $class->list_images('lb-storage', $scfg, undef, undef, undef);
    my %by = map { $_->{volid} => $_ } @$l;
    ok(  exists $by{ volid(100, $U{ours}) },   'labelled volume of this storage is listed' );
    ok( !(grep { /$U{legacy}/ } keys %by),   'unlabelled volume with a plugin-like vm-<id>- name is not listed (no name-based ownership)' );
    ok( !exists $by{ volid(100, $U{other_pve}) }, "another PVE cluster's volume is not listed" );
    ok( !(grep { /$U{foreign}/ } keys %by),  'lbcli-created volume (no labels, foreign name) is not listed' );
    ok( !(grep { /$U{decoy}/ } keys %by),    'volume carrying only a pveNode label (never written by the plugin alone) is not listed' );
    ok( !(grep { /$U{allowany}/ } keys %by), 'foreign ALLOW_ANY volume is not listed' );
    ok( !(grep { /:vm-0-/ } keys %by),       'no vm-0 ("unowned") volids are produced any more' );
    is( scalar keys %by, 1, 'exactly the one labelled plugin volume is listed' );
}

# ── free_image: refuses foreign volumes, still frees ours, idempotent on gone ──
for my $k (qw(foreign decoy other_pve allowany legacy)) {
    @calls = ();
    eval { $class->free_image('lb-storage', $scfg, "vm-0-$U{$k}", 0) };
    like( $@, qr/refusing to delete Lightbits volume $U{$k}/, "free_image refuses the $k volume" );
    like( $@, qr/lbpve3/, "  ...and names this storage's owner id" );
    is( scalar(@calls), 0, "  ...without issuing any mutating API call" );
}
{
    @calls = ();
    eval { $class->free_image('lb-storage', $scfg, "vm-100-$U{ours}", 0) };
    is( $@, '', 'free_image still frees a volume of this storage' );
    ok( (grep { $_->[0] eq 'DELETE' && $_->[1] =~ /$U{ours}/ } @calls), '  ...with a DELETE of that volume' );

    @calls = (); local $gone->{ $U{ours} } = 1;
    eval { $class->free_image('lb-storage', $scfg, "vm-100-$U{ours}", 0) };
    is( $@, '', 'free_image of an already-deleted volume is still an idempotent no-op' );
    is( scalar(@calls), 0, '  ...with no API call' );
}

# ── activate_volume: refuses foreign volumes before the ACL grant ───────────────
{
    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::LightbitsPlugin::_symlink_path = sub { '/nonexistent-link-path' };
    local *PVE::Storage::Custom::LightbitsPlugin::_subsys_nqn   = sub { 'nqn.subsys' };
    local *PVE::Storage::Custom::LightbitsPlugin::_nvme_endpoints = sub { () };
    local *PVE::Storage::Custom::LightbitsPlugin::_connected_endpoints = sub { {} };
    local *PVE::Storage::Custom::LightbitsPlugin::_is_connected = sub { 0 };
    local *PVE::Storage::Custom::LightbitsPlugin::_nudge_discovery_client = sub { 1 };   # never run systemctl in unit tests
    local *PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device = sub { undef };
    local *PVE::Storage::Custom::LightbitsPlugin::_write_dsc_conf = sub { 1 };
    use warnings 'redefine', 'once';

    for my $k (qw(foreign decoy other_pve legacy)) {
        @calls = ();
        eval { $class->activate_volume('lb-storage', $scfg, "vm-0-$U{$k}", undef, {}) };
        like( $@, qr/refusing to activate Lightbits volume $U{$k}/, "activate_volume refuses the $k volume" );
        ok( !(grep { $_->[0] eq 'PUT' } @calls), "  ...and its ACL is left untouched (no PUT)" );
    }

    @calls = ();
    eval { $class->activate_volume('lb-storage', $scfg, "vm-100-$U{ours}", undef, {}) };
    like( $@, qr/did not appear/, 'activate_volume of our own volume proceeds past the guard (fails later only because this stub has no device)' );

    @calls = (); local $gone->{ $U{ours} } = 1;
    eval { $class->activate_volume('lb-storage', $scfg, "vm-100-$U{ours}", undef, {}) };
    like( $@, qr/no longer exists/, 'activate_volume of a vanished volume fails immediately, naming it' );
}

# ── resize / snapshot / rollback / size lookup: same guard, before any PUT/POST ─
{
    my %cases = (
        'volume_size_info'         => sub { $class->volume_size_info($scfg, 'lb-storage', $_[0]) },
        'volume_resize'            => sub { $class->volume_resize($scfg, 'lb-storage', $_[0], 2 * 1024**3, 0) },
        'volume_snapshot'          => sub { $class->volume_snapshot($scfg, 'lb-storage', $_[0], 'snap1') },
        'volume_snapshot_delete'   => sub { $class->volume_snapshot_delete($scfg, 'lb-storage', $_[0], 'snap1', 0) },
        'volume_snapshot_rollback' => sub { $class->volume_snapshot_rollback($scfg, 'lb-storage', $_[0], 'snap1') },
    );
    for my $op (sort keys %cases) {
        for my $k (qw(foreign decoy other_pve)) {
            @calls = ();
            eval { $cases{$op}->("vm-0-$U{$k}") };
            like( $@, qr/refusing to .*Lightbits volume $U{$k}/, "$op refuses the $k volume" );
            is( scalar(@calls), 0, "  ...without issuing any mutating API call" );
        }
    }
    # our own volume passes the guard (and reaches the normal code path)
    @calls = ();
    my ($size) = eval { $class->volume_size_info($scfg, 'lb-storage', "vm-100-$U{ours}") };
    is( $@, '', 'volume_size_info of our own volume passes the guard' );
    is( $size, 1, '  ...and reports its size' );
    @calls = ();
    eval { $class->volume_resize($scfg, 'lb-storage', "vm-100-$U{ours}", 2 * 1024**3, 0) };
    ok( (grep { $_->[0] eq 'PUT' && $_->[1] =~ /$U{ours}/ } @calls), 'volume_resize of our own volume issues its PUT' );
    # a vanished volume is reported as gone, with the usual wording
    local $gone->{ $U{ours} } = 1;
    eval { $class->volume_size_info($scfg, 'lb-storage', "vm-100-$U{ours}") };
    like( $@, qr/no longer exists/, 'volume_size_info of a vanished volume dies with the "no longer exists" wording' );
}

done_testing();
