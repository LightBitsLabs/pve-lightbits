# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.

package PVE::Tools;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(run_command file_set_contents file_read_firstline);
sub run_command {}

# Minimal stand-ins for the real helpers. file_set_contents writes atomically in
# PVE; here a plain write plus chmod is enough to assert content and mode.
sub file_set_contents {
    my ($filename, $data, $perm) = @_;
    $perm = 0644 if !defined $perm;
    open(my $fh, '>', $filename) or die "unable to open '$filename' - $!\n";
    print $fh $data;
    close($fh) or die "unable to write '$filename' - $!\n";
    chmod($perm, $filename) or die "unable to chmod '$filename' - $!\n";
    return;
}

sub file_read_firstline {
    my ($filename) = @_;
    open(my $fh, '<', $filename) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef if !defined $line;
    chomp $line;
    return $line;
}
1;
