# PiFlash::MediaWriter - write to Raspberry Pi SD card installation with scriptable customization
# by Ian Kluft

# pragmas to silence some warnings from Perl::Critic
## no critic (Modules::RequireExplicitPackage)
# This solves a catch-22 where parts of Perl::Critic want both package and use-strict to be first
use strict;
use warnings;
use utf8;
use 5.01400;    # require 2011 or newer version of Perl
## use critic (Modules::RequireExplicitPackage)

package PiFlash::MediaWriter;

use autodie;   # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)
use Carp qw(carp croak);
use Try::Tiny;
use File::Basename;
use File::Slurp qw(slurp);
use File::Temp;
use PiFlash::State;
use PiFlash::Command;
use PiFlash::Inspector;
use PiFlash::Hook;

# ABSTRACT: write to Raspberry Pi SD card installation with scriptable customization

=head1 SYNOPSIS

 PiFlash::MediaWriter::flash_device();

=head1 DESCRIPTION

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::Inspector>, L<PiFlash::State>

=head1 BUGS AND LIMITATIONS

Report bugs via GitHub at L<https://github.com/ikluft/piflash/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/piflash/pulls>

=cut

# generate random hex digits
sub random_hex
{
    my $length = shift;
    my $hex    = "";
    while ( $length > 0 ) {
        my $chunk = ( $length > 4 ) ? 4 : $length;
        $length -= $chunk;
        $hex .= sprintf "%0*x", $chunk, int( rand( 16**$chunk ) );
    }
    return $hex;
}

# generate a random UUID
# 128 bits/32 hexadecimal digits, used to set a probably-unique UUID on an ext2/3/4 filesystem we created
sub random_uuid
{
    my $uuid;

    # start with our own contrived prefix for our UUIDs
    $uuid .= "314decaf-";    # "314" first digits of pi (as in RasPi), and "decaf" among few words from hex digits

    # next 4 digits are from lower 4 hex digits of current time (rolls over every 18 days)
    $uuid .= sprintf "%04x-", ( time & 0xffff );

    # next 4 digits are the UUID format version (4 for random) and 3 random hex digits
    $uuid .= "4" . random_hex(3) . "-";

    # next 4 digits are a UUID variant digit and 3 random hex digits
    $uuid .= ( sprintf "%x", 8 + int( rand(4) ) ) . random_hex(3) . "-";

    # conclude with 8 random hex digits
    $uuid .= random_hex(12);

    return $uuid;
}

# generate a random label string
# 11 characters, used to set a probably-unique label on a VFAT/ExFAT filesystem we created
sub random_label
{
    my $label = "RPI";
    for ( my $i = 0 ; $i < 8 ; $i++ ) {
        my $num = int( rand(36) );
        if ( $num <= 9 ) {
            $label .= chr( ord('0') + $num );
        } else {
            $label .= chr( ord('A') + $num - 10 );
        }
    }
    return $label;
}

# reread partition table, with retries if necessary
sub reread_pt
{
    my $reason = shift;

    # re-read partition table, use multiple tries if necessary
    my $tries = 10;
    while (1) {
        try {
            PiFlash::Command::cmd(
                "reread partition table for $reason", PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("blockdev"),   "--rereadpt",
                PiFlash::State::output("path")
            );
        };

        # check for errors, retry if possible
        if ($@) {
            if ( ref $@ ) {

                # reference means unrecognized error - rethrow the exception
                croak $@;
            } elsif ( $@ =~ /exited with value 1/ ) {

                # exit status 1 means retry
                $tries--;
                if ( $tries > 0 ) {

                    # wait a second and try again - sync may need to settle
                    sleep 1;
                    next;
                }

                # otherwise fail for repeated failed retries
                croak $@;
            } else {

                # other unrecognized error - rethrow the exception
                croak $@;
            }
        }

        # got through without an error - done
        last;
    }
    return;
}

# look up boot and root partition & filesystem info
# save data in PiFlash::State::output
sub get_sd_partitions
{
    my $output = PiFlash::State::output();
    ( exists $output->{partitions} ) and return;
    my @partitions = grep { /part\s*$/x } PiFlash::Command::cmd2str(
        "lsblk - find partitions",
        PiFlash::Command::prog("lsblk"),
        "--list", PiFlash::State::output("path")
    );

    if (@partitions) {
        for ( my $i = 0 ; $i < scalar @partitions ; $i++ ) {
            $partitions[$i] =~ s/^([^\s]+)\s.*/$1/diex;
        }
        my $part_boot = $partitions[0];
        my $num_root  = scalar @partitions;
        my $part_root = $partitions[ $num_root - 1 ];
        PiFlash::State::output( "num_boot",    0 );
        PiFlash::State::output( "part_boot",   $part_boot );
        PiFlash::State::output( "fstype_boot", PiFlash::Inspector::get_fstype("/dev/$part_boot") );
        PiFlash::State::output( "num_root",    $num_root );
        PiFlash::State::output( "part_root",   $part_root );
        PiFlash::State::output( "fstype_root", PiFlash::Inspector::get_fstype("/dev/$part_root") );
    }
    PiFlash::State::output( "partitions", \@partitions );

    if ( PiFlash::State::verbose() ) {
        print "get_sd_partitions: ";
        for my $key (qw(num_boot part_boot fstype_boot num_root part_root fstype_root)) {
            print "$key=" . ( PiFlash::State::output($key) // "undef" ) . " ";
        }
        print "\n";
    }
    return;
}

# flash the output device from the input file
sub flash_device
{
    # flash the device
    if ( PiFlash::State::has_input("imgfile") ) {

        # if we know an embedded image file name, use it in the start message
        say "flashing "
            . PiFlash::State::input("path") . " / "
            . PiFlash::State::input("imgfile") . " -> "
            . PiFlash::State::output("path");
    } else {

        # print a start message with source and destination
        say "flashing " . PiFlash::State::input("path") . " -> " . PiFlash::State::output("path");
    }
    say "wait for it to finish - this takes a while, progress not always indicated";
    my $dd_args = "bs=4M oflag=sync status=progress";
    if ( PiFlash::State::input("type") eq "img" ) {
        PiFlash::Command::cmd(
            "dd flash",
            PiFlash::Command::prog("sudo") . " "
                . PiFlash::Command::prog("dd")
                . " if=\""
                . PiFlash::State::input("path")
                . "\" of=\""
                . PiFlash::State::output("path")
                . "\" $dd_args"
        );
    } elsif ( PiFlash::State::input("type") eq "zip" ) {
        if ( PiFlash::State::has_input("NOOBS") ) {

            # format SD and copy NOOBS archive to it
            my $label = random_label();
            PiFlash::State::output( "label", $label );
            my $fstype = PiFlash::State::system("primary_fs");
            if ( $fstype ne "vfat" ) {
                PiFlash::State->error("NOOBS requires VFAT filesystem, not in this kernel - need to load a module?");
            }
            say "formatting $fstype filesystem for Raspberry Pi NOOBS system...";
            PiFlash::Command::cmd(
                "write partition table",
                PiFlash::Command::prog("echo"),
                "type=c", "|",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("sfdisk"),
                PiFlash::State::output("path")
            );
            my @partitions = grep { /part\s*$/x } PiFlash::Command::cmd2str(
                "lsblk - find partitions", PiFlash::Command::prog("lsblk"),
                "--list",                  PiFlash::State::output("path")
            );
            my $partition = "/dev/" . ( substr $partitions[0], 0, index( $partitions[0], ' ' ) );
            PiFlash::Command::cmd(
                "format sd card",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mkfs.$fstype"),
                "-n", $label, $partition
            );
            my $mntdir = PiFlash::State::system("media_dir") . "/piflash/sdcard";
            PiFlash::Command::cmd(
                "reread partition table for NOOBS", PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("blockdev"), "--rereadpt",
                PiFlash::State::output("path")
            );
            PiFlash::Command::cmd(
                "create mount point",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mkdir"),
                "-p", $mntdir
            );
            PiFlash::Command::cmd(
                "mount SD card",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mount"),
                "-t", $fstype, "LABEL=$label", $mntdir
            );
            PiFlash::Command::cmd(
                "unzip NOOBS contents",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("unzip"),
                "-d", $mntdir, PiFlash::State::input("path")
            );
            PiFlash::Command::cmd(
                "unmount SD card",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("umount"), $mntdir
            );
        } else {

            # flash zip archive to SD
            PiFlash::Command::cmd(
                "unzip/dd flash",
                PiFlash::Command::prog("unzip")
                    . " -p \""
                    . PiFlash::State::input("path") . "\" \""
                    . PiFlash::State::input("imgfile") . "\" | "
                    . PiFlash::Command::prog("sudo") . " "
                    . PiFlash::Command::prog("dd")
                    . " of=\""
                    . PiFlash::State::output("path")
                    . "\" $dd_args"
            );
        }
    } elsif ( PiFlash::State::input("type") eq "gz" ) {

        # flash gzip-compressed image file to SD
        PiFlash::Command::cmd(
            "gunzip/dd flash",
            PiFlash::Command::prog("gunzip")
                . " --stdout \""
                . PiFlash::State::input("path") . "\" | "
                . PiFlash::Command::prog("sudo") . " "
                . PiFlash::Command::prog("dd")
                . " of=\""
                . PiFlash::State::output("path")
                . "\" $dd_args"
        );
    } elsif ( PiFlash::State::input("type") eq "xz" ) {

        # flash xz-compressed image file to SD
        PiFlash::Command::cmd(
            "xz/dd flash",
            PiFlash::Command::prog("xz")
                . " --decompress --stdout \""
                . PiFlash::State::input("path") . "\" | "
                . PiFlash::Command::prog("sudo") . " "
                . PiFlash::Command::prog("dd")
                . " of=\""
                . PiFlash::State::output("path")
                . "\" $dd_args"
        );
    }
    say "- synchronizing buffers";
    PiFlash::Command::cmd( "sync", PiFlash::Command::prog("sync") );
    reread_pt("post-sync");    # re-read partition table, use multiple tries if necessary
    get_sd_partitions();
    my @partitions = PiFlash::State::output("partitions");

    # check if there are any partitions before partition-dependent processing
    # protects from scenario (such as RISCOS) where whole-device filesystem has no partition table
    if (@partitions) {
        my $sd_name     = basename( PiFlash::State::output("path") );
        my $num_boot    = PiFlash::State::output("num_boot");
        my $part_boot   = PiFlash::State::output("part_boot");
        my $num_root    = PiFlash::State::output("num_root");
        my $part_root   = PiFlash::State::output("part_root");
        my $fstype_root = PiFlash::State::output("fstype_root");

        # resize root filesystem if command-line flag is set
        # resize flag is silently ignored for NOOBS images because it will re-image and resize
        if ( PiFlash::State::has_cli_opt("resize") and not PiFlash::State::has_input("NOOBS") ) {
            say "- resizing the partition";

            if ( defined $fstype_root ) {
                my @sfdisk_resize_input = (", +");
                if ( $fstype_root =~ /^ext[234]/x ) {

                    # ext2/3/4 filesystem can be resized
                    PiFlash::Command::cmd2str(
                        \@sfdisk_resize_input,          "resize partition",
                        PiFlash::Command::prog("sudo"), PiFlash::Command::prog("sfdisk"),
                        "--quiet",                      "--no-reread",
                        "-N",                           $num_root,
                        PiFlash::State::output("path")
                    );
                    say "- checking the filesystem";
                    PiFlash::Command::cmd2str(
                        "filesystem check ($fstype_root)",
                        PiFlash::Command::prog("sudo"),
                        PiFlash::Command::prog("e2fsck"),
                        "-fy", "/dev/$part_root"
                    );
                    say "- resizing the filesystem";
                    PiFlash::Command::cmd2str(
                        "resize filesystem",
                        PiFlash::Command::prog("sudo"),
                        PiFlash::Command::prog("resize2fs"),
                        "/dev/$part_root"
                    );
                    reread_pt("resize $fstype_root");    # re-read partition table, use multiple tries if necessary
                } elsif ( $fstype_root eq "btrfs" ) {

                    # btrfs filesystem can be resized
                    PiFlash::Command::cmd2str(
                        \@sfdisk_resize_input,          "resize partition",
                        PiFlash::Command::prog("sudo"), PiFlash::Command::prog("sfdisk"),
                        "--quiet",                      "--no-reread",
                        "-N",                           $num_root,
                        PiFlash::State::output("path")
                    );
                    say "- checking the filesystem";
                    PiFlash::Command::cmd2str(
                        "filesystem check (btrfs)",
                        PiFlash::Command::prog("sudo"),
                        PiFlash::Command::prog("btrfs"),
                        qw(check --progress),
                        "/dev/$part_root"
                    );
                    say "- resizing the filesystem";
                    my $mntdir   = PiFlash::State::system("media_dir") . "/piflash/sdcard";
                    my $mnt_root = $mntdir . "/root";
                    PiFlash::Command::cmd(
                        "create mount point for root fs",
                        PiFlash::Command::prog("sudo"),
                        PiFlash::Command::prog("mkdir"),
                        "-p", $mnt_root
                    );
                    PiFlash::Command::cmd2str(
                        "resize filesystem",
                        PiFlash::Command::prog("sudo"),
                        PiFlash::Command::prog("btrfs"),
                        qw(resize max), $mnt_root
                    );
                    PiFlash::Command::cmd(
                        "unmount root fs",
                        PiFlash::Command::prog("sudo"),
                        PiFlash::Command::prog("umount"), $mnt_root
                    );
                    reread_pt("resize $fstype_root");    # re-read partition table, use multiple tries if necessary
                } else {
                    carp "unrecognized filesystem type $fstype_root - resize not attempted";
                }
            } else {
                carp "unknown filesystem type - resize not attempted";
            }
        }

        # check if any hooks are registered for filesystem access
        if ( PiFlash::Hook::has("fs_mount") ) {
            reread_pt("filesystem hooks");    # re-read partition table, use multiple tries if necessary
            get_sd_partitions();
            my $fstype_boot = PiFlash::State::output("fstype_boot");
            my $dev_boot    = "/dev/" . PiFlash::State::output("part_boot");
            my $dev_root    = "/dev/" . PiFlash::State::output("part_root");
            my $mntdir      = PiFlash::State::system("media_dir") . "/piflash/sdcard";
            my $mnt_boot    = $mntdir . "/boot";
            my $mnt_root    = $mntdir . "/root";
            PiFlash::Command::cmd(
                "create mount point for boot fs",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mkdir"),
                "-p", $mnt_boot
            );
            PiFlash::Command::cmd(
                "create mount point for root fs",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mkdir"),
                "-p", $mnt_root
            );
            PiFlash::Command::cmd(
                "mount boot fs",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mount"),
                "-t", $fstype_boot, $dev_boot, $mnt_boot
            );
            PiFlash::Command::cmd(
                "mount root fs",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("mount"),
                "-t", $fstype_root, $dev_root, $mnt_root
            );
            PiFlash::Hook::fs_mount( { boot => $mnt_boot, root => $mnt_root } );
            PiFlash::Command::cmd(
                "unmount root fs",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("umount"), $mnt_root
            );
            PiFlash::Command::cmd(
                "unmount boot fs",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("umount"), $mnt_boot
            );
        }
    }

    # call hooks for optional post-install tweaks
    PiFlash::Hook::post_install();

    # report that it's done
    say "done - it is safe to remove the SD card";
    return;
}

1;
