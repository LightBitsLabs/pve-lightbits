#!/usr/bin/perl
# Tests for alloc_image volume naming + ownership labels.
#
# Volume names must be unique within a Lightbits project (LightOS enforces it),
# so each disk is named vm-<vmid>-<vmgenid>-disk-<n>: the vmid+vmgenid keep it
# unique across hypervisors that share a project, the index across a VM's disks.
# The same ownership data is also written as labels (pveVmid/pveVmgenid/pveNode).

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';

# Point the vmgenid lookup at a temp dir holding fixture guest configs.
my $confdir = tempdir(CLEANUP => 1);
{ no warnings 'once'; $PVE::Storage::Custom::LightbitsPlugin::QEMU_CONF_DIR = $confdir; }

sub write_conf {
    my ($vmid, @lines) = @_;
    open(my $fh, '>', "$confdir/$vmid.conf") or die $!;
    print $fh "$_\n" for @lines;
    close($fh);
}

my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
my $GENID   = '02b26b1b-0d41-4d3e-bd40-2970bc13db80';

# ── _vm_guid ──────────────────────────────────────────────────────────────────
write_conf(100,
    'smbios1: uuid=dcbdd285-7b5a-4e32-a60f-d8cd75ebe791',
    "vmgenid: $GENID",
    'scsi0: lb-storage:abc',
    '[snap1]',
    'vmgenid: ffffffff-ffff-ffff-ffff-ffffffffffff',   # snapshot section, must be ignored
);
is( PVE::Storage::Custom::LightbitsPlugin::_vm_guid(100), $GENID,
    '_vm_guid reads vmgenid from the live config section (ignores snapshots)' );

write_conf(101, 'vmgenid: 0', 'name: no-genid');
like( PVE::Storage::Custom::LightbitsPlugin::_vm_guid(101), $UUID_RE,
    '_vm_guid falls back to a generated UUID when vmgenid is 0' );

like( PVE::Storage::Custom::LightbitsPlugin::_vm_guid(999), $UUID_RE,
    '_vm_guid falls back to a generated UUID when the config is missing' );

# ── _api stub: serves the disk-index list, captures the create body ─────────────
my @existing;     # volumes the GET list returns (drives _next_disk_index)
my $posted;       # captured POST body
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.2014-08.org.nvmexpress:uuid:test-host' };
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    return do { $posted = $body; { UUID => 'feedface-0000-4000-8000-000000000001' } } if $method eq 'POST';
    return { state => 'Available' } if $method eq 'GET' && $path =~ m{/volumes/};
    return { volumes => [@existing] } if $method eq 'GET';
    return {};
};
use warnings 'redefine';

my $scfg = { lb_project => 'default', lb_owner_id => 'node-a' };

# ── _next_disk_index ────────────────────────────────────────────────────────────
@existing = ();
is( PVE::Storage::Custom::LightbitsPlugin::_next_disk_index($scfg, 100), 0,
    '_next_disk_index is 0 when the VM has no disks' );
@existing = (
    { name => "vm-100-$GENID-disk-0" },
    { name => "vm-100-$GENID-disk-1" },
    { name => 'vm-100-disk' },                 # legacy, not counted
    { name => "vm-200-$GENID-disk-7" },         # other VM, not counted
);
is( PVE::Storage::Custom::LightbitsPlugin::_next_disk_index($scfg, 100), 2,
    '_next_disk_index returns max(existing)+1 for the VM' );

# ── alloc_image: first disk ─────────────────────────────────────────────────────
@existing = ();
my $uuid = $class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576);
is( $uuid, 'vm-100-feedface-0000-4000-8000-000000000001',
    'alloc_image returns a vm-<vmid>-<uuid> volname' );
is( $posted->{name}, "vm-100-$GENID-disk-0", 'name = vm-<vmid>-<vmgenid>-disk-0' );
ok( length($posted->{name}) <= 253, 'name is within the 253-char LightOS limit' );
like( $posted->{name}, qr/^[A-Za-z0-9.-]+$/, 'name uses only LightOS-allowed characters' );

my %lbl = map { $_->{key} => $_->{value} } @{ $posted->{labels} // [] };
is( $lbl{pveVmid},    '100',   'pveVmid label set' );
is( $lbl{pveVmgenid}, $GENID,  'pveVmgenid label set' );
is( $lbl{pveNode},    'node-a','pveNode label = owner id' );

# ── alloc_image: second disk increments the index ──────────────────────────────
@existing = ( { name => "vm-100-$GENID-disk-0" } );
$class->alloc_image('lb-storage', $scfg, 100, 'raw', undef, 1048576);
is( $posted->{name}, "vm-100-$GENID-disk-1", 'a second disk increments the index' );

# ── alloc_image: VM without a vmgenid still gets a unique name ──────────────────
@existing = ();
$class->alloc_image('lb-storage', $scfg, 999, 'raw', undef, 1048576);
like( $posted->{name}, qr/^vm-999-[0-9a-f-]{36}-disk-0$/,
    'fallback UUID still yields a valid unique name when vmgenid is absent' );

done_testing();
