#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for _api_endpoints: parsing the (possibly comma-separated) lb_api_host
# into a list of host:port strings for REST API failover.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

sub eps { return PVE::Storage::Custom::LightbitsPlugin::_api_endpoints(@_) }

is_deeply( [ eps('10.0.0.1:443') ], ['10.0.0.1:443'], 'single host:port' );
is_deeply( [ eps('10.0.0.1:443,10.0.0.2:443,10.0.0.3:443') ],
    ['10.0.0.1:443', '10.0.0.2:443', '10.0.0.3:443'],
    'three comma-separated endpoints' );
is_deeply( [ eps(' 10.0.0.1:443 , 10.0.0.2:443 ') ],
    ['10.0.0.1:443', '10.0.0.2:443'],
    'whitespace around entries is trimmed' );
is_deeply( [ eps('myhost') ], ['myhost'], 'bare host with no port is kept as-is' );
is_deeply( [ eps('') ], [], 'empty string -> no endpoints' );
is_deeply( [ eps(undef) ], [], 'undef -> no endpoints' );
is_deeply( [ eps('a:443,,  ,b:443') ], ['a:443', 'b:443'],
    'empty/blank entries are skipped' );

done_testing();
