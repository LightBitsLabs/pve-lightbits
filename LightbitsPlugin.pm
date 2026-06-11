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

sub _find_nvme_device {
    my ($subsys_nqn, $nsid) = @_;
    return undef unless -d '/sys/class/nvme';
    opendir(my $dh, '/sys/class/nvme') or return undef;
    for my $ctl (readdir $dh) {
        # Capture into $1 to untaint (taint mode: readdir output is tainted)
        next unless $ctl =~ /^(nvme\d+)$/;
        my $safe_ctl = $1;
        my $nqn_f = "/sys/class/nvme/$safe_ctl/subsysnqn";
        next unless -f $nqn_f;
        open(my $fh, '<', $nqn_f) or next;
        chomp(my $nqn = <$fh>);
        next unless $nqn eq $subsys_nqn;
        # find namespace by nsid via sysfs (kernel names namespaces sequentially,
        # independent of the actual namespace ID)
        opendir(my $ndh, "/sys/class/nvme/$safe_ctl") or next;
        for my $ns (readdir $ndh) {
            # Capture ns_num via regex to untaint it
            my $ns_num;
            if    ($ns =~ /^${safe_ctl}c\d+n(\d+)$/) { $ns_num = $1 }
            elsif ($ns =~ /^${safe_ctl}n(\d+)$/)      { $ns_num = $1 }
            else                                       { next }
            my $nsid_f = "/sys/class/nvme/$safe_ctl/$ns/nsid";
            next unless -f $nsid_f;
            open(my $nfh, '<', $nsid_f) or next;
            chomp(my $found_nsid = <$nfh>);
            next unless $found_nsid == $nsid;
            my $dev = "/dev/${safe_ctl}n${ns_num}";
            return $dev if -b $dev;
        }
    }
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

    my $body = {
        name         => $vol_name,
        size         => "$bytes",
        replicaCount => 1,
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

    # Wait for volume to become Available
    for my $attempt (1..30) {
        my $v = _api($scfg, 'GET', "/api/v2/volumes/$uuid?projectName=$project");
        last if ($v->{state} // '') eq 'Available';
        sleep 1;
    }

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

    # Connect to subsystem if not already connected
    unless (_is_connected($subsys_nqn)) {
        my ($nvme_host, $nvme_port) = split(/:/, $scfg->{lb_nvme_host});
        run_command(['nvme', 'connect',
            '-t', 'tcp',
            '-a', $nvme_host,
            '-s', $nvme_port // '4420',
            '-n', $subsys_nqn,
        ]);

        # Wait for devices to appear
        for my $attempt (1..30) {
            last if _is_connected($subsys_nqn);
            sleep 1;
        }
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

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $subsys_nqn = _subsys_nqn($scfg);
    my $link       = _symlink_path($storeid, _vol_uuid($volname));

    unlink $link if -l $link;

    # Only disconnect if no other volumes from this storage are still active
    my $still_active = grep { -l "$SYMLINK_DIR/$storeid/$_" }
                       map  { $_->{UUID} }
                       @{(_api($scfg, 'GET', "/api/v2/volumes?projectName=" . _project($scfg))->{volumes} // [])};

    unless ($still_active) {
        run_command(['nvme', 'disconnect', '-n', $subsys_nqn])
            if _is_connected($subsys_nqn);
    }

    return 1;
}

# ── Features ──────────────────────────────────────────────────────────────────

sub volume_has_feature {
    my ($class, $cfg, $feature, $storeid, $volname, $snap, $running) = @_;
    my %features = (copy => 1, sparseinit => 0);
    return $features{$feature} // 0;
}

# NB: do not call __PACKAGE__->register() here. PVE::Storage's third-party
# plugin loader (which scans PVE/Storage/Custom/) calls register() for us, and
# registering twice dies on a duplicate storage type.

1;
