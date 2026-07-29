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

my $TESTED = 15;   # keep in sync with $TESTED_APIVER in the plugin

# ── api(): host at or below our tested version → match it exactly (no warning) ──
for my $v (2, 11, 12, 13, 14, 15) {
    $host_apiver = $v;
    is( $class->api(), $v, "api() returns host APIVER $v verbatim when <= tested ($TESTED)" );
}

# ── api(): host newer than we tested → claim our tested max ─────────────────────
# api() returns our tested max in both cases; what differs is what the PVE loader
# then does, since it only accepts api() within [APIVER - APIAGE, APIVER]:
#   host one ahead (window min 16-5=11 <= 15): loads with the "older API" warning
#   host far ahead (window min 99-2=97  >  15): rejected by the loader as too old
$host_apiver = 16; $host_apiage = 5;
is( $class->api(), $TESTED, 'api() returns tested max when host is one ahead (loader loads it, with warning)' );

$host_apiver = 99; $host_apiage = 2;
is( $class->api(), $TESTED, 'api() returns tested max when host is far ahead (loader rejects it as too old)' );

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

# ── get_identity(): normalised so the same cluster always yields one identity ───
# lb_api_host is a free-form comma-separated list, so the same cluster gets
# written differently on different nodes. Those entries must still match.
my $canonical = 'lightbits://10.0.0.1:443,10.0.0.2:443,10.0.0.3:443/default';
for my $spec (
    '10.0.0.1:443,10.0.0.2:443,10.0.0.3:443',       # as written
    '10.0.0.3:443,10.0.0.1:443,10.0.0.2:443',       # different order
    ' 10.0.0.2:443 , 10.0.0.3:443 , 10.0.0.1:443 ', # padded with whitespace
    '10.0.0.1:443,,10.0.0.2:443,10.0.0.3:443',      # stray empty element
) {
    is( $class->get_identity({ lb_api_host => $spec }, 'lb'), $canonical,
        "get_identity normalises '$spec' to a single identity" );
}

is( $class->get_identity({ lb_api_host => 'LB01:443,lb02:443' }, 'lb'),
    'lightbits://lb01:443,lb02:443/default',
    'get_identity lowercases hostnames (DNS names are case-insensitive)' );

# _api always builds an https:// URL, so a bare host and the same host with an
# explicit :443 are the very same endpoint and must not get distinct identities.
is( $class->get_identity({ lb_api_host => '10.0.0.1' }, 'lb'),
    $class->get_identity({ lb_api_host => '10.0.0.1:443' }, 'lb'),
    'a bare host and an explicit :443 produce the same identity' );
is( $class->get_identity({ lb_api_host => '10.0.0.1' }, 'lb'),
    'lightbits://10.0.0.1:443/default',
    'a bare host is canonicalised to the default HTTPS port' );
is( $class->get_identity({ lb_api_host => '10.0.0.2:443,10.0.0.1' }, 'lb'),
    'lightbits://10.0.0.1:443,10.0.0.2:443/default',
    'a mixed bare/explicit list canonicalises then sorts' );

# A non-default port is a genuinely different endpoint and must be preserved.
is( $class->get_identity({ lb_api_host => '10.0.0.1:8443' }, 'lb'),
    'lightbits://10.0.0.1:8443/default',
    'an explicit non-default port is preserved' );
isnt( $class->get_identity({ lb_api_host => '10.0.0.1' }, 'lb'),
      $class->get_identity({ lb_api_host => '10.0.0.1:8443' }, 'lb'),
      'a bare host does not collide with the same host on another port' );

# IPv6 literals are bracketed, matching the convention _nvme_endpoints uses.
is( $class->get_identity({ lb_api_host => '[FD00::1]' }, 'lb'),
    $class->get_identity({ lb_api_host => '[fd00::1]:443' }, 'lb'),
    'a bracketed IPv6 literal canonicalises port and case alike' );
is( $class->get_identity({ lb_api_host => '[fd00::1]' }, 'lb'),
    'lightbits://[fd00::1]:443/default',
    'a bare bracketed IPv6 literal gains the default port' );
is( $class->get_identity({ lb_api_host => '[fd00::1]:8443' }, 'lb'),
    'lightbits://[fd00::1]:8443/default',
    'an IPv6 literal keeps its explicit non-default port' );

# Genuinely different clusters, or the same cluster under a different project,
# must NOT collide.
isnt( $class->get_identity({ lb_api_host => '10.0.0.1:443' }, 'lb'),
      $class->get_identity({ lb_api_host => '10.9.9.9:443' }, 'lb'),
      'different clusters keep different identities' );
isnt( $class->get_identity({ lb_api_host => '10.0.0.1:443', lb_project => 'p1' }, 'lb'),
      $class->get_identity({ lb_api_host => '10.0.0.1:443', lb_project => 'p2' }, 'lb'),
      'the same cluster under different projects keeps different identities' );

# get_identity must be a pure function of the config: no API call, no die, even
# when lb_api_host is missing entirely.
is( $class->get_identity({}, 'lb'), 'lightbits:///default',
    'get_identity does not die when lb_api_host is unset' );

done_testing();
