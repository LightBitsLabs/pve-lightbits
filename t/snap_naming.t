#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests the LightOS snapshot name encode/decode helpers. The source volume UUID
# is embedded in the snapshot name so names stay unique within a project and map
# back to the Proxmox snapshot name without labels. Because the UUID itself
# contains '-', the decode must work by shape, not by splitting on '-'.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $P    = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID = 'feedface-0000-4000-8000-000000000abc';

no strict 'refs';
my $enc = \&{"${P}::_lb_snap_name"};
my $dec = \&{"${P}::_pve_snap_name"};
use strict 'refs';

# ── round-trip, including snap names that themselves contain '-' ───────────────
for my $snap ('snap1', 'pre-migration', 'a-b-c-d', 'with.dot', 'UPPER_case-9') {
    my $lb = $enc->($UUID, $snap);
    is( $lb, "snap-$UUID-$snap", "encode '$snap' embeds the volume UUID" );
    is( $dec->($lb), $snap, "decode '$snap' recovers the Proxmox name (UUID has dashes)" );
}

# ── names not in our scheme decode to undef ────────────────────────────────────
is( $dec->("snapshot_0"),                 undef, 'foreign snapshot name -> undef' );
is( $dec->("vm-100-$UUID"),               undef, 'a volume name -> undef' );
is( $dec->("snap-not-a-uuid-here"),       undef, 'snap- prefix without a real UUID -> undef' );
is( $dec->(undef),                        undef, 'undef -> undef' );

done_testing();
