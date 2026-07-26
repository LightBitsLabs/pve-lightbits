#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for _api's lb_api_host failover: a comma-separated list of endpoints
# is tried, cycling on transport failure / 5xx, but a 4xx is a definitive
# answer (same cluster state behind every endpoint) and is not retried.

use strict;
use warnings;
use Test::More;
use FindBin;
use HTTP::Response;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

# Responses keyed by endpoint string (e.g. "10.0.0.1:443"); each entry is
# either an HTTP::Response to return, or a coderef called with no args for
# a per-call dynamic response. Populated per test below.
my %responses;
my @calls;   # endpoint strings contacted, in order

no warnings qw(redefine once);
*LWP::UserAgent::request = sub {
    my ($self, $req) = @_;
    my $url = $req->uri->as_string;
    for my $ep (keys %responses) {
        next unless index($url, "https://$ep") == 0;
        push @calls, $ep;
        my $r = $responses{$ep};
        return ref($r) eq 'CODE' ? $r->() : $r;
    }
    die "test bug: no mocked response for URL $url\n";
};

sub reset_calls { @calls = (); %responses = (); }
sub scfg { return { lb_api_host => $_[0], lb_jwt => 'tok' }; }

# ── all endpoints fail with a connection-style error -> dies, every endpoint
#    tried exactly once ────────────────────────────────────────────────────────
reset_calls();
%responses = map {
    $_ => HTTP::Response->new(500, "Can't connect", ['Client-Warning' => 'Internal response'], '')
} ('10.0.0.1:443', '10.0.0.2:443', '10.0.0.3:443');

my $err = eval {
    PVE::Storage::Custom::LightbitsPlugin::_api(
        scfg('10.0.0.1:443,10.0.0.2:443,10.0.0.3:443'), 'GET', '/x');
    1;
};
my $all_fail_msg = $@;
ok( !$err, 'dies when every endpoint fails' );
is( scalar(@calls), 3, 'every configured endpoint was tried exactly once' );
is_deeply( [ sort @calls ], ['10.0.0.1:443', '10.0.0.2:443', '10.0.0.3:443'],
    'the three endpoints tried are exactly the configured ones' );
for my $ep ('10.0.0.1:443', '10.0.0.2:443', '10.0.0.3:443') {
    like( $all_fail_msg, qr/\Q$ep\E/,
        "final error message names $ep, not just the last endpoint tried" );
}

# ── one healthy endpoint among failing ones -> succeeds ────────────────────────
reset_calls();
%responses = (
    '10.0.0.1:443' => HTTP::Response->new(500, 'error', ['Client-Warning' => 'Internal response'], ''),
    '10.0.0.2:443' => HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"ok":1}'),
    '10.0.0.3:443' => HTTP::Response->new(500, 'error', ['Client-Warning' => 'Internal response'], ''),
);
my $result = PVE::Storage::Custom::LightbitsPlugin::_api(
    scfg('10.0.0.1:443,10.0.0.2:443,10.0.0.3:443'), 'GET', '/x');
is_deeply( $result, { ok => 1 }, 'succeeds once a healthy endpoint is reached' );
ok( grep { $_ eq '10.0.0.2:443' } @calls, 'the healthy endpoint was contacted' );

# ── single configured endpoint, failing -> dies after one attempt ──────────────
reset_calls();
%responses = ( '10.0.0.1:443' =>
    HTTP::Response->new(500, 'error', ['Client-Warning' => 'Internal response'], '') );
$err = eval {
    PVE::Storage::Custom::LightbitsPlugin::_api(scfg('10.0.0.1:443'), 'GET', '/x');
    1;
};
my $die_msg = $@;   # capture immediately - a later eval/assertion could clobber $@
ok( !$err, 'single failing endpoint dies' );
is( scalar(@calls), 1, 'exactly one attempt with a single configured endpoint' );
like( $die_msg, qr/\Q - \E/, 'error uses a plain ASCII " - " separator' );
unlike( $die_msg, qr/\N{U+2014}/, 'error contains no Unicode em-dash (mojibakes in the PVE GUI/task log)' );

# ── a 4xx is definitive: not retried against other endpoints ───────────────────
reset_calls();
%responses = map {
    $_ => HTTP::Response->new(403, 'Forbidden', ['Content-Type' => 'application/json'], '{"error":"forbidden"}')
} ('10.0.0.1:443', '10.0.0.2:443');
$err = eval {
    PVE::Storage::Custom::LightbitsPlugin::_api(
        scfg('10.0.0.1:443,10.0.0.2:443'), 'GET', '/x');
    1;
};
ok( !$err, 'a 4xx response propagates as an error' );
is( scalar(@calls), 1, 'a 4xx is not retried against another endpoint' );

# ── 404 still maps to an empty hashref (unchanged prior behavior) ──────────────
reset_calls();
%responses = ( '10.0.0.1:443' =>
    HTTP::Response->new(404, 'Not Found', ['Content-Type' => 'application/json'], '') );
$result = PVE::Storage::Custom::LightbitsPlugin::_api(scfg('10.0.0.1:443'), 'GET', '/x');
is_deeply( $result, {}, '404 maps to an empty hashref' );

# ── lb_api_host not configured -> clear error, no request attempted ────────────
reset_calls();
$err = eval { PVE::Storage::Custom::LightbitsPlugin::_api(scfg(undef), 'GET', '/x'); 1; };
ok( !$err, 'dies cleanly when lb_api_host is unset' );
is( scalar(@calls), 0, 'no request attempted when lb_api_host is unset' );

# ── a 5xx on a non-idempotent mutation is NOT retried against another
#    endpoint — a 5xx can arrive after the mutation already committed
#    server-side (e.g. a proxy timeout past a successful backend write), so
#    retrying it elsewhere risks creating a duplicate/orphaned resource.
#    All endpoints fail identically here so the assertion holds regardless of
#    _api's random start index (contrast with the all-failing GET case at the
#    top of this file, which tries every endpoint before giving up). ──────────
for my $method (qw(POST PUT DELETE)) {
    reset_calls();
    %responses = map {
        $_ => HTTP::Response->new(500, 'error', ['Client-Warning' => 'Internal response'], '')
    } ('10.0.0.1:443', '10.0.0.2:443', '10.0.0.3:443');
    $err = eval {
        PVE::Storage::Custom::LightbitsPlugin::_api(
            scfg('10.0.0.1:443,10.0.0.2:443,10.0.0.3:443'), $method, '/x',
            $method eq 'GET' ? undef : { name => 'vol' });
        1;
    };
    ok( !$err, "a 5xx on $method propagates as an error instead of retrying" );
    is( scalar(@calls), 1, "$method is tried against exactly one endpoint, never a second" );
}

# HEAD is retried like GET (both side-effect-free) — same all-failing setup as
# the GET case at the top of this file, just with a different method.
reset_calls();
%responses = map {
    $_ => HTTP::Response->new(500, "Can't connect", ['Client-Warning' => 'Internal response'], '')
} ('10.0.0.1:443', '10.0.0.2:443', '10.0.0.3:443');
$err = eval {
    PVE::Storage::Custom::LightbitsPlugin::_api(
        scfg('10.0.0.1:443,10.0.0.2:443,10.0.0.3:443'), 'HEAD', '/x');
    1;
};
ok( !$err, 'dies when every endpoint fails a HEAD request too' );
is( scalar(@calls), 3, 'HEAD, like GET, is retried against every configured endpoint' );

done_testing();
