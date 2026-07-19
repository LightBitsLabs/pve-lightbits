#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for the discovery-client config-file helpers: activate_volume seeds
# discovery-client instead of driving `nvme connect` itself, by writing
# /etc/discovery-client/discovery.d/lightbits-<storeid>.conf.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

sub dsc_conf_lines  { return PVE::Storage::Custom::LightbitsPlugin::_dsc_conf_lines(@_) }
sub dsc_conf_path   { return PVE::Storage::Custom::LightbitsPlugin::_dsc_conf_path(@_) }
sub write_dsc_conf  { return PVE::Storage::Custom::LightbitsPlugin::_write_dsc_conf(@_) }
sub remove_dsc_conf { return PVE::Storage::Custom::LightbitsPlugin::_remove_dsc_conf(@_) }

# ── _dsc_conf_lines: one line per lb_nvme_host endpoint, fixed discovery port ───
my @lines = dsc_conf_lines(
    { lb_nvme_host => '10.0.0.1:4420,10.0.0.2:4420' },
    'nqn.host', 'nqn.subsys',
);
is_deeply( \@lines, [
    '-t tcp -a 10.0.0.1 -s 8009 -q nqn.host -n nqn.subsys',
    '-t tcp -a 10.0.0.2 -s 8009 -q nqn.host -n nqn.subsys',
], 'one line per endpoint, using the fixed discovery port (not the I/O port)' );

is_deeply( [ dsc_conf_lines({ lb_nvme_host => undef }, 'h', 's') ], [],
    'no lb_nvme_host -> no lines' );

# ── _dsc_conf_path ───────────────────────────────────────────────────────────
{
    no warnings 'once';
    local $PVE::Storage::Custom::LightbitsPlugin::DSC_CONF_DIR = '/etc/discovery-client/discovery.d';
    is( dsc_conf_path('lb-storage'),
        '/etc/discovery-client/discovery.d/lightbits-lb-storage.conf',
        'conf path is namespaced by storeid' );
}

# ── _write_dsc_conf / _remove_dsc_conf against a temp dir ───────────────────────
my $root = tempdir(CLEANUP => 1);
{
    no warnings 'once';
    local $PVE::Storage::Custom::LightbitsPlugin::DSC_ROOT_DIR = $root;
    local $PVE::Storage::Custom::LightbitsPlugin::DSC_CONF_DIR = "$root/discovery.d";

    write_dsc_conf('lb-storage',
        { lb_nvme_host => '10.0.0.1:4420,10.0.0.2:4420' },
        'nqn.host', 'nqn.subsys');

    my $path = "$root/discovery.d/lightbits-lb-storage.conf";
    ok( -f $path, 'conf file was created' );
    open(my $fh, '<', $path) or die $!;
    my @got = <$fh>;
    close($fh);
    is_deeply( \@got, [
        "-t tcp -a 10.0.0.1 -s 8009 -q nqn.host -n nqn.subsys\n",
        "-t tcp -a 10.0.0.2 -s 8009 -q nqn.host -n nqn.subsys\n",
    ], 'conf file content matches _dsc_conf_lines' );

    # No leftover temp file in the staging root (only the discovery.d subdir's
    # final file should remain after the atomic rename).
    opendir(my $dh, $root) or die $!;
    my @root_entries = grep { !/^\.\.?$/ && $_ ne 'discovery.d' } readdir($dh);
    closedir($dh);
    is_deeply( \@root_entries, [], 'no leftover temp file after the atomic rename' );

    # Re-writing (e.g. a second activate_volume with different endpoints)
    # replaces the file rather than appending.
    write_dsc_conf('lb-storage',
        { lb_nvme_host => '10.0.0.9:4420' }, 'nqn.host', 'nqn.subsys');
    open(my $fh2, '<', $path) or die $!;
    my @got2 = <$fh2>;
    close($fh2);
    is_deeply( \@got2, ["-t tcp -a 10.0.0.9 -s 8009 -q nqn.host -n nqn.subsys\n"],
        'a second write replaces (not appends to) the conf file' );

    # A second storeid gets its own file; removing one leaves the other intact.
    write_dsc_conf('other-storage',
        { lb_nvme_host => '10.0.0.5:4420' }, 'nqn.host', 'nqn.subsys');
    remove_dsc_conf('lb-storage');
    ok( !-f $path, "_remove_dsc_conf removes only its own storeid's conf file" );
    ok( -f "$root/discovery.d/lightbits-other-storage.conf",
        "a different storeid's conf file is untouched" );

    # Idempotent: removing an already-absent conf file does not die.
    my $ok = eval { remove_dsc_conf('lb-storage'); 1; };
    ok( $ok, 'removing an already-absent conf file is a no-op, not an error' )
        or diag($@);
}

done_testing();
