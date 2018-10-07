# PiFlash - flash a Raspberry Pi image to an SD card, with safety checks to avoid erasing wrong device
# This module/script uses sudo to perform root-privileged functions.
# by Ian Kluft
use strict;
use warnings;
use v5.18.0; # require 2014 or newer version of Perl
use PiFlash::State;
use PiFlash::Command;
use PiFlash::Inspector;
use Carp;
use POSIX; # included with perl
use File::Basename; # included with perl
use File::LibMagic; # rpm: "dnf install perl-File-LibMagic", deb: "apt-get install libfile-libmagic-perl"

package PiFlash;

use autodie; # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)
use Getopt::Long; # included with perl

=head1 NAME

piflash - Raspberry Pi SD-flashing script with safety checks to avoid erasing the wrong device

=head1 SYNOPSIS

 piflash [--verbose] input-file output-device

 piflash [--verbose] --SDsearch

=head1 DESCRIPTION

This script flashes an SD card for a Raspberry Pi. It includes safety checks so that it can only erase and write to an SD card, not another device on the system. The safety checks are probably of most use to beginners. For more advanced users (like the author) it also has the convenience of flashing directly from the file formats downloadable from raspberrypi.org without extracting a .img file from a zip/gz/xz file.

=over 1

=item *
The optional parameter --verbose makes much more verbose status and error messages.  Use this when troubleshooting any problem or preparing program output to ask for help or report a bug.

=item *
input-file is the path of the binary image file used as input for flashing the SD card. If it's a .img file then it will be flashed directly. If it's a gzip (.gz), xz (.xz) or zip (.zip) file then the .img file will be extracted from it to flash the SD card. It is not necessary to unpack the file if it's in one of these formats. This covers most of the images downloadable from the Raspberry Pi foundation's web site.

=item *
output-file is the path to the block device where the SSD card is located. The device should not be mounted - if it ismounted the script will detect it and exit with an error. This operation will erase the SD card and write the new image from the input-file to it. (So make sure it's an SD card you're willing to have erased.)

=item *
The --SDsearch parameter tells piflash to print a list of device names for SD cards available on the system and then exit. Do not specify an input file or output device when using this option - it will exit before they would be used.

=back

=head2 Safety Checks

The program makes a number of safety checks for you. Since the SD card flashing process may need root permissions, these are considered prudent precautions.

=over 1

=item *
The input file's format will be checked. If it ends in .img then it will be flashed directly as a binary image file. If it ends in .xz, .gzip or .zip, it will extract the binary image from the file. If the filename doesn't have a suffix, libmagic will be used to inspect the contents of the file (for "magic numbers") to determine its format.

=item *
The output device must be a block device.

=item *
If the output device is a mounted filesystem, it will refuse to erase it.

=item *
If the output device is not an SD card, it will refuse to erase it.
Piflash has been tested with USB and PCI based SD card interfaces.

=back

=head2 Automated Flashing Procedure

Piflash automates the process of flashing an SD card from various Raspberry Pi OS images.

=over 1

=item *
For most disk images, either in a raw *.img file, compressed in a *.gz or *.xz file, or included in a *.zip archive, piflash recognizes the file format and extracts the disk image for flashing, eliminating the step of uncompressing or unarchiving it before it can be flashed to the SD.

=item *
For zip archives, it checks if it contains the Raspberry Pi NOOBS (New Out Of the Box System), in which case it handles it differently. The steps it takes are similar to the instructions that one would have to follow manually.  It formats a new VFAT filesystem on the card. (FAT/VFAT is the only format recognized by the Raspberry Pi's simple boot loader.) Then it copies the contents of the zip archive into the card, automating the entire flashing process even for a NOOBS system, which previously didn't even have instructions to be done from Linux systems.

=back

=head1 INSTALLATION

The piflash script only works on Linux systems. It depends on features of the Linux kernel to look up whether the output device is an SD card and other information about it. It has been tested so far on Fedora 25, and some experimentation with Ubuntu 16.04 (in a virtual machine) to get the kernel parameters right for a USB SD card reader.

=head2 System Dependencies

Some programs and libraries must be installed on the system for piflash to work - most packages have such dependencies.

On RPM-based Linux systems (Red Hat, Fedora, CentOS) the following command, run as root, will install the dependencies.

	dnf install coreutils util-linux sudo perl file-libs perl-File-LibMagic perl-IO gzip unzip xz e2fsprogs dosfstools

On Deb-based Linux systems (Debian, Ubuntu, Raspbian) the following command, run as root, will install the dependencies.

	apt-get install coreutils util-linux klibc-utils sudo perl-base libmagic1 libfile-libmagic-perl gzip xz-utils e2fsprogs dosfstools

On source-based or other Linux distributions, make sure the following are installed:

=over 1

=item programs:
blockdev, dd, echo, gunzip, lsblk, mkdir, mkfs.vfat, mount, perl, sfdisk, sudo, sync, true, umount, unzip, xz

=item libraries:
libmagic/file-libs, File::LibMagic (perl)

=back

=head2 Piflash script

The piflash script can be downloaded with either of these commands.

	curl -L https://github.com/ikluft/ikluft-tools/raw/master/piflash/piflash > piflash

or

	wget https://github.com/ikluft/ikluft-tools/raw/master/piflash/piflash

=head2 Bug reporting

Report bugs via GitHub at https://github.com/ikluft/ikluft-tools/issues - this location may eventually change
if piflash becomes popular enough to warrant having its own source code repository.

When reporting a bug, please include the full output using the --verbose option. That will include all of the
program's state information, which will help understand the bigger picture what was happening on your system.
Feel free to remove information you don't want to post in a publicly-visible bug report - though it's helpful
to add "[redacted]" where you removed something so it's clear what happened.

For any SD card reader hardware which piflash fails to recognize (and therefore refuses to write to),
please describe the hardware as best you can including name, product number, bus (USB, PCI, etc),
any known controller chips.

=cut

# print program usage message
sub usage
{
	say STDERR "usage: ".PiFlash::Inspector::base($0)." [--verbose] input-file output-device";
	say STDERR "       ".PiFlash::Inspector::base($0)." [--verbose] --SDsearch";
	exit 1;
}

# print numbers with readable suffixes for megabytes, gigabytes, terabytes, etc
# handle more prefixes than currently needed for extra scalability to keep up with Moore's Law for a while
sub num_readable
{
	my $num = shift;
	my @suffixes = qw(bytes KB MB GB TB PB EB ZB);
	my $magnitude = int(log($num)/log(1024));
	if ($magnitude > $#suffixes) {
		$magnitude = $#suffixes;
	}
	my $num_base = $num/(1024**($magnitude));
	return sprintf "%4.2f%s", $num_base, $suffixes[$magnitude];
}

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

# piflash script main routine to be called from exception-handling wrapper
sub piflash
{
	# initialize program state storage
	PiFlash::State->init("system", "input", "output", "option", "log");

	# collect and validate command-line arguments
	do { GetOptions (PiFlash::State::option(), "verbose", "sdsearch"); };
	if ($@) {
		# in case of failure, add state info if verbose mode is set
		PiFlash::State->error($@);
	}
	if (($#ARGV != 1) and (!PiFlash::State::has_option("sdsearch"))) {
		usage();
	}
	# collect system info: kernel specs and locations of needed programs
	PiFlash::Inspector::collect_system_info();

	# if --SDsearch option was selected, search for SD cards and exit
	if (PiFlash::State::has_option("sdsearch")) {
		# SDsearch mode: print list of SD card devices and exit
		PiFlash::Inspector::sd_search();
		return;
	}

	# set input and output paths
	PiFlash::State::input("path", $ARGV[0]);
	PiFlash::State::output("path", $ARGV[1]);
	say "requested to flash ".PiFlash::State::input("path")." to ".PiFlash::State::output("path");
	say "output device ".PiFlash::State::output("path")." will be erased";

	# check the input file
	PiFlash::Inspector::collect_file_info();
	
	# check the output device
	PiFlash::Inspector::collect_device_info();

	# check input file and output device sizes
	if (PiFlash::State::input("size") > PiFlash::State::output("size")) {
		PiFlash::State->error("output device not large enough for this image - currently have: "
			.num_readable(PiFlash::State::output("size")).", minimum size: "
			.num_readable(PiFlash::State::input("size")));
	}
	# check if SD card is recommended 8GB - check for 6GB since it isn't a hard limit
	if (PiFlash::State::has_input("NOOBS") and PiFlash::State::output("size") < 6*1024*1024*1024) {
		PiFlash::State->error("NOOBS images want 8GB SD card - currently have: "
			.num_readable(PiFlash::State::output("size")));
	}

	# test access to root privilege
	# sudo should be configured to not prompt for a password again on this session for some minutes
	say "verify sudo access";
	do { PiFlash::Command::cmd("sudo test", PiFlash::Command::prog("sudo"), PiFlash::Command::prog("true")); };
	if ($@) {
		# in case of failure, report that root privilege is required
		PiFlash::State->error("root privileges required to run this script");
	}

	# flash the device
	flash_device();
}

# run main routine and catch exceptions
sub main
{
	local $@; # avoid interference from anything that modifies global $@
	do { piflash(); };

	# catch any exceptions thrown in main routine
	if (my $exception = $@) {
		if (ref $exception) {
			# exception is an object - try common output functions in case they include more details
			# these are not generated by this program - but if another module surprises us, try to handle it gracefully
			if ($exception->can('as_string')) {
				# typical of Exception::Class derivative classes
				PiFlash::State->error("[".(ref $exception)."]: ".$exception->as_string());
			}
			if ($exception->can('to_string')) {
				# typical of Exception::Base derivative classes
				PiFlash::State->error("[".(ref $exception)."]: ".$exception->to_string());
			}
			# if exception object was not handled, fall through and print whatever it says as if it's a string
		}

		# print exception as a plain string
		# don't run this through PiFlash::State->error() because it probably already came from there
		say STDERR "$0 failed: $@";
		return 1;
	} else {
		if (PiFlash::State::verbose()) {
			say "Program state dump...\n".PiFlash::State::odump($PiFlash::State::state,0);
		}
	}

	# return success
	return 0;
}

1;
