#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for deactivate_volume's discovery-client seed cleanup: a storage's own
# discovery-client conf file must be removed as soon as none of ITS OWN
# volumes are active, independent of whether a different storage sharing the
# same cluster/subsystem NQN still has volumes active. The subsystem-wide
# `nvme disconnect`, in contrast, must still wait for every storage sharing
# that subsystem to go idle.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $NQN   = 'nqn.2016-01.com.lightbitslabs:uuid:shared-subsys';

my $symlink_root = tempdir(CLEANUP => 1);
my $sysfs_root   = tempdir(CLEANUP => 1);

no warnings 'once';
local $PVE::Storage::Custom::LightbitsPlugin::SYMLINK_DIR = $symlink_root;
local $PVE::Storage::Custom::LightbitsPlugin::SYS_BLOCK   = $sysfs_root;
use warnings 'once';

# A single fake block device backing both storages' symlinks, so
# _nqn_still_in_use's sysfs lookup resolves to the shared subsystem NQN.
make_path("$sysfs_root/nvme0n1/device");
open(my $fh, '>', "$sysfs_root/nvme0n1/device/subsysnqn") or die $!;
print $fh "$NQN\n";
close($fh);

my $uuid_a = 'feedface-0000-4000-8000-00000000000a';
my $uuid_b = 'feedface-0000-4000-8000-00000000000b';
make_path("$symlink_root/storage-a");
make_path("$symlink_root/storage-b");
symlink('/dev/nvme0n1', "$symlink_root/storage-a/$uuid_a") or die $!;
symlink('/dev/nvme0n1', "$symlink_root/storage-b/$uuid_b") or die $!;

my @removed_conf;
my @disconnected;
no warnings 'redefine', 'once';
local *PVE::Storage::Custom::LightbitsPlugin::_remove_dsc_conf = sub { push @removed_conf, $_[0] };
local *PVE::Storage::Custom::LightbitsPlugin::_is_connected    = sub { 1 };
local *PVE::Storage::Custom::LightbitsPlugin::run_command      = sub { push @disconnected, [@_] };
use warnings 'redefine', 'once';

my $scfg_a = { lb_subsys_nqn => $NQN };
my $scfg_b = { lb_subsys_nqn => $NQN };
my $volname_a = "vm-100-$uuid_a";
my $volname_b = "vm-200-$uuid_b";

# ── storage-a's last volume deactivates while storage-b (same subsystem) is
#    still active: storage-a's OWN conf file must be removed regardless, but
#    the shared subsystem must NOT be disconnected out from under storage-b ──
$class->deactivate_volume('storage-a', $scfg_a, $volname_a, undef, {});

ok( !-l "$symlink_root/storage-a/$uuid_a", "storage-a's symlink was removed" );
is_deeply( \@removed_conf, ['storage-a'],
    "storage-a's own discovery-client conf is removed as soon as ITS volume deactivates" );
is( scalar(@disconnected), 0,
    "nvme disconnect is NOT run while storage-b still has an active volume on the same subsystem" );

# ── storage-b's last volume deactivates too: now nothing shares the
#    subsystem, so the disconnect finally runs ──────────────────────────────
@removed_conf = ();
$class->deactivate_volume('storage-b', $scfg_b, $volname_b, undef, {});

ok( !-l "$symlink_root/storage-b/$uuid_b", "storage-b's symlink was removed" );
is_deeply( \@removed_conf, ['storage-b'], "storage-b's own conf is removed too" );
is( scalar(@disconnected), 1,
    "nvme disconnect now runs, since no storage sharing the subsystem is active anymore" );
is_deeply( $disconnected[0][0], ['nvme', 'disconnect', '-n', $NQN],
    'disconnect targets the shared subsystem NQN' );

done_testing();
