#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_rollback_is_possible: it refuses a rollback that would shrink the
# namespace below the size Proxmox's VM config expects (snapshot taken before a
# resize), and allows it otherwise. This keeps the device and the VM config size
# consistent.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-000000000abc';
my $SUUID = 'aaaaaaaa-0000-4000-8000-000000000001';

my ($vol_size, $snap_size);
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    return { snapshots => [
        { name => "snap-$UUID-snap1", UUID => $SUUID, sourceVolumeUUID => $UUID },
    ] } if $method eq 'GET' && $path =~ m{/snapshots$};
    return { size => $snap_size } if $method eq 'GET' && $path =~ m{/snapshots/};
    return { size => $vol_size }  if $method eq 'GET' && $path =~ m{/volumes/};
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $volname = "vm-100-$UUID";

# ── equal sizes: allowed ───────────────────────────────────────────────────────
($vol_size, $snap_size) = (1073741824, 1073741824);
is( eval { $class->volume_rollback_is_possible($scfg, 'lb-storage', $volname, 'snap1') }, 1,
    'allows rollback when sizes match' );

# ── volume smaller than snapshot (shrunk since): allowed (no FS-corruption risk) ─
($vol_size, $snap_size) = (1073741824, 2147483648);
is( eval { $class->volume_rollback_is_possible($scfg, 'lb-storage', $volname, 'snap1') }, 1,
    'allows rollback when the snapshot is larger than the current volume' );

# ── volume grown since the snapshot: refused (would shrink under the guest FS) ──
($vol_size, $snap_size) = (3221225472, 1073741824);
ok( !eval { $class->volume_rollback_is_possible($scfg, 'lb-storage', $volname, 'snap1'); 1 },
    'refuses rollback that would shrink a resized volume' );
like( $@, qr/resized after the snapshot/, 'error explains the resize/shrink hazard' );

done_testing();
