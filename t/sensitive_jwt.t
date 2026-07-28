#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Tests for storing lb_jwt as a Proxmox sensitive property.
#
# Declaring lb_jwt in plugindata's 'sensitive-properties' keeps it out of
# /etc/pve/storage.cfg (root:www-data 0640, readable by the whole www-data
# group) and makes PVE hand it to our hooks instead, to persist under
# /etc/pve/priv/storage at 0600.
#
# The catch is that PVE never reads it back for us: a sensitive property does
# not appear in $scfg, so every path that talks to the API has to load the token
# itself. The entry-point coverage test at the bottom is the important one here,
# because missing a single method would break only that operation, at runtime.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $P     = 'PVE::Storage::Custom::LightbitsPlugin';
my $UUID  = 'feedface-0000-4000-8000-0000000000aa';
my $TOKEN = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig';

my $priv = tempdir(CLEANUP => 1);
{
    no warnings 'once';
    $PVE::Storage::Custom::LightbitsPlugin::PRIV_DIR = $priv;
}

sub jwt_file  { return PVE::Storage::Custom::LightbitsPlugin::_jwt_file(@_) }
sub read_jwt  { return PVE::Storage::Custom::LightbitsPlugin::_read_jwt(@_) }
sub write_jwt { return PVE::Storage::Custom::LightbitsPlugin::_write_jwt(@_) }
sub ensure_jwt { return PVE::Storage::Custom::LightbitsPlugin::_ensure_jwt(@_) }

# ── plugindata declares lb_jwt sensitive ───────────────────────────────────────
my $pd = $class->plugindata();
ok( $pd->{'sensitive-properties'}, "plugindata declares 'sensitive-properties'" );
is( ref($pd->{'sensitive-properties'}), 'HASH',
    'sensitive-properties is a hashref (PVE reads it with sort keys)' );
ok( $pd->{'sensitive-properties'}{lb_jwt}, 'lb_jwt is marked sensitive' );

# Declaring our own list REPLACES PVE's built-in default rather than extending
# it, so every secret this plugin has must appear here. Guard against a future
# secret option being added to options() and silently left in plaintext.
my $opts = $class->options();
my @secretish = grep { /jwt|password|secret|key(ring)?$|token/i } keys %$opts;
is_deeply( [sort @secretish], ['lb_jwt'],
    'lb_jwt is the only secret-looking option, so the replacement list is complete' );

# lb_jwt must still be declared normally: the sensitive extraction happens
# inside the API handler, after schema validation, so an undeclared parameter
# would be rejected outright.
ok( $class->properties()->{lb_jwt}, 'lb_jwt is still declared in properties()' );
ok( exists $opts->{lb_jwt},         'lb_jwt is still declared in options()' );

# ── file storage: round-trip, permissions, absence ─────────────────────────────
is( jwt_file('lb'), "$priv/lb.pw", 'the token file follows PVE\'s <storeid>.pw convention' );
is( read_jwt('lb'), undef, 'no token file yet reads as undef, not an empty string' );

write_jwt('lb', $TOKEN);
is( read_jwt('lb'), $TOKEN, 'the token round-trips through the private file' );
my $mode = (stat jwt_file('lb'))[2] & 07777;
is( sprintf('0%o', $mode), '0600', 'the token file is root-only (0600)' );

# A JWT is a long single line; make sure nothing truncates or re-wraps it.
my $long = 'x' x 4096;
write_jwt('lb', $long);
is( read_jwt('lb'), $long, 'a long token survives intact' );
write_jwt('lb', $TOKEN);

# ── _ensure_jwt ────────────────────────────────────────────────────────────────
{
    my $scfg = {};
    ensure_jwt($scfg, 'lb');
    is( $scfg->{lb_jwt}, $TOKEN, '_ensure_jwt loads the token from the private file' );
}
{
    # Legacy entry: the token is still in plaintext in storage.cfg. It must win,
    # so an existing storage keeps working untouched across the upgrade.
    my $scfg = { lb_jwt => 'legacy-plaintext-token' };
    ensure_jwt($scfg, 'lb');
    is( $scfg->{lb_jwt}, 'legacy-plaintext-token',
        '_ensure_jwt leaves an existing plaintext token alone' );
}
{
    my $scfg = {};
    ensure_jwt($scfg, 'no-such-storage');
    is( $scfg->{lb_jwt}, undef, '_ensure_jwt leaves the token undef when no file exists' );
}
{
    # An empty value in $scfg must not shadow the real token.
    my $scfg = { lb_jwt => '' };
    ensure_jwt($scfg, 'lb');
    is( $scfg->{lb_jwt}, $TOKEN, '_ensure_jwt treats an empty lb_jwt as absent' );
}

# ── _api fails clearly rather than sending an empty bearer token ───────────────
{
    my $ok = eval {
        PVE::Storage::Custom::LightbitsPlugin::_api(
            { lb_api_host => '10.0.0.1:443' }, 'GET', '/api/v2/cluster');
        1;
    };
    ok( !$ok, '_api dies when no token is available' );
    like( $@, qr/token is not available/, 'the error says the token is missing' );
    like( $@, qr/pvesm set/, 'the error tells the operator how to set it' );
    unlike( $@, qr/401|Unauthorized/, 'it does not surface as an opaque auth failure' );
}

# ── hooks: add / update / delete ───────────────────────────────────────────────
unlink jwt_file('new');
$class->on_add_hook('new', { lb_api_host => '10.0.0.1:443' }, lb_jwt => $TOKEN);
is( read_jwt('new'), $TOKEN, 'on_add_hook persists the token handed to it' );

$class->on_update_hook('new', {}, lb_jwt => 'rotated');
is( read_jwt('new'), 'rotated', 'on_update_hook replaces the stored token' );

# An update that does not mention lb_jwt must leave the stored token alone.
$class->on_update_hook('new', {}, lb_project => 'other');
is( read_jwt('new'), 'rotated', 'an unrelated update does not disturb the token' );

# extract_sensitive_params signals a deletion as an explicit undef.
$class->on_update_hook('new', {}, lb_jwt => undef);
is( read_jwt('new'), undef, 'an explicit undef deletes the stored token' );

write_jwt('new', $TOKEN);
$class->on_delete_hook('new', {});
is( read_jwt('new'), undef, 'on_delete_hook removes the token file' );
ok( !-e jwt_file('new'), 'the token file is gone after on_delete_hook' );

# on_delete_hook for a storage that never had a token must not blow up.
my $ok = eval { $class->on_delete_hook('never-existed', {}); 1 };
ok( $ok, 'on_delete_hook is a no-op when there is no token file' );

# ── on_update_hook_full: the plaintext migration path ──────────────────────────
# $scfg here is the live stored config, which PVE writes back to storage.cfg
# right after the hook returns. A token left in plaintext by a pre-sensitive
# entry has to be moved out and removed from $scfg, or it would be written back
# verbatim on every update and linger forever.
{
    unlink jwt_file('legacy');
    my $scfg = { lb_api_host => '10.0.0.1:443', lb_jwt => 'plaintext-from-storage-cfg' };
    $class->on_update_hook_full('legacy', $scfg, { lb_project => 'p' }, undef, {});
    is( read_jwt('legacy'), 'plaintext-from-storage-cfg',
        'a plaintext token is migrated into the private file' );
    ok( !exists $scfg->{lb_jwt},
        'lb_jwt is removed from the live config so it is not written back' );
}
{
    # A new token supplied in the same request wins over the stale plaintext.
    unlink jwt_file('legacy');
    my $scfg = { lb_jwt => 'stale-plaintext' };
    $class->on_update_hook_full('legacy', $scfg, {}, undef, { lb_jwt => 'brand-new' });
    is( read_jwt('legacy'), 'brand-new',
        'a token supplied in the update wins over the stale plaintext' );
    ok( !exists $scfg->{lb_jwt}, 'the stale plaintext is still cleared' );
}
{
    # Deleting the token must not resurrect it from the plaintext value.
    write_jwt('legacy', $TOKEN);
    my $scfg = { lb_jwt => 'stale-plaintext' };
    $class->on_update_hook_full('legacy', $scfg, {}, ['lb_jwt'], { lb_jwt => undef });
    is( read_jwt('legacy'), undef, 'deleting the token removes the private file' );
    ok( !exists $scfg->{lb_jwt}, 'and clears the plaintext rather than falling back to it' );
}
{
    # Nothing to migrate: no plaintext, no secret in the update.
    unlink jwt_file('modern');
    write_jwt('modern', $TOKEN);
    my $scfg = { lb_api_host => '10.0.0.1:443' };
    $class->on_update_hook_full('modern', $scfg, { lb_project => 'p' }, undef, {});
    is( read_jwt('modern'), $TOKEN, 'an already-migrated storage keeps its token' );
}
{
    # $sensitive may be undef on some call paths; must not autovivify or die.
    my $scfg = {};
    my $survived = eval { $class->on_update_hook_full('modern', $scfg, {}, undef, undef); 1 };
    ok( $survived, 'on_update_hook_full tolerates an undef sensitive hashref' );
}

# ── every API-touching entry point loads the token ─────────────────────────────
#
# This is the guard that matters. A sensitive property is invisible in $scfg, so
# a method that forgets to call _ensure_jwt fails at runtime with an
# authentication error on that operation alone - the kind of gap a unit test has
# to catch, because it is invisible until someone exercises that exact path.
{
    my @calls;
    no warnings 'redefine';
    my $real = \&PVE::Storage::Custom::LightbitsPlugin::_ensure_jwt;
    local *PVE::Storage::Custom::LightbitsPlugin::_ensure_jwt = sub {
        push @calls, [ $_[1] ];   # storeid
        return $real->(@_);
    };
    # Stop each method at its first API call: _ensure_jwt must already have run.
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub { die "STOP\n" };
    local *PVE::Storage::Custom::LightbitsPlugin::_host_nqn = sub { 'nqn.test:host' };
    use warnings 'redefine';

    my $vol = "vm-100-$UUID";
    my @entry_points = (
        [ 'status'                      => sub { $class->status('lb', $_[0], {}) } ],
        [ 'list_images'                 => sub { $class->list_images('lb', $_[0], undef, undef, {}) } ],
        [ 'volume_size_info'            => sub { $class->volume_size_info($_[0], 'lb', $vol) } ],
        [ 'alloc_image'                 => sub { $class->alloc_image('lb', $_[0], 100, 'raw', undef, 1048576) } ],
        [ 'free_image'                  => sub { $class->free_image('lb', $_[0], $vol, 0) } ],
        [ 'activate_volume'             => sub { $class->activate_volume('lb', $_[0], $vol) } ],
        [ 'deactivate_volume'           => sub { $class->deactivate_volume('lb', $_[0], $vol) } ],
        [ 'volume_resize'               => sub { $class->volume_resize($_[0], 'lb', $vol, 2 * 1024**3, 0) } ],
        [ 'volume_snapshot'             => sub { $class->volume_snapshot($_[0], 'lb', $vol, 'snap1') } ],
        [ 'volume_snapshot_delete'      => sub { $class->volume_snapshot_delete($_[0], 'lb', $vol, 'snap1', 0) } ],
        [ 'volume_rollback_is_possible' => sub { $class->volume_rollback_is_possible($_[0], 'lb', $vol, 'snap1', {}) } ],
        [ 'volume_snapshot_rollback'    => sub { $class->volume_snapshot_rollback($_[0], 'lb', $vol, 'snap1') } ],
        [ 'volume_snapshot_info'        => sub { $class->volume_snapshot_info($_[0], 'lb', $vol) } ],
    );

    for my $ep (@entry_points) {
        my ($name, $call) = @$ep;
        @calls = ();
        my $scfg = { lb_api_host => '10.0.0.1:443', lb_project => 'default' };
        {
            local $SIG{__WARN__} = sub { };   # these paths warn as they bail out
            eval { $call->($scfg) };
        }
        ok( scalar(@calls) >= 1, "$name loads the token before touching the API" );
        is( $calls[0][0], 'lb', "$name passes the right storeid to _ensure_jwt" )
            if @calls;
    }
}

done_testing();
