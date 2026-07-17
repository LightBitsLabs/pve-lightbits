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
        ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0 },
        timeout  => $opts{timeout} // 15,
    );

    my $start = int(rand(scalar @endpoints));
    my $last_err;
    for my $i (0 .. $#endpoints) {
        my $host = $endpoints[($start + $i) % @endpoints];
        my $req  = HTTP::Request->new($method => "https://$host$path");
        $req->header('Authorization' => "Bearer $scfg->{lb_jwt}");

        if ($body) {
            $req->header('Content-Type' => 'application/json');
            $req->content(encode_json($body));
        }

        my $res = $ua->request($req);
        return {} if $res->code == 404;
        if ($res->is_success) {
            return {} if !$res->content || $res->content eq '{}';
            return decode_json($res->content);
        }

        $last_err = "Lightbits API $method $path failed via $host: "
            . $res->status_line . " — " . $res->content . "\n";
        my $retryable_method = $method =~ /^(?:GET|HEAD)$/;
        die $last_err unless $retryable_method
            && ($res->code >= 500 || ($res->header('Client-Warning') // '') eq 'Internal response');
    }
    die $last_err;
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

        # The namespace's subsystem NQN. The head's "device" link points at the
        # NVMe subsystem; fall back to the namespace dir for older kernels.
        my $nqn_f = "$SYS_BLOCK/$ns/device/subsysnqn";
        $nqn_f = "$SYS_BLOCK/$ns/subsysnqn" unless -f $nqn_f;
        next unless -f $nqn_f;
        open(my $fh, '<', $nqn_f) or next;
        chomp(my $nqn = <$fh>);
        close($fh);
        next unless $nqn eq $subsys_nqn;

        my $nsid_f = "$SYS_BLOCK/$ns/nsid";
        next unless -f $nsid_f;
        open(my $nfh, '<', $nsid_f) or next;
        chomp(my $found_nsid = <$nfh>);
        close($nfh);
        next unless $found_nsid == $nsid;

        my $dev = _dev_path($ns);
        return $dev if _is_block($dev);
    }
    closedir($dh);
    return undef;
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
    my ($storeid, $uuid) = @_;
    my $link = _symlink_path($storeid, $uuid);
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
    my $vol_uuid = _vol_uuid($volname);
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
my $TESTED_APIVER = 15;   # PVE 9.x: qemu_blockdev_options (12), get_identity (14),
                          # volume_resize 'snapname' param + volume_snapshot_info
                          # 'virtual-size' field (15) — both additive/optional per
                          # libpve-storage-perl 9.1.6's changelog, no plugin change needed.

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
sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    return "lightbits://$scfg->{lb_api_host}/" . _project($scfg);
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
                . "multi-node cluster — discovery-client then discovers nodes added to "
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
        my %label = map { ($_->{key} // '') => $_->{value} } @{$vol->{labels} // []};

        # Node-aware: never list (and therefore never let Proxmox delete) a
        # volume owned by a different hypervisor. Foreign volumes with no
        # pveNode label are treated as this node's, for backward compatibility.
        next if defined $label{$LBL_NODE} && $label{$LBL_NODE} ne $owner_id;

        # Owner VM id: prefer the label, else parse the Lightbits name. Volumes
        # with no owner use 0 so PVE never indexes its VM list with an undef key.
        my $owner = 0;
        if (defined $label{$LBL_VMID} && $label{$LBL_VMID} =~ /^(\d+)$/) {
            $owner = $1;
        } elsif ($name =~ /^vm-(\d+)-/) {
            $owner = $1;
        }

        next if defined $vmid && $owner != $vmid;

        # volid embeds the owner vmid (and the Lightbits UUID is the real id).
        push @res, {
            volid  => "$storeid:vm-${owner}-${uuid}",
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
    my $uuid    = _vol_uuid($volname);
    my $vol     = _api($scfg, 'GET', "/api/v2/volumes/$uuid?projectName=$project", undef, timeout => $timeout // 15);
    my $size    = int($vol->{size} // 0);
    my $used    = int(($vol->{statistics} // {})->{logicalUsedStorage} // 0);
    return wantarray ? ($size, 'raw', $used, undef) : $size;
}

# ── Volume lifecycle ──────────────────────────────────────────────────────────

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
    my $index    = _next_disk_index($scfg, $vmid);
    my $owner_id = _owner_id($scfg);
    my $vol_name = "vm-${vmid}-${guid}-disk-${index}";
    # int() so the value (a string when read back from storage.cfg) serialises
    # as a JSON number, matching the previous hardcoded literal.
    my $replica_count = int($scfg->{lb_replica_count} // 1);

    my $body = {
        name         => $vol_name,
        size         => "$bytes",
        replicaCount => $replica_count,
        projectName  => $project,
        acl          => { values => [$host_nqn] },
        labels       => [
            { key => $LBL_VMID,    value => "$vmid" },
            { key => $LBL_VMGENID, value => "$guid" },
            { key => $LBL_NODE,    value => "$owner_id" },
        ],
    };

    my $result = _api($scfg, 'POST', '/api/v2/volumes', $body);
    my $uuid   = $result->{UUID} or die "Lightbits volume creation returned no UUID\n";

    # Wait for the volume to become Available, failing fast on a terminal cluster
    # failure (or if it never converges). Otherwise a Failed volume would be
    # returned as if it were created and the problem would only surface later —
    # cryptically — when activate_volume can't find its NSID.
    my $state = '';
    for my $attempt (1..30) {
        my $v  = _api($scfg, 'GET', "/api/v2/volumes/$uuid?projectName=$project");
        $state = $v->{state} // '';
        last if $state eq 'Available';
        die "Lightbits volume $vol_name ($uuid) creation failed on the cluster "
            . "(state '$state')\n"
            if $state =~ /^(Failed|Deleting|Deleted)$/i;
        sleep 1;
    }
    die "Lightbits volume $vol_name ($uuid) did not become Available within timeout "
        . "(last state '$state')\n"
        if $state ne 'Available';

    # The volid embeds the vmid so PVE can identify the owning guest (the UUID
    # remains the Lightbits volume's real identity, recovered via _vol_uuid).
    return "vm-${vmid}-${uuid}";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $project = _project($scfg);
    my $uuid    = _vol_uuid($volname);

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

    my $link = _symlink_path($storeid, $uuid);
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
    return (_symlink_path($storeid, _vol_uuid($volname)), $vmid, 'images');
}

# ── Activate / deactivate ─────────────────────────────────────────────────────

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

    # Extract + untaint the Lightbits UUID from the volume name for fs/API ops.
    my $uuid       = _vol_uuid($volname);
    my $project    = _project($scfg);
    my $subsys_nqn = _subsys_nqn($scfg);
    my $link       = _symlink_path($storeid, $uuid);

    return 1 if -b $link;

    # Fetch volume metadata
    my $vol  = _api($scfg, 'GET', "/api/v2/volumes/$uuid?projectName=$project");
    my $nsid = $vol->{nsid} or die "Cannot determine NSID for volume $uuid\n";

    # Seed discovery-client with this cluster's discovery endpoints instead of
    # driving `nvme connect` ourselves (see the "discovery-client integration"
    # note above _dsc_conf_path). discovery-client then connects every data
    # node itself — ensuring the volume's ANA-optimized path is present on a
    # multi-node cluster (a single connection can land on a non-optimized path,
    # leaving the namespace inaccessible) — and keeps that current as nodes are
    # added later, unlike a one-shot connect loop.
    _write_dsc_conf($storeid, $scfg, _host_nqn(), $subsys_nqn);

    # Wait for a path to the subsystem to come up.
    for my $attempt (1..30) {
        last if _is_connected($subsys_nqn);
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
    symlink($dev, $link) or die "Cannot create symlink $link -> $dev: $!\n";

    return 1;
}

# True if any volume of ANY storage on this host still maps the given subsystem
# NQN (via a /dev/lightbits/<storeid>/<uuid> symlink). Used to decide, from local
# state only, whether the subsystem may be disconnected.
sub _nqn_still_in_use {
    my ($subsys_nqn) = @_;
    for my $l (glob("$SYMLINK_DIR/*/*")) {
        next unless -l $l;
        my $dev = readlink($l) or next;
        next unless $dev =~ m{/(nvme\d+n\d+)$};
        my $ns = $1;
        my $f = "$SYS_BLOCK/$ns/device/subsysnqn";
        $f = "$SYS_BLOCK/$ns/subsysnqn" unless -f $f;
        my $nqn = _read_sysfs($f);
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
    my $link       = _symlink_path($storeid, _vol_uuid($volname));

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
    my $uuid    = _vol_uuid($volname);

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
        my $vol = _api($scfg, 'GET', "/api/v2/volumes/$uuid?projectName=$project");
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
    _rescan_controller($storeid, $uuid);

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
    my $vol_uuid = _vol_uuid($volname);

    # PVE already validates snapshot names; assert defensively so an out-of-charset
    # name fails here rather than at the API.
    die "invalid snapshot name '$snap'\n"
        unless $snap =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

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
        my $s  = _api($scfg, 'GET', "/api/v2/projects/$project/snapshots/$snap_uuid");
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
    my $vol_uuid  = _vol_uuid($volname);
    my $snap_uuid = _snap_uuid($scfg, $project, $volname, $snap);

    my $vol   = _api($scfg, 'GET', "/api/v2/volumes/$vol_uuid?projectName=$project");
    my $sd    = _api($scfg, 'GET', "/api/v2/projects/$project/snapshots/$snap_uuid");
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
    my $vol_uuid  = _vol_uuid($volname);
    my $snap_uuid = _snap_uuid($scfg, $project, $volname, $snap);

    _api($scfg, 'PUT', "/api/v2/projects/$project/volumes/$vol_uuid/rollback",
        { srcSnapshotUUID => $snap_uuid });

    # Wait for the volume to return to Available, failing on a terminal state or a
    # timeout rather than assuming success.
    my $state = '';
    for my $attempt (1..60) {
        my $v  = _api($scfg, 'GET', "/api/v2/volumes/$vol_uuid?projectName=$project");
        $state = $v->{state} // '';
        last if $state eq 'Available';
        die "Lightbits volume $vol_uuid rollback to '$snap' failed (state '$state')\n"
            if $state =~ /^(Failed|Deleting|Deleted)$/i;
        sleep 2;
    }
    die "Lightbits volume $vol_uuid rollback to '$snap' did not complete "
        . "(last state '$state')\n"
        if $state ne 'Available';

    _rescan_controller($storeid, $vol_uuid);

    return undef;
}

# Snapshot inventory for a volume, keyed by Proxmox snapshot name. Overrides the
# base (which shells out to qemu-img on a filesystem path this block storage does
# not have). `order` reflects creation order; only snapshots in our naming scheme
# are reported.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $project  = _project($scfg);
    my $vol_uuid = _vol_uuid($volname);

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
