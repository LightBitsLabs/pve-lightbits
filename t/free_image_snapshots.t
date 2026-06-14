#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests that free_image deletes the volume's snapshots before the volume (LightOS
# does not remove a volume's snapshots with it, so leaving them would orphan
# space and reserve names), is best-effort (a snapshot it can't delete is warned
# about but does not block freeing the volume), and matches only this volume's
# snapshots by sourceVolumeUUID.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-000000000abc';
my $OTHER = 'baddcafe-0000-4000-8000-000000000999';

my @deleted;            # ordered list of DELETEd paths
my $snap_delete_err;    # if set, snapshot DELETEs die with this
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_api = sub {
    my ($scfg, $method, $path, $body) = @_;
    return { snapshots => [
        { name => "snap-$UUID-a", UUID => 'sa', sourceVolumeUUID => $UUID },
        { name => "snap-$UUID-b", UUID => 'sb', sourceVolumeUUID => $UUID },
        { name => "snap-$OTHER-x", UUID => 'sx', sourceVolumeUUID => $OTHER },
    ] } if $method eq 'GET' && $path =~ m{/snapshots$};
    # re-check after a failed delete: report the snapshot still present so the
    # error surfaces (exercises the best-effort warn path)
    return { state => 'Available' } if $method eq 'GET' && $path =~ m{/snapshots/s[ab]$};
    if ($method eq 'DELETE') {
        push @deleted, $path;
        die $snap_delete_err if $snap_delete_err && $path =~ m{/snapshots/};
        return {};
    }
    return {};
};
use warnings 'redefine';

my $scfg    = { lb_project => 'default' };
my $volname = "vm-100-$UUID";

# ── snapshots deleted first, then the volume; foreign snapshot untouched ───────
@deleted = ();
$snap_delete_err = undef;
$class->free_image('lb-storage', $scfg, $volname, 0);

is( scalar(@deleted), 3, 'two snapshot deletes + one volume delete' );
is_deeply( [ @deleted[0,1] ],
    [ '/api/v2/projects/default/snapshots/sa', '/api/v2/projects/default/snapshots/sb' ],
    'this volume\'s snapshots are deleted first' );
like( $deleted[2], qr{/api/v2/volumes/$UUID}, 'the volume is deleted last' );
ok( !(grep { m{/snapshots/sx} } @deleted), 'a different volume\'s snapshot is never touched' );

# ── best-effort: a snapshot delete failure does not block freeing the volume ───
@deleted = ();
$snap_delete_err = "boom: snapshot has a dependent clone\n";
{
    local $SIG{__WARN__} = sub { };   # swallow the expected warning
    eval { $class->free_image('lb-storage', $scfg, $volname, 0); };
}
is( $@, '', 'free_image still completes when a snapshot cannot be deleted' );
like( $deleted[-1], qr{/api/v2/volumes/$UUID}, 'the volume is still deleted' );

done_testing();
