#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for stale-symlink handling in activate_volume.
#
# NVMe controller numbering is not stable across a disconnect/reconnect, so the
# /dev/lightbits/<storeid>/<uuid> symlink left by an earlier activation may now
# dangle, or resolve to a namespace belonging to a *different* volume. Trusting
# it blindly either breaks activation for good (symlink() fails EEXIST) or hands
# QEMU the wrong disk. activate_volume must re-validate the link against this
# volume's (subsystem NQN, nsid) and rebuild it when it no longer matches.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $P     = 'PVE::Storage::Custom::LightbitsPlugin';

my ($sysblk, $devdir, $linkdir) = (tempdir(CLEANUP => 1), tempdir(CLEANUP => 1), tempdir(CLEANUP => 1));
{
    no warnings 'once';
    $PVE::Storage::Custom::LightbitsPlugin::SYS_BLOCK   = $sysblk;
    $PVE::Storage::Custom::LightbitsPlugin::DEV_DIR     = $devdir;
    $PVE::Storage::Custom::LightbitsPlugin::SYMLINK_DIR = $linkdir;
}

sub wr { my ($f, $c) = @_; make_path($f =~ m{(.*)/[^/]+$}); open(my $fh, '>', $f) or die $!; print $fh $c; close $fh }

# Create a fake namespace: /sys/block/<name>/{nsid,device/subsysnqn} + /dev/<name>.
sub mk_ns {
    my (%a) = @_;
    wr("$sysblk/$a{name}/nsid", "$a{nsid}\n");
    wr("$sysblk/$a{name}/device/subsysnqn", "$a{nqn}\n");
    wr("$devdir/$a{name}", '');
}

my $NQN     = 'nqn.2016-01.com.lightbitslabs:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my $UUID    = 'feedface-0000-4000-8000-000000000abc';
my $STOREID = 'lb';
my $VOLNAME = "vm-100-$UUID";
my $LINK    = "$linkdir/$STOREID/$UUID";

# Our volume is nsid 9; a different volume shares the subsystem as nsid 4.
mk_ns(name => 'nvme0n1', nsid => 9, nqn => $NQN);
mk_ns(name => 'nvme1n1', nsid => 4, nqn => $NQN);
make_path("$linkdir/$STOREID");

# Any file we create under the fake /dev counts as a block device, and a symlink
# to one does too (-b follows symlinks, so mirror that by resolving first).
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_is_block = sub { -e $_[0] };
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.host.local' };
# Stub out the parts of activate_volume that touch the real system.
*PVE::Storage::Custom::LightbitsPlugin::_write_dsc_conf = sub { 1 };
*PVE::Storage::Custom::LightbitsPlugin::_is_connected   = sub { 1 };
*PVE::Storage::Custom::LightbitsPlugin::_subsys_nqn     = sub { $NQN };
use warnings 'redefine';

# Count API calls so we can assert the fast path doesn't do extra work.
my $api_calls = 0;
{
    no warnings 'redefine';
    *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path) = @_;
        $api_calls++;
        return { nsid => 9 } if $method eq 'GET' && $path =~ m{/api/v2/volumes/\Q$UUID\E};
        return {};
    };
    use warnings 'redefine';
}

my $scfg = { lb_project => 'default', lb_api_host => '10.0.0.1:443' };

# ── _ns_matches / _symlink_ns unit behaviour ───────────────────────────────────
ok( $P->can('_ns_matches') && $P->can('_symlink_ns') && $P->can('_symlink_is_current'),
    'namespace-matching helpers are defined' );
is( PVE::Storage::Custom::LightbitsPlugin::_ns_matches('nvme0n1', $NQN, 9), 1,
    '_ns_matches: right nqn + right nsid' );
is( PVE::Storage::Custom::LightbitsPlugin::_ns_matches('nvme0n1', $NQN, 4), 0,
    '_ns_matches: right nqn but wrong nsid' );
is( PVE::Storage::Custom::LightbitsPlugin::_ns_matches('nvme0n1', 'nqn.other', 9), 0,
    '_ns_matches: wrong nqn' );
is( PVE::Storage::Custom::LightbitsPlugin::_symlink_ns("$linkdir/nope"), undef,
    '_symlink_ns: absent link → undef' );

# ── fresh activation: no link yet → created, pointing at our namespace ─────────
unlink $LINK;
is( $class->activate_volume($STOREID, $scfg, $VOLNAME), 1, 'fresh activation succeeds' );
is( readlink($LINK), "$devdir/nvme0n1", 'symlink points at the nsid-9 head device' );

# ── already correct: link is reused as-is ──────────────────────────────────────
$api_calls = 0;
is( $class->activate_volume($STOREID, $scfg, $VOLNAME), 1, 'reactivation succeeds' );
is( readlink($LINK), "$devdir/nvme0n1", 'valid symlink is left untouched' );
is( $api_calls, 1, 'valid symlink costs one metadata GET and no device rescan' );

# ── DANGLING link (controller renumbered away) → recreated, not EEXIST ─────────
unlink $LINK;
symlink("$devdir/nvme7n1", $LINK) or die $!;   # nvme7n1 does not exist
is( $class->activate_volume($STOREID, $scfg, $VOLNAME), 1,
    'activation recovers from a dangling symlink instead of dying with EEXIST' );
is( readlink($LINK), "$devdir/nvme0n1", 'dangling symlink is replaced with the live device' );

# ── WRONG-VOLUME link (name reused by another namespace) → corrected ───────────
unlink $LINK;
symlink("$devdir/nvme1n1", $LINK) or die $!;   # exists, but is nsid 4 — not ours
is( $class->activate_volume($STOREID, $scfg, $VOLNAME), 1,
    'activation succeeds when the symlink resolves to another volume' );
is( readlink($LINK), "$devdir/nvme0n1",
    'symlink pointing at a different volume is corrected, not reported as success' );

done_testing();
