#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# path() with a snapshot (issue #48): snapshots are supported, but a Lightbits
# snapshot has no block device of its own, so path() refuses with a message
# that says exactly that and names the snapshot, instead of claiming that
# snapshots are unsupported.

use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $U     = '6cfb3b59-2fab-4c6e-914b-6d7b1193caac';
my $scfg  = { lb_project => 'default' };

# ── snapshot passed as the $snap argument ─────────────────────────────────────
eval { $class->path($scfg, "vm-100-$U", 'lb-storage', 'before-upgrade') };
my $e = $@;
like( $e, qr/^Lightbits snapshot 'before-upgrade' of vm-100-\Q$U\E cannot be accessed as a block device; roll back to it, or clone or back up the VM from its current state\n\z/,
    'snapshot argument: dies naming the snapshot and the volume, with the way forward' );
unlike( $e, qr/not supported/i, '  ...and no longer claims snapshots are unsupported' );
unlike( $e, qr/[^\x00-\x7F]/, '  ...ASCII only (no mojibake in the PVE task log)' );

# ── snapshot embedded in the volname (vm-<vmid>-<uuid>@<snap>) ───────────────
eval { $class->path($scfg, "vm-100-$U\@nightly", 'lb-storage', undef) };
like( $@, qr/^Lightbits snapshot 'nightly' of vm-100-\Q$U\E\@nightly cannot be accessed as a block device;/,
    'embedded snapshot: same message, naming the embedded snapshot' );

# ── no snapshot: unchanged ────────────────────────────────────────────────────
my ($path, $owner, $vtype) = $class->path($scfg, "vm-100-$U", 'lb-storage', undef);
is( $path,  "/dev/lightbits/lb-storage/$U", 'no snapshot: path is the UUID symlink' );
is( $owner, 100, '  ...owner vmid unchanged' );
is( $vtype, 'images', '  ...vtype unchanged' );

done_testing();
