#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_snapshot: the project-scoped POST shape (UUID-embedded name +
# sourceVolumeUUID), and that it fails fast rather than reporting a snapshot as
# taken when the snapshot never reaches Available.

use strict;
use warnings;
use Test::More;
use FindBin;

BEGIN { *CORE::GLOBAL::sleep = sub { }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-000000000abc';
my $SUUID = 'aaaaaaaa-0000-4000-8000-000000000001';

my %post;            # captured POST
my $snap_state = 'Available';
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    if ($method eq 'POST') {
        %post = (path => $path, body => $body);
        return { UUID => $SUUID };
    }
    return { state => $snap_state } if $method eq 'GET' && $path =~ m{/snapshots/};
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $volname = "vm-100-$UUID";

# ── POST request shape ─────────────────────────────────────────────────────────
$snap_state = 'Available';
my $ret = eval { $class->volume_snapshot($scfg, 'lb-storage', $volname, 'snap1') };
is( $@, '', 'volume_snapshot succeeds when the snapshot becomes Available' );
is( $ret, undef, 'returns undef' );
is( $post{path}, '/api/v2/projects/default/snapshots', 'POSTs to the project-scoped snapshots endpoint' );
is( $post{body}{name}, "snap-$UUID-snap1", 'snapshot name embeds the source volume UUID' );
is( $post{body}{sourceVolumeUUID}, $UUID, 'body carries sourceVolumeUUID' );

# ── invalid snapshot name is rejected before the API ───────────────────────────
ok( !eval { $class->volume_snapshot($scfg, 'lb-storage', $volname, 'bad name!'); 1 },
    'rejects an out-of-charset snapshot name' );

# ── terminal failure state dies ────────────────────────────────────────────────
$snap_state = 'Failed';
ok( !eval { $class->volume_snapshot($scfg, 'lb-storage', $volname, 'snap2'); 1 },
    'dies when the snapshot enters a Failed state' );
like( $@, qr/Failed/, 'error names the failed state' );

# ── never-Available dies on timeout (does not return success) ──────────────────
$snap_state = 'Creating';
ok( !eval { $class->volume_snapshot($scfg, 'lb-storage', $volname, 'snap3'); 1 },
    'dies when the snapshot never becomes Available' );
like( $@, qr/did not become Available/, 'error reports the timeout' );

done_testing();
