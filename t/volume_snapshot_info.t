#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests volume_snapshot_info: it filters the project snapshot list client-side on
# sourceVolumeUUID (the server-side filter is not relied upon), reports only
# snapshots in our naming scheme keyed by the Proxmox name, orders them by
# creation time, and parses the UTC ISO-8601 creationTime (with a nanosecond
# fraction) to epoch seconds via timegm.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-000000000abc';
my $OTHER = 'baddcafe-0000-4000-8000-000000000999';

no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    return { snapshots => [
        # our volume, two snapshots (note: 'older' created before 'newer')
        { name => "snap-$UUID-newer", UUID => 's2', sourceVolumeUUID => $UUID,
          creationTime => '2026-06-14T12:00:05.459308408Z' },
        { name => "snap-$UUID-older", UUID => 's1', sourceVolumeUUID => $UUID,
          creationTime => '2026-06-14T11:00:00Z' },
        # a different volume's snapshot -> must be filtered out
        { name => "snap-$OTHER-foreign", UUID => 's3', sourceVolumeUUID => $OTHER,
          creationTime => '2026-06-14T10:00:00Z' },
        # not in our naming scheme -> ignored
        { name => "snapshot_0", UUID => 's4', sourceVolumeUUID => $UUID,
          creationTime => '2026-06-14T09:00:00Z' },
    ] } if $method eq 'GET' && $path =~ m{/snapshots$};
    return {};
};
use warnings 'redefine';

my $scfg = { lb_project => 'default' };
my $info = $class->volume_snapshot_info($scfg, 'lb-storage', "vm-100-$UUID");

is_deeply( [ sort keys %$info ], [ 'newer', 'older' ],
    'only this volume\'s in-scheme snapshots are reported (foreign + non-scheme dropped)' );

# order reflects creation time: older (0) before newer (1)
is( $info->{older}{order}, 0, 'oldest snapshot has order 0' );
is( $info->{newer}{order}, 1, 'newer snapshot has order 1' );

# snapshot UUID is exposed as id
is( $info->{older}{id}, 's1', 'older snapshot carries its UUID as id' );
is( $info->{newer}{id}, 's2', 'newer snapshot carries its UUID as id' );

# timestamps parsed as UTC (timegm), nanosecond fraction ignored
use Time::Local qw(timegm);
is( $info->{older}{timestamp}, timegm(0, 0, 11, 14, 5, 2026 - 1900),
    'older timestamp parsed as UTC' );
is( $info->{newer}{timestamp}, timegm(5, 0, 12, 14, 5, 2026 - 1900),
    'newer timestamp parsed as UTC with the nanosecond fraction stripped' );

done_testing();
