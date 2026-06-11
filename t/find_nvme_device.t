#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for _find_nvme_device's multipath-safe head-device resolution.
#
# Under native NVMe multipath each namespace appears in /sys/block both as the
# multipath HEAD (nvme<C>n<N>, has a /dev node) and as one per-path device
# (nvme<C>c<P>n<N>, no /dev node). The resolver must always return the head and
# never a per-path device. We drive it with a fake /sys/block + /dev tree.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

# _find_nvme_device is a plain function (not a method) — call it as one.
sub find { return PVE::Storage::Custom::LightbitsPlugin::_find_nvme_device(@_) }

my $sysblk = tempdir(CLEANUP => 1);
my $devdir = tempdir(CLEANUP => 1);
{
    no warnings 'once';
    $PVE::Storage::Custom::LightbitsPlugin::SYS_BLOCK = $sysblk;
    $PVE::Storage::Custom::LightbitsPlugin::DEV_DIR   = $devdir;
}
# Treat any fake /dev file we create as a block device.
no warnings 'redefine';
*PVE::Storage::Custom::LightbitsPlugin::_is_block = sub { -e $_[0] };
use warnings 'redefine';

sub wr { my ($f, $c) = @_; make_path($f =~ m{(.*)/[^/]+$}); open(my $fh, '>', $f) or die $!; print $fh $c; close $fh }

# Create a /sys/block namespace entry. %a: name, nsid, nqn, loc(device|direct), dev(0|1)
sub mk_ns {
    my %a = @_;
    wr("$sysblk/$a{name}/nsid", "$a{nsid}\n");
    if (($a{loc} // 'device') eq 'device') { wr("$sysblk/$a{name}/device/subsysnqn", "$a{nqn}\n") }
    else                                   { wr("$sysblk/$a{name}/subsysnqn", "$a{nqn}\n") }
    wr("$devdir/$a{name}", '') if $a{dev};
}

my $NQN = 'nqn.2016-01.com.lightbitslabs:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

# ── multipath: head + one per-path entry → return the head ──────────────────────
mk_ns(name => 'nvme0n1',   nsid => 9, nqn => $NQN, dev => 1);   # head
mk_ns(name => 'nvme0c0n1', nsid => 9, nqn => $NQN, dev => 0);   # per-path, no /dev node
is( find($NQN, 9), "$devdir/nvme0n1",
    'multipath: returns the head device, not the per-path cN device' );

# ── multiple paths, one head → still the head ──────────────────────────────────
mk_ns(name => 'nvme1n1',   nsid => 4, nqn => $NQN, dev => 1);   # head
mk_ns(name => 'nvme1c0n1', nsid => 4, nqn => $NQN, dev => 0);
mk_ns(name => 'nvme1c1n1', nsid => 4, nqn => $NQN, dev => 0);
is( find($NQN, 4), "$devdir/nvme1n1",
    'multiple paths collapse to the single head device' );

# ── non-multipath single namespace ─────────────────────────────────────────────
mk_ns(name => 'nvme2n1', nsid => 5, nqn => $NQN, dev => 1);
is( find($NQN, 5), "$devdir/nvme2n1",
    'non-multipath: returns the namespace device' );

# ── subsysnqn exposed one level up (older-kernel fallback) ──────────────────────
mk_ns(name => 'nvme3n1', nsid => 7, nqn => $NQN, loc => 'direct', dev => 1);
is( find($NQN, 7), "$devdir/nvme3n1",
    'falls back to /sys/block/<ns>/subsysnqn when device/subsysnqn is absent' );

# ── negative: nsid mismatch / nqn mismatch ─────────────────────────────────────
is( find($NQN, 9999), undef, 'unknown nsid → undef' );
is( find('nqn.other', 9), undef, 'unknown subsystem NQN → undef' );

# ── negative: head matches but has no /dev node → undef (the -b guard) ──────────
mk_ns(name => 'nvme4n1', nsid => 11, nqn => $NQN, dev => 0);
is( find($NQN, 11), undef,
    'matching head with no /dev node is not returned' );

# ── negative: only a per-path entry exists (no head) → undef ────────────────────
mk_ns(name => 'nvme5c0n1', nsid => 12, nqn => $NQN, dev => 0);
is( find($NQN, 12), undef,
    'a lone per-path cN entry is never returned' );

done_testing();
