# PiFlash::MediaWriter - write to Raspberry Pi SD card installation with scriptable customization
# by Ian Kluft

use strict;
use warnings;
use v5.18.0; # require 2014 or newer version of Perl
use PiFlash::State;
use PiFlash::Command;

package PiFlash::MediaWriter;

use autodie; # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)

# ABSTRACT: write to Raspberry Pi SD card installation with scriptable customization

=head1 SYNOPSIS

 PiFlash::MediaWriter::flash_device();

=head1 DESCRIPTION

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::Inspector>, L<PiFlash::State>

=cut

# generate random hex digits
sub random_hex
{
	my $length = shift;
	my $hex = "";
	while ($length > 0) {
		my $chunk = ($length > 4) ? 4 : $length;
		$length -= $chunk;
		$hex .= sprintf "%0*x", $chunk, int(rand(16**$chunk));
	}
	return $hex;
}

# generate a random UUID
# 128 bits/32 hexadecimal digits, used to set a probably-unique UUID on an ext2/3/4 filesystem we created
sub random_uuid
{
	my $uuid;

	# start with our own contrived prefix for our UUIDs
	$uuid .= "314decaf-"; # "314" first digits of pi (as in RasPi), and "decaf" among few words from hex digits

	# next 4 digits are from lower 4 hex digits of current time (rolls over every 18 days)
	$uuid .= sprintf "%04x-", (time & 0xffff);

	# next 4 digits are the UUID format version (4 for random) and 3 random hex digits
	$uuid .= "4".random_hex(3)."-";

	# next 4 digits are a UUID variant digit and 3 random hex digits
	$uuid .= (sprintf "%x", 8+int(rand(4))).random_hex(3)."-";
	
	# conclude with 8 random hex digits
	$uuid .= random_hex(12);

	return $uuid;
}

# generate a random label string
# 11 characters, used to set a probably-unique label on a VFAT/ExFAT filesystem we created
sub random_label
{
	my $label = "RPI";
	for (my $i=0; $i<8; $i++) {
		my $num = int(rand(36));
		if ($num <= 9) {
			$label .= chr(ord('0')+$num);
		} else {
			$label .= chr(ord('A')+$num-10);
		}
	}
	return $label;
}

# flash the output device from the input file
sub flash_device
{
	# flash the device
	if (PiFlash::State::has_input("imgfile")) {
		# if we know an embedded image file name, use it in the start message
		say "flashing ".PiFlash::State::input("path")." / ".PiFlash::State::input("imgfile")." -> "
			.PiFlash::State::output("path");
	} else {
		# print a start message with source and destination
		say "flashing ".PiFlash::State::input("path")." -> ".PiFlash::State::output("path");
	}
	say "wait for it to finish - this takes a while, progress not always indicated";
	if (PiFlash::State::input("type") eq "img") {
		PiFlash::Command::cmd("dd flash", PiFlash::Command::prog("sudo")." ".PiFlash::Command::prog("dd")
			." bs=4M if=\"".PiFlash::State::input("path")."\" of=\""
			.PiFlash::State::output("path")."\" status=progress" );
	} elsif (PiFlash::State::input("type") eq "zip") {
		if (PiFlash::State::has_input("NOOBS")) {
			# format SD and copy NOOBS archive to it
			my $label = random_label();
			PiFlash::State::output("label", $label);
			my $fstype = PiFlash::State::system("primary_fs");
			if ($fstype ne "vfat") {
				PiFlash::State->error("NOOBS requires VFAT filesystem, not in this kernel - need to load a module?");
			}
			say "formatting $fstype filesystem for Raspberry Pi NOOBS system...";
			PiFlash::Command::cmd("write partition table", PiFlash::Command::prog("echo"), "type=c", "|",
				PiFlash::Command::prog("sudo"), PiFlash::Command::prog("sfdisk"), PiFlash::State::output("path"));
			my @partitions = grep {/part\s*$/} PiFlash::Command::cmd2str("lsblk - find partitions",
				PiFlash::Command::prog("lsblk"), "--list", PiFlash::State::output("path"));
			$partitions[0] =~ /^([^\s]+)\s/;
			my $partition = "/dev/".$1;
			PiFlash::Command::cmd("format sd card", PiFlash::Command::prog("sudo"),
				PiFlash::Command::prog("mkfs.$fstype"), "-n", $label, $partition);
			my $mntdir = PiFlash::State::system("media_dir")."/piflash/sdcard";
			PiFlash::Command::cmd("reread partition table", PiFlash::Command::prog("sudo"),
				PiFlash::Command::prog("blockdev"), "--rereadpt", PiFlash::State::output("path"));
			PiFlash::Command::cmd("create mount point", PiFlash::Command::prog("sudo"),
				PiFlash::Command::prog("mkdir"), "-p", $mntdir );
			PiFlash::Command::cmd("mount SD card", PiFlash::Command::prog("sudo"), PiFlash::Command::prog("mount"),
				"-t", $fstype, "LABEL=$label", $mntdir);
			PiFlash::Command::cmd("unzip NOOBS contents", PiFlash::Command::prog("sudo"),
				PiFlash::Command::prog("unzip"), "-d", $mntdir, PiFlash::State::input("path"));
			PiFlash::Command::cmd("unmount SD card", PiFlash::Command::prog("sudo"), PiFlash::Command::prog("umount"),
				$mntdir);
		} else {
			# flash zip archive to SD
			PiFlash::Command::cmd("unzip/dd flash", PiFlash::Command::prog("unzip")." -p \""
				.PiFlash::State::input("path")."\" \"".PiFlash::State::input("imgfile")."\" | "
				.PiFlash::Command::prog("sudo")." ".PiFlash::Command::prog("dd")." bs=4M of=\""
				.PiFlash::State::output("path")."\" status=progress");
		}
	} elsif (PiFlash::State::input("type") eq "gz") {
		# flash gzip-compressed image file to SD
		PiFlash::Command::cmd("gunzip/dd flash", PiFlash::Command::prog("gunzip")." --stdout \""
			.PiFlash::State::input("path")."\" | ".PiFlash::Command::prog("sudo")." ".PiFlash::Command::prog("dd")
			." bs=4M of=\"".PiFlash::State::output("path")."\" status=progress");
	} elsif (PiFlash::State::input("type") eq "xz") {
		# flash xz-compressed image file to SD
		PiFlash::Command::cmd("xz/dd flash", PiFlash::Command::prog("xz")." --decompress --stdout \""
			.PiFlash::State::input("path")."\" | ".PiFlash::Command::prog("sudo")." ".PiFlash::Command::prog("dd")
			." bs=4M of=\"".PiFlash::State::output("path")."\" status=progress");
	}
	say "wait for it to finish - synchronizing buffers";
	PiFlash::Command::cmd("sync", PiFlash::Command::prog("sync"));
	say "done - it is safe to remove the SD card";
}

1;
