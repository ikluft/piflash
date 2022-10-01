#!/usr/bin/perl
# 021_plugin.t - tests for PiFlash plugin interface

use strict;
use warnings;
use autodie;
use Test::More;
use File::Basename;
use PiFlash;
use PiFlash::State;
use Data::Dumper;

# detect debug mode from environment
# run as "DEBUG=1 perl -Ilib t/021_plugin.t" to get debug output to STDERR
my $debug_mode = exists $ENV{DEBUG};

# base class for plugin testing and 3 test classes that inhert from it
package TestBase {
    use parent 'PiFlash::Plugin';

    # init class method is part of the plugin interface
    # called from PiFlash::Object->new() via PiFlash::Plugin->init_plugins()
    sub init
    {
        my $self = shift;

        # save data indicating which class/subclass was here
        $self->{class}  = ref $self;
        $self->{status} = "enabled";
    }
};

package PiFlash::Plugin::Test1 {
    our @ISA = 'TestBase';
};

package PiFlash::Plugin::Test2 {
    our @ISA = 'TestBase';
};

package PiFlash::Plugin::Test3 {
    our @ISA = 'TestBase';
};

# initialize program state storage
my @top_level_params = qw(cli_opt config plugin);
PiFlash::State->init(@top_level_params);

# function with tests to run enabled/disabled combinations of test classes
sub plugin_tests
{
    my $filepath = shift;
    my $bits     = shift;
    my $mode     = shift;

    # clear cli_opt/plugin/config in PiFlash::State
    my $pif_state = PiFlash::State->instance();
    foreach my $category (@top_level_params) {
        $pif_state->{$category} = {};
    }

    # read the config file
    # must do this before setting configs to load modules, otherwise it would overwrite those configs
    eval { PiFlash::State::read_config($filepath); };
    if ($@) {

        # do not design errors into the config files for plugin tests
        # do that in 020_config_yaml.t which should be done before this test script
        BAIL_OUT("plugin config file $filepath threw exception $@");
    }

    # enable selected test plugin modules
    my @plugins;
    for ( my $modnum = 0 ; $modnum < scalar @$bits ; $modnum++ ) {
        if ( $bits->[$modnum] ) {
            push @plugins, sprintf "Test%d", $modnum + 1;
        }
    }
    if (@plugins) {
        my $plugin_str = join( ",", @plugins );
        $debug_mode and print STDERR "debug plugin_tests: plugins(" . join( "", @$bits ) . "): $plugin_str\n";
        if ( $mode eq "cli" ) {
            PiFlash::State::cli_opt( "plugin", $plugin_str );
        } elsif ( $mode eq "cfg" ) {
            PiFlash::State::config( "plugin", $plugin_str );
        } else {
            BAIL_OUT( "unknown test mode: '" . ( $mode // "undef" ) . "'" );
        }
    }
    my $test_name = $mode . join( "", @$bits );

    # initialize the plugins
    eval { PiFlash::Plugin->init_plugins(); };

    # run tests
    my $plugin_data = PiFlash::State::plugin();
    is( "$@", '', "$filepath/$test_name 1: no exceptions" );
    for ( my $modnum = 0 ; $modnum < scalar @$bits ; $modnum++ ) {
        my $modname      = sprintf "Test%d", $modnum + 1;
        my $plugin_class = "PiFlash::Plugin::" . $modname;
        my $plugin_obj   = $plugin_class->get_data();
        my $subtest      = $modnum * 2 + 2;
        if ( $bits->[$modnum] ) {
            is( $plugin_obj->{status}, "enabled", "$filepath/$test_name/$modnum " . ($subtest) . ": enabled" );
            is_deeply(
                $plugin_obj->{config},
                $plugin_data->{docs}{$modname},
                "$filepath/$test_name/$modnum " . ( $subtest + 1 ) . ": data match"
            );
        } else {
            ok( !PiFlash::State::has_plugin($modname), "$filepath/$test_name/$modnum " . ($subtest) . ": disabled" );
            pass( "$filepath/$test_name/$modnum " . ( $subtest + 1 ) . ": no data" )
                ;    # always missing if module is missing
        }
    }
    $debug_mode and print STDERR "debug plugin_tests: " . Dumper($pif_state);
}

# read list of test input files from subdirectory with same basename as this script
my $input_dir = "t/test-inputs/" . basename( $0, ".t" );
if ( !-d $input_dir ) {
    BAIL_OUT("can't find test inputs directory: expected $input_dir");
}
opendir( my $dh, $input_dir ) or BAIL_OUT("can't open $input_dir directory");
my @files = sort grep { /^[^.]/ and -f "$input_dir/$_" } readdir($dh);
closedir $dh;

# compute number of tests:
#    8 combinations of enabled/disabled plugins for 3 test classes (2^3) to check for interference between plugins
#    x 2 passes enabling plugins from CLI or config
#    x 7 tests per file
#    x n files
plan tests => 8 * 2 * 7 * ( scalar @files );

# run plugin_tests() for each file
foreach my $file (@files) {
    for ( my $i = 0 ; $i < 8 ; $i++ ) {

        # use $i's binary bits to make an array of true/false enabled state for 3 test modules
        my @bits;
        for ( my $bit = 2 ; $bit >= 0 ; $bit-- ) {
            push @bits, $i & ( 2**$bit ) ? 1 : 0;
        }

        # run each test mode (enabling plugins from CLI or config)
        foreach my $mode (qw(cli cfg)) {
            plugin_tests( "$input_dir/$file", \@bits, $mode );
        }
    }
}

1;
