#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for the dynamic api() version negotiation and get_identity().
#
# A static api() cannot be both silent and loadable across PVE point releases,
# because the storage APIVER differs between them. api() therefore reports the
# running host's APIVER, clamped to the highest version we have validated
# ($TESTED_APIVER). These tests drive it by faking PVE::Storage::APIVER/APIAGE.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";

# PVE::Storage isn't stubbed as a module; provide APIVER/APIAGE as subs over
# mutable lexicals so each case can pretend to run on a different host version.
# (Constants declared via `use constant` are just subs, so this matches how the
# plugin reads them at runtime: PVE::Storage::APIVER().)
my ($host_apiver, $host_apiage, $break) = (14, 5, 0);
{
    no warnings 'once';
    *PVE::Storage::APIVER = sub { die "no APIVER\n" if $break; $host_apiver };
    *PVE::Storage::APIAGE = sub { die "no APIAGE\n" if $break; $host_apiage };
}

require "$FindBin::RealBin/../LightbitsPlugin.pm";
my $class = 'PVE::Storage::Custom::LightbitsPlugin';

my $TESTED = 14;   # keep in sync with $TESTED_APIVER in the plugin

# ── api(): host at or below our tested version → match it exactly (no warning) ──
for my $v (2, 11, 12, 13, 14) {
    $host_apiver = $v;
    is( $class->api(), $v, "api() returns host APIVER $v verbatim when <= tested ($TESTED)" );
}

# ── api(): host newer than we tested → claim our tested max (loads, warns) ──────
$host_apiver = 15; $host_apiage = 5;
is( $class->api(), $TESTED, 'api() caps at tested version when host is one ahead' );

$host_apiver = 99; $host_apiage = 2;
is( $class->api(), $TESTED, 'api() caps at tested version when host is far ahead' );

# ── api(): PVE::Storage unavailable → fall back to tested version ───────────────
$break = 1;
is( $class->api(), $TESTED, 'api() falls back to tested version if APIVER is unreadable' );
$break = 0;

# ── get_identity(): stable id from cluster endpoint + project ───────────────────
is( $class->get_identity({ lb_api_host => '10.0.0.1:443', lb_project => 'p1' }, 'lb'),
    'lightbits://10.0.0.1:443/p1',
    'get_identity combines api host and project' );
is( $class->get_identity({ lb_api_host => '10.0.0.2:443' }, 'lb'),
    'lightbits://10.0.0.2:443/default',
    'get_identity falls back to the default project' );

done_testing();
