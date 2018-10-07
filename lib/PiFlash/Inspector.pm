# PiFlash::Inspector - inspection of the Linux system configuration including identifying SD card devices
use strict;
use warnings;
use v5.18.0; # require 2014 or newer version of Perl
use PiFlash::State;
use PiFlash::Command;

package PiFlash::Inspector;

use autodie; # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)
use File::Basename;
use File::Slurp;

# ABSTRACT: PiFlash functions to inspect Linux system devices to flash an SD card for Raspberry Pi

=head1 SYNOPSIS

 PiFlash::Inspector::collect_system_info();
 PiFlash::Inspector::collect_file_info();
 PiFlash::Inspector::collect_device_info();
 PiFlash::Inspector::blkparam(\%output, param-name, ...);
 $bool = PiFlash::Inspector::is_sd();
 $bool = PiFlash::Inspector::is_sd(\%device_info);
 PiFlash::Inspector::sd_search();

=head1 DESCRIPTION

This class contains internal functions used by L<PiFlash> to gather data about available devices on the system and determine if they are SD card devices.

PiFlash uses this info to refuse to write/destroy a device which is not an SD card. This provides a safeguard while using root permissions against a potential error which has happened where users have accidentally erased the wrong block device, losing a hard drive they wanted to keep.

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::Inspector>, L<PiFlash::State>

=cut

#
# class-global variables
#

# recognized file suffixes which SD cards can be flashed from
our @known_suffixes = qw(gz zip xz img);

# block device parameters to collect via lsblk
our @blkdev_params = ( "MOUNTPOINT", "FSTYPE", "SIZE", "SUBSYSTEMS", "TYPE", "MODEL", "RO", "RM", "HOTPLUG", "PHY-SEC");

# collect data about the system: kernel specs, program locations
sub collect_system_info
{
	my $system = PiFlash::State::system();

	# Make sure we're on a Linux system - this program uses Linux-only features
	($system->{sysname}, $system->{nodename}, $system->{release}, $system->{version},
		$system->{machine}) = POSIX::uname();
	if ($system->{sysname} ne "Linux") {
		PiFlash::State->error("This depends on features of Linux. Found $system->{sysname} kernel - cannot continue.");
	}

	# hard-code known-secure locations of programs here if you need to override any on your system
	# $prog{name} = "/path/to/name";

	# loop through needed programs and record locations from environment variable or system directories
	$system->{prog} = {};

	# set PATH in environment as a precaution - we don't intend to use it but mkfs does
	# search paths in standard Unix PATH order
	my @path;
	for my $path ("/sbin", "/usr/sbin", "/bin", "/usr/bin") {
		# include in PATH standard Unix directories which exist on this system
		if (-d $path) {
			push @path, $path;
		}
	}
	## no critic (RequireLocalizedPunctuationVars])
	$ENV{PATH} = join ":", @path;
	## use critic
	$system->{PATH} = $ENV{PATH};

	# find filesystems supported by this kernel (for formatting SD card)
	my %fs_pref = (vfat => 1, ext4 => 2, ext3 => 3, ext2 => 4, exfat => 5, other => 6); # fs preference order
	my @filesystems = grep {! /^nodev\s/} slurp("/proc/filesystems");
	for (my $i=0; $i<=$#filesystems; $i++) {
		# remove leading and trailing whitespace;
		$filesystems[$i] =~ s/^\s*//;
		$filesystems[$i] =~ s/\s*$//;
	}
	# sort list by decreasing preference (increasing numbers)
	$system->{filesystems} = [ sort {($fs_pref{$a} // $fs_pref{other})
		<=> ($fs_pref{$b} // $fs_pref{other})} @filesystems ];
	$system->{primary_fs} = $system->{filesystems}[0];


	# find locations where we can put mount points
	foreach my $dir ( qw(/run/media /media /mnt) ) {
		if ( -d $dir ) {
			PiFlash::State::system("media_dir", $dir); # use the first one
			last;
		}
	}
}

# collect input file info
# verify existence, deduce file type from contents, get size, check for raw filesystem image or NOOBS archive
sub collect_file_info
{
	my $input = PiFlash::State::input();

	# verify input file exists
	if (! -e $input->{path}) {
		PiFlash::State->error("input ".$input->{path}." does not exist");
	}
	if (! -f $input->{path}) {
		PiFlash::State->error("input ".$input->{path}." is not a regular file");
	}

	# use libmagic/file to collect file data
	# it is collected even if type will be determined by suffix so we can later inspect data further
	{
		my $magic = File::LibMagic->new();
		$input->{info} = $magic->info_from_filename($input->{path});
		if ($input->{info}{mime_type} eq "application/gzip"
			or $input->{info}{mime_type} eq "application/x-xz")
		{
			my $uncompress_magic = File::LibMagic->new(uncompress => 1);
			$input->{info}{uncompress} = $uncompress_magic->info_from_filename($input->{path});
		}
	}

	# parse the file name
	$input->{parse} = {};
	($input->{parse}{name}, $input->{parse}{path}, $input->{parse}{suffix})
		= fileparse($input->{path}, map {".".$_} @known_suffixes);

	# use libmagic/file to determine file type from contents
	say "input file is a ".$input->{info}{description};
	if ($input->{info}{description} =~ /^Zip archive data/i) {
		$input->{type} = "zip";
	} elsif ($input->{info}{description} =~ /^gzip compressed data/i) {
		$input->{type} = "gz";
	} elsif ($input->{info}{description} =~ /^XZ compressed data/i) {
		$input->{type} = "xz";
	} elsif ($input->{info}{description} =~ /^DOS\/MBR boot sector/i) {
		$input->{type} = "img";
	}
	if (!exists $input->{type}) {
		PiFlash::State->error("collect_file_info(): file type not recognized on $input->{path}");
	}

	# get file size - start with raw file size, update later if it's compressed/archive
	$input->{size} = -s $input->{path};

	# find embedded image in archived/compressed files (either *.img or a NOOBS image)
	if ($input->{type} eq "zip") {
		# process zip archives
		my @zip_content = PiFlash::Command::cmd2str("unzip - list contents", PiFlash::Command::prog("unzip"),
			"-l", $input->{path});
		chomp @zip_content;
		my $found_build_data = 0;
		my @imgfiles;
		my $zip_lastline = pop @zip_content; # last line contains total size
		$zip_lastline =~ /^\s*(\d+)/;
		$input->{size} = $1;
		foreach my $zc_entry (@zip_content) {
			if ($zc_entry =~ /\sBUILD-DATA$/) {
				$found_build_data = 1;
			} elsif ($zc_entry =~ /^\s*(\d+)\s.*\s([^\s]*)$/) {
				push @imgfiles, [$2, $1];
			}
		}

		# detect if the zip archive contains Raspberry Pi NOOBS (New Out Of the Box System)
		if ($found_build_data) {
			my @noobs_version = grep {/^NOOBS Version:/} PiFlash::Command::cmd2str("unzip - check for NOOBS",
				PiFlash::Command::prog("unzip"), "-p", $input->{path}, "BUILD-DATA");
			chomp @noobs_version;
			if (scalar @noobs_version > 0) {
				if ($noobs_version[0] =~ /^NOOBS Version: (.*)/) {
					$input->{NOOBS} = $1;
				}
			}
		}

		# if NOOBS system was not found, look for a *.img file
		if (!exists $input->{NOOBS}) {
			if (scalar @imgfiles == 0) {
				PiFlash::State->error("input file is a zip archive but does not contain a *.img file or NOOBS system");
			}
			$input->{imgfile} = $imgfiles[0][0];
			$input->{size} = $imgfiles[0][1];
		}
	} elsif ($input->{type} eq "gz") {
		# process gzip compressed files
		my @gunzip_out = PiFlash::Command::cmd2str("gunzip - list contents", PiFlash::Command::prog("gunzip"),
			"--list", "--quiet", $input->{path});
		chomp @gunzip_out;
		$gunzip_out[0] =~ /^\s+\d+\s+(\d+)\s+[\d.]+%\s+(.*)/;
		$input->{size} = $1;
		$input->{imgfile} = $2;
	} elsif ($input->{type} eq "xz") {
		# process xz compressed files
		if ($input->{path} =~ /^.*\/([^\/]*\.img)\.xz/) {
			$input->{imgfile} = $1;
		}
		my @xz_out = PiFlash::Command::cmd2str("xz - list contents", PiFlash::Command::prog("xz"), "--robot",
			"--list", $input->{path});
		chomp @xz_out;
		foreach my $xz_line (@xz_out) {
			if ($xz_line =~ /^file\s+\d+\s+\d+\s+\d+\s+(\d+)/) {
				$input->{size} = $1;
				last;
			}
		}
	}
}

# collect output device info
sub collect_device_info
{
	my $output = PiFlash::State::output();

	# check that device exists
	if (! -e $output->{path}) {
		PiFlash::State->error("output device ".$output->{path}." does not exist");
	}
	if (! -b $output->{path}) {
		PiFlash::State->error("output device ".$output->{path}." is not a block device");
	}

	# check block device parameters

	# load block device info into %output
	blkparam(@blkdev_params);
	if ($output->{mountpoint} ne "") {
		PiFlash::State->error("output device is mounted - this operation would erase it");
	}
	if ($output->{fstype} eq "swap") {
		PiFlash::State->error("output device is a swap device - this operation would erase it");
	}
	if ($output->{type} eq "part") {
		PiFlash::State->error("output device is a partition - Raspberry Pi flash needs whole SD device");
	}

	# check for SD/MMC card via USB or PCI bus interfaces
	if (!is_sd()) {
		PiFlash::State->error("output device is not an SD card - this operation would erase it");
	}
}

# blkparam function: get device information with lsblk command
# usage: blkparam(\%output, param-name, ...)
#   output: reference to hash with output device parameter strings
#   param-name: list of parameter names to read into output hash
sub blkparam
{
	# use PiFlash::State::output device unless another hash is provided
	my $blkdev;
	if (ref($_[0]) eq "HASH") {
		$blkdev = shift @_;
	} else {
		$blkdev = PiFlash::State::output();
	}

	# get the device's path
	# throw an exception if the device's hash data doesn't have it
	if (!exists $blkdev->{path}) {
		PiFlash::State::error("blkparam: device hash does not contain path to device");
	}
	my $path = $blkdev->{path};

	# loop through the requested parameters and get each one for the device with lsblk
	foreach my $paramname (@_) {
		if (exists $blkdev->{lc $paramname}) {
			# skip names of existing data to avoid overwriting
			say STDERR "blkparam(): skipped collection of parameter $paramname to avoid overwriting existing data";
			next;
		}
		my $value = PiFlash::Command::cmd2str("lsblk lookup of $paramname", PiFlash::Command::prog("lsblk"),
			"--bytes", "--nodeps", "--noheadings", "--output", $paramname, $path);
		if ($? == -1) {
			PiFlash::State->error("blkparam($paramname): failed to execute lsblk: $!");
		} elsif ($? & 127) {
			PiFlash::State->error(sprintf "blkparam($paramname): lsblk died with signal %d, %s coredump",
				($? & 127),  ($? & 128) ? 'with' : 'without');
		} elsif ($? != 0) {
			PiFlash::State->error(sprintf "blkparam($paramname): lsblk exited with value %d", $? >> 8);
		}
		$value =~ s/^\s*//; # remove leading whitespace
		$value =~ s/\s*$//; # remove trailing whitespace
		$blkdev->{lc $paramname} = $value;
	}
}

# check if a device is an SD card
sub is_sd
{
	# use PiFlash::State::output device unless another hash is provided
	my $blkdev;
	if (ref($_[0]) eq "HASH") {
		$blkdev = shift @_;
	} else {
		$blkdev = PiFlash::State::output();
	}

	# check for SD/MMC card via USB or PCI bus interfaces
	if ($blkdev->{model} eq "SD/MMC") {
		# detected SD card via USB adapter
		PiFlash::State::verbose() and say "output device ".$blkdev->{path}." is an SD card via USB adapter";
		return 1;
	}

	# check if the SD card driver operates this device
	my $found_mmc = 0;
	my $found_usb = 0;
	my @subsystems = split /:/, $blkdev->{subsystems};
	foreach my $subsystem (@subsystems) {
		if ($subsystem eq "mmc_host" or $subsystem eq "mmc") {
			$found_mmc = 1;
		}
		if ($subsystem eq "usb") {
			$found_usb = 1;
		}
	}
	if ($found_mmc) {
		# verify that the MMC device is actually an SD card
		my $sysfs_devtype_path = "/sys/block/".basename($blkdev->{path})."/device/type";
		if (! -f $sysfs_devtype_path) {
			PiFlash::State->error("cannot find output device ".$blkdev->{path}." type - Linux kernel "
				.PiFlash::State::system("release")." may be too old");
		}
		my $sysfs_devtype = slurp($sysfs_devtype_path);
		PiFlash::State::verbose() and say "output device ".$blkdev->{path}." is a $sysfs_devtype";
		if ($sysfs_devtype eq "SD") {
			return 1;
		}
	}

	# allow USB writable/hotplug/removable drives with physical sector size 512
	# this is imprecise because some other non-SD flash devices will be accepted as SD
	# it will still avoid allowing hard drives to be erased
	if ($found_usb) {
		if($blkdev->{ro}==0 and $blkdev->{rm}==1 and $blkdev->{hotplug}==1 and $blkdev->{"phy-sec"}==512) {
			PiFlash::State::verbose() and say "output device ".$blkdev->{path}." close enough: USB removable writable hotplug ps=512";
			return 1;
		}
	}
	
	PiFlash::State::verbose() and say "output device ".$blkdev->{path}." rejected as SD card";
	return 0;
}

# search for and print names of SD card devices
sub sd_search
{
	# add block devices to system info
	my $system = PiFlash::State::system();
	$system->{blkdev} = {};

	# loop through available devices - collect info and print list of available SD cards
	my @blkdev = PiFlash::Command::cmd2str("lsblk - find block devices", PiFlash::Command::prog("lsblk"),
		"--nodeps", "--noheadings", "--list", "--output", "NAME");
	my @sdcard;
	foreach my $blkdevname (@blkdev) {
		$system->{blkdev}{$blkdevname} = {};
		my $blkdev = $system->{blkdev}{$blkdevname};
		$blkdev->{path} = "/dev/$blkdevname";
		blkparam($blkdev, @blkdev_params);
		if (is_sd($blkdev)) {
			push @sdcard, $blkdev->{path};
		}
	}

	# print results of SD search
	if (scalar @sdcard == 0) {
		say "no SD cards found on system";
	} else {
		say "SD cards found: ".join(" ", @sdcard);
	}
}

# base function: get basename from a file path
sub base
{
	my $path = shift;
	my $filename = File::Basename::fileparse($path, ());
	return $filename;
}

# slurp function: get file contents into a string
sub slurp
{
	my $filename = shift;
	open my $fh, "<", $filename;
	my $str = do {
		## no critic (RequireInitializationForLocalVars)
		local $/; # avoid interference from functions which modify global $/
		<$fh>
	};
	close $fh;
	if (wantarray) {
		my @str = split /^/, $str;
		chomp @str;
		return @str;
	}
	chomp $str;
	return $str;
}

1;
