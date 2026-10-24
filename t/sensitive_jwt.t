#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# lb_jwt as a Proxmox sensitive property. Declared in plugindata's
# 'sensitive-properties', it is kept out of /etc/pve/storage.cfg (root:www-data
# 0640, also returned by GET /storage/<id>) and persisted by the hooks under
# /etc/pve/priv/storage/<storeid>.pw at 0600.
#
# Proxmox never reads it back into $scfg, so every entry point that can reach
# the API loads it through _with_jwt, which returns a copy: Proxmox's own hash
# must never carry the token, or a later save of that hash would write it back
# to storage.cfg. The coverage tests at the bottom are the important ones:
# missing one entry point breaks only that operation, at runtime.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

BEGIN { no warnings 'once'; *CORE::GLOBAL::sleep = sub { 1 }; }

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $TOKEN = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig';
my $priv  = tempdir(CLEANUP => 1);
{ no warnings 'once'; $PVE::Storage::Custom::LightbitsPlugin::PRIV_DIR = $priv; }

sub P { no strict 'refs'; return &{"PVE::Storage::Custom::LightbitsPlugin::$_[0]"}(@_[1 .. $#_]) }

# ── declaration ────────────────────────────────────────────────────────────────
my $pd = $class->plugindata();
is(ref $pd->{'sensitive-properties'}, 'HASH', 'sensitive-properties is a hashref');
ok($pd->{'sensitive-properties'}{lb_jwt}, 'lb_jwt is marked sensitive');
# Our list REPLACES Proxmox's default one, so every secret-looking option must be on it.
my @secretish = grep { /jwt|password|secret|key(ring)?$|token/i } keys %{ $class->options() };
is_deeply([sort @secretish], ['lb_jwt'], 'lb_jwt is the only secret-looking option');
ok($class->properties()->{lb_jwt}, 'lb_jwt is still declared in properties()');
ok($class->options()->{lb_jwt}{optional}, 'lb_jwt is optional in options(): Proxmox extracts it before validating the rest');

# ── private file ─────────────────────────────────────────────────────────────
P('_write_jwt', 'lb-a', $TOKEN);
my $f = "$priv/lb-a.pw";
ok(-f $f, 'token written to <PRIV_DIR>/<storeid>.pw');
is((stat $f)[2] & 07777, 0600, 'mode 0600');
is(P('_read_jwt', 'lb-a'), $TOKEN, 'read back');
for my $bad ('../etc/x', 'a/b', '', '-x', "lb-a\n") {
    eval { P('_jwt_file', $bad) };
    like($@, qr/invalid storage id/, 'storage id ' . ($bad =~ s/\n/\\n/r) . ' refused for the file path');
}
P('_delete_jwt', 'lb-a');
ok(!-e $f, 'deleted');
is(P('_read_jwt', 'lb-a'), undef, 'absent file reads as undef');

# ── hooks ────────────────────────────────────────────────────────────────────
$class->on_add_hook('lb-a', { lb_api_host => 'h' }, lb_jwt => $TOKEN);
is(P('_read_jwt', 'lb-a'), $TOKEN, 'on_add_hook stores the token');

$class->on_update_hook_full('lb-a', {}, {}, [], { lb_jwt => 'NEW' });
is(P('_read_jwt', 'lb-a'), 'NEW', 'on_update_hook_full rotates it');

$class->on_update_hook_full('lb-a', {}, {}, [], {});
is(P('_read_jwt', 'lb-a'), 'NEW', 'an update without lb_jwt leaves it alone');

$class->on_update_hook_full('lb-a', {}, {}, ['lb_jwt'], { lb_jwt => undef });
is(P('_read_jwt', 'lb-a'), undef, 'explicit undef (delete) removes it');

my $legacy = { lb_api_host => 'h', lb_jwt => 'PLAINTEXT' };
$class->on_update_hook_full('lb-a', $legacy, { content => 'images' }, [], {});
is(P('_read_jwt', 'lb-a'), 'PLAINTEXT', 'migration: plaintext token moved to the private file');
ok(!exists $legacy->{lb_jwt}, 'migration: removed from the config Proxmox writes back');

$legacy = { lb_api_host => 'h', lb_jwt => 'PLAINTEXT' };
$class->on_update_hook_full('lb-a', $legacy, {}, [], { lb_jwt => 'GIVEN' });
is(P('_read_jwt', 'lb-a'), 'GIVEN', 'a token given in the same update wins over the old plaintext');
ok(!exists $legacy->{lb_jwt}, 'and the plaintext is still removed');

$class->on_update_hook('lb-a', {}, lb_jwt => 'OLDAPI');
is(P('_read_jwt', 'lb-a'), 'OLDAPI', 'on_update_hook (older storage API) stores it too');

$class->on_delete_hook('lb-a', {});
is(P('_read_jwt', 'lb-a'), undef, 'on_delete_hook removes the file');

# ── _with_jwt ────────────────────────────────────────────────────────────────
P('_write_jwt', 'lb-a', $TOKEN);
my $scfg = { lb_api_host => 'h', lb_project => 'default' };
my $c = P('_with_jwt', $scfg, 'lb-a');
is($c->{lb_jwt}, $TOKEN, 'copy carries the token');
ok(!exists $scfg->{lb_jwt}, "caller's hash is not modified");
isnt($c, $scfg, 'a different hash');
my $plain = { lb_jwt => 'PLAINTEXT' };
is(P('_with_jwt', $plain, 'lb-a'), $plain, 'a token already in $scfg (pre-migration entry) is used as is');
is(P('_with_jwt', $scfg, undef), $scfg, 'no storage id: unchanged');

eval { P('_api', { lb_api_host => '127.0.0.1:1' }, 'GET', '/api/v2/cluster') };
like($@, qr/API token is not available for this storage.*pvesm set/s, '_api without a token fails clearly');

# ── every API-reaching entry point loads the token, without touching $scfg ──────
my @seen;
{
    no warnings 'redefine';
    *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my ($s) = @_;
        push @seen, $s->{lb_jwt};
        die "stop\n";    # one call is enough to see what token it carried
    };
    # alloc_image and activate_volume read the host NQN first; never depend on the test host having one.
    *PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.2014-08.org.nvmexpress:uuid:test-host' };
}
my $U   = 'feedface-0000-4000-8000-0000000000aa';
my $vol = "vm-100-$U";
my %entry = (
    status                      => sub { $class->status('lb-a', $_[0], {}) },
    list_images                 => sub { $class->list_images('lb-a', $_[0], undef, undef, {}) },
    volume_size_info            => sub { $class->volume_size_info($_[0], 'lb-a', $vol) },
    alloc_image                 => sub { $class->alloc_image('lb-a', $_[0], 100, 'raw', undef, 1024 * 1024) },
    free_image                  => sub { $class->free_image('lb-a', $_[0], $vol) },
    activate_volume             => sub { $class->activate_volume('lb-a', $_[0], $vol) },
    volume_resize               => sub { $class->volume_resize($_[0], 'lb-a', $vol, 2 * 1024**3, 0) },
    volume_snapshot             => sub { $class->volume_snapshot($_[0], 'lb-a', $vol, 's1') },
    volume_snapshot_delete      => sub { $class->volume_snapshot_delete($_[0], 'lb-a', $vol, 's1', 0) },
    volume_rollback_is_possible => sub { $class->volume_rollback_is_possible($_[0], 'lb-a', $vol, 's1', []) },
    volume_snapshot_rollback    => sub { $class->volume_snapshot_rollback($_[0], 'lb-a', $vol, 's1') },
    volume_snapshot_info        => sub { $class->volume_snapshot_info($_[0], 'lb-a', $vol) },
);
local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /unreachable: stop/ };   # list_images/status warn on the stub's die
for my $name (sort keys %entry) {
    @seen = ();
    my $s = { lb_api_host => '10.0.0.1:443', lb_project => 'default', lb_owner_id => 'lbpve4',
              lb_nvme_host => '10.0.0.1:4420' };
    eval { $entry{$name}->($s) };
    ok(@seen, "$name reaches the API");
    is_deeply([ grep { !defined $_ || $_ ne $TOKEN } @seen ], [], "$name sends the token from the private file");
    ok(!exists $s->{lb_jwt}, "$name leaves Proxmox's \$scfg without the token");
}

# Static guard: any public method taking $storeid and $scfg must load the token
# first, so a method added later cannot silently skip it.
open(my $fh, '<', "$FindBin::RealBin/../LightbitsPlugin.pm") or die $!;
my $src = do { local $/; <$fh> };
my %exempt = map { $_ => 1 } qw(get_identity path on_add_hook on_update_hook on_update_hook_full on_delete_hook);
while ($src =~ /^sub ([a-z]\w*) \{\n    my \(\$class, ([^)]*)\) = \@_;\n(.*?)\n\}/msg) {
    my ($name, $args, $body) = ($1, $2, $3);
    next if $exempt{$name} || $args !~ /\$storeid/ || $args !~ /\$scfg/;
    like($body, qr/\A    \$scfg = _with_jwt\(\$scfg, \$storeid\);/, "$name loads the token first");
}

done_testing();
