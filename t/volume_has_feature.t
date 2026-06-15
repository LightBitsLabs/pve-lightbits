#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_has_feature: PVE probes 'snapshot' with no snapname when *taking* a
# snapshot (so it must be truthy for the current volume), but we do not offer
# nested snapshots (snapshot of a snapshot). copy/resize are offered for the
# current/base volume; clone and sparseinit are not.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class   = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID    = 'feedface-0000-4000-8000-000000000abc';
my $volname = "vm-100-$UUID";
my $scfg    = { lb_project => 'default' };

# has_feature($scfg, $feature, $storeid, $volname, $snapname, $running, $opts)
my $has = sub {
    my ($feature, $snapname) = @_;
    return $class->volume_has_feature($scfg, $feature, 'lb-storage', $volname, $snapname, 0);
};

ok(  $has->('snapshot', undef), "snapshot allowed on the current volume (snapname undef)" );
ok( !$has->('snapshot', 'snap1'), "no nested snapshots (snapshot of a snapshot is refused)" );

# A snapshot embedded in the volname (vm-<vmid>-<uuid>@<snap>) must be honored even
# when $snapname is unset, so it is treated as snapshot context (not the live volume).
ok(
    !$class->volume_has_feature($scfg, 'snapshot', 'lb-storage', "$volname\@snap1", undef, 0),
    'embedded @snap in volname is treated as snapshot context (no nested snapshots)'
);
ok(  $has->('copy', undef),   'copy allowed on the current volume' );
ok(  $has->('resize', undef), 'resize allowed' );
ok( !$has->('clone', undef),  'clone (linked clone) not offered' );
ok( !$has->('sparseinit', undef), 'sparseinit not offered' );
ok( !$has->('bogus', undef),  'unknown feature -> false' );

done_testing();
