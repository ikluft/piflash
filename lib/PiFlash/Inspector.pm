# PiFlash::Inspector - inspection of the Linux system configuration including identifying SD card devices
# by Ian Kluft

# pragmas to silence some warnings from Perl::Critic
## no critic (Modules::RequireExplicitPackage)
# This solves a catch-22 where parts of Perl::Critic want both package and use-strict to be first
use strict;
use warnings;
use utf8;
## use critic (Modules::RequireExplicitPackage)

package PiFlash::Inspector;

use autodie;   # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)
use Try::Tiny;
use Readonly;
use File::Basename;
use File::Slurp qw(slurp);
use File::LibMagic;    # rpm: "dnf install perl-File-LibMagic", deb: "apt-get install libfile-libmagic-perl"
use PiFlash::State;
use PiFlash::Command;

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

This class contains internal functions used by L<PiFlash> in the process of collecting data on the system's devices to determine which are SD cards, to avoid accidentally erasing any devices which are not SD cards. This is for automation of the process of flashing an SD card for a Raspberry Pi single-board computer from a Linux system.

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::State>

=head1 BUGS AND LIMITATIONS

Report bugs via GitHub at L<https://github.com/ikluft/piflash/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/piflash/pulls>

=cut

#
# constants
#

# recognized file suffixes which SD cards can be flashed from
Readonly::Array my @known_suffixes => qw(gz zip xz img);

# prefix for functions to process specific file types for embedded boot images
Readonly::Scalar my $process_func_prefix => "process_file_";

# These regex patterns are meant to contain spaces to match libmagic output
## no critic (RegularExpressions::RequireExtendedFormatting)

# list of libmagic file strings corellated to file type strings as pairs
Readonly::Array my @magic_to_type => (
    [ qr(^Zip archive data)i,     "zip" ],
    [ qr(^gzip compressed data)i, "gz" ],
    [ qr(^XZ compressed data)i,   "xz" ],
    [ qr(^DOS\/MBR boot sector)i, "img" ],
);

# list of libmagic file strings corellated to filesystems as pairs
# a code of 1 means use $1 from regex match, and convert it to lower case
Readonly::Array my @magic_to_fs => (
    [ qr(^Linux rev \d+.\d+ (ext[234]) filesystem data,)i, 1 ],
    [ qr(^(\w+) Filesystem)i,                              1 ],
    [ qr(\s+(\w+)\sfilesystem)i,                           1 ],
    [ qr(^DOS\/MBR boot sector, .*, FAT (32 bit),)i,       "vfat" ],
    [ qr(^Linux\/\w+ swap file)i,                          "swap" ],
);
## critic (RegularExpressions::RequireExtendedFormatting)

# block device parameters to collect via lsblk
Readonly::Array my @blkdev_params => qw(MOUNTPOINT FSTYPE SIZE SUBSYSTEMS TYPE MODEL RO RM HOTPLUG PHY-SEC);

#
# system data collection functions
#

# collect data about the system: kernel specs, program locations
sub collect_system_info
{
    my $system = PiFlash::State::system();

    # Make sure we're on a Linux system - this program uses Linux-only features
    ( $system->{sysname}, $system->{nodename}, $system->{release}, $system->{version}, $system->{machine} ) =
        POSIX::uname();
    if ( $system->{sysname} ne "Linux" ) {
        PiFlash::State->error("This depends on features of Linux. Found $system->{sysname} kernel - cannot continue.");
    }

    # hard-code known-secure locations of programs here if you need to override any on your system
    # $prog{name} = "/path/to/name";

    # loop through needed programs and record locations from environment variable or system directories
    $system->{prog} = {};

    # set PATH in environment as a precaution - we don't intend to use it but mkfs does
    # search paths in standard Unix PATH order
    my @path;
    for my $path ( "/sbin", "/usr/sbin", "/bin", "/usr/bin" ) {

        # include in PATH standard Unix directories which exist on this system
        if ( -d $path ) {
            push @path, $path;
        }
    }
    ## no critic (RequireLocalizedPunctuationVars])
    $ENV{PATH} = join ":", @path;
    ## use critic
    $system->{PATH} = $ENV{PATH};

    # find filesystems supported by this kernel (for formatting SD card)
    my %fs_pref     = ( vfat => 1, ext4 => 2, ext3 => 3, ext2 => 4, exfat => 5, other => 6 );    # fs preference order
    my @filesystems = grep { not /^nodev\s/x } slurp("/proc/filesystems");
    chomp @filesystems;
    for ( my $i = 0 ; $i <= $#filesystems ; $i++ ) {

        # remove leading and trailing whitespace;
        $filesystems[$i] =~ s/^\s*//x;
        $filesystems[$i] =~ s/\s*$//x;
    }

    # sort list by decreasing preference (increasing numbers)
    $system->{filesystems} =
        [ sort { ( $fs_pref{$a} // $fs_pref{other} ) <=> ( $fs_pref{$b} // $fs_pref{other} ) } @filesystems ];
    $system->{primary_fs} = $system->{filesystems}[0];

    # find locations where we can put mount points
    foreach my $dir (qw(/run/media /media /mnt)) {
        if ( -d $dir ) {
            PiFlash::State::system( "media_dir", $dir );    # use the first one
            last;
        }
    }
    return;
}

# collect input file info - extra steps for zip file
sub process_file_zip
{
    my $input = PiFlash::State::input();

    # process zip archives
    my @zip_content =
        PiFlash::Command::cmd2str( "unzip - list contents", PiFlash::Command::prog("unzip"), "-l", $input->{path} );
    chomp @zip_content;
    my $found_build_data = 0;
    my @imgfiles;
    my $zip_lastline = pop @zip_content;    # last line contains total size
    {
        my $size = $zip_lastline;           # get last line of unzip output with total size
        $size =~ s/^ \s*//x;                # remove leading whitespace
        $size =~ s/[^\d]*$//x;              # remove anything else after numeric digits
        $input->{size} = $size;
    }
    foreach my $zc_entry (@zip_content) {
        if ( $zc_entry =~ /\sBUILD-DATA$/x ) {
            $found_build_data = 1;
        } elsif ( $zc_entry =~ /^\s*(\d+)\s.*\s([^\s]*)$/x ) {
            push @imgfiles, [ $2, $1 ];
        }
    }

    # detect if the zip archive contains Raspberry Pi NOOBS (New Out Of the Box System)
    if ($found_build_data) {
        my @noobs_version = grep { /^NOOBS Version:/x } PiFlash::Command::cmd2str(
            "unzip - check for NOOBS",
            PiFlash::Command::prog("unzip"),
            "-p", $input->{path}, "BUILD-DATA"
        );
        chomp @noobs_version;
        if ( scalar @noobs_version > 0 ) {
            if ( $noobs_version[0] =~ /^NOOBS Version: (.*)/x ) {
                $input->{NOOBS} = $1;
            }
        }
    }

    # if NOOBS system was not found, look for a *.img file
    if ( not exists $input->{NOOBS} ) {
        if ( scalar @imgfiles == 0 ) {
            PiFlash::State->error("input file is a zip archive but does not contain a *.img file or NOOBS system");
        }
        $input->{imgfile} = $imgfiles[0][0];
        $input->{size}    = $imgfiles[0][1];
    }
    return;
}

# collect input file info - extra steps for gz file
sub process_file_gz
{
    my $input = PiFlash::State::input();

    # process gzip compressed files
    my @gunzip_out = PiFlash::Command::cmd2str(
        "gunzip - list contents",
        PiFlash::Command::prog("gunzip"),
        "--list", "--quiet", $input->{path}
    );
    chomp @gunzip_out;
    my @fields = split ' ', @gunzip_out;
    $input->{size}    = $fields[1];
    $input->{imgfile} = $fields[3];
    return;
}

# collect input file info - extra steps for xz file
sub process_file_xz
{
    my $input = PiFlash::State::input();

    # process xz compressed files
    if ( $input->{path} =~ /^.*\/([^\/]*\.img)\.xz/x ) {
        $input->{imgfile} = $1;
    }
    my @xz_out = PiFlash::Command::cmd2str(
        "xz - list contents",
        PiFlash::Command::prog("xz"),
        "--robot", "--list", $input->{path}
    );
    chomp @xz_out;
    foreach my $xz_line (@xz_out) {
        if ( $xz_line =~ /^file\s+\d+\s+\d+\s+\d+\s+(\d+)/x ) {
            $input->{size} = $1;
            last;
        }
    }
    return;
}

# collect input file info
# verify existence, deduce file type from contents, get size, check for raw filesystem image or NOOBS archive
sub collect_file_info
{
    my $input = PiFlash::State::input();

    # verify input file exists
    if ( not -e $input->{path} ) {
        PiFlash::State->error( "input " . $input->{path} . " does not exist" );
    }
    if ( not -f $input->{path} ) {
        PiFlash::State->error( "input " . $input->{path} . " is not a regular file" );
    }

    # use libmagic/file to collect file data
    # it is collected even if type will be determined by suffix so we can later inspect data further
    {
        my $magic = File::LibMagic->new();
        $input->{info} = $magic->info_from_filename( $input->{path} );
        if (   $input->{info}{mime_type} eq "application/gzip"
            or $input->{info}{mime_type} eq "application/x-xz" )
        {
            my $uncompress_magic = File::LibMagic->new( uncompress => 1 );
            $input->{info}{uncompress} = $uncompress_magic->info_from_filename( $input->{path} );
        }
    }

    # parse the file name
    $input->{parse} = {};
    ( $input->{parse}{name}, $input->{parse}{path}, $input->{parse}{suffix} ) =
        fileparse( $input->{path}, map { "." . $_ } @known_suffixes );

    # use libmagic/file to determine file type from contents
    PiFlash::State::verbose() and say STDERR "input file is a " . $input->{info}{description};
    foreach my $m2t_pair (@magic_to_type) {
        my ( $regex, $type_str) = @$m2t_pair;
        PiFlash::State::verbose() and say STDERR "collect_file_info: check $regex";

        # @magic_to_type constant contains pairs of regex (to match libmagic) and file type string if matched
        if ( $input->{info}{description} =~ $regex ) {
            $input->{type} = $type_str;;
            PiFlash::State::verbose() and say STDERR "collect_file_info: input type = ".$input->{type};
            last;
        }
    }
    if ( not exists $input->{type} ) {
        PiFlash::State->error("collect_file_info(): file type not recognized on $input->{path}");
    }

    # get file size - start with raw file size, update later if it's compressed/archive
    $input->{size} = -s $input->{path};

    # find embedded boot image in archived/compressed files of various formats
    # call the function named by "process_file_" and file type, if it exists
    if ( my $process_func = __PACKAGE__->can( $process_func_prefix . $input->{type} ) ) {

        # call function to process the file type
        $process_func->();
    }
    return;
}

# collect output device info
sub collect_device_info
{
    my $output = PiFlash::State::output();

    # check that device exists
    if ( not -e $output->{path} ) {
        PiFlash::State->error( "output device " . $output->{path} . " does not exist" );
    }
    if ( not -b $output->{path} ) {
        PiFlash::State->error( "output device " . $output->{path} . " is not a block device" );
    }

    # check block device parameters

    # load block device info into %output
    blkparam(@blkdev_params);
    if ( $output->{mountpoint} ne "" ) {
        PiFlash::State->error("output device is mounted - this operation would erase it");
    }
    if ( ( not exists $output->{fstype} ) or $output->{fstype} =~ /^\s*$/x ) {

        # multi-pronged approach to find fstype on output device
        # lsblk in util-linux reads filesystem type but errors out for blank drive, which we must allow
        # blkid can detect a disk or partition - we allow disks but not partitions for output device
        # libmagic can describe the device if all else fails
        $output->{fstype} = get_fstype( $output->{path} ) // "";
    }
    if ( $output->{fstype} eq "swap" ) {
        PiFlash::State->error("output device is a swap device - this operation would erase it");
    }
    if ( $output->{type} eq "part" ) {
        PiFlash::State->error("output device is a partition - Raspberry Pi flash needs whole SD device");
    }

    # check for SD/MMC card via USB or PCI bus interfaces
    if ( not is_sd() ) {
        PiFlash::State->error("output device is not an SD card - this operation would erase it");
    }
}

# blkparam function: get device information with lsblk command
# usage: blkparam(\%output, param-name, ...)
#   output: reference to hash with output device parameter strings
#   param-name: list of parameter names to read into output hash
sub blkparam
{
    my @args = @_;

    # use PiFlash::State::output device unless another hash is provided
    my $blkdev;
    if ( ref( $args[0] ) eq "HASH" ) {
        $blkdev = shift @args;
    } else {
        $blkdev = PiFlash::State::output();
    }

    # get the device's path
    # throw an exception if the device's hash data doesn't have it
    if ( not exists $blkdev->{path} ) {
        PiFlash::State::error("blkparam: device hash does not contain path to device");
    }
    my $path = $blkdev->{path};

    # loop through the requested parameters and get each one for the device with lsblk
    foreach my $paramname (@args) {
        if ( exists $blkdev->{ lc $paramname } ) {

            # skip names of existing data to avoid overwriting
            say STDERR "blkparam(): skipped collection of parameter $paramname to avoid overwriting existing data";
            next;
        }
        my $value = PiFlash::Command::cmd2str(
            "lsblk lookup of $paramname",
            PiFlash::Command::prog("lsblk"),
            "--bytes", "--nodeps", "--noheadings", "--output", $paramname, $path
        );
        if ( $? == -1 ) {
            PiFlash::State->error("blkparam($paramname): failed to execute lsblk: $!");
        } elsif ( $? & 127 ) {
            PiFlash::State->error(
                sprintf "blkparam($paramname): lsblk died with signal %d, %s coredump",
                ( $? & 127 ),
                ( $? & 128 ) ? 'with' : 'without'
            );
        } elsif ( $? != 0 ) {
            PiFlash::State->error( sprintf "blkparam($paramname): lsblk exited with value %d", $? >> 8 );
        }
        chomp $value;
        $value =~ s/^\s*//x;    # remove leading whitespace
        $value =~ s/\s*$//x;    # remove trailing whitespace
        $blkdev->{ lc $paramname } = $value;
    }
    return;
}

# check if a device is an SD card
sub is_sd
{
    my @args = @_;

    # use PiFlash::State::output device unless another hash is provided
    my $blkdev;
    if ( ref( $args[0] ) eq "HASH" ) {
        $blkdev = shift @args;
    } else {
        $blkdev = PiFlash::State::output();
    }

    # check for SD/MMC card via USB or PCI bus interfaces
    if ( $blkdev->{model} eq "SD/MMC" ) {

        # detected SD card via USB adapter
        PiFlash::State::verbose() and say STDERR "output device " . $blkdev->{path} . " is an SD card via USB adapter";
        return 1;
    }

    # check if the SD card driver operates this device
    my $found_mmc  = 0;
    my $found_usb  = 0;
    my @subsystems = split /:/x, $blkdev->{subsystems};
    foreach my $subsystem (@subsystems) {
        if ( $subsystem eq "mmc_host" or $subsystem eq "mmc" ) {
            $found_mmc = 1;
        }
        if ( $subsystem eq "usb" ) {
            $found_usb = 1;
        }
    }
    if ($found_mmc) {

        # verify that the MMC device is actually an SD card
        my $sysfs_devtype_path = "/sys/block/" . basename( $blkdev->{path} ) . "/device/type";
        if ( not -f $sysfs_devtype_path ) {
            PiFlash::State->error( "cannot find output device "
                    . $blkdev->{path}
                    . " type - Linux kernel "
                    . PiFlash::State::system("release")
                    . " may be too old" );
        }
        my $sysfs_devtype = slurp($sysfs_devtype_path);
        chomp $sysfs_devtype;
        PiFlash::State::verbose() and say STDERR "output device " . $blkdev->{path} . " is a $sysfs_devtype";
        if ( $sysfs_devtype eq "SD" ) {
            return 1;
        }
    }

    # allow USB writable/hotplug/removable drives with physical sector size 512
    # this is imprecise because some other non-SD flash devices will be accepted as SD
    # it will still avoid allowing hard drives to be erased
    if ($found_usb) {
        if ( $blkdev->{ro} == 0 and $blkdev->{rm} == 1 and $blkdev->{hotplug} == 1 and $blkdev->{"phy-sec"} == 512 ) {
            PiFlash::State::verbose()
                and say STDERR "output device " . $blkdev->{path}
                    . " close enough: USB removable writable hotplug ps=512";
            return 1;
        }
    }

    PiFlash::State::verbose() and say STDERR "output device " . $blkdev->{path} . " rejected as SD card";
    return 0;
}

# search for and print names of SD card devices
sub sd_search
{
    # add block devices to system info
    my $system = PiFlash::State::system();
    $system->{blkdev} = {};

    # loop through available devices - collect info and print list of available SD cards
    my @blkdev = PiFlash::Command::cmd2str(
        "lsblk - find block devices",
        PiFlash::Command::prog("lsblk"),
        "--nodeps", "--noheadings", "--list", "--output", "NAME"
    );
    my @sdcard;
    foreach my $blkdevname (@blkdev) {
        $system->{blkdev}{$blkdevname} = {};
        my $blkdev = $system->{blkdev}{$blkdevname};
        $blkdev->{path} = "/dev/$blkdevname";
        blkparam( $blkdev, @blkdev_params );
        if ( is_sd($blkdev) ) {
            push @sdcard, $blkdev->{path};
        }
    }

    # print results of SD search
    if ( scalar @sdcard == 0 ) {
        say "no SD cards found on system";
    } else {
        say "SD cards found: " . join( " ", @sdcard );
    }
    return;
}

# base function: get basename from a file path
sub base
{
    my $path     = shift;
    my $filename = File::Basename::fileparse( $path, () );
    return $filename;
}

# get filesystem type info
# workaround for apparent bug in lsblk (from util-linux) which omits requested FSTYPE data when in the background
# use blkid or libmagic if it fails
sub get_fstype
{
    my $devpath = shift;
    my $fstype;
    try {
        $fstype = PiFlash::Command::cmd2str(
            "use lsblk to get fs type for $devpath",
            PiFlash::Command::prog("sudo"),
            PiFlash::Command::prog("lsblk"),
            "--nodeps", "--noheadings", "--output", "FSTYPE", $devpath
        );
    } catch {
        undef $fstype;
    };

    # fallback: use blkid
    if ( ( not defined $fstype ) or $fstype =~ /^\s*$/x ) {
        try {
            $fstype = PiFlash::Command::cmd2str(
                "use blkid to get fs type for $devpath",
                PiFlash::Command::prog("sudo"),
                PiFlash::Command::prog("blkid"),
                "--probe", "--output=value", "--match-tag=TYPE", $devpath
            );
        } catch {
            undef $fstype;
        };
    }

    # fallback 2: use File::LibMagic as backup filesystem type lookup
    if ( ( not defined $fstype ) or $fstype =~ /^\s*$/x ) {
        my $magic = File::LibMagic->new();
        $fstype = undef;
        $magic->{flags} |= File::LibMagic::MAGIC_DEVICES;    # undocumented trick for equivalent of "file -s" on device
        my $magic_data = $magic->info_from_filename($devpath);
        if ( PiFlash::State::verbose() ) {
            for my $key ( keys %$magic_data ) {
                say STDERR "get_fstype: magic_data/$key = " . $magic_data->{$key};
            }
        }

        # use @magic_to_fs table to check regexes against libmagic result
        foreach my $m2f_pair (@magic_to_fs) {

            # @magic_to_fs constant contains pairs of regex (to match libmagic) and filesystem if matched
            PiFlash::State::verbose() and say STDERR "get_fstype: check ".$m2f_pair->[0];
            if ( $magic_data->{description} =~ $m2f_pair->[0] ) {
                if ( $m2f_pair->[1] == 1 ) {
                    $fstype = $1;
                } else {
                    $fstype = $m2f_pair->[1];
                }
                last;
            }
        }
    }

    # return filesystem type string, or undef if not determined
    defined $fstype and chomp $fstype;
    PiFlash::State::verbose() and say STDERR "get_fstype($devpath) = " . ( $fstype // "undef" );
    return $fstype;
}

1;
