#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Cold-node activation: after the plugin's own `nvme disconnect` on the last
# deactivation, discovery-client did not act on the re-created config file and
# the next activation failed after the full wait (live, 2026-10-04). The fix:
# if no connection appears within $DSC_NUDGE_AFTER seconds of writing the
# config, activate_volume restarts discovery-client once and keeps waiting.
#
#  - no nudge when the connection comes up in time
#  - exactly one nudge when it does not, issued at $DSC_NUDGE_AFTER, and the
#    activation then succeeds once the daemon connects
#  - still fails with the usual message when even the nudge does not help, and
#    the nudge is attempted only once

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

BEGIN { no warnings 'once'; *CORE::GLOBAL::sleep = sub { 1 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $dir   = tempdir(CLEANUP => 1);
my $uuid  = 'feedface-0000-4000-8000-000000000abc';
my $scfg  = { lb_project => 'default', lb_owner_id => 'node-a' };
my $vol   = { nsid => 7, acl => { values => ['nqn.host.local'] },
              labels => [ { key => 'pveVmid', value => '100' }, { key => 'pveNode', value => 'node-a' } ] };
$PVE::Storage::Custom::LightbitsPlugin::SYMLINK_DIR = $dir;
$PVE::Storage::Custom::LightbitsPlugin::DSC_NUDGE_AFTER  = 3;
$PVE::Storage::Custom::LightbitsPlugin::DSC_CONNECT_WAIT = 8;

my ($probes, $nudges, $connected_after);   # connect on the N-th probe (undef = never)
no warnings 'redefine', 'once';
*PVE::Storage::Custom::LightbitsPlugin::_api            = sub { my (undef,$m)=@_; return $vol if $m eq 'GET'; return {} };
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn       = sub { 'nqn.host.local' };
*PVE::Storage::Custom::LightbitsPlugin::_symlink_path   = sub { "$dir/$uuid" };
*PVE::Storage::Custom::LightbitsPlugin::_symlink_is_current = sub { 0 };
*PVE::Storage::Custom::LightbitsPlugin::_subsys_nqn     = sub { 'nqn.subsys' };
*PVE::Storage::Custom::LightbitsPlugin::_write_dsc_conf = sub { 1 };
*PVE::Storage::Custom::LightbitsPlugin::_nudge_discovery_client = sub { $nudges++; 1 };
*PVE::Storage::Custom::LightbitsPlugin::_is_connected   = sub { $probes++; return defined $connected_after && $probes >= $connected_after ? 1 : 0 };
*PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device = sub { return (defined $connected_after && $probes >= $connected_after) ? "$dir/nvme0n1" : undef };
use warnings 'redefine', 'once';

sub run { ($probes, $nudges) = (0, 0); my $ok = eval { $class->activate_volume('lb-storage', $scfg, "vm-100-$uuid", undef, {}) }; my $err = $@; unlink "$dir/$uuid"; return ($ok, $err); }

# connection comes up quickly -> no nudge
$connected_after = 2;
my ($ok, $err) = run();
is( $err, '', 'activation succeeds when discovery-client connects by itself' );
is( $nudges, 0, '  ...without nudging discovery-client' );

# cold node: nothing connects until the nudge -> exactly one nudge, then success
$connected_after = 5;   # i.e. after the nudge at probe 3
($ok, $err) = run();
is( $err, '', 'activation succeeds when discovery-client only connects after the nudge' );
is( $nudges, 1, '  ...with exactly one nudge' );
ok( $probes >= 5, '  ...issued before the connection appeared (nudge at DSC_NUDGE_AFTER)' );

# nothing helps -> still the usual error, nudge attempted once, total wait honoured
$connected_after = undef;
($ok, $err) = run();
like( $err, qr/did not appear/, 'activation still fails with the usual message when even the nudge does not help' );
is( $nudges, 1, '  ...after exactly one nudge' );
is( $probes, 8, '  ...having waited the full DSC_CONNECT_WAIT' );

done_testing();
