# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.

package PVE::Storage::Custom::LightbitsPlugin;

use strict;
use warnings;
use base qw(PVE::Storage::Plugin);

use JSON qw(encode_json decode_json);
use LWP::UserAgent;
use HTTP::Request;
use File::Path qw(make_path);
use Time::Local qw(timegm);
use PVE::Tools qw(run_command);

# Overridable in tests.
our $SYMLINK_DIR = '/dev/lightbits';

# ── Lightbits REST API helper ─────────────────────────────────────────────────

# Parse lb_api_host — one or more comma-separated "host:port" (or bare host)
# API endpoints — into a list of trimmed strings used directly in request URLs.
sub _api_endpoints {
    my ($spec) = @_;
    my @eps;
    for my $e (split /,/, ($spec // '')) {
        $e =~ s/^\s+|\s+$//g;
        push @eps, $e if length $e;
    }
    return @eps;
}

# TLS options for the API client.
#
# Verification is OFF unless lb_fingerprint or lb_ssl_verify is set, because a
# LightOS cluster serves its API with a certificate issued by its own
# per-cluster CA and turning verification on by default would break every
# existing storage entry. Turn it on where you can: every request carries the
# lb_jwt bearer token in an Authorization header, so without verification an
# on-path attacker can present any certificate, terminate the connection, and
# harvest a token that grants full control of the project's volumes.
#
# Two ways to verify:
#   - lb_fingerprint: pin the SHA-256 fingerprint of the API certificate, the
#     same mechanism Proxmox's own PBS storage uses for self-signed servers.
#     This is the one that works against a LightOS cluster as shipped: its
#     API certificate is issued to the name "api.service" with no SAN by the
#     cluster's internal CA, which the cluster does not hand out, so CA-based
#     verification of an endpoint addressed by IP cannot succeed. Every node
#     of a cluster presents the same certificate (verified live on a 3-node
#     LightOS 3.20.1 cluster across all six API endpoints), so one fingerprint
#     covers every lb_api_host entry. A matching fingerprint is accepted
#     regardless of CA chain and hostname; a mismatch falls through to the
#     chain check and fails. Several fingerprints may be listed, which is how
#     a certificate rotation stays seamless: add the new one before the
#     rotation, drop the old one after. Only the control plane depends on
#     this — the NVMe/TCP data path carries no TLS and running guests keep
#     their I/O whatever happens to the API certificate — but VM starts and
#     HA restarts need the API, so a stale pin would block them.
#   - lb_ssl_verify: peer and hostname verification against the host's trust
#     store, or lb_ca_file. For clusters fronted by a properly issued
#     certificate (a load balancer or proxy), or a LightOS cluster addressed
#     by a hostname that matches its certificate.
sub _ssl_opts {
    my ($scfg) = @_;

    my $fp_raw = $scfg->{lb_fingerprint} // '';
    my @fps = grep { length } map { s/^\s+|\s+$//gr } split /,/, $fp_raw;
    # A value that is set but yields no pins (only whitespace or commas, which
    # the schema pattern stops at pvesm but a hand-edited storage.cfg does not)
    # must not quietly leave the connection unverified.
    die "lb_fingerprint is set but contains no SHA-256 fingerprint\n"
        if $fp_raw =~ /\S/ && !@fps;

    return { verify_hostname => 0, SSL_verify_mode => 0 }
        unless @fps || $scfg->{lb_ssl_verify};

    # SSL_verify_mode 1 is IO::Socket::SSL's SSL_VERIFY_PEER.
    my %opts = (verify_hostname => 1, SSL_verify_mode => 1);
    if (@fps) {
        # IO::Socket::SSL wants "sha256$<hex>" (one, or a list of them); the
        # operator-facing form is openssl's colon-separated hex, as in PBS.
        my @pins;
        for my $fp (@fps) {
            (my $hex = lc $fp) =~ s/://g;
            die "lb_fingerprint '$fp' is not a SHA-256 fingerprint (64 hex digits)\n"
                unless $hex =~ /^[0-9a-f]{64}$/;
            push @pins, "sha256\$$hex";
        }
        $opts{SSL_fingerprint} = @pins == 1 ? $pins[0] : \@pins;
    }
    if (defined $scfg->{lb_ca_file} && length $scfg->{lb_ca_file}) {
        my $ca = $scfg->{lb_ca_file};
        die "lb_ca_file '$ca' is not a readable file\n" unless -r $ca;
        $opts{SSL_ca_file} = $ca;
    }
    return \%opts;
}

# lb_api_host may list several cluster management nodes for failover (mirrors
# Lightbits' own Cinder driver's lightos_api_address ListOpt + round-robin).
# Each call picks its own random start index — there's no long-lived process
# here to hold one across calls the way Cinder does — and cycles through every
# configured endpoint on a transport failure or 5xx before giving up. A 4xx is
# a definitive answer from a healthy node (every endpoint fronts the same
# cluster state) and is not retried against another one. Retrying across
# endpoints is further restricted to GET/HEAD: a 5xx can arrive after a POST
# (alloc_image, snapshot create) or other mutation already committed on the
# server (e.g. a proxy timeout after the backend succeeded), so retrying it
# against a different endpoint risks a duplicate/orphaned resource. GET/HEAD
# have no such side effect, so those are safe to retry.
sub _api {
    my ($scfg, $method, $path, $body, %opts) = @_;

    my @endpoints = _api_endpoints($scfg->{lb_api_host});
    die "lb_api_host is not configured\n" unless @endpoints;

    my $ua = LWP::UserAgent->new(
        ssl_opts => _ssl_opts($scfg),
        timeout  => $opts{timeout} // 15,
    );

    my $start = int(rand(scalar @endpoints));
    my @errors;
    for my $i (0 .. $#endpoints) {
        my $host = $endpoints[($start + $i) % @endpoints];
        my $req  = HTTP::Request->new($method => "https://$host$path");
        $req->header('Authorization' => "Bearer $scfg->{lb_jwt}");

        if ($body) {
            $req->header('Content-Type' => 'application/json');
            $req->content(encode_json($body));
        }

        my $res = $ua->request($req);
        # A 404 is reported as an empty result so the idempotent paths can treat
        # "already gone" as success (free_image deleting a volume that is no
        # longer there, _delete_snapshot re-checking after a racing delete).
        # Callers that go on to read fields out of the result need to tell an
        # absent resource apart from an empty one and ask for undef instead;
        # see _get_existing.
        if ($res->code == 404) {
            return $opts{missing_is_undef} ? undef : {};
        }
        if ($res->is_success) {
            return {} if !$res->content || $res->content eq '{}';
            return decode_json($res->content);
        }

        push @errors, "Lightbits API $method $path failed via $host: "
            . $res->status_line . " - " . $res->content . "\n";
        # Read methods are retried on any transport failure (LWP's synthetic
        # "Internal response") or genuine 5xx. Mutating calls are retried on the
        # next endpoint ONLY when the failure provably happened before the
        # request was delivered — LWP's "Can't connect to host:port" (refused,
        # connect timeout, unresolvable) or a failed TLS handshake. A read
        # timeout or a reset after the request was written, and any real 5xx,
        # may mean the mutation already took effect, so those stay single-shot.
        # Seen live 2026-10-04: with one of three LightOS nodes' API down, a
        # third of all snapshot/rollback/delete calls died on "Connection
        # refused" instead of failing over, leaving VMs locked.
        my $transport_failure = ($res->header('Client-Warning') // '') eq 'Internal response';
        my $retryable_method  = $method =~ /^(?:GET|HEAD)$/;
        die $errors[-1] unless ($retryable_method && ($transport_failure || $res->code >= 500))
            || _failed_before_send($res);
    }
    die join('', @errors);
}

# True only for LWP's synthetic responses whose error text proves the request
# never left this host: the connect itself failed (refused, connect timeout, no
# route, name resolution) or the TLS handshake failed. Anything else — a read
# timeout, "write failed", a reset mid-exchange — may have reached the server.
sub _failed_before_send {
    my ($res) = @_;
    return 0 unless ($res->header('Client-Warning') // '') eq 'Internal response';
    my $text = $res->status_line . ' ' . ($res->content // '');
    return $text =~ /Can't connect to |SSL (?:upgrade|connect attempt) failed|Name or service not known/ ? 1 : 0;
}

# GET a resource that the caller is about to read fields out of, failing
# immediately if the cluster says it is gone.
#
# _api maps a 404 to an empty hash, which is right for the idempotent delete
# paths but wrong here: an empty hash has no `state` and no `size`, so a
# resource deleted out of band reads as "present, just not converged yet". The
# polling loops would spin out their full 30-60 iteration timeout before failing
# with a misleading "did not become Available" message that sends the operator
# looking for a cluster convergence problem, and volume_rollback_is_possible
# would compare two zero sizes and green-light a rollback that cannot work.
sub _get_existing {
    my ($scfg, $path, $what, %opts) = @_;
    my $data = _api($scfg, 'GET', $path, undef, %opts, missing_is_undef => 1);
    die "$what no longer exists on the Lightbits cluster (deleted outside Proxmox?)\n"
        unless defined $data;
    return $data;
}

sub _project    { return $_[0]->{lb_project} // 'default'; }
sub _subsys_nqn {
    my ($scfg) = @_;
    return $scfg->{lb_subsys_nqn} if $scfg->{lb_subsys_nqn};
    my $data = _api($scfg, 'GET', '/api/v2/cluster');
    my $nqn = $data->{subsystemNQN} or die "Cannot determine subsystem NQN from cluster API\n";
    return $nqn;
}

# ── NVMe-oF helpers ───────────────────────────────────────────────────────────

sub _host_nqn {
    open(my $fh, '<', '/etc/nvme/hostnqn') or die "Cannot read /etc/nvme/hostnqn: $!\n";
    chomp(my $nqn = <$fh>);
    return $nqn;
}

# Parse lb_nvme_host — one or more comma-separated "host:port" endpoints — into a
# list of [host, port] pairs. Whitespace around entries is trimmed, an entry with
# no ":port" defaults to 4420, and the *rightmost* ":<port>" is used so bracketed
# IPv6 literals (e.g. "[fd00::1]:4420") parse correctly.
sub _nvme_endpoints {
    my ($spec) = @_;
    my @eps;
    for my $e (split /,/, ($spec // '')) {
        $e =~ s/^\s+|\s+$//g;
        next unless length $e;
        # Capture (untaints under perl -T) and strip IPv6 brackets so the bare
        # address is passed to `nvme -a`. IPv6 literals must be bracketed to be
        # distinguishable from host:port.
        my ($h, $p);
        if    ($e =~ /^\[(.+)\]:(\d+)$/) { ($h, $p) = ($1, $2); }       # [IPv6]:port
        elsif ($e =~ /^\[(.+)\]$/)       { ($h, $p) = ($1, '4420'); }   # [IPv6]
        elsif ($e =~ /^(.+):(\d+)$/)     { ($h, $p) = ($1, $2); }       # host:port
        elsif ($e =~ /^(\S+)$/)          { ($h, $p) = ($1, '4420'); }   # bare host
        else                             { next; }
        push @eps, [$h, $p];
    }
    return @eps;
}

# ── discovery-client integration ──────────────────────────────────────────────
#
# We don't run `nvme connect` ourselves. Instead we seed Lightbits'
# discovery-client daemon (must be installed/running on this host — see
# scripts/install.sh) with this cluster's discovery endpoints, and it owns the
# actual connecting. This mirrors Lightbits' own os-brick connector
# (dsc_connect_volume()/move_dsc_file()): unlike a static per-connect loop,
# discovery-client keeps itself in sync as cluster nodes are added later, with
# no config change on this host. It does NOT proactively remove connections for
# *removed* nodes (they go stale) unless the cluster has `ctrlLossTMO`
# configured (LightOS 3.19.1+) — that's why deactivate_volume below still runs
# an explicit `nvme disconnect`.

# Overridable in tests. $DSC_ROOT_DIR is discovery-client's own top-level config
# dir (used only as a same-filesystem staging area for the atomic rename below,
# never written into directly); $DSC_CONF_DIR is the directory it watches.
our $DSC_ROOT_DIR = '/etc/discovery-client';
our $DSC_CONF_DIR = '/etc/discovery-client/discovery.d';

# LightOS' NVMe-oF discovery service port. Fixed by convention (distinct from
# the I/O port carried in lb_nvme_host) — every entry researched for this
# plugin uses 8009, so it is not user-configurable.
my $DSC_DISCOVERY_PORT = 8009;

sub _dsc_conf_path {
    my ($storeid) = @_;
    return "$DSC_CONF_DIR/lightbits-$storeid.conf";
}

# One "-t tcp -a <host> -s 8009 -q <hostnqn> -n <subsysnqn>" line per configured
# lb_nvme_host endpoint (only the host is used — discovery always happens on
# the fixed discovery port above, not whatever I/O port that entry carries).
sub _dsc_conf_lines {
    my ($scfg, $host_nqn, $subsys_nqn) = @_;
    my @lines;
    for my $ep (_nvme_endpoints($scfg->{lb_nvme_host})) {
        my ($host) = @$ep;
        push @lines, "-t tcp -a $host -s $DSC_DISCOVERY_PORT -q $host_nqn -n $subsys_nqn";
    }
    return @lines;
}

# Seconds to wait for discovery-client to connect after its config was written
# before nudging it, and the total wait before giving up. Overridable in tests.
our $DSC_NUDGE_AFTER  = 10;
our $DSC_CONNECT_WAIT = 45;

# Restart discovery-client so it re-reads $DSC_CONF_DIR and connects. Used only
# when the daemon ignored a (re)written config for $DSC_NUDGE_AFTER seconds
# (see activate_volume). Best-effort: a failed restart is reported but the
# activation keeps waiting and then fails with its own, more useful, message.
sub _nudge_discovery_client {
    my ($storeid, $subsys_nqn) = @_;
    warn "Lightbits storage '$storeid': discovery-client has not connected to "
       . "$subsys_nqn ${DSC_NUDGE_AFTER}s after its config was written; "
       . "restarting discovery-client so it re-reads " . _dsc_conf_path($storeid) . "\n";
    my $rc = system('systemctl', 'restart', 'discovery-client');
    warn "Lightbits storage '$storeid': 'systemctl restart discovery-client' failed (rc=$rc)\n" if $rc != 0;
    return $rc == 0 ? 1 : 0;
}

# Atomically create/replace this storage's discovery-client config file. The
# temp file is written in $DSC_ROOT_DIR — outside the watched directory — and
# moved into place with rename(2), a single atomic filesystem operation, so
# discovery-client (which watches $DSC_CONF_DIR via inotify) only ever observes
# a complete file and never a partially-written one.
sub _write_dsc_conf {
    my ($storeid, $scfg, $host_nqn, $subsys_nqn) = @_;
    my @lines = _dsc_conf_lines($scfg, $host_nqn, $subsys_nqn);
    return unless @lines;   # nothing configured in lb_nvme_host; nothing to seed

    make_path($DSC_ROOT_DIR);
    make_path($DSC_CONF_DIR);
    my $final = _dsc_conf_path($storeid);
    my $tmp   = "$DSC_ROOT_DIR/.lightbits-$storeid.conf.tmp.$$";
    open(my $fh, '>', $tmp) or die "Cannot write $tmp: $!\n";
    print $fh "$_\n" for @lines;
    close($fh) or die "Cannot write $tmp: $!\n";
    rename($tmp, $final) or die "Cannot rename $tmp -> $final: $!\n";
}

sub _remove_dsc_conf {
    my ($storeid) = @_;
    my $f = _dsc_conf_path($storeid);
    unlink $f if -f $f;
}

# Read a single trimmed line from a sysfs file, or undef if unreadable.
sub _read_sysfs {
    my ($f) = @_;
    open(my $fh, '<', $f) or return undef;
    my $v = <$fh>;
    close($fh);
    return undef unless defined $v;
    chomp $v;
    return $v;
}

sub _is_connected {
    my ($subsys_nqn) = @_;
    return 0 unless -d '/sys/class/nvme';
    opendir(my $dh, '/sys/class/nvme') or return 0;
    for my $ctl (readdir $dh) {
        next unless $ctl =~ /^nvme\d+$/;
        my $f = "/sys/class/nvme/$ctl/subsysnqn";
        next unless -f $f;
        open(my $fh, '<', $f) or next;
        chomp(my $nqn = <$fh>);
        return 1 if $nqn eq $subsys_nqn;
    }
    return 0;
}

# Sysfs/dev roots and the block-device test, factored out so they can be
# overridden in unit tests (the function otherwise reads the real /sys and /dev).
our $SYS_BLOCK = '/sys/block';
our $DEV_DIR   = '/dev';
sub _dev_path { return "$DEV_DIR/$_[0]"; }
sub _is_block { return -b $_[0]; }

# Subsystem NQN of a /sys/block namespace entry, or undef. The head's "device"
# link points at the NVMe subsystem; fall back to the namespace dir itself for
# older kernels that expose subsysnqn there.
sub _ns_subsysnqn {
    my ($ns) = @_;
    my $f = "$SYS_BLOCK/$ns/device/subsysnqn";
    $f = "$SYS_BLOCK/$ns/subsysnqn" unless -f $f;
    return _read_sysfs($f);
}

# True if the /sys/block namespace entry $ns is exactly the (subsystem NQN,
# nsid) namespace we are looking for.
sub _ns_matches {
    my ($ns, $subsys_nqn, $nsid) = @_;
    my $nqn = _ns_subsysnqn($ns);
    return 0 unless defined $nqn && $nqn eq $subsys_nqn;
    my $found = _read_sysfs("$SYS_BLOCK/$ns/nsid");
    return 0 unless defined $found && $found =~ /^(\d+)$/;
    return $1 == $nsid ? 1 : 0;
}

# Resolve the namespace HEAD block device for a (subsystem NQN, nsid) pair.
#
# Under native NVMe multipath (CONFIG_NVME_MULTIPATH=Y, the default), each
# namespace appears twice in /sys/block: one entry per controller path,
# "nvme<C>c<P>n<N>", which has NO /dev node; and the multipath HEAD,
# "nvme<C>n<N>", which does. QEMU attaches the head, and the head is what
# survives a path failover — so we must always return it, never a per-path
# device. (The previous /sys/class/nvme walk built the device name from a path
# controller's number, which only equals the head when there is a single path;
# with multiple paths it produced a name with no /dev node and failed.)
#
# We therefore enumerate /sys/block, consider only head entries (no "c<P>"
# segment), and match the namespace by its subsystem NQN and nsid.
sub _find_nvme_device {
    my ($subsys_nqn, $nsid) = @_;
    return undef unless -d $SYS_BLOCK;
    opendir(my $dh, $SYS_BLOCK) or return undef;
    for my $entry (readdir $dh) {
        # Head namespace only ("nvme<C>n<N>"); the per-path "nvme<C>c<P>n<N>"
        # form is skipped. Capture to untaint (the CI runs perl -T).
        next unless $entry =~ /^(nvme\d+n\d+)$/;
        my $ns = $1;
        next unless _ns_matches($ns, $subsys_nqn, $nsid);

        my $dev = _dev_path($ns);
        return $dev if _is_block($dev);
    }
    closedir($dh);
    return undef;
}

# The "nvme<C>n<N>" namespace a volume symlink resolves to, or undef when the
# link is absent or points somewhere unrecognised. The capture untaints the
# value read back from the filesystem.
sub _symlink_ns {
    my ($link) = @_;
    return undef unless -l $link;
    my $dev = readlink($link) or return undef;
    return $1 if $dev =~ m{/(nvme\d+n\d+)$};
    return undef;
}

# True when $link still resolves to the head block device of exactly this
# (subsystem NQN, nsid) namespace.
#
# NVMe controller numbering is NOT stable across a disconnect/reconnect or a
# path flap: the device this volume occupied can come back as a different
# nvme<C>n<N>, and the old name can be reused by an entirely different
# namespace. A symlink left behind by an earlier activation is therefore only
# trustworthy once re-validated — otherwise a dangling link makes the symlink()
# below fail with EEXIST (activation stays broken until someone unlinks it by
# hand), and a link that now resolves to another volume's device would be
# reported as success and hand QEMU the wrong disk. Two sysfs reads, no API call.
sub _symlink_is_current {
    my ($link, $subsys_nqn, $nsid) = @_;
    # _is_block (not a bare -b) so tests can drive this with a fake /dev; both
    # follow the symlink, so this is the same check in production.
    return 0 unless _is_block($link);
    my $ns = _symlink_ns($link) or return 0;
    return _ns_matches($ns, $subsys_nqn, $nsid);
}

sub _symlink_path {
    my ($storeid, $volname) = @_;
    return "$SYMLINK_DIR/$storeid/$volname";
}

# Force the kernel to re-read a namespace's capacity by rescanning its NVMe
# *controller* (e.g. /dev/nvme0). We rescan the controller, not the namespace:
# under native NVMe multipath the per-path node may not exist. No-op when the
# volume isn't mapped on this node; idempotent. Used after operations that change
# the backing data/size out-of-band (resize, snapshot rollback).
sub _rescan_controller {
    my ($storeid, $link_name) = @_;
    my $link = _symlink_path($storeid, $link_name);
    return unless -l $link;
    my $dev = readlink($link);
    return unless $dev && $dev =~ m{/dev/(nvme\d+)};
    my $ctrl = $1;
    eval { run_command(['nvme', 'ns-rescan', "/dev/$ctrl"]) };
    warn "Could not rescan NVMe controller /dev/$ctrl: $@\n" if $@;
}

# Extract the Lightbits volume UUID from a Proxmox volume name. Names are
# "vm-<vmid>-<uuid>" (the UUID is always the trailing component); a bare UUID is
# also accepted. A trailing "@<snap>" (present on some PVE code paths) is dropped
# first, so the UUID resolves from a snapshot-qualified name too. The capture
# also untaints the value for filesystem/API use.
sub _vol_uuid {
    my ($volname) = @_;
    (my $base = $volname) =~ s/\@.*$//;
    return $1 if $base =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
    die "Cannot determine Lightbits volume UUID from '$volname'\n";
}

# ── Snapshot naming & lookup helpers ──────────────────────────────────────────

# LightOS snapshot names embed the source volume UUID. LightOS requires snapshot
# names to be unique within a project, so embedding the UUID keeps two volumes'
# identically-named Proxmox snapshots (e.g. both "snap1") distinct, and lets a
# LightOS snapshot map back to its Proxmox name without relying on labels
# (snapshots don't carry the volume's ownership labels).
my $SNAP_PREFIX = 'snap-';

sub _lb_snap_name {
    my ($vol_uuid, $pve_snap) = @_;
    return "${SNAP_PREFIX}${vol_uuid}-${pve_snap}";
}

# Inverse of _lb_snap_name. The UUID itself contains '-', so decode by fixed
# shape rather than splitting on '-': prefix, 36-char UUID, '-', then the
# Proxmox snapshot name. Returns undef for names not in our scheme.
sub _pve_snap_name {
    my ($lb_name) = @_;
    return undef unless defined $lb_name
        && $lb_name =~ /^\Q$SNAP_PREFIX\E[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-(.+)$/i;
    return $1;
}

# All snapshots whose source is the given volume UUID. The list endpoint's
# server-side source filter is not relied upon; we filter client-side on the
# globally-unique sourceVolumeUUID, which is also what keeps the result correct
# and node-safe when several hypervisors share a project.
#
# A failed listing (auth/transport/server error) propagates as a die rather than
# being masked as an empty result: a caller must not mistake a transient failure
# for "no snapshots" (e.g. a delete would then look idempotently successful while
# leaving the snapshot behind). free_image, which must stay best-effort, wraps
# this call in eval.
sub _snapshots_for_volume {
    my ($scfg, $project, $vol_uuid) = @_;
    my $data = _api($scfg, 'GET', "/api/v2/projects/$project/snapshots");
    return [ grep { ($_->{sourceVolumeUUID} // '') eq $vol_uuid }
                @{ $data->{snapshots} // [] } ];
}

# Resolve a Proxmox snapshot name to its LightOS snapshot UUID. Dies with "not
# found" when the snapshot is genuinely absent, or propagates a listing failure
# (auth/transport/server error); callers that need idempotency distinguish the
# two (see volume_snapshot_delete).
sub _snap_uuid {
    my ($scfg, $project, $volname, $pve_snap) = @_;
    my $vol_uuid = _resolve_existing_uuid($scfg, $volname);
    my $want     = _lb_snap_name($vol_uuid, $pve_snap);
    for my $s (@{ _snapshots_for_volume($scfg, $project, $vol_uuid) }) {
        return $s->{UUID} if ($s->{name} // '') eq $want;
    }
    die "Lightbits snapshot '$pve_snap' not found for volume $vol_uuid\n";
}

# Parse a LightOS ISO-8601 UTC timestamp ("YYYY-MM-DDThh:mm:ss[.fraction]Z") to
# epoch seconds. The value is UTC, so use timegm (not POSIX::mktime, which would
# interpret it in the host's local timezone); the fractional part is ignored.
sub _epoch_from_iso8601 {
    my ($s) = @_;
    return 0 unless defined $s
        && $s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;
    return timegm($6, $5, $4, $3, $2 - 1, $1 - 1900);
}

# ── Plugin registration ───────────────────────────────────────────────────────

# Highest storage APIVER whose contract this plugin satisfies. Bump as newer
# Proxmox VE releases are validated. See the API changelog at
# https://pve.proxmox.com/wiki/Storage_Plugin_Development
my $TESTED_APIVER = 16;   # PVE 9.x: qemu_blockdev_options (12), get_identity (14),
                          # volume_resize 'snapname' param + volume_snapshot_info
                          # 'virtual-size' field (15) — both additive/optional per
                          # libpve-storage-perl 9.1.6's changelog, no plugin change needed.
                          # 16 (libpve-storage-perl 9.1.12): volume-name/format helper
                          # methods on the base class (get_parsed_format,
                          # volname_for_format, ...) that a plugin MAY override; PVE
                          # only calls them from the base-class alloc_image and
                          # rename_volume, which this plugin does not use, and the
                          # 'import' content type, which this plugin does not offer.

# Report the storage API version of the *running* host rather than a fixed
# number, because the APIVER differs across PVE point releases and the loader
# only accepts a plugin whose api() falls within [APIVER - APIAGE, APIVER]: a
# value below APIVER (but inside the window) merely triggers the "older storage
# API" warning, while a value below the window is rejected outright. So:
#   - host APIVER <= our tested max: return it verbatim -> exact match, no warning.
#   - host APIVER >  our tested max: return our tested max. This loads (with the
#     deprecation warning) while the host is still within its backward-compat
#     window, and is rejected by the loader once the host moves past it entirely.
# Mirrors LINBIT's LINSTOR plugin. Falls back to our tested version if
# PVE::Storage is somehow absent.
sub api {
    my $apiver = eval { PVE::Storage::APIVER() };
    return $TESTED_APIVER if !defined $apiver;
    return $apiver if $apiver <= $TESTED_APIVER;
    return $TESTED_APIVER;
}

sub type       { return 'lightbits'; }

# Stable identifier for the backing store (storage API 14). Two storage entries
# pointing at the same LightOS cluster endpoint and project share an identity,
# which lets PVE recognise the same backend across nodes.
#
# The endpoint list is normalised before use: lb_api_host is a free-form,
# comma-separated list of management nodes, so the *same* cluster is routinely
# written differently on different nodes (a different order, extra whitespace,
# a hostname in another case, or a port left implicit). Interpolating the raw
# string would give those entries distinct identities and defeat the point of
# this method, so each endpoint is canonicalised and the list sorted, making the
# result independent of how the list was typed.
#
# Two entries that list a genuinely different *subset* of the cluster's nodes
# still differ. Resolving that would mean asking the cluster for its own UUID,
# which we deliberately do not do: get_identity must stay a pure, non-failing
# function of the config, and an identity that changed whenever the API was
# unreachable would be worse than one that is merely conservative.

# Canonical form of a single lb_api_host entry, for identity comparison only.
#
# Lowercased (hostnames and hex IPv6 literals are case-insensitive) and given an
# explicit port, because _api always builds an https:// URL and so treats a bare
# "10.0.0.1" and "10.0.0.1:443" as the very same endpoint. Leaving the port
# implicit would hand those two spellings different identities.
#
# IPv6 literals must be bracketed to be distinguishable from host:port, the same
# convention _nvme_endpoints uses. This is only ever used to build an identity
# string, never to build a request URL, so it cannot affect what we connect to.
my $DEFAULT_API_PORT = 443;

sub _canonical_api_endpoint {
    my ($ep) = @_;
    $ep = lc $ep;
    return $ep            if $ep =~ /^\[.+\]:\d+$/;    # [IPv6]:port
    return "$ep:$DEFAULT_API_PORT" if $ep =~ /^\[.+\]$/;          # [IPv6]
    return $ep            if $ep =~ /^[^\[\]:]+:\d+$/;  # host:port
    return "$ep:$DEFAULT_API_PORT";                     # bare host
}

sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    my @endpoints = sort map { _canonical_api_endpoint($_) }
                        _api_endpoints($scfg->{lb_api_host});
    return 'lightbits://' . join(',', @endpoints) . '/' . _project($scfg);
}

sub parse_volname {
    my ($class, $volname) = @_;
    my $uuid = qr/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
    # "vm-<vmid>-<uuid>": the embedded vmid identifies the owning guest, so PVE
    # frees the disk when the VM is destroyed (returned as the owner below).
    if ($volname =~ /^vm-(\d+)-$uuid$/) {
        return ('images', $volname, $1, undef, undef, 0, 'raw');
    }
    # Bare UUID: a volume not owned by a guest -> owner 0.
    if ($volname =~ /^$uuid$/) {
        return ('images', $volname, 0, undef, undef, 0, 'raw');
    }
    # Snapshot-qualified "vm-<vmid>-<uuid>@<snap>": the snap name is returned in
    # slot 5; $volname (slot 1) stays the base volume name.
    if ($volname =~ /^(vm-(\d+)-$uuid)\@(.+)$/) {
        return ('images', $1, $2, undef, $3, 0, 'raw');
    }
    # "vm-<vmid>-cloudinit": the VM's cloud-init drive. qemu-server recognises a
    # cloud-init drive by this exact name (Drive::drive_is_cloudinit), so it
    # carries no UUID; the LightOS volume is found by labels (_resolve_uuid).
    if ($volname =~ /^(vm-(\d+)-cloudinit)(?:\@(.+))?$/) {
        return ('images', $1, $2, undef, $3, 0, 'raw');
    }
    die "unable to parse Lightbits volume name '$volname'\n";
}

sub plugindata {
    return {
        content => [ { images => 1, none => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
    };
}

sub properties {
    return {
        lb_api_host => {
            description => "Lightbits API endpoint(s): a host:port, or a comma-separated "
                . "list of cluster management nodes for failover (e.g. "
                . "192.168.1.1:443,192.168.1.2:443). Listing more than one node means the "
                . "plugin can still reach the cluster's API if any single node is down.",
            type        => 'string',
        },
        lb_jwt => {
            description => "Lightbits JWT authentication token",
            type        => 'string',
        },
        lb_project => {
            description => "Lightbits project name (default: 'default')",
            type        => 'string',
        },
        lb_nvme_host => {
            description => "Lightbits data-node address(es) used to seed discovery-client: "
                . "a host:port, or a comma-separated list (e.g. "
                . "192.168.1.1:4420,192.168.1.2:4420). List every data node on a "
                . "multi-node cluster - discovery-client then discovers nodes added to "
                . "the cluster later on its own, but does not proactively drop the "
                . "connection to a node removed from this list; shrinking it only takes "
                . "full effect once the connection is cleared by this storage's own "
                . "final deactivation (or a manual 'nvme disconnect').",
            type        => 'string',
        },
        lb_subsys_nqn => {
            description => "Lightbits subsystem NQN",
            type        => 'string',
        },
        lb_owner_id => {
            description => "Identity tag for this Proxmox node/cluster, stored on "
                . "each volume so a VM destroy here cannot touch another "
                . "hypervisor's volumes (default: hostname).",
            type        => 'string',
        },
        lb_replica_count => {
            description => "Number of replicas to create each volume with. Must be "
                . "supported by the cluster (a single-node cluster requires 1).",
            type        => 'integer',
            minimum     => 1,
            maximum     => 3,
            default     => 1,
        },
        lb_fingerprint => {
            description => "SHA-256 fingerprint of the Lightbits API server's TLS "
                . "certificate, colon-separated hex as printed by "
                . "'openssl s_client -connect <host>:443 </dev/null 2>/dev/null | "
                . "openssl x509 -fingerprint -sha256 -noout'. Pins the certificate: the "
                . "connection is verified against this fingerprint instead of a CA, "
                . "which is the way to verify a LightOS cluster's own certificate (issued "
                . "by the cluster's internal CA to the name api.service, identical on "
                . "every node). Recommended wherever lb_ssl_verify cannot be used. A "
                . "comma-separated list is accepted so a certificate rotation can be "
                . "staged: add the new fingerprint before, remove the old one after.",
            type        => 'string',
            pattern     => '([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}(,([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2})*',
        },
        lb_ssl_verify => {
            description => "Verify the Lightbits API server's TLS certificate against "
                . "the host's trust store (or lb_ca_file), including the hostname. Off by "
                . "default, because a LightOS cluster serves its API with a certificate "
                . "from its own cluster CA; for such clusters use lb_fingerprint instead. "
                . "Enable verification wherever you can: every API request carries the "
                . "lb_jwt bearer token, so without it an on-path attacker can present any "
                . "certificate and capture a token that grants full control of the "
                . "project's volumes.",
            type        => 'boolean',
            default     => 0,
        },
        lb_ca_file => {
            description => "Path to a PEM CA bundle used to verify the Lightbits API "
                . "server's certificate when lb_ssl_verify is enabled. Defaults to the "
                . "host's system trust store.",
            type        => 'string',
        },
    };
}

sub options {
    return {
        lb_api_host   => {},
        lb_jwt        => {},
        lb_project    => { optional => 1 },
        lb_nvme_host  => {},
        lb_subsys_nqn => { fixed => 1, optional => 1 },
        lb_owner_id   => { optional => 1 },
        lb_replica_count => { optional => 1 },
        lb_fingerprint => { optional => 1 },
        lb_ssl_verify => { optional => 1 },
        lb_ca_file    => { optional => 1 },
        content       => { optional => 1 },
        shared        => { optional => 1 },
        disable       => { optional => 1 },
        nodes         => { optional => 1 },
    };
}

# ── Capacity ──────────────────────────────────────────────────────────────────

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $data = eval { _api($scfg, 'GET', '/api/v2/cluster', undef, timeout => 5) };
    if ($@) {
        warn "Lightbits storage '$storeid' is unreachable: $@";
        return (0, 0, 0, 0);
    }

    my $stats = $data->{statistics} // {};
    my $total = int($stats->{estimatedLogicalStorage}    // 0);
    my $avail = int($stats->{estimatedFreeLogicalStorage} // 0);
    my $used  = $total - $avail;

    return ($total, $avail, $used, 1);
}

# ── Naming & ownership helpers ─────────────────────────────────────────────────

# Directory holding Proxmox VM config files; overridable in tests.
our $QEMU_CONF_DIR = '/etc/pve/qemu-server';

# Label keys recording volume ownership. LightOS strips any "<prefix>-" or
# "<prefix>." from a label key (keeping only the trailing segment), so these
# are intentionally separator-free to survive verbatim.
my $LBL_VMID    = 'pveVmid';
my $LBL_VMGENID = 'pveVmgenid';
my $LBL_NODE    = 'pveNode';
# Role of a volume within its VM. Only written for volumes whose PVE-side name
# cannot carry the LightOS UUID: today the cloud-init drive (see _resolve_uuid).
my $LBL_ROLE       = 'pveRole';
my $ROLE_CLOUDINIT = 'cloudinit';

# Identity of this Proxmox node. Volumes are tagged with it so that destroying
# a VM here can never delete another hypervisor's volumes when several share a
# Lightbits project. Override with the `lb_owner_id` storage option.
sub _hostname {
    if (open(my $fh, '<', '/proc/sys/kernel/hostname')) {
        chomp(my $h = <$fh>);
        close($fh);
        return $h if defined $h && length $h;
    }
    return 'localhost';
}

sub _owner_id {
    my ($scfg) = @_;
    return $scfg->{lb_owner_id} if defined $scfg->{lb_owner_id} && length $scfg->{lb_owner_id};
    my $host = _hostname();
    $host =~ s/\s+//g;
    return $host;
}

# Labels of a volume as a flat hash (empty when the volume has none).
sub _vol_labels {
    my ($vol) = @_;
    return map { ($_->{key} // '') => $_->{value} } @{ $vol->{labels} // [] };
}

# Does this volume belong to this Proxmox storage? Everything that lists,
# activates or deletes a volume goes through here, so a LightOS project that
# also holds volumes created by other consumers (lbcli, another hypervisor,
# an application server) is safe to share with Proxmox: those volumes are
# invisible to PVE and the plugin refuses to touch them even when an operator
# names one by volid.
#
# A volume is ours when, and only when, it carries the plugin's ownership
# labels: a numeric pveVmid and a pveNode equal to this storage's owner id
# (another PVE node or cluster sharing the project keeps its own volumes).
# Every release of this plugin has written these labels on alloc_image, so
# there is no name-based fallback: a pveNode label alone (a hand-labelled
# decoy), a different pveNode, or no labels at all -- however the volume is
# named -- means "not ours". A volume that lost its labels can be re-adopted
# with `lbcli update volume --labels ...` (see README, "Volumes the plugin
# does not own").
sub _is_owned_volume {
    my ($vol, $owner_id) = @_;
    my %label = _vol_labels($vol);
    return 0 unless defined $label{$LBL_NODE} && $label{$LBL_NODE} eq $owner_id;
    return defined $label{$LBL_VMID} && $label{$LBL_VMID} =~ /^\d+$/ ? 1 : 0;
}

# Fetch a volume and refuse to proceed unless it is ours (see _is_owned_volume).
# Every path that mutates or hands out a volume by volid goes through here:
# volume_size_info, activate_volume, free_image, volume_resize, volume_snapshot,
# volume_snapshot_delete and volume_snapshot_rollback.
# Returns the volume record; dies naming the volume and the storage's owner id.
# A volume that no longer exists comes back as an empty hash (_api maps 404 to
# {}), which is returned as-is so idempotent callers can treat it as "gone".
sub _owned_volume_or_die {
    my ($scfg, $project, $uuid, $what) = @_;
    my $vol = _api($scfg, 'GET', "/api/v2/volumes/$uuid?projectName=$project");
    return $vol unless %$vol;
    my $owner_id = _owner_id($scfg);
    return $vol if _is_owned_volume($vol, $owner_id);
    my $name = $vol->{name} // '?';
    die "refusing to $what Lightbits volume $uuid ('$name', project '$project'): "
      . "it was not created by this Proxmox storage (owner id '$owner_id') "
      . "- missing or foreign ownership labels. Manage it with lbcli instead.\n";
}

# Same, for callers that also need the volume to exist: a vanished volume is
# reported with the same wording as _get_existing.
sub _owned_existing_volume {
    my ($scfg, $project, $uuid, $what) = @_;
    my $vol = _owned_volume_or_die($scfg, $project, $uuid, $what);
    die "Volume $uuid no longer exists on the Lightbits cluster (deleted outside Proxmox?)\n"
        unless %$vol;
    return $vol;
}

# ── Cloud-init volumes ────────────────────────────────────────────────────────
#
# qemu-server identifies a VM's cloud-init drive purely by its volume name:
# Drive::drive_is_cloudinit matches "vm-<vmid>-cloudinit" at the end of the
# volid, API2::Qemu / clone_disk / restore allocate it by passing exactly that
# $name to alloc_image, and Cloudinit::commit_cloudinit_disk writes the
# generated ISO into path() of that volid. A volid of our usual
# "vm-<vmid>-<uuid>" shape is therefore never treated as cloud-init: PVE writes
# no ISO into it, the guest boots without user-data, and `qm destroy --purge`
# leaves the 4 MiB volume behind (reproduced 2026-10-04 with `qm clone --full
# --storage <lb>` and `qmrestore --storage <lb>`, pve-lightbits issue #41).
#
# So for this one drive the plugin honours PVE's name. "vm-<vmid>-cloudinit"
# has no room for the LightOS UUID, so the volume is found through its labels
# instead (pveVmid + pveNode + pveRole=cloudinit); the LightOS name itself,
# "vm-<vmid>-<vmgenid>-cloudinit", stays unique per project like the disks'.
# Every method that takes a volname goes through _resolve_uuid / _link_name
# below, so the rest of the plugin keeps working on UUIDs.

# vmid of a cloud-init volname ("vm-<vmid>-cloudinit", optionally
# "@<snap>"-qualified), or undef for any other volume name.
sub _cloudinit_vmid {
    my ($volname) = @_;
    (my $base = $volname) =~ s/\@.*$//;
    return $1 if $base =~ /^vm-(\d+)-cloudinit$/;
    return undef;
}

# Name of the volume's /dev/lightbits/<storeid>/ symlink: the LightOS UUID for
# UUID-bearing volnames, the volname itself for a cloud-init drive (so path()
# and deactivate_volume need no API call to find the link). Untainted.
sub _link_name {
    my ($volname) = @_;
    (my $base = $volname) =~ s/\@.*$//;
    return $1 if $base =~ /^(vm-\d+-cloudinit)$/;
    return _vol_uuid($base);
}

# This storage's cloud-init volume of $vmid: the volume carrying our ownership
# labels for that VM plus pveRole=cloudinit and not already being deleted.
# Returns the volume record, or undef when there is none. More than one is a
# state the plugin never creates (alloc_image refuses a second one) and cannot
# pick from safely, so it is reported for the operator to resolve.
sub _find_cloudinit_volume {
    my ($scfg, $project, $vmid) = @_;
    my $data     = _api($scfg, 'GET', "/api/v2/volumes?projectName=$project");
    my $owner_id = _owner_id($scfg);
    my @found;
    for my $vol (@{ $data->{volumes} // [] }) {
        next unless _is_owned_volume($vol, $owner_id);
        my %label = _vol_labels($vol);
        next unless ($label{$LBL_ROLE} // '') eq $ROLE_CLOUDINIT;
        next unless $label{$LBL_VMID} == $vmid;
        next if ($vol->{state} // '') =~ /^(Deleting|Deleted)$/i;
        push @found, $vol;
    }
    die "VM $vmid has " . scalar(@found) . " cloud-init volumes on this Lightbits storage "
      . "(project '$project'): " . join(', ', map { "$_->{UUID} ('$_->{name}')" } @found)
      . ". Remove the stale one(s) with lbcli before continuing.\n"
        if @found > 1;
    return $found[0];
}

# LightOS UUID behind a PVE volname: read straight out of a UUID-bearing name,
# looked up by labels for a cloud-init drive. undef only for a cloud-init
# volume that no longer exists (callers that must be idempotent on "already
# gone" check for it; the rest use _resolve_existing_uuid).
sub _resolve_uuid {
    my ($scfg, $volname) = @_;
    my $vmid = _cloudinit_vmid($volname);
    return _vol_uuid($volname) unless defined $vmid;
    my $vol = _find_cloudinit_volume($scfg, _project($scfg), $vmid);
    return $vol ? $vol->{UUID} : undef;
}

sub _resolve_existing_uuid {
    my ($scfg, $volname) = @_;
    my $uuid = _resolve_uuid($scfg, $volname);
    die "Volume $volname no longer exists on the Lightbits cluster (deleted outside Proxmox?)\n"
        unless defined $uuid;
    return $uuid;
}

# Generate a random v4-ish UUID, used as a fallback per-VM identity.
sub _gen_uuid {
    if (open(my $fh, '<', '/proc/sys/kernel/random/uuid')) {
        chomp(my $u = <$fh>);
        close($fh);
        return lc($u) if $u =~ /^[0-9a-f-]{36}$/i;
    }
    return sprintf('%08x-%04x-4%03x-%04x-%012x',
        int(rand(2**32)), int(rand(2**16)), int(rand(2**12)),
        (int(rand(2**16)) & 0x3fff) | 0x8000, int(rand(2**48)));
}

# Stable per-VM identity: the guest's vmgenid, read from its config. Falls back
# to a generated UUID when the VM has no usable vmgenid (e.g. "vmgenid: 0",
# missing, or the config is not written yet), so volume names stay unique.
sub _vm_guid {
    my ($vmid) = @_;
    my ($safe) = ($vmid =~ /^(\d+)$/);
    if (defined $safe && open(my $fh, '<', "$QEMU_CONF_DIR/$safe.conf")) {
        while (my $line = <$fh>) {
            last if $line =~ /^\[/;    # stop before snapshot sections
            if ($line =~ /^vmgenid:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*$/i) {
                close($fh);
                return lc($1);
            }
        }
        close($fh);
    }
    return _gen_uuid();
}

# Next free disk index for a VM, derived from existing volume names in the
# project. Our volids are UUIDs, so PVE's find_free_diskname cannot do this.
sub _next_disk_index {
    my ($scfg, $vmid) = @_;
    my $project = _project($scfg);
    my $data = eval { _api($scfg, 'GET', "/api/v2/volumes?projectName=$project", undef, timeout => 5) };
    return 0 if $@;
    my $next = 0;
    for my $vol (@{$data->{volumes} // []}) {
        my $n = $vol->{name} // '';
        next unless $n =~ /^vm-\Q$vmid\E-[0-9a-f-]{36}-disk-(\d+)$/i;
        $next = $1 + 1 if $1 >= $next;
    }
    return $next;
}

# ── Volume listing ────────────────────────────────────────────────────────────

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $project = _project($scfg);
    my $data    = eval { _api($scfg, 'GET', "/api/v2/volumes?projectName=$project", undef, timeout => 5) };
    if ($@) {
        warn "Lightbits storage '$storeid' is unreachable: $@";
        return [];
    }

    my $owner_id = _owner_id($scfg);

    my @res;
    for my $vol (@{$data->{volumes} // []}) {
        my $uuid  = $vol->{UUID};
        my $name  = $vol->{name} // '';
        my %label = _vol_labels($vol);

        # Never list (and therefore never let Proxmox free, or show as an
        # "unused disk") a volume that is not this storage's: another
        # hypervisor's, or one created outside Proxmox altogether
        # (see _is_owned_volume).
        next unless _is_owned_volume($vol, $owner_id);

        # Owner VM id: prefer the label, else parse the Lightbits name. Volumes
        # with no owner use 0 so PVE never indexes its VM list with an undef key.
        my $owner = 0;
        if (defined $label{$LBL_VMID} && $label{$LBL_VMID} =~ /^(\d+)$/) {
            $owner = $1;
        } elsif ($name =~ /^vm-(\d+)-/) {
            $owner = $1;
        }

        next if defined $vmid && $owner != $vmid;

        # volid embeds the owner vmid (and the Lightbits UUID is the real id);
        # a cloud-init drive is listed under the name qemu-server knows it by,
        # or PVE would see the same volume twice and offer the UUID-named one
        # as an "unused disk".
        my $volname = ($label{$LBL_ROLE} // '') eq $ROLE_CLOUDINIT
            ? "vm-${owner}-cloudinit" : "vm-${owner}-${uuid}";
        push @res, {
            volid  => "$storeid:$volname",
            format => 'raw',
            size   => int($vol->{size} // 0),
            vmid   => $owner,
        };
    }
    return \@res;
}

# Size of a single volume. Required so PVE can query an existing volume (e.g.
# when attaching it to a VM); without it the base implementation falls back to
# a filesystem path, which block storage like ours doesn't have.
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my $project = _project($scfg);
    my $uuid    = _resolve_existing_uuid($scfg, $volname);
    # Ownership guard: this is what `qm set --scsiN <volid>` consults for a
    # stopped VM (no activation happens), so refusing here keeps a foreign volid
    # out of VM configs altogether instead of failing later on resize/snapshot.
    # Strict: a vanished volume must not be reported as a 0-byte disk, which
    # would propagate a bogus size into the guest config.
    my $vol     = _owned_existing_volume($scfg, $project, $uuid, 'use');
    my $size    = int($vol->{size} // 0);
    my $used    = int(($vol->{statistics} // {})->{logicalUsedStorage} // 0);
    return wantarray ? ($size, 'raw', $used, undef) : $size;
}

# ── Volume lifecycle ──────────────────────────────────────────────────────────

# Best-effort removal of a volume that was created but never became usable.
#
# Deliberately non-fatal: the creation failure is what the operator needs to
# see, so a cleanup problem is warned about rather than allowed to replace it
# (dying here would swap a precise "volume entered state Failed" for a vague
# delete error). A volume the cluster is already removing needs no DELETE.
sub _discard_orphan_volume {
    my ($scfg, $project, $uuid, $vol_name, $state) = @_;
    return if defined $state && $state =~ /^(Deleting|Deleted)$/i;
    eval { _api($scfg, 'DELETE', "/api/v2/volumes/$uuid?projectName=$project"); 1 }
        or warn "Lightbits: could not remove unusable volume $vol_name ($uuid) after a "
            . "failed creation; it may need to be deleted manually: $@";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $project  = _project($scfg);
    my $host_nqn = _host_nqn();

    # size comes in KB; Lightbits wants bytes, must be 4096-aligned
    my $bytes = int($size) * 1024;
    $bytes    = int(($bytes + 4095) / 4096) * 4096;

    # The name carries the VM id, the VM's vmgenid and a disk index so it is
    # unique within the project even when several Proxmox hypervisors share one
    # Lightbits cluster (LightOS enforces unique volume names per project). The
    # same ownership data is also stored as queryable labels.
    my $guid     = _vm_guid($vmid);
    my $owner_id = _owner_id($scfg);
    my @labels   = (
        { key => $LBL_VMID,    value => "$vmid" },
        { key => $LBL_VMGENID, value => "$guid" },
        { key => $LBL_NODE,    value => "$owner_id" },
    );

    # qemu-server names the one volume it must recognise again by name: the
    # cloud-init drive, requested as $name = "vm-<vmid>-cloudinit" (see the
    # "Cloud-init volumes" note above _cloudinit_vmid). Honour that name — the
    # volid returned below is the one PVE stores and matches — and tag the
    # volume's role so the UUID can be looked up from it later. Any other
    # $name PVE passes is advisory and the UUID-based scheme is kept.
    my ($vol_name, $volname);
    if (defined(my $ci_vmid = defined $name ? _cloudinit_vmid($name) : undef)) {
        die "cloud-init volume name '$name' does not belong to VM $vmid\n"
            if $ci_vmid != $vmid;
        # One per VM: a second one could not be told apart by name later, and
        # PVE itself never asks for two. Fail here with the existing volume
        # named rather than on a LightOS name clash or, worse, silently.
        # Check-then-create is atomic against other allocations on this
        # storage: PVE::Storage::vdisk_alloc (the only caller, `pvesm alloc`
        # included) runs alloc_image inside cluster_lock_storage, a
        # cluster-wide cfs lock per storeid for shared storage and a local
        # file lock otherwise, so a concurrent allocation for the same VM
        # waits here and then sees this one's volume.
        if (my $existing = _find_cloudinit_volume($scfg, $project, $vmid)) {
            die "VM $vmid already has a cloud-init volume on this Lightbits storage: "
              . "$existing->{UUID} ('$existing->{name}'). Free it first "
              . "(pvesm free $storeid:vm-$vmid-cloudinit).\n";
        }
        $vol_name = "vm-${vmid}-${guid}-cloudinit";
        $volname  = "vm-${vmid}-cloudinit";
        push @labels, { key => $LBL_ROLE, value => $ROLE_CLOUDINIT };
    } else {
        my $index = _next_disk_index($scfg, $vmid);
        $vol_name = "vm-${vmid}-${guid}-disk-${index}";
    }
    # int() so the value (a string when read back from storage.cfg) serialises
    # as a JSON number, matching the previous hardcoded literal.
    my $replica_count = int($scfg->{lb_replica_count} // 1);

    my $body = {
        name         => $vol_name,
        size         => "$bytes",
        replicaCount => $replica_count,
        projectName  => $project,
        acl          => { values => [$host_nqn] },
        labels       => \@labels,
    };

    my $result = _api($scfg, 'POST', '/api/v2/volumes', $body);
    my $uuid   = $result->{UUID} or die "Lightbits volume creation returned no UUID\n";

    # Wait for the volume to become Available, failing fast on a terminal cluster
    # failure (or if it never converges). Otherwise a Failed volume would be
    # returned as if it were created and the problem would only surface later —
    # cryptically — when activate_volume can't find its NSID.
    # The polling itself is wrapped, because it can also throw — a transport
    # failure, every endpoint returning 5xx, or the volume disappearing out of
    # band. Letting that propagate straight out would skip the cleanup below and
    # strand the volume just as surely as a Failed state does.
    my $state = '';
    my $poll_err;
    eval {
        for my $attempt (1..30) {
            # _get_existing (not plain _api): a volume vanishing out of band
            # mid-poll dies here with an error naming it — caught by this eval,
            # so the cleanup below still runs (a 404-tolerated no-op for a
            # vanished volume) and the accurate error is re-raised.
            my $v  = _get_existing($scfg, "/api/v2/volumes/$uuid?projectName=$project",
                "Volume $vol_name ($uuid)");
            $state = $v->{state} // '';
            last if $state eq 'Available';
            last if $state =~ /^(Failed|Deleting|Deleted)$/i;
            sleep 1;
        }
        1;
    } or do {
        $poll_err = $@ || "unknown error while waiting for volume $uuid\n";
    };

    if (defined $poll_err || $state ne 'Available') {
        # The volume exists on the cluster but is unusable, and PVE only starts
        # tracking it once we return a volid — so dying here without cleaning up
        # strands it with nothing left to reap it. The orphan holds its name
        # (LightOS enforces per-project name uniqueness, so a retry with the same
        # vmid and vmgenid collides on the same disk index) and, depending on how
        # it failed, its space.
        _discard_orphan_volume($scfg, $project, $uuid, $vol_name, $state);

        # Re-raise the polling error unchanged: it names the actual transport or
        # API failure, which is more use than any summary we could add.
        die $poll_err if defined $poll_err;

        die "Lightbits volume $vol_name ($uuid) creation failed on the cluster "
            . "(state '$state')\n"
            if $state =~ /^(Failed|Deleting|Deleted)$/i;
        die "Lightbits volume $vol_name ($uuid) did not become Available within timeout "
            . "(last state '$state')\n";
    }

    # The volid embeds the vmid so PVE can identify the owning guest (the UUID
    # remains the Lightbits volume's real identity, recovered via _vol_uuid) —
    # except for the cloud-init drive, which keeps the name PVE asked for.
    return $volname // "vm-${vmid}-${uuid}";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $project = _project($scfg);
    my $link    = _symlink_path($storeid, _link_name($volname));

    # A cloud-init volume that is already gone resolves to no UUID at all;
    # same idempotent outcome as the vanished-volume branch below.
    my $uuid = _resolve_uuid($scfg, $volname);
    unless (defined $uuid) {
        unlink $link if -l $link;
        return undef;
    }

    # Ownership guard: only volumes this storage created may be deleted from
    # Proxmox. An operator can hand any volid to `pvesm free`; without this
    # check that deleted a volume (and its snapshots) belonging to another
    # consumer of the same LightOS project. A volume that is already gone is
    # not an error (idempotent delete, as before).
    my $vol = _owned_volume_or_die($scfg, $project, $uuid, 'delete');
    unless (%$vol) {
        unlink $link if -l $link;
        return undef;
    }

    # Delete the volume's snapshots first: a deleted volume's snapshots are not
    # removed with it, so leaving them behind would hold space and reserve names.
    # Best-effort — a snapshot that unexpectedly can't be deleted is warned about
    # but must not block freeing the volume, so `qm destroy --purge` still
    # completes. (A clone created from a snapshot does not block deleting that
    # snapshot on the LightOS versions tested — clone data is reference-counted.)
    # We match only this volume's snapshots (by sourceVolumeUUID), so a destroy
    # here never removes another node's.
    my $snaps = eval { _snapshots_for_volume($scfg, $project, $uuid) };
    warn "Lightbits: could not list snapshots of volume $uuid before freeing it "
        . "(any snapshots may be left behind): $@" if $@;
    for my $s (@{ $snaps || [] }) {
        eval { _delete_snapshot($scfg, $project, $s->{UUID}); };
        warn "Lightbits: could not delete snapshot $s->{name} ($s->{UUID}) "
            . "of volume $uuid: $@" if $@;
    }

    _api($scfg, 'DELETE', "/api/v2/volumes/$uuid?projectName=$project");

    unlink $link if -l $link;

    return undef;
}

# ── Path ──────────────────────────────────────────────────────────────────────

sub path {
    my ($class, $cfg, $volname, $storeid, $snap) = @_;
    # Honor a snapshot embedded in the volname (vm-<vmid>-<uuid>@<snap>) even when
    # PVE does not pass it as a separate $snap argument; otherwise a
    # snapshot-qualified volname would be treated as the live volume.
    my (undef, undef, $vmid, undef, $parsed_snap) = $class->parse_volname($volname);
    $snap //= $parsed_snap;
    die "Snapshots not supported by Lightbits plugin\n" if $snap;
    # Return the owning vmid so PVE frees this disk when its VM is destroyed.
    return (_symlink_path($storeid, _link_name($volname)), $vmid, 'images');
}

# ── Activate / deactivate ─────────────────────────────────────────────────────

# Idempotently, additively grant this host's NQN access to a volume. $vol is
# the already-fetched GET response, so this costs no extra API call in the
# common case (host already ACL'd). Additive — never removes an existing
# entry — so a volume with several hosts activated concurrently (shared=1,
# or a migration mid-flight) keeps every host's access; pruning stale entries
# is a separate, not-yet-implemented concern.
sub _ensure_host_acl {
    my ($scfg, $project, $uuid, $vol) = @_;
    my $host_nqn = _host_nqn();
    my @values   = @{ $vol->{acl}{values} // [] };
    return if grep { $_ eq $host_nqn } @values;

    push @values, $host_nqn;
    _api($scfg, 'PUT', "/api/v2/volumes/$uuid?projectName=$project",
        { projectName => $project, acl => { values => \@values } });
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    make_path("$SYMLINK_DIR/$storeid");
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # Resolve the Lightbits UUID (untainted) for the API calls; the symlink is
    # keyed on the volname-derived link name (the UUID, or the cloud-init name).
    my $uuid       = _resolve_existing_uuid($scfg, $volname);
    my $project    = _project($scfg);
    my $subsys_nqn = _subsys_nqn($scfg);
    my $link       = _symlink_path($storeid, _link_name($volname));

    # Fetch volume metadata. This runs before the "already active" check below
    # because that check needs the nsid to tell a still-valid symlink from one
    # left over from a previous activation (see _symlink_is_current).
    # Ownership guard first: activating a volume rewrites its ACL (below), so
    # a foreign volume named by volid must be refused before anything is sent.
    my $vol = _owned_existing_volume($scfg, $project, $uuid, 'activate');
    my $nsid = $vol->{nsid} or die "Cannot determine NSID for volume $uuid\n";

    # Grant this host access before waiting for its device: alloc_image only
    # ACLs the creating host, so a volume activated on a different host
    # (offline migration, HA failover, or shared=1 multi-node access) would
    # otherwise never see its namespace and the wait below would time out.
    # Runs before the mapped-already early return on purpose: the grant is a
    # no-op API-wise when the host is already in the ACL, and it must not be
    # skippable by a symlink that merely looks current.
    _ensure_host_acl($scfg, $project, $uuid, $vol);

    # Already mapped on this node, and the link still points at this volume's
    # namespace: nothing to do.
    return 1 if _symlink_is_current($link, $subsys_nqn, $nsid);

    # Otherwise any link present is stale (dangling, or now resolving to some
    # other namespace). Drop it so the symlink() below can recreate it.
    unlink $link if -l $link;

    # Seed discovery-client with this cluster's discovery endpoints instead of
    # driving `nvme connect` ourselves (see the "discovery-client integration"
    # note above _dsc_conf_path). discovery-client then connects every data
    # node itself — ensuring the volume's ANA-optimized path is present on a
    # multi-node cluster (a single connection can land on a non-optimized path,
    # leaving the namespace inaccessible) — and keeps that current as nodes are
    # added later, unlike a one-shot connect loop.
    _write_dsc_conf($storeid, $scfg, _host_nqn(), $subsys_nqn);

    # Wait for a path to the subsystem to come up. discovery-client is supposed
    # to pick the (re)written config up via inotify, but after a full teardown
    # — the plugin's own `nvme disconnect` on the last deactivation, i.e. the
    # first VM start on a "cold" node — it reliably did not (validated 2026-10-04
    # on LightOS 3.20.1: no reconnect for 9+ minutes, every retry failing after
    # the 60 s wait, while `systemctl restart discovery-client` made the very
    # next activation succeed). So if no connection shows up within
    # $DSC_NUDGE_AFTER seconds, nudge the daemon once and keep waiting; the
    # restart is harmless for running guests because the kernel owns the
    # existing connections (survives even `kill -9` of discovery-client).
    my $nudged = 0;
    for my $attempt (1..$DSC_CONNECT_WAIT) {
        last if _is_connected($subsys_nqn);
        if (!$nudged && $attempt >= $DSC_NUDGE_AFTER) {
            _nudge_discovery_client($storeid, $subsys_nqn);
            $nudged = 1;
        }
        sleep 1;
    }

    # Find the block device for this volume's NSID
    my $dev;
    for my $attempt (1..30) {
        $dev = _find_nvme_device($subsys_nqn, $nsid);
        last if $dev;
        sleep 1;
    }
    die "Block device for volume $uuid (nsid=$nsid) did not appear. Check that "
        . "discovery-client is installed and running (systemctl status "
        . "discovery-client) and that " . _dsc_conf_path($storeid) . " exists; "
        . "also verify this host's NQN is present in the volume's ACL.\n"
        unless $dev;

    make_path("$SYMLINK_DIR/$storeid");
    # Two concurrent activations of the same volume (parallel full clones from
    # one template, seen live 2026-10-04) race between the "already current"
    # check above and this symlink(): the loser gets EEXIST although the link
    # now points at the right namespace. Treat that as success.
    unless (symlink($dev, $link)) {
        my $err = $!;
        return 1 if _symlink_is_current($link, $subsys_nqn, $nsid);
        die "Cannot create symlink $link -> $dev: $err\n";
    }

    return 1;
}

# True if any volume of ANY storage on this host still maps the given subsystem
# NQN (via a /dev/lightbits/<storeid>/<uuid> symlink). Used to decide, from local
# state only, whether the subsystem may be disconnected.
sub _nqn_still_in_use {
    my ($subsys_nqn) = @_;
    for my $l (glob("$SYMLINK_DIR/*/*")) {
        my $ns = _symlink_ns($l) or next;
        my $nqn = _ns_subsysnqn($ns);
        return 1 if defined $nqn && $nqn eq $subsys_nqn;
    }
    return 0;
}

# True if this storeid (not any other) still has an active volume symlink.
# Every volume of a given storeid shares the same cluster/subsystem, so unlike
# _nqn_still_in_use above this needs no NQN check of its own.
sub _storeid_still_in_use {
    my ($storeid) = @_;
    return 0 unless -d "$SYMLINK_DIR/$storeid";
    for my $l (glob("$SYMLINK_DIR/$storeid/*")) {
        return 1 if -l $l;
    }
    return 0;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $subsys_nqn = _subsys_nqn($scfg);
    my $link       = _symlink_path($storeid, _link_name($volname));

    unlink $link if -l $link;

    # Remove this storage's own discovery-client seed as soon as none of ITS
    # volumes are active, independent of whether another storage shares the
    # same cluster/subsystem — that sharing is exactly what the subsystem-wide
    # disconnect below still has to respect, but this storage's own seed file
    # has no reason to wait on an unrelated storage's activity.
    _remove_dsc_conf($storeid) unless _storeid_still_in_use($storeid);

    # Disconnect only when no volume of ANY storage on this host still maps
    # this subsystem — checked from local symlinks, not the API. `nvme
    # disconnect` is subsystem-wide (drops every path/controller for the NQN),
    # so a per-storeid or API-derived check could tear down paths still in use
    # by another storage that shares the same cluster, or fire on a transient
    # API error. discovery-client does not proactively tear down connections
    # on its own (see the "discovery-client integration" note above
    # _dsc_conf_path), so without this the subsystem would stay connected
    # indefinitely after the last volume using it goes away.
    unless (_nqn_still_in_use($subsys_nqn)) {
        run_command(['nvme', 'disconnect', '-n', $subsys_nqn])
            if _is_connected($subsys_nqn);
    }

    return 1;
}

# ── Features ──────────────────────────────────────────────────────────────────

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    # Nested {feature}{key}{format}, mirroring the base plugin. $key is 'snap'
    # when a snapshot name is in play, else 'base'/'current'. We support raw
    # volumes only, and:
    #   - snapshot: on the current volume (PVE probes 'snapshot' with no snapname
    #     when taking one); we do not offer nested snapshots (no 'snap' key).
    #   - copy: whole-volume copy for clone/migrate of a base or current volume.
    #   - resize: grow the current volume.
    my $features = {
        snapshot => { current => { raw => 1 } },
        copy     => { base => { raw => 1 }, current => { raw => 1 } },
        resize   => { base => { raw => 1 }, current => { raw => 1 } },
    };

    my (undef, undef, undef, undef, $parsed_snap, $isBase, $format) =
        $class->parse_volname($volname);

    # A snapshot may arrive either as the $snapname argument or embedded in the
    # volname (vm-<vmid>-<uuid>@<snap>); honor both.
    $snapname //= $parsed_snap;
    my $key = defined($snapname) && length($snapname) ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if defined $features->{$feature}{$key}{$format};
    return 0;
}

# ── Volume resize ──────────────────────────────────────────────────────────────

# Grow a Lightbits volume. PVE hands us the *new total* size in bytes (already
# padded to a 1 KiB multiple by PVE::Storage::volume_resize); we 4 KiB-align it
# for LightOS and PUT it. Unlike the file-based base plugin — which returns early
# for a running guest — we resize the backing volume regardless of $running: PVE
# issues the guest-visible block_resize to QEMU after this returns, and that
# requires the underlying device to already be bigger.
sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $project = _project($scfg);
    my $uuid    = _resolve_existing_uuid($scfg, $volname);

    # Ownership guard before the PUT (a VM config may still reference a foreign
    # volid from before the guard existed).
    _owned_existing_volume($scfg, $project, $uuid, 'resize');

    # 4 KiB-align (Lightbits requires it), matching alloc_image.
    my $bytes = int(($size + 4095) / 4096) * 4096;

    my $body = {
        size        => "$bytes",
        projectName => $project,
    };
    _api($scfg, 'PUT', "/api/v2/volumes/$uuid?projectName=$project", $body);

    # Wait for Lightbits to apply the new size across all replicas. Keep the last
    # observed size/state so we can verify success after the loop rather than
    # assuming it on timeout.
    my ($cur, $state) = (0, '');
    for my $attempt (1..60) {
        my $vol = _get_existing($scfg, "/api/v2/volumes/$uuid?projectName=$project",
            "Volume $uuid");
        $cur    = int($vol->{size} // 0);
        $state  = $vol->{state} // '';
        last if $cur >= $bytes && $state eq 'Available';
        sleep 2;
    }

    # Fail fast if the resize never converged: returning $bytes here would make
    # PVE (and the caller's block_resize) assume a size the volume doesn't have.
    die "Lightbits volume $uuid resize did not complete: expected >= $bytes bytes "
        . "in state 'Available', last saw $cur bytes in state '$state'\n"
        if $cur < $bytes || $state ne 'Available';

    # Refresh the kernel's view of the grown namespace. In practice the NVMe
    # controller already updates the namespace capacity on its own, via an
    # asynchronous "namespace attribute changed" event — so this rescan is a
    # robustness backup, not the primary mechanism. It guards two cases the async
    # path doesn't guarantee: (1) the event may not have been processed yet when
    # PVE follows up with QEMU block_resize on a running guest (a small race), and
    # (2) some kernel/target combinations don't emit/honor that event reliably.
    # `nvme ns-rescan` forces a synchronous re-read, so the new size is visible
    # before we return — cheap and idempotent.
    _rescan_controller($storeid, _link_name($volname));

    return $bytes;
}

# ── Snapshots ──────────────────────────────────────────────────────────────────

# Take a point-in-time snapshot of a volume. PVE routes snapshots of both stopped
# and running guests here (raw volumes use the storage's native snapshot, not a
# QEMU one); for a running guest the snapshot is crash-consistent — PVE freezes
# the filesystem first when the guest runs qemu-guest-agent. The call is metadata
# only (it does not touch the NVMe device).
sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $project  = _project($scfg);
    my $vol_uuid = _resolve_existing_uuid($scfg, $volname);

    # PVE already validates snapshot names; assert defensively so an out-of-charset
    # name fails here rather than at the API.
    die "invalid snapshot name '$snap'\n"
        unless $snap =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

    # Ownership guard: never snapshot a volume this storage did not create.
    _owned_existing_volume($scfg, $project, $vol_uuid, 'snapshot');

    my $body = {
        name             => _lb_snap_name($vol_uuid, $snap),
        sourceVolumeUUID => $vol_uuid,
        projectName      => $project,
    };
    my $result    = _api($scfg, 'POST', "/api/v2/projects/$project/snapshots", $body);
    my $snap_uuid = $result->{UUID} or die "Lightbits snapshot creation returned no UUID\n";

    # Wait for the snapshot to become Available, failing on a terminal state or a
    # timeout so we never report a snapshot as taken when it never materialised.
    my $state = '';
    for my $attempt (1..30) {
        my $s  = _get_existing($scfg, "/api/v2/projects/$project/snapshots/$snap_uuid",
            "Snapshot $snap ($snap_uuid)");
        $state = $s->{state} // '';
        last if $state eq 'Available';
        die "Lightbits snapshot $snap ($snap_uuid) creation failed (state '$state')\n"
            if $state =~ /^(Failed|Deleting|Deleted)$/i;
        sleep 1;
    }
    die "Lightbits snapshot $snap ($snap_uuid) did not become Available within "
        . "timeout (last state '$state')\n"
        if $state ne 'Available';

    return undef;
}

# Delete a snapshot idempotently. A concurrent or repeated delete can fail in
# several ways — the snapshot is already in state 'Deleting', another delete task
# for it is in flight, or a racing delete leaves an etag/precondition mismatch.
# Rather than enumerate every error string, we re-check after any failure: if the
# snapshot is now absent or already being deleted, the delete effectively
# succeeded; only a genuine refusal (the snapshot is still present and Available)
# is raised to the caller.
sub _delete_snapshot {
    my ($scfg, $project, $snap_uuid) = @_;
    eval { _api($scfg, 'DELETE', "/api/v2/projects/$project/snapshots/$snap_uuid"); };
    my $err = $@ or return;
    my $s = eval { _api($scfg, 'GET', "/api/v2/projects/$project/snapshots/$snap_uuid") };
    if (!$@) {
        my $gone  = !(ref($s) eq 'HASH' && %$s);       # _api returns {} on 404
        my $state = (ref($s) eq 'HASH') ? ($s->{state} // '') : '';
        return if $gone || $state =~ /^(Deleting|Deleted)$/i;
    }
    die $err;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $project = _project($scfg);

    # Ownership guard: a foreign volume's snapshots are not ours to delete. A
    # volume that is already gone falls through to the idempotent path below
    # (a vanished cloud-init volume has no UUID left to look up: nothing to do).
    my $vol_uuid = _resolve_uuid($scfg, $volname);
    return undef unless defined $vol_uuid;
    _owned_volume_or_die($scfg, $project, $vol_uuid, 'delete a snapshot of');

    # Idempotent on an already-removed snapshot: _snap_uuid dies with "not found"
    # when the snapshot is gone from the listing, which we treat as success (PVE
    # cleanup paths can fire delete more than once). A transient failure (API,
    # auth, listing) must NOT look like a successful delete, so re-raise anything
    # that isn't a genuine "not found".
    my ($snap_uuid, $err);
    {
        local $@;
        $snap_uuid = eval { _snap_uuid($scfg, $project, $volname, $snap) };
        $err = $@;
    }
    if (!defined $snap_uuid) {
        die $err if $err && $err !~ /not found/i;
        return undef;
    }

    _delete_snapshot($scfg, $project, $snap_uuid);
    return undef;
}

# Assert that rolling back $volname to $snap is allowed. Called by PVE inside the
# config lock, before the guest is stopped.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    my $project   = _project($scfg);
    my $vol_uuid  = _resolve_existing_uuid($scfg, $volname);
    my $snap_uuid = _snap_uuid($scfg, $project, $volname, $snap);

    my $vol   = _get_existing($scfg, "/api/v2/volumes/$vol_uuid?projectName=$project",
        "Volume $vol_uuid");
    my $sd    = _get_existing($scfg, "/api/v2/projects/$project/snapshots/$snap_uuid",
        "Snapshot '$snap' ($snap_uuid)");
    my $vsize = int($vol->{size} // 0);
    my $ssize = int($sd->{size}  // 0);

    # A snapshot records the volume's size at capture time, and rollback restores
    # that size. If the volume was grown afterwards, rolling back would make the
    # namespace smaller than the size Proxmox's VM config still expects; refuse so
    # the device and the config stay consistent.
    die "cannot roll back '$volname' to snapshot '$snap': the volume was resized "
        . "after the snapshot was taken (snapshot ${ssize}B < volume ${vsize}B); "
        . "rolling back would shrink the device below the size Proxmox expects.\n"
        if $ssize && $ssize < $vsize;

    return 1;
}

# Roll a volume back to a snapshot using LightOS's native server-side rollback.
# This is the efficient path: the cluster re-points the volume to the snapshot in
# place — near-instant, no host-side block copy, and the volume keeps its existing
# thin-provisioned allocation. PVE stops the guest before calling this, so the
# device is not open; we rescan the controller afterwards to refresh capacity.
sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $project   = _project($scfg);
    my $vol_uuid  = _resolve_existing_uuid($scfg, $volname);

    # Ownership guard before the rollback PUT.
    _owned_existing_volume($scfg, $project, $vol_uuid, 'roll back');

    my $snap_uuid = _snap_uuid($scfg, $project, $volname, $snap);

    _api($scfg, 'PUT', "/api/v2/projects/$project/volumes/$vol_uuid/rollback",
        { srcSnapshotUUID => $snap_uuid });

    # Wait for the volume to return to Available, failing on a terminal state or a
    # timeout rather than assuming success.
    my $state = '';
    for my $attempt (1..60) {
        my $v  = _get_existing($scfg, "/api/v2/volumes/$vol_uuid?projectName=$project",
            "Volume $vol_uuid");
        $state = $v->{state} // '';
        last if $state eq 'Available';
        die "Lightbits volume $vol_uuid rollback to '$snap' failed (state '$state')\n"
            if $state =~ /^(Failed|Deleting|Deleted)$/i;
        sleep 2;
    }
    die "Lightbits volume $vol_uuid rollback to '$snap' did not complete "
        . "(last state '$state')\n"
        if $state ne 'Available';

    _rescan_controller($storeid, _link_name($volname));

    return undef;
}

# Snapshot inventory for a volume, keyed by Proxmox snapshot name. Overrides the
# base (which shells out to qemu-img on a filesystem path this block storage does
# not have). `order` reflects creation order; only snapshots in our naming scheme
# are reported.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $project  = _project($scfg);
    my $vol_uuid = _resolve_existing_uuid($scfg, $volname);

    my @snaps;
    for my $s (@{ _snapshots_for_volume($scfg, $project, $vol_uuid) }) {
        my $name = _pve_snap_name($s->{name});
        next unless defined $name;
        push @snaps, {
            name => $name,
            id   => $s->{UUID},
            ts   => _epoch_from_iso8601($s->{creationTime}),
        };
    }

    my $info  = {};
    my $order = 0;
    for my $s (sort { $a->{ts} <=> $b->{ts} } @snaps) {
        $info->{ $s->{name} } = { id => $s->{id}, order => $order++, timestamp => $s->{ts} };
    }
    return $info;
}

# NB: do not call __PACKAGE__->register() here. PVE::Storage's third-party
# plugin loader (which scans PVE/Storage/Custom/) calls register() for us, and
# registering twice dies on a duplicate storage type.

1;
