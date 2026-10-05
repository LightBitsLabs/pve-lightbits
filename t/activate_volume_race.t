#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Two concurrent activations of the same volume (e.g. parallel full clones
# from one template) race between activate_volume's "symlink already current"
# check and its symlink(): the loser gets EEXIST although the link now points
# at the right namespace. Seen live 2026-10-04 (1 of 3 parallel clones failed
# with "Cannot create symlink ...: File exists"). The loser must treat that as
# success; a link that points at the WRONG device must still be an error.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

BEGIN { no warnings 'once'; *CORE::GLOBAL::sleep = sub { 1 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $P     = 'PVE::Storage::Custom::LightbitsPlugin';
my $dir   = tempdir(CLEANUP => 1);
my $uuid  = 'feedface-0000-4000-8000-000000000abc';
my $link  = "$dir/$uuid";
# keep every filesystem side effect inside the temp dir: CI runs unprivileged
# and activate_volume creates "$SYMLINK_DIR/<storeid>" before linking
$PVE::Storage::Custom::LightbitsPlugin::SYMLINK_DIR = $dir;
my $scfg  = { lb_project => 'default', lb_owner_id => 'node-a' };
my $vol   = { nsid => 7, acl => { values => ['nqn.host.local'] },
              labels => [ { key => 'pveVmid', value => '100' }, { key => 'pveNode', value => 'node-a' } ] };

no warnings 'redefine', 'once';
*PVE::Storage::Custom::LightbitsPlugin::_api            = sub { my (undef,$m)=@_; return $vol if $m eq 'GET'; return {} };
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn       = sub { 'nqn.host.local' };
*PVE::Storage::Custom::LightbitsPlugin::_symlink_path   = sub { $link };
*PVE::Storage::Custom::LightbitsPlugin::_subsys_nqn     = sub { 'nqn.subsys' };
*PVE::Storage::Custom::LightbitsPlugin::_write_dsc_conf = sub { 1 };
*PVE::Storage::Custom::LightbitsPlugin::_is_connected   = sub { 1 };
*PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device = sub { "$dir/nvme0n1" };
# the "current" check: first call (before the race) says no link yet; after the
# racing winner created it, say yes iff the link points at the right device
my $pre_race = 1;
*PVE::Storage::Custom::LightbitsPlugin::_symlink_is_current = sub {
    my ($l) = @_;
    return 0 if $pre_race;
    return (readlink($l) // '') eq "$dir/nvme0n1" ? 1 : 0;
};
use warnings 'redefine', 'once';

# ── loser of the race: a concurrent activation created the correct link between
#    our check and our symlink() → EEXIST must be treated as success ───────────
{
    $pre_race = 1;
    # simulate the winner: the link appears (pointing at the right device) right
    # before our symlink() runs, by hooking the moment _find_nvme_device returns
    local *PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device = sub {
        symlink("$dir/nvme0n1", $link); $pre_race = 0; return "$dir/nvme0n1";
    };
    my $ok = eval { $class->activate_volume('lb-storage', $scfg, "vm-100-$uuid", undef, {}) };
    is( $@, '', 'activate_volume succeeds when a concurrent activation created the correct symlink first' );
    is( $ok, 1, '  ...and returns success' );
    is( readlink($link), "$dir/nvme0n1", '  ...leaving the (correct) link in place' );
    unlink $link;
}

# ── a racing link that points at the WRONG device is still an error ───────────
{
    $pre_race = 1;
    local *PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device = sub {
        symlink("$dir/nvme0n9", $link); $pre_race = 0; return "$dir/nvme0n1";
    };
    eval { $class->activate_volume('lb-storage', $scfg, "vm-100-$uuid", undef, {}) };
    like( $@, qr/Cannot create symlink .*File exists/, 'a pre-existing link to a different device still fails loudly' );
    unlink $link;
}

done_testing();
