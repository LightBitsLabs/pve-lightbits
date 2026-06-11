#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for _nvme_endpoints: parsing the (possibly comma-separated) lb_nvme_host
# into [host, port] pairs for multi-path NVMe-oF connect.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

# plain function (not a method)
sub eps { return PVE::Storage::Custom::LightbitsPlugin::_nvme_endpoints(@_) }

is_deeply( [ eps('10.0.0.1:4420') ], [ ['10.0.0.1','4420'] ],
    'single host:port' );
is_deeply( [ eps('10.19.38.4:4420,10.19.38.19:4420,10.19.38.23:4420') ],
    [ ['10.19.38.4','4420'], ['10.19.38.19','4420'], ['10.19.38.23','4420'] ],
    'three comma-separated endpoints (multipath)' );
is_deeply( [ eps(' 10.0.0.1:4420 , 10.0.0.2:4420 ') ],
    [ ['10.0.0.1','4420'], ['10.0.0.2','4420'] ],
    'whitespace around entries is trimmed' );
is_deeply( [ eps('myhost') ], [ ['myhost','4420'] ],
    'no :port defaults to 4420' );
is_deeply( [ eps('[fd00::1]:4420') ], [ ['[fd00::1]','4420'] ],
    'rightmost colon -> bracketed IPv6 literal parses' );
is_deeply( [ eps('') ], [], 'empty string -> no endpoints' );
is_deeply( [ eps(undef) ], [], 'undef -> no endpoints' );
is_deeply( [ eps('a:4420,,  ,b:4420') ], [ ['a','4420'], ['b','4420'] ],
    'empty/blank entries are skipped' );

done_testing();
