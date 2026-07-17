#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for _ensure_host_acl and its use from activate_volume: a volume
# activated on a host other than the one that created it must have that
# host's NQN added to the volume's ACL, additively and idempotently.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';

no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.host.local' };
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $project = 'default';
my $uuid    = 'feedface-0000-4000-8000-000000000abc';

# ── missing from ACL: PUT adds it additively, preserving existing entries ──────
{
    my @puts;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path, $body) = @_;
        push @puts, { method => $method, path => $path, body => $body };
        return {};
    };
    use warnings 'redefine';

    my $vol = { acl => { values => ['nqn.other-host'] } };
    PVE::Storage::Custom::LightbitsPlugin::_ensure_host_acl($scfg, $project, $uuid, $vol);

    is( scalar(@puts), 1, 'issues exactly one PUT when this host is missing from the ACL' );
    is( $puts[0]{method}, 'PUT', 'uses PUT to update the volume' );
    is( $puts[0]{path}, "/api/v2/volumes/$uuid?projectName=$project",
        'PUT targets the project-scoped volume UUID endpoint' );
    is_deeply( $puts[0]{body}{acl}{values}, ['nqn.other-host', 'nqn.host.local'],
        'PUT body keeps the existing ACL entry and appends this host, additively' );
}

# ── already present: no API call at all (idempotent, no-op on the hot path) ────
{
    my @calls;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        push @calls, [@_];
        return {};
    };
    use warnings 'redefine';

    my $vol = { acl => { values => ['nqn.other-host', 'nqn.host.local'] } };
    PVE::Storage::Custom::LightbitsPlugin::_ensure_host_acl($scfg, $project, $uuid, $vol);

    is( scalar(@calls), 0, 'no API call when this host is already in the ACL' );
}

# ── empty/missing ACL: PUT grants just this host ───────────────────────────────
{
    my @puts;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path, $body) = @_;
        push @puts, { method => $method, body => $body };
        return {};
    };
    use warnings 'redefine';

    my $vol = {};
    PVE::Storage::Custom::LightbitsPlugin::_ensure_host_acl($scfg, $project, $uuid, $vol);

    is( scalar(@puts), 1, 'issues a PUT when the volume has no ACL at all' );
    is_deeply( $puts[0]{body}{acl}{values}, ['nqn.host.local'],
        'PUT body grants just this host when starting from an empty ACL' );
}

# ── activate_volume calls it before waiting for the device ─────────────────────
{
    my @puts;
    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my (undef, $method, $path, $body) = @_;
        push @puts, { method => $method, body => $body } if $method eq 'PUT';
        return { nsid => 5, acl => { values => ['nqn.other-host'] } } if $method eq 'GET';
        return {};
    };
    local *PVE::Storage::Custom::LightbitsPlugin::_symlink_path = sub { '/nonexistent-link-path' };
    local *PVE::Storage::Custom::LightbitsPlugin::_subsys_nqn = sub { 'nqn.subsys' };
    local *PVE::Storage::Custom::LightbitsPlugin::_nvme_endpoints = sub { () };
    local *PVE::Storage::Custom::LightbitsPlugin::_connected_endpoints = sub { {} };
    local *PVE::Storage::Custom::LightbitsPlugin::_is_connected = sub { 0 };
    local *PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device = sub { undef };
    local *CORE::GLOBAL::sleep = sub { };
    use warnings 'redefine', 'once';

    my $volname = 'vm-100-feedface-0000-4000-8000-000000000abc';
    eval { $class->activate_volume('lb-storage', $scfg, $volname, undef, {}) };
    like( $@, qr/did not appear/, 'activate_volume still fails past the ACL step (no device in this stub)' );
    is( scalar(@puts), 1, 'activate_volume granted the ACL before giving up on the device wait' );
    is_deeply( $puts[0]{body}{acl}{values}, ['nqn.other-host', 'nqn.host.local'],
        'activate_volume\'s ACL grant is additive, matching _ensure_host_acl directly' );
}

done_testing();
