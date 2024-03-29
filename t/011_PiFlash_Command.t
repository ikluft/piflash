#!/usr/bin/perl
# 011PiFlash_Command.t - tests for PiFlash::Command module

use strict;
use warnings;
use autodie;

use Test::More;
use PiFlash;
use PiFlash::State;
use PiFlash::Command;
use Data::Dumper;

# detect debug mode from environment
# run as "DEBUG=1 perl -Ilib t/011PiFlash_Command.t" to get debug output to STDERR
my $debug_mode = exists $ENV{DEBUG};

# expand parameter variable names in parameters
sub expand
{
    my $varhash    = shift;
    my $varname    = shift;
    my $prog       = PiFlash::State::system("prog");
    my $varname_re = join( '|', ( keys %$varhash, keys %$prog ) );
    my $value      = $varhash->{$varname} // "";
    if ( ref $value eq "ARRAY" ) {
        for ( my $i = 0 ; $i < scalar @$value ; $i++ ) {
            ( defined $value->[$i] ) or next;
            while ( $value->[$i] =~ /\$($varname_re)/ ) {
                my $match = $1;
                my $subst = $varhash->{$match} // $prog->{$match};
                $value->[$i] =~ s/\$$match/$subst/g;
            }
        }
    } else {
        while ( $value =~ /\$($varname_re)/ ) {
            my $match = $1;
            my $subst = $varhash->{$match} // $prog->{$match};
            $value =~ s/\$$match/$subst/g;
        }
    }
    return $value;
}

# find a program's expected location to verify PiFlash::Command::prog()
sub find_prog
{
    my $prog = shift;

    foreach my $path ( "/usr/bin", "/sbin", "/usr/sbin", "/bin" ) {
        if ( -x "$path/$prog" ) {
            return "$path/$prog";
        }
    }

    # return undef value by default
}

# test PiFlash::Command::prog()
sub test_prog
{
    my $params   = shift;                            # hash structure of test parameters
    my $prog     = PiFlash::State::system("prog");
    my $progname = expand( $params, "progname" );
    my ( $progpath, $exception );

    # set test-fixture data in environment if provided
    my %saved_env;
    my $need_restore_env = 0;
    if ( ( exists $params->{env} ) and ( ref $params->{env} eq "HASH" ) ) {
        foreach my $key ( keys %{ $params->{env} } ) {
            if ( exists $ENV{$key} ) {
                $saved_env{$key} = $ENV{$key};
            }
            $ENV{$key} = $params->{env}{$key};
        }
        $need_restore_env = 1;
    }

    # run the prog function to locate the selected program's path
    $debug_mode and warn "prog test for $progname";
    eval { $progpath = PiFlash::Command::prog($progname) };
    $exception = $@;

    # test and report results
    my $test_set = "path " . $params->{test_set_suffix};
    if ($debug_mode) {
        if ( exists $prog->{$progname} ) {
            warn "comparing " . $prog->{$progname} . " eq $progpath";
        } else {
            warn "$progname cache missing\n" . Dumper($prog);
        }
    }
    if ( !exists $params->{expected_exception} ) {
        is( $prog->{$progname}, $progpath, "$test_set: path in cache: $progname -> " . ( $progpath // "(undef)" ) );
        if ( defined $progpath ) {
            ok( -x $progpath, "$test_set: path points to executable program" );
        } else {
            fail("$test_set: path points to executable program (undefined)");
        }
        is( $exception, '', "$test_set: no exceptions" );

        # verify program is in expected location
        my $expected_path = find_prog($progname);
        my $envprog       = PiFlash::Command::envprog($progname);
        my $reason        = "default";
        if ( exists $ENV{$envprog} and -x $ENV{$envprog} ) {
            if ( -x $expected_path ) {
                $reason = "default, ignore ENV{$envprog}";
            } else {
                $expected_path = $ENV{$envprog};
                $reason        = "ENV{$envprog}";
            }
        }
        is( $progpath, $expected_path, "$test_set: expected at $expected_path by $reason" );
    } else {
        ok( !exists $prog->{$progname}, "$test_set: path not in cache as expected after exception" );
        is( $progpath, undef, "$test_set: path undefined after expected exception" );
        my $expected_exception = expand( $params, "expected_exception" );
        like( $exception, qr/$expected_exception/, "$test_set: expected exception" );
        pass("$test_set: $progname has no location due to expected exception");
    }

    # restore environment and remove test-fixture data from it
    if ($need_restore_env) {
        foreach my $key ( keys %{ $params->{env} } ) {
            if ( exists $ENV{$key} ) {
                $ENV{$key} = $saved_env{$key};
            } else {
                delete $ENV{$key};
            }
        }
    }
}

# function to check log results in last command in log
sub check_cmd_log
{
    my $key            = shift;
    my $expected_value = shift;
    my $params         = shift;

    # fetch the log value for comparison
    my $log       = PiFlash::State::log("cmd");
    my $log_entry = $log->[ ( scalar @$log ) - 1 ];
    my $log_value = $log_entry->{$key};

    # if it's an array, loop through to compare elements
    if ( ref $expected_value eq "ARRAY" ) {
        if ( ref $log_value ne "ARRAY" ) {

            # mismatch if both are not array refs
            $debug_mode and warn "mismatch ref type: log value not ARRAY";
            return 0;
        }
        if ( $log_value->[ ( scalar @$log_value ) - 1 ] eq "" ) {

            # eliminate blank last line for comparison due to appended newline
            pop @$log_value;
        }
        if ( ( scalar @$expected_value ) != ( scalar @$log_value ) ) {

            # mismatch if result arrays are different numbers of lines
            $debug_mode
                and warn "mismatch array length " . ( scalar @$expected_value ) . " != " . ( scalar @$log_value );
            return 0;
        }
        my $i;
        for ( $i = 0 ; $i < scalar @$expected_value ; $i++ ) {
            if ( $expected_value->[$i] ne $log_value->[$i] ) {

                # mismatch if any lines aren't equal
                $debug_mode and warn "mismatch line: $expected_value->[$i] ne $log_value->[$i]";
                return 0;
            }
        }
        return 1;    # if we got here, it's a match
    }

    # if both values are undefined, that's a special case match because eq operator doesn't like them
    if ( ( !defined $expected_value ) and ( !defined $log_value ) ) {
        return 1;
    }

    # with previous case tested, they are not both undefined; so undef in either is a mismatch
    if ( ( !defined $expected_value ) or ( !defined $log_value ) ) {
        $debug_mode and warn "mismatch on one undef";
        return 0;
    }

    # otherwise compare values
    chomp $log_value;
    if ( ( exists $params->{regex} ) and $params->{regex} ) {
        return $expected_value =~ qr/$log_value/;
    }
    return $expected_value eq $log_value;
}

# test PiFlash::Command::fork_exec()
# function to run a set of tests on a fork_exec command
sub test_fork_exec
{
    my $params = shift;    # hash structure of test parameters

    my ( $out, $err, $exception );
    my $cmdname = expand( $params, "cmdname" );
    my $cmdline = expand( $params, "cmdline" );

    # run command
    $debug_mode and warn "running '$cmdname' as: " . join( " ", @$cmdline );
    eval { ( $out, $err ) = PiFlash::Command::fork_exec( ( $params->{input} // () ), $cmdname, @$cmdline ) };
    $exception = $@;

    # tweak captured data for comparison
    chomp $out if defined $out;
    chomp $err if defined $err;

    # test and report results
    my $test_set = "fork_exec " . $params->{test_set_suffix};
    ok( check_cmd_log( "cmdname", $cmdname ), "$test_set: command name logged: $cmdname" );
    ok( check_cmd_log( "cmdline", $cmdline ), "$test_set: command line logged: " . join( " ", @$cmdline ) );
    if ( exists $params->{expected_exception} ) {
        my $expected_exception = expand( $params, "expected_exception" );
        like( $exception, qr/$expected_exception/, "$test_set: expected exception" );
    } else {
        is( $exception, '', "$test_set: no exceptions" );
    }
    if ( exists $params->{expected_signal} ) {
        my $expected_signal = expand( $params, "expected_signal" );
        ok( check_cmd_log( "signal", $expected_signal, { regex => 1 } ), "$test_set: $expected_signal" );
    } else {
        ok( check_cmd_log( "signal", undef ), "$test_set: no signals" );
    }
    ok( check_cmd_log( "returncode", $params->{returncode} ), "$test_set: returncode is $params->{returncode}" );
    is( $out, $params->{expected_out}, "$test_set: output capture match" );
    ok( check_cmd_log( "out", $params->{expected_out} ), "$test_set: output log match" );
    is( $err, $params->{expected_err}, "$test_set: error capture match" );
    ok( check_cmd_log( "err", $params->{expected_err} ), "$test_set: error log match" );
}

#
# lists of tests
#

# strings used for tests
# test string: uses Latin text for intention to appear obviously out of place outside the context of these tests
my $test_string = "Ad astra per alas porci";

# (what it means: Latin for "to the stars on the wings of a pig", motto used by author John Steinbeck after a teacher
# once told him he'd only be a successful writer when pigs fly)

# test PiFlash::Command::prog() and check for existence of prerequisite programs for following tests
my $trueprog = find_prog("true");
if ( !defined $trueprog ) {
    BAIL_OUT("This system doesn't have a 'true' program? Tests were counting on one to be there.");
}

# test fixtures for program path tests
# these also fill the path cache for commands used in later fork-exec tests
my @prog_tests = (
    { progname => "true" },
    { progname => "false" },
    { progname => "cat" },
    { progname => "echo" },
    { progname => "sh" },
    { progname => "kill" },
    {
        progname           => "xyzzy-notfound",
        expected_exception => "unknown secure location for \$progname",
    },
    {
        env      => { XYZZY_NOTFOUND_PROG => $trueprog },
        progname => "xyzzy-notfound",
    },
    {
        env      => { ECHO_PROG => $trueprog },
        progname => "echo",
    },
);

# data for fork_exec() test sets
my @fork_exec_tests = (

    # test capturing true result with fork_exec()
    # runs command: true
    {
        cmdname      => "true command",
        cmdline      => [q{$true}],
        returncode   => 0,
        expected_out => undef,
        expected_err => undef,
    },

    # test capturing false result with fork_exec()
    # runs command: false
    # exception expected during this test
    {
        cmdname            => "false command",
        cmdline            => [q{$false}],
        returncode         => 1,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command exited with value \$returncode",
    },

    # test capturing output of a fixed string from a program with fork_exec()
    # runs command: echo "$test_string"
    {
        cmdname      => "echo string to stdout",
        cmdline      => [ q{$echo}, $test_string ],
        returncode   => 0,
        expected_out => $test_string,
        expected_err => undef,
    },

    # test capturing an error output
    {
        cmdname      => "echo string to stderr",
        cmdline      => [ q{$sh}, "-c", qq{\$echo $test_string >&2} ],
        returncode   => 0,
        expected_out => undef,
        expected_err => $test_string,
    },

    # test sending input and receiving the same string back as output from a program with fork_exec()
    # runs command: cat
    # input piped to the program: $test_string
    {
        input        => [$test_string],
        cmdname      => "cat input to output",
        cmdline      => [q{$cat}],
        returncode   => 0,
        expected_out => $test_string,
        expected_err => undef,
    },

    # test sending input and receiving the same string back in stderr with fork_exec()
    # runs command: cat
    # input piped to the program: $test_string
    {
        input        => [$test_string],
        cmdname      => "cat input to stderr",
        cmdline      => [ q{$sh}, "-c", qq{\$cat >&2} ],
        returncode   => 0,
        expected_out => undef,
        expected_err => $test_string,
    },

    # test capturing an error 1 result
    # exception expected during this test
    {
        cmdname            => "return errorcode \$returncode",
        cmdline            => [ q{$sh}, "-c", q{exit $returncode} ],
        returncode         => 1,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command exited with value \$returncode",
    },

    # test capturing an error 2 result
    # exception expected during this test
    {
        cmdname            => "return errorcode \$returncode",
        cmdline            => [ q{$sh}, "-c", q{exit $returncode} ],
        returncode         => 2,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command exited with value \$returncode",
    },

    # test capturing an error 3 result
    # exception expected during this test
    {
        cmdname            => "return errorcode \$returncode",
        cmdline            => [ q{$sh}, "-c", q{exit $returncode} ],
        returncode         => 3,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command exited with value \$returncode",
    },

    # test capturing an error 255 result
    # exception expected during this test
    {
        cmdname            => "return errorcode \$returncode",
        cmdline            => [ q{$sh}, "-c", q{exit $returncode} ],
        returncode         => 255,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command exited with value \$returncode",
    },

    # test receiving signal 1 SIGHUP
    {
        cmdname            => "signal \$signal SIGHUP",
        cmdline            => [ q{$sh}, "-c", q{$kill -$signal $$} ],
        signal             => 1,
        returncode         => 0,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command died with signal \$signal,",
        expected_signal    => "signal \$signal",
    },

    # test receiving signal 2 SIGINT
    {
        cmdname            => "signal \$signal SIGINT",
        cmdline            => [ q{$sh}, "-c", q{$kill -$signal $$} ],
        signal             => 2,
        returncode         => 0,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command died with signal \$signal,",
        expected_signal    => "signal \$signal",
    },

    # test receiving signal 9 SIGKILL
    {
        cmdname            => "signal \$signal SIGKILL",
        cmdline            => [ q{$sh}, "-c", q{$kill -$signal $$} ],
        signal             => 9,
        returncode         => 0,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command died with signal \$signal,",
        expected_signal    => "signal \$signal",
    },

    # test receiving signal 15 SIGTERM
    {
        cmdname            => "signal \$signal SIGTERM",
        cmdline            => [ q{$sh}, "-c", q{$kill -$signal $$} ],
        signal             => 15,
        returncode         => 0,
        expected_out       => undef,
        expected_err       => undef,
        expected_exception => "\$cmdname command died with signal \$signal,",
        expected_signal    => "signal \$signal",
    },
);

plan tests => 1 + ( scalar @prog_tests ) * 4 + ( scalar @fork_exec_tests ) * 9;

# initialize program state storage
my @top_level_params = PiFlash::state_categories();
PiFlash::State->init(@top_level_params);
PiFlash::State::cli_opt( "logging", 1 );    # logging required to keep logs of commands (like verbose but no output)

# test forking a simple process that returns a true value using fork_child()
{
    my $pid = PiFlash::Command::fork_child(
        sub {
            # in child process
            return 0;    # 0 = success on exit of a program; test is successful if received by parent process
        }
    );
    waitpid( $pid, 0 );
    my $returncode = $? >> 8;
    is( $returncode, 0, "simple fork test" );
}

# run fork_exec() tests
PiFlash::Command::prog();    # init cache
{
    my $count = 0;
    foreach my $prog_test (@prog_tests) {
        $count++;
        $prog_test->{test_set_suffix} = $count;
        test_prog($prog_test);
    }
}

# use prog cache from previous tests to check for existence of prerequisite programs for following tests
my $prog       = PiFlash::State::system("prog");
my @prog_names = qw(true false cat echo sh kill);
my @missing;
foreach my $progname (@prog_names) {
    if ( !exists $prog->{$progname} ) {
        push @missing, $progname;
    }
}
if (@missing) {
    BAIL_OUT( "missing command required for tests: " . join( " ", @missing ) );
}

# run fork_exec() tests
{
    my $count = 0;
    foreach my $fe_test (@fork_exec_tests) {
        $count++;
        $fe_test->{test_set_suffix} = $count;
        test_fork_exec($fe_test);
    }
}

$debug_mode and warn PiFlash::State::odump( PiFlash::State::get_state(), 0 );

1;
