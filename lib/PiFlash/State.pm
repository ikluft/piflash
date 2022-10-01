# PiFlash::State - store program-site state information for PiFlash
# by Ian Kluft
#
# the information stored here includes configuration,command-line arguments, system hardware inspection results, etc
#

# pragmas to silence some warnings from Perl::Critic
## no critic (Modules::RequireExplicitPackage)
# This solves a catch-22 where parts of Perl::Critic want both package and use-strict to be first
use strict;
use warnings;
use utf8;
use 5.01400;    # require 2011 or newer version of Perl
## use critic (Modules::RequireExplicitPackage)

# State class to hold program state, and print it all out in case of errors
# this is a low-level package - it stores state data but at this level has no knowledge of what is being stored in it
package PiFlash::State;

use base 'Class::Singleton';
use autodie;
use YAML::XS;    # RPM: perl-YAML-LibYAML, DEB: libyaml-libyaml-perl
use Carp qw(croak);

# ABSTRACT: PiFlash::State class to store configuration, device info and program state

=head1 SYNOPSIS

 # initialize: creates empty sub-objects and accessor functions as shown below
 PiFlash::State->init("system", "input", "output", "cli_opt", "log");

 # better initialization - use PiFlash's state category list function
 my @categories = PiFlash::state_categories();
 PiFlash::State->init(@categories);

 # core functions
 $bool_verbose_mode = PiFlash::State::verbose()
 $bool_logging_mode = PiFlash::State::logging()
 PiFlash::State::odump
 PiFlash::State->error("error message");

 # system accessors
 my $system = PiFlash::State::system();
 my $bool = PiFlash::State::has_system($key);
 my $value = PiFlash::State::system($key);
 PiFlash::State::system($key, $value);

 # input accessors
 my $input = PiFlash::State::input();
 my $bool = PiFlash::State::has_input($key);
 my $value = PiFlash::State::input($key);
 PiFlash::State::input($key, $value);

 # output accessors
 my $output = PiFlash::State::output();
 my $bool = PiFlash::State::has_output($key);
 my $value = PiFlash::State::output($key);
 PiFlash::State::output($key, $value);

 # cli_opt accessors
 my $cli_opt = PiFlash::State::cli_opt();
 my $bool = PiFlash::State::has_cli_opt($key);
 my $value = PiFlash::State::cli_opt($key);
 PiFlash::State::cli_opt($key, $value);

 # log accessors
 my $log = PiFlash::State::log();
 my $bool = PiFlash::State::has_log($key);
 my $value = PiFlash::State::log($key);
 PiFlash::State::log($key, $value);

=head1 DESCRIPTION

This class contains internal functions used by L<PiFlash> to store command-line parameters, input & output file data, available device data and program logs.

PiFlash uses the device info to refuse to write/destroy a device which is not an SD card. This provides a safeguard while using root permissions against a potential error which has happened where users have accidentally erased the wrong block device, losing a hard drive they wanted to keep.

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::Inspector>

=head1 BUGS AND LIMITATIONS

Report bugs via GitHub at L<https://github.com/ikluft/piflash/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/piflash/pulls>

=cut

# initialize class' singleton object from parameters
# class method
sub init
{
    my ( $class, @args ) = @_;
    defined $class
        or croak "init: class parameter not received";
    if ( $class ne __PACKAGE__ ) {

        # Arguably this should have been a class function and not a method. Since it's a method and user code
        # may call it, for compatibility that won't be changed now. Enforce use only for this class.
        croak "init() method serves only " . __PACKAGE__;
    }
    if ( __PACKAGE__->has_instance() ) {
        my $instance = __PACKAGE__->instance();
        if ( ( scalar keys %$instance ) > 0 ) {
            return;    # avoid overwriting existing data if called again
        }
    }

    # global security settings for YAML::XS parser
    # since PiFlash can run parts as root, we must not allow external code to be run without user authorization
    ## no critic (Variables::ProhibitPackageVars)
    $YAML::XS::LoadBlessed = 0;
    $YAML::XS::UseCode     = 0;
    $YAML::XS::LoadCode    = 0;
    ## critic (Variables::ProhibitPackageVars)

    # instantiate the state object as a singleton (only one instance in the system)
    my $self = __PACKAGE__->instance();

    # loop through parameters adding each name as a top-level state hash and accessor functions
    while ( scalar @args > 0 ) {
        my $top_level_param = shift @args;

        # create top-level hash named for the parameter
        $self->{$top_level_param} = {};

        # generate class accessor methods named for the parameter
        {
            ## no critic (ProhibitNoStrict)
            no strict qw(refs);

            # accessor fieldname()
            if ( not __PACKAGE__->can($top_level_param) ) {
                *{ __PACKAGE__ . "::" . $top_level_param } = sub {
                    return __PACKAGE__->accessor( $top_level_param, @_ );
                };
            }

            # accessor has_fieldname()
            if ( not __PACKAGE__->can( "has_" . $top_level_param ) ) {
                *{ __PACKAGE__ . "::has_" . $top_level_param } = sub {
                    return __PACKAGE__->has( $top_level_param, @_ );
                };
            }
        }
    }
    return;
}

# get top level state
# This takes no parameters. It can be called as a class function or method.
sub get_state
{
    my ( $caller_package, $filename, $line ) = caller;
    if ( $caller_package ne __PACKAGE__ ) {
        croak __PACKAGE__ . " internal-use-only method called by $caller_package at $filename line $line";
    }
    return __PACKAGE__->instance();
}

# state value get/set accessor
# class method
sub accessor
{
    my ( $class, $top_level_param, $name, $value ) = @_;
    my $self = $class->get_state();

    if ( defined $value ) {

        # got name & value - set the new value for name
        $self->{$top_level_param}{$name} = $value;
        return $value;
    }

    if ( defined $name ) {

        # got only name - return the value/ref of name
        return ( exists $self->{$top_level_param}{$name} )
            ? $self->{$top_level_param}{$name}
            : undef;
    }

    # no name or value - return ref to top-level hash (top_level_parameter from init() context)
    return $self->{$top_level_param};
}

# check if a top level state has a key
# class method
sub has
{
    my ( $class, $top_level_param, $name ) = @_;
    my $self = $class->get_state();
    return ( ( exists $self->{$top_level_param} ) and ( exists $self->{$top_level_param}{$name} ) );
}

# return boolean value for verbose mode
sub verbose
{
    return PiFlash::State::cli_opt("verbose") // 0;
}

# return boolean value for logging mode (recording run data without printing verbose messages, intended for testing)
sub logging
{
    return PiFlash::State::cli_opt("logging") // 0;
}

# dump data structure recursively, part of verbose/logging state output
# intended as a lightweight equivalent of Data::Dumper without requiring installation of an extra package
# object method
sub odump
{
    my ( $obj, $level ) = @_;
    if ( not defined $obj ) {

        # bail out for undefined value
        return "";
    }
    if ( not ref $obj ) {

        # process plain scalar
        return ( "    " x $level ) . "[value]" . $obj . "\n";
    }
    if ( ref $obj eq "SCALAR" ) {

        # process scalar reference
        return ( "    " x $level ) . ( $$obj // "undef" ) . "\n";
    }
    if (   ref $obj eq "HASH"
        or ref $obj eq __PACKAGE__
        or ( ref $obj =~ /^PiFlash::/x and $obj->isa("PiFlash::Object") ) )
    {
        # process hash reference
        my $str = "";
        foreach my $key ( sort { lc $a cmp lc $b } keys %$obj ) {
            if ( ref $obj->{$key} ) {
                $str .= ( "    " x $level ) . "$key:" . "\n";
                $str .= odump( $obj->{$key}, $level + 1 );
            } else {
                $str .= ( "    " x $level ) . "$key: " . ( $obj->{$key} // "undef" ) . "\n";
            }
        }
        return $str;
    }
    if ( ref $obj eq "ARRAY" ) {

        # process array reference
        my $str = "";
        foreach my $entry (@$obj) {
            if ( ref $entry ) {
                $str .= odump( $entry, $level + 1 );
            } else {
                $str .= ( "    " x $level ) . "$entry\n";
            }
        }
        return $str;
    }
    if ( ref $obj eq "CODE" ) {

        # process function reference
        return ( "    " x $level ) . "[function]$obj" . "\n";
    }

    # other references/unknown type
    my $type = ref $obj;
    return ( "    " x $level ) . "[$type]$obj" . "\n";
}

# die/exception with verbose state dump
# class method
sub error
{
    my ( $class, $message ) = @_;
    croak "error: " . $message
        . ( ( verbose() or logging() ) ? "\nProgram state dump...\n" . odump( __PACKAGE__->get_state(), 0 ) : "" );
}

# read YAML configuration file
sub read_config
{
    my $filepath = shift;

    # if the provided file name exists and ...
    if ( -f $filepath ) {

        # capture as many YAML documents as can be parsed from the configuration file
        my @yaml_docs = eval { YAML::XS::LoadFile($filepath); };
        if ($@) {
            __PACKAGE__->error( __PACKAGE__ . "::read_config error reading $filepath: $@" );
        }

        # save the first YAML document as the configuration
        my $yaml_config = shift @yaml_docs;
        if ( ref $yaml_config eq "HASH" ) {

            # if it's a hash, then use all its mappings in PiFlash::State::config
            my $pif_state = __PACKAGE__->get_state();
            $pif_state->{config} = $yaml_config;
        } else {

            # otherwise save the reference in a config entry called config
            PiFlash::State::config( "config", $yaml_config );
        }

        # if any other YAML documents were parsed, save them as a list in a config called "docs"
        # these are available for plugins but not currently defined
        if (@yaml_docs) {

            # save the YAML doc structures as a list
            PiFlash::State::config( "docs", \@yaml_docs );

            # the first doc must be the table of contents with a list of metadata about following docs
            # others after that are categorized by the plugin name in the metadata
            my $toc = $yaml_docs[0];
            if ( ref $toc eq "ARRAY" ) {
                PiFlash::State::plugin( "docs", { toc => $toc } );
                my $docs = PiFlash::State::plugin("docs");
                for ( my $i = 1 ; $i < scalar @yaml_docs ; $i++ ) {
                    ( $i <= scalar @$toc ) or next;
                    if ( ref $yaml_docs[$i] eq "HASH" and exists $toc->[ $i - 1 ]{type} ) {
                        my $type = $toc->[ $i - 1 ]{type};
                        $docs->{$type} = $yaml_docs[$i];
                    }
                }
            }
        }
    }
    return;
}

1;
