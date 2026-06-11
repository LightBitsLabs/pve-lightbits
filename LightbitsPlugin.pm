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
use PVE::Tools qw(run_command);

my $SYMLINK_DIR = '/dev/lightbits';

# ── Lightbits REST API helper ─────────────────────────────────────────────────

sub _api {
    my ($scfg, $method, $path, $body, %opts) = @_;

    my $ua = LWP::UserAgent->new(
        ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0 },
        timeout  => $opts{timeout} // 15,
    );

    my $url = "https://$scfg->{lb_api_host}$path";
    my $req = HTTP::Request->new($method => $url);
    $req->header('Authorization' => "Bearer $scfg->{lb_jwt}");

    if ($body) {
        $req->header('Content-Type' => 'application/json');
        $req->content(encode_json($body));
    }

    my $res = $ua->request($req);
    return {} if $res->code == 404 || !$res->content || $res->content eq '{}';
    die "Lightbits API $method $path failed: " . $res->status_line . " — " . $res->content . "\n"
        unless $res->is_success;

    return decode_json($res->content);
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

# host:port endpoints already connected as paths for this subsystem NQN, so
# activate_volume only connects the ones that are missing (and avoids nvme-cli
# "already connected" errors). Keyed from each controller's sysfs address.
sub _connected_endpoints {
    my ($subsys_nqn) = @_;
    my %seen;
    return \%seen unless -d '/sys/class/nvme';
    opendir(my $dh, '/sys/class/nvme') or return \%seen;
    for my $ctl (readdir $dh) {
        next unless $ctl =~ /^(nvme\d+)$/;
        my $safe = $1;
        my $nqn = _read_sysfs("/sys/class/nvme/$safe/subsysnqn");
        next unless defined $nqn && $nqn eq $subsys_nqn;
        my $addr = _read_sysfs("/sys/class/nvme/$safe/address") // '';
        $seen{"$1:$2"} = 1 if $addr =~ /traddr=([^,\s]+).*?trsvcid=(\d+)/;
    }
    closedir($dh);
    return \%seen;
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

# Extract the Lightbits volume UUID from a Proxmox volume name. Names are
# "vm-<vmid>-<uuid>" (the UUID is always the trailing component); a bare UUID is
# also accepted. The capture also untaints the value for filesystem/API use.
sub _vol_uuid {
    my ($volname) = @_;
    return $1 if $volname =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
    die "Cannot determine Lightbits volume UUID from '$volname'\n";
}

# ── Plugin registration ───────────────────────────────────────────────────────

# Highest storage APIVER whose contract this plugin satisfies. Bump as newer
# Proxmox VE releases are validated. See the API changelog at
# https://pve.proxmox.com/wiki/Storage_Plugin_Development
my $TESTED_APIVER = 14;   # PVE 9.x: qemu_blockdev_options (12), get_identity (14)

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
            description => "Lightbits API endpoint (host:port)",
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
            description => "Lightbits NVMe-oF endpoint (host:port, e.g. 192.168.1.1:4420)",
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
        lb_api_host   => { fixed    => 1 },
        lb_jwt        => { fixed    => 1 },
        lb_project    => { optional => 1 },
        lb_nvme_host  => { fixed    => 1 },
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

    _api($scfg, 'DELETE', "/api/v2/volumes/$uuid?projectName=$project");

    my $link = _symlink_path($storeid, $uuid);
    unlink $link if -l $link;

    return undef;
}

# ── Path ──────────────────────────────────────────────────────────────────────

sub path {
    my ($class, $cfg, $volname, $storeid, $snap) = @_;
    die "Snapshots not supported by Lightbits plugin\n" if $snap;
    # Return the owning vmid so PVE frees this disk when its VM is destroyed.
    my (undef, undef, $vmid) = $class->parse_volname($volname);
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

    # Connect every configured endpoint that isn't already a path for this
    # subsystem. lb_nvme_host may be a comma-separated host:port list; connecting
    # to all data nodes ensures the volume's ANA-optimized path is present on a
    # multi-node cluster (a single connection can land on a non-optimized path,
    # leaving the namespace inaccessible) and gives redundancy for node failover.
    # We gate per endpoint, not per subsystem, so a path that failed to connect
    # the first time is retried on a later activation instead of leaving the
    # volume permanently single-path. Native NVMe multipath presents the paths
    # as one device.
    my $connected = _connected_endpoints($subsys_nqn);
    for my $ep (_nvme_endpoints($scfg->{lb_nvme_host})) {
        my ($nvme_host, $nvme_port) = @$ep;
        next if $connected->{"$nvme_host:$nvme_port"};
        eval {
            run_command(['nvme', 'connect',
                '-t', 'tcp',
                '-a', $nvme_host,
                '-s', $nvme_port,
                '-n', $subsys_nqn,
                '--keep-alive-tmo=30',
                '--reconnect-delay=10',
                '--ctrl-loss-tmo=-1',
            ]);
        };
        warn "Lightbits: nvme connect to $nvme_host:$nvme_port failed: $@\n" if $@;
    }

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
    die "Block device for volume $uuid (nsid=$nsid) did not appear\n" unless $dev;

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

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $subsys_nqn = _subsys_nqn($scfg);
    my $link       = _symlink_path($storeid, _vol_uuid($volname));

    unlink $link if -l $link;

    # Disconnect the subsystem only when no volume of ANY storage on this host
    # still maps it — checked from local symlinks, not the API. `nvme disconnect`
    # is subsystem-wide (drops every path/controller for the NQN), so a per-storid
    # or API-derived check could tear down paths still in use by another storage
    # that shares the same cluster, or fire on a transient API error.
    unless (_nqn_still_in_use($subsys_nqn)) {
        run_command(['nvme', 'disconnect', '-n', $subsys_nqn])
            if _is_connected($subsys_nqn);
    }

    return 1;
}

# ── Features ──────────────────────────────────────────────────────────────────

sub volume_has_feature {
    my ($class, $cfg, $feature, $storeid, $volname, $snap, $running) = @_;
    my %features = (copy => 1, sparseinit => 0, resize => 1);
    return $features{$feature} // 0;
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
    # before we return — cheap and idempotent. We rescan the *controller*
    # (e.g. /dev/nvme0), not the namespace: under NVMe multipath the per-path node
    # may not exist, and `blockdev --rereadpt` only re-reads a partition table,
    # not the device capacity.
    my $link = _symlink_path($storeid, $uuid);
    if (-l $link) {
        my $dev = readlink($link);
        if ($dev && $dev =~ m{/dev/(nvme\d+)}) {
            my $ctrl = $1;
            eval { run_command(['nvme', 'ns-rescan', "/dev/$ctrl"]) };
            warn "Could not rescan NVMe controller /dev/$ctrl after resize: $@\n" if $@;
        }
    }

    return $bytes;
}

# NB: do not call __PACKAGE__->register() here. PVE::Storage's third-party
# plugin loader (which scans PVE/Storage/Custom/) calls register() for us, and
# registering twice dies on a duplicate storage type.

1;
