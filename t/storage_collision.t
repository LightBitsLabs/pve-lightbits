#!/usr/bin/perl
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Two storage entries on the same cluster with the same project and owner id
# select the same volumes (issue #71). Such a pair is refused when an entry is
# added or changed, and warned about when one that already exists is used.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

use lib "$FindBin::RealBin/stubs";
require "$FindBin::RealBin/../LightbitsPlugin.pm";

my $class = 'PVE::Storage::Custom::LightbitsPlugin';
my $pkg   = 'PVE::Storage::Custom::LightbitsPlugin';
my $tmp   = tempdir(CLEANUP => 1);

# storage.cfg as the plugin sees it, the cluster UUID behind each API endpoint,
# and a log of the cluster lookups made.
my (%entries, %uuid_of, @asked);
{
    no warnings qw(once redefine);
    $PVE::Storage::Custom::LightbitsPlugin::PRIV_DIR               = "$tmp/priv";
    $PVE::Storage::Custom::LightbitsPlugin::FAILOVER_STATE_DIR     = "$tmp/state";
    $PVE::Storage::Custom::LightbitsPlugin::STORAGE_ENTRIES        = sub { \%entries };
    *PVE::Storage::Custom::LightbitsPlugin::_hostname = sub { 'pve1' };
    *PVE::Storage::Custom::LightbitsPlugin::_api = sub {
        my ($scfg, $method, $path) = @_;
        die "unexpected API call $method $path\n" unless $path eq '/api/v2/cluster';
        push @asked, $scfg->{lb_api_host};
        my $u = $uuid_of{ $scfg->{lb_api_host} };
        die "Lightbits API unreachable\n" unless defined $u;
        return { UUID => $u };
    };
}
sub P { no strict 'refs'; return &{"${pkg}::$_[0]"}(@_[1 .. $#_]) }
sub lb { return { type => 'lightbits', lb_api_host => '10.0.0.1:443', lb_nvme_host => '10.0.0.1:4420', @_ } }
sub add_err {
    my ($id, $scfg, %sens) = @_;
    @asked = ();
    eval { $class->on_add_hook($id, $scfg, %sens) };
    return $@;
}

# ── add: refused when cluster, project and owner id all match ─────────────────
%entries = ('lb-a' => lb());
my $err = add_err('lb-b', lb(), lb_jwt => 'tok');
like($err, qr/'lb-b' would share its volumes with storage 'lb-a'/, 'same endpoint, project and owner: refused');
like($err, qr/project 'default' with owner id 'pve1'/, 'the error names the project and owner id');
like($err, qr/different lb_owner_id or lb_project/, 'and says how to fix it');
ok(!-e "$tmp/priv/lb-b.pw", 'a refused entry leaves no token file behind');
is(scalar @asked, 0, 'a shared endpoint needs no cluster lookup');

# ── add: accepted when any one of the three differs ───────────────────────────
is(add_err('lb-b', lb(lb_project => 'other'), lb_jwt => 'tok'), '', 'different project: accepted');
ok(-e "$tmp/priv/lb-b.pw", 'an accepted entry has its token stored');
is(add_err('lb-b', lb(lb_owner_id => 'pve1-compressed')), '', 'different owner id: accepted');
%uuid_of = ('10.0.0.1:443' => 'uuid-1', '10.9.9.9:443' => 'uuid-2');
is(add_err('lb-b', lb(lb_api_host => '10.9.9.9:443')), '', 'different cluster: accepted');
is(scalar @asked, 2, 'both clusters were asked for their identity');

# ── owner id: explicit value equal to the hostname default still collides ─────
like(add_err('lb-b', lb(lb_owner_id => 'pve1')), qr/would share/, 'explicit owner id equal to the default: refused');
%entries = ('lb-a' => lb(lb_project => 'p1', lb_owner_id => 'x'));
like(add_err('lb-b', lb(lb_project => 'p1', lb_owner_id => 'x')), qr/project 'p1' with owner id 'x'/, 'explicit project and owner: refused');

# ── same cluster under another address ────────────────────────────────────────
%entries = ('lb-a' => lb(lb_api_host => '10.0.0.1:443,10.0.0.2:443'));
like(add_err('lb-b', lb(lb_api_host => ' 10.0.0.2 ')), qr/would share/, 'one endpoint in common (default port, spaces): refused');
%entries = ('lb-a' => lb(lb_api_host => 'LB.example.com:443'));
like(add_err('lb-b', lb(lb_api_host => 'lb.example.com')), qr/would share/, 'host name case and default port are ignored');
%entries = ('lb-a' => lb(lb_api_host => '10.0.0.1:443'));
%uuid_of = ('10.0.0.1:443' => 'uuid-1', 'lb.example.com:443' => 'uuid-1');
like(add_err('lb-b', lb(lb_api_host => 'lb.example.com:443')), qr/would share/, 'no endpoint in common but the same cluster UUID: refused');
%uuid_of = ('10.0.0.1:443' => 'uuid-1');
is(add_err('lb-b', lb(lb_api_host => 'lb.example.com:443')), '', 'new cluster unreachable and no endpoint in common: accepted');
%uuid_of = ('lb.example.com:443' => 'uuid-1');
is(add_err('lb-b', lb(lb_api_host => 'lb.example.com:443')), '', 'other cluster unreachable and no endpoint in common: accepted');

# ── the other entry's stored token is used for its cluster lookup ─────────────
{
    my @tokens;
    no warnings 'redefine';
    local *PVE::Storage::Custom::LightbitsPlugin::_api = sub { push @tokens, $_[0]{lb_jwt}; return { UUID => 'u' } };
    %entries = ('lb-a' => lb());
    P('_write_jwt', 'lb-a', 'tok-a');
    add_err('lb-b', lb(lb_api_host => 'elsewhere:443'), lb_jwt => 'tok-b');
    is_deeply(\@tokens, ['tok-b', 'tok-a'], 'each cluster is asked with its own entry\'s token');
}

# ── entries that are not in the way ───────────────────────────────────────────
%uuid_of = ();
%entries = ('lb-a' => lb(disable => 1));
is(add_err('lb-b', lb()), '', 'a disabled entry does not collide');
%entries = ('lb-a' => lb());
is(add_err('lb-b', lb(disable => 1)), '', 'an entry added disabled is not checked');
%entries = ('nfs1' => { type => 'nfs', server => '10.0.0.1' }, 'lb-b' => lb());
is(add_err('lb-b', lb()), '', 'other storage types and the entry itself are ignored');
%entries = ('lb-a' => lb(nodes => { n1 => 1, n2 => 1 }));
is(add_err('lb-b', lb(nodes => { n3 => 1 })), '', 'node lists with no node in common: accepted');
like(add_err('lb-b', lb(nodes => { n2 => 1, n3 => 1 })), qr/would share/, 'node lists with a node in common: refused');
like(add_err('lb-b', lb()), qr/would share/, 'one entry on every node: refused');
like(add_err('lb-b', lb(nodes => 'n2,n3')), qr/would share/, 'a node list given as a string is understood');

# ── update (on_update_hook_full) ──────────────────────────────────────────────
sub upd_err {
    my ($id, $update, $delete, $sens) = @_;
    eval { $class->on_update_hook_full($id, $entries{$id}, $update, $delete, $sens) };
    return $@;
}
%entries = ('lb-a' => lb(), 'lb-b' => lb(lb_project => 'other'));
like(upd_err('lb-b', { lb_project => 'default' }, []), qr/'lb-b' would share its volumes with storage 'lb-a'/,
    'update moving an entry onto another entry\'s project: refused');
like(upd_err('lb-b', {}, ['lb_project']), qr/would share/, 'deleting lb_project (back to default): refused');
is(upd_err('lb-b', { lb_project => 'third' }, []), '', 'update to a free project: accepted');
is($entries{'lb-b'}{lb_project}, 'other', 'the hook does not apply the update itself');

# A pair that already collides can still be maintained, and can be fixed.
%entries = ('lb-a' => lb(), 'lb-b' => lb());
is(upd_err('lb-b', { lb_replica_count => 3 }, []), '', 'unrelated update on a colliding entry: accepted');
is(upd_err('lb-b', {}, [], { lb_jwt => 'new-token' }), '', 'token rotation on a colliding entry: accepted');
is(P('_read_jwt', 'lb-b'), 'new-token', 'and the token is stored');
is(upd_err('lb-b', { lb_owner_id => 'pve1-b' }, []), '', 'fixing it with a distinct owner id: accepted');
is(upd_err('lb-b', { disable => 1 }, []), '', 'fixing it by disabling one entry: accepted');
like(upd_err('lb-b', { lb_owner_id => 'pve1' }, []), qr/would share/, 'an update that keeps the collision: refused');
%entries = ('lb-a' => lb(), 'lb-b' => lb(disable => 1));
like(upd_err('lb-b', {}, ['disable']), qr/would share/, 're-enabling a colliding entry: refused');

# ── update on a storage API without on_update_hook_full ───────────────────────
%entries = ('lb-a' => lb(), 'lb-b' => lb(lb_project => 'other'));
eval { $class->on_update_hook('lb-b', { lb_project => 'default' }) };
like($@, qr/would share/, 'on_update_hook: refused using the stored entry plus the update');
eval { $class->on_update_hook('lb-b', { lb_replica_count => 2 }) };
is($@, '', 'on_update_hook: unrelated update accepted');

# ── existing pair: warned when used, never fatal, no API call ─────────────────
%entries = ('lb-a' => lb(), 'lb-b' => lb());
{
    no warnings 'once';
    $PVE::Storage::Custom::LightbitsPlugin::SYMLINK_DIR = "$tmp/dev";
}
my @warned;
local $SIG{__WARN__} = sub { push @warned, @_ };
@asked = ();
ok($class->activate_storage('lb-b', $entries{'lb-b'}), 'activate_storage still succeeds for a colliding entry');
is(scalar @warned, 1, 'one warning');
like($warned[0], qr/^WARNING: Lightbits storage 'lb-b' shares its volumes with storage 'lb-a'/, 'naming both entries');
is(scalar @asked, 0, 'without any API call');
$class->activate_storage('lb-b', $entries{'lb-b'});
is(scalar @warned, 1, 'rate-limited: not repeated at once');
{
    local $0 = 'task UPID:pve1:0001:qmstart:100:root@pam:';
    $class->activate_storage('lb-b', $entries{'lb-b'});
    is(scalar @warned, 2, 'always shown inside a task log');
}
@warned = ();
%entries = ('lb-a' => lb(), 'lb-b' => lb(lb_owner_id => 'pve1-b'));
$class->activate_storage('lb-b', $entries{'lb-b'});
is(scalar @warned, 0, 'no warning for entries that do not collide');
{
    no warnings 'once';
    local $PVE::Storage::Custom::LightbitsPlugin::STORAGE_ENTRIES = sub { die "pmxcfs not available\n" };
    ok($class->activate_storage('lb-b', $entries{'lb-b'}), 'a failure reading the entries never breaks activate_storage');
}

done_testing();
