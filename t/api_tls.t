#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for the lb_ssl_verify / lb_ca_file TLS options.
#
# The API client sent the lb_jwt bearer token over an unverified TLS connection
# unconditionally. Verification stays off by default (a LightOS cluster usually
# presents a self-signed certificate, and flipping the default would break every
# existing storage entry), but must be switchable per storage, and the options
# must actually reach LWP::UserAgent rather than only being accepted by the
# config schema.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);
use HTTP::Response;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
sub ssl_opts { return PVE::Storage::Custom::LightbitsPlugin::_ssl_opts(@_) }

# ── default: verification off, preserving pre-existing behaviour ───────────────
is_deeply( ssl_opts({}), { verify_hostname => 0, SSL_verify_mode => 0 },
    'verification is off when lb_ssl_verify is unset' );
is_deeply( ssl_opts({ lb_ssl_verify => 0 }), { verify_hostname => 0, SSL_verify_mode => 0 },
    'verification is off when lb_ssl_verify is explicitly 0' );

# ── enabled: peer + hostname verification against the system trust store ───────
is_deeply( ssl_opts({ lb_ssl_verify => 1 }), { verify_hostname => 1, SSL_verify_mode => 1 },
    'lb_ssl_verify=1 turns on peer and hostname verification' );

# ── enabled with a CA bundle ───────────────────────────────────────────────────
my ($fh, $ca) = tempfile(UNLINK => 1);
print $fh "-----BEGIN CERTIFICATE-----\n";
close $fh;
is_deeply( ssl_opts({ lb_ssl_verify => 1, lb_ca_file => $ca }),
    { verify_hostname => 1, SSL_verify_mode => 1, SSL_ca_file => $ca },
    'lb_ca_file is passed through as SSL_ca_file' );

# An empty lb_ca_file (e.g. cleared via `pvesm set`) is not a CA path.
is_deeply( ssl_opts({ lb_ssl_verify => 1, lb_ca_file => '' }),
    { verify_hostname => 1, SSL_verify_mode => 1 },
    'an empty lb_ca_file is ignored rather than passed as a path' );

# ── unreadable CA bundle fails loudly, not silently unverified ─────────────────
{
    my $err = eval { ssl_opts({ lb_ssl_verify => 1, lb_ca_file => '/nonexistent/ca.pem' }); 1 };
    ok( !$err, 'an unreadable lb_ca_file dies' );
    like( $@, qr/lb_ca_file .*not a readable file/,
        'the error names lb_ca_file so the operator knows what to fix' );
}

# lb_ca_file without lb_ssl_verify is inert (verification is what gates it).
is_deeply( ssl_opts({ lb_ca_file => '/nonexistent/ca.pem' }),
    { verify_hostname => 0, SSL_verify_mode => 0 },
    'lb_ca_file alone does not enable verification (and does not die)' );

# ── the options actually reach the user agent ──────────────────────────────────
{
    my @constructed;
    no warnings qw(redefine once);
    my $orig_new = \&LWP::UserAgent::new;
    local *LWP::UserAgent::new = sub {
        my ($pkg, %args) = @_;
        push @constructed, $args{ssl_opts};
        return $orig_new->($pkg, %args);
    };
    local *LWP::UserAgent::request = sub {
        return HTTP::Response->new(200, 'OK', [], '{}');
    };
    use warnings qw(redefine once);

    PVE::Storage::Custom::LightbitsPlugin::_api(
        { lb_api_host => '10.0.0.1:443', lb_jwt => 'tok', lb_ssl_verify => 1 },
        'GET', '/api/v2/cluster');
    is_deeply( $constructed[0], { verify_hostname => 1, SSL_verify_mode => 1 },
        '_api builds its user agent with verification on when lb_ssl_verify is set' );

    @constructed = ();
    PVE::Storage::Custom::LightbitsPlugin::_api(
        { lb_api_host => '10.0.0.1:443', lb_jwt => 'tok' },
        'GET', '/api/v2/cluster');
    is_deeply( $constructed[0], { verify_hostname => 0, SSL_verify_mode => 0 },
        '_api defaults to the previous unverified behaviour' );
}

# ── schema wiring: both options are declared and optional ──────────────────────
my $props = $class->properties();
my $opts  = $class->options();
for my $k (qw(lb_ssl_verify lb_ca_file)) {
    ok( $props->{$k} && $props->{$k}{description}, "$k is declared in properties()" );
    ok( $opts->{$k} && $opts->{$k}{optional}, "$k is an optional storage option" );
}
is( $props->{lb_ssl_verify}{type}, 'boolean', 'lb_ssl_verify is a boolean' );
is( $props->{lb_ssl_verify}{default}, 0, 'lb_ssl_verify defaults to 0' );

# Property descriptions are operator-facing and pass through Proxmox's task-log
# layer, which double-encodes non-ASCII (see the 0.9.1 mojibake fix).
for my $k (qw(lb_ssl_verify lb_ca_file)) {
    unlike( $props->{$k}{description}, qr/[^\x00-\x7f]/,
        "$k description is plain ASCII" );
}

done_testing();
