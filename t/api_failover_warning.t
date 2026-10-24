#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for _api's failover warning (issue #47): a call that succeeds only
# after skipping one or more lb_api_host endpoints warns exactly once, naming
# the skipped endpoints; a call that needs no failover, or that ends in an
# error, warns nothing.

use strict;
use warnings;
use Test::More;
use FindBin;
use HTTP::Response;

# Pin _api's random start index so the endpoint order is deterministic:
# $main::START picks the first endpoint tried (int(rand(n)) == $main::START).
our $START = 0;
BEGIN { *CORE::GLOBAL::rand = sub { return $main::START + 0.5 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my %responses;
my @calls;

no warnings qw(redefine once);
*LWP::UserAgent::request = sub {
    my ($self, $req) = @_;
    my $url = $req->uri->as_string;
    for my $ep (keys %responses) {
        next unless index($url, "https://$ep") == 0;
        push @calls, $ep;
        return $responses{$ep};
    }
    die "test bug: no mocked response for URL $url\n";
};
use warnings;

my $EPS = '10.0.0.1:443,10.0.0.2:443,10.0.0.3:443';
sub scfg { return { lb_api_host => $_[0] // $EPS, lb_jwt => 'secret-token' }; }
sub refused { HTTP::Response->new(500, "Can't connect to $_[0] (Connection refused)", ['Client-Warning' => 'Internal response'], '') }
sub ok200   { HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"ok":1}') }

# Run one _api call, collecting warnings; returns (result, error, \@warnings).
sub run {
    my ($method, %o) = @_;
    @calls = ();
    my @w;
    local $SIG{__WARN__} = sub { push @w, $_[0] };
    my $r = eval {
        PVE::Storage::Custom::LightbitsPlugin::_api(scfg($o{eps}), $method, '/api/v2/x',
            $method =~ /^(?:GET|HEAD)$/ ? undef : { name => 'vol' });
    };
    return ($r, $@, \@w);
}

# ── first endpoint refuses, second answers -> one warning naming the first ───
$START = 0;
%responses = ('10.0.0.1:443' => refused('10.0.0.1:443'), '10.0.0.2:443' => ok200(), '10.0.0.3:443' => ok200());
my ($r, $err, $w) = run('GET');
is( $err, '', 'GET succeeds past a refusing endpoint' );
is_deeply( $r, { ok => 1 }, '  ...with the live endpoint\'s answer' );
is( scalar(@$w), 1, '  ...and warns exactly once' );
like( $w->[0], qr/^Lightbits API GET \/api\/v2\/x succeeded via 10\.0\.0\.2:443 after failing via 10\.0\.0\.1:443 \(500 Can't connect to 10\.0\.0\.1:443 \(Connection refused\)\)/,
    '  ...naming the method, path, the endpoint that answered and the skipped one with its status' );
like( $w->[0], qr/check those lb_api_host endpoints\n\z/, '  ...ending in an operator hint and a single newline' );
is( ($w->[0] =~ tr/\n//), 1, '  ...on exactly one line' );
unlike( $w->[0], qr/secret-token/, '  ...never containing the JWT' );
unlike( $w->[0], qr/[^\x00-\x7F]/, '  ...ASCII only' );

# ── two endpoints skipped -> still one warning, naming both in order ─────────
%responses = ('10.0.0.1:443' => refused('10.0.0.1:443'), '10.0.0.2:443' => refused('10.0.0.2:443'), '10.0.0.3:443' => ok200());
($r, $err, $w) = run('GET');
is( $err, '', 'GET succeeds on the third endpoint' );
is( scalar(@$w), 1, '  ...with a single warning' );
like( $w->[0], qr/succeeded via 10\.0\.0\.3:443 after failing via 10\.0\.0\.1:443 \(.*\), 10\.0\.0\.2:443 \(/,
    '  ...listing both skipped endpoints in the order tried' );

# ── random start honoured: start at the third endpoint, wrap to the first ────
$START = 2;
%responses = ('10.0.0.1:443' => ok200(), '10.0.0.2:443' => ok200(), '10.0.0.3:443' => refused('10.0.0.3:443'));
($r, $err, $w) = run('GET');
is_deeply( \@calls, ['10.0.0.3:443', '10.0.0.1:443'], 'wraps from the last endpoint to the first' );
like( $w->[0] // '', qr/succeeded via 10\.0\.0\.1:443 after failing via 10\.0\.0\.3:443 /, '  ...and the warning says so' );
$START = 0;

# ── no failover needed -> no warning ─────────────────────────────────────────
%responses = map { $_ => ok200() } qw(10.0.0.1:443 10.0.0.2:443 10.0.0.3:443);
($r, $err, $w) = run('GET');
is( $err, '', 'GET on a healthy first endpoint succeeds' );
is( scalar(@$w), 0, '  ...without any warning' );
is( scalar(@calls), 1, '  ...after one request' );

# ── a mutation that fails over before sending warns too ──────────────────────
%responses = ('10.0.0.1:443' => refused('10.0.0.1:443'), '10.0.0.2:443' => ok200(), '10.0.0.3:443' => ok200());
($r, $err, $w) = run('POST');
is( $err, '', 'POST fails over past a refused connect' );
is( scalar(@$w), 1, '  ...and warns once' );
like( $w->[0], qr/^Lightbits API POST /, '  ...naming the method' );

# ── a 404 from the endpoint reached after failover still warns (the failover
#    happened; the 404 itself is a definitive answer, not a failure) ─────────
%responses = (
    '10.0.0.1:443' => refused('10.0.0.1:443'),
    '10.0.0.2:443' => HTTP::Response->new(404, 'Not Found', [], ''),
    '10.0.0.3:443' => ok200(),
);
($r, $err, $w) = run('GET');
is_deeply( $r, {}, '404 after failover still maps to an empty hashref' );
is( scalar(@$w), 1, '  ...and warns about the skipped endpoint' );

# ── a plain 404 or 4xx on the first endpoint -> no warning ───────────────────
%responses = map { $_ => HTTP::Response->new(404, 'Not Found', [], '') } qw(10.0.0.1:443 10.0.0.2:443 10.0.0.3:443);
($r, $err, $w) = run('GET');
is( scalar(@$w), 0, 'a 404 with no failover does not warn' );
%responses = map { $_ => HTTP::Response->new(403, 'Forbidden', [], '{}') } qw(10.0.0.1:443 10.0.0.2:443 10.0.0.3:443);
($r, $err, $w) = run('GET');
ok( $err, 'a 4xx still dies' );
is( scalar(@$w), 0, '  ...without a failover warning' );

# ── every endpoint fails -> dies, no warning (the error already names all) ───
%responses = map { $_ => refused($_) } qw(10.0.0.1:443 10.0.0.2:443 10.0.0.3:443);
($r, $err, $w) = run('GET');
like( $err, qr/10\.0\.0\.1:443.*10\.0\.0\.2:443.*10\.0\.0\.3:443/s, 'all endpoints failing dies naming every endpoint' );
is( scalar(@$w), 0, '  ...and emits no failover warning' );

# ── a single configured endpoint never warns ─────────────────────────────────
%responses = ('10.0.0.1:443' => ok200());
($r, $err, $w) = run('GET', eps => '10.0.0.1:443');
is( scalar(@$w), 0, 'a single endpoint that answers does not warn' );

done_testing();
