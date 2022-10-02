# PiFlash::Command - run commands including fork paramaters and piping input & output
# by Ian Kluft

# pragmas to silence some warnings from Perl::Critic
## no critic (Modules::RequireExplicitPackage)
# This solves a catch-22 where parts of Perl::Critic want both package and use-strict to be first
use strict;
use warnings;
use utf8;
## use critic (Modules::RequireExplicitPackage)

package PiFlash::Command;

use autodie;
use POSIX;                          # included with perl
use IO::Handle;                     # rpm: "dnf install perl-IO", deb: included with perl
use IO::Poll qw(POLLIN POLLHUP);    # same as IO::Handle
use Carp qw(carp croak);
use PiFlash::State;

# ABSTRACT: process/command running utilities for piflash

=head1 SYNOPSIS

 PiFlash::Command::cmd( label, command_line)
 PiFlash::Command::cmd2str( label, comannd_line)
 PiFlash::Command::prog( "program-name" )

=head1 DESCRIPTION

This class contains internal functions used by L<PiFlash> to run programs and return their status, as well as piping
their input and output.

=head1 SEE ALSO

L<piflash>, L<PiFlash::Inspector>, L<PiFlash::State>

=head1 BUGS AND LIMITATIONS

Report bugs via GitHub at L<https://github.com/ikluft/piflash/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/piflash/pulls>

=cut

# fork wrapper function
# borrowed from Aaron Crane's YAPC::EU 2009 presentation slides online
sub fork_child
{
    my ($child_process_code) = @_;

    # fork and catch errors
    my $pid = fork;
    if ( !defined $pid ) {
        PiFlash::State->error("Failed to fork: $!\n");
    }

    # if in parent process, return child pid
    if ( $pid != 0 ) {
        return $pid;
    }

    # if in child process, run requested code
    my $result = $child_process_code->();

    # if we got here, child code returned - so exit to end the subprocess
    exit $result;
}

# command logging function
sub cmd_log
{
    my @args = @_;

    # record all command return codes, stdout & stderr in a new top-level store in State
    # it's overhead but useful for problem-reporting, troubleshooting, debugging and testing
    if ( PiFlash::State::verbose() or PiFlash::State::logging() ) {
        my $log = PiFlash::State::log();
        if ( !exists $log->{cmd} ) {
            $log->{cmd} = [];
        }
        push @{ $log->{cmd} }, {@args};
    }
    return;
}

# return new structure of child I/O file descriptors
sub init_child_io
{
    my $cmdname = shift;
    my $childio = {
        cmdname => $cmdname,
        in      => { read => undef, write => undef },
        out     => { read => undef, write => undef },
        err     => { read => undef, write => undef }
    };
    pipe $childio->{in}{read}, $childio->{in}{write}
        or PiFlash::State->error("fork_exec($cmdname): failed to open child process input pipe: $!");
    pipe $childio->{out}{read}, $childio->{out}{write}
        or PiFlash::State->error("fork_exec($cmdname): failed to open child process output pipe: $!");
    pipe $childio->{err}{read}, $childio->{err}{write}
        or PiFlash::State->error("fork_exec($cmdname): failed to open child process error pipe: $!");
    return $childio;
}

# start child process
sub child_proc
{
    my ( $childio, @args ) = @_;

    # in child process

    # close our copy of parent's end of pipes to avoid deadlock - it must now be only one with them open
    my $cmdname = $childio->{cmdname};
    close $childio->{in}{write}
        or croak "fork_exec($cmdname): child failed to close parent process input writer pipe: $!";
    close $childio->{out}{read}
        or croak "fork_exec($cmdname): child failed to close parent process output reader pipe: $!";
    close $childio->{err}{read}
        or croak "fork_exec($cmdname): child failed to close parent process error reader pipe: $!";

    # dup file descriptors into child's standard in=0/out=1/err=2 positions
    POSIX::dup2( fileno $childio->{in}{read}, 0 )
        or croak "fork_exec($cmdname): child failed to reopen stdin from pipe: $!\n";
    POSIX::dup2( fileno $childio->{out}{write}, 1 )
        or croak "fork_exec($cmdname): child failed to reopen stdout to pipe: $!\n";
    POSIX::dup2( fileno $childio->{err}{write}, 2 )
        or croak "fork_exec($cmdname): child failed to reopen stderr to pipe: $!\n";

    # close the file descriptors that were just consumed by dup2
    close $childio->{in}{read}
        or croak "fork_exec($cmdname): child failed to close child process input reader pipe: $!";
    close $childio->{out}{write}
        or croak "fork_exec($cmdname): child failed to close child process output writer pipe: $!";
    close $childio->{err}{write}
        or croak "fork_exec($cmdname): child failed to close child process error writer pipe: $!";

    # execute the command
    exec @args
        or croak "fork_exec($cmdname): failed to execute command - returned $?";
}

# monitor child process from parent
sub monitor_child
{
    my ($childio) = @_;

    # in parent process

    # close our copy of child's end of pipes to avoid deadlock - it must now be only one with them open
    my $cmdname = $childio->{cmdname};
    close $childio->{in}{read}
        or PiFlash::State->error("fork_exec($cmdname): parent failed to close child process input reader pipe: $!");
    close $childio->{out}{write}
        or PiFlash::State->error("fork_exec($cmdname): parent failed to close child process output writer pipe: $!");
    close $childio->{err}{write}
        or PiFlash::State->error("fork_exec($cmdname): parent failed to close child process error writer pipe: $!");

    # write to child's input if any content was provided
    if ( exists $childio->{in_data} ) {

        # blocks until input is accepted - this interface reqiuires child commands using input take it before output
        # because parent process is not multithreaded
        my $writefd = $childio->{in}{write};
        if ( not say $writefd join( "\n", @{ $childio->{in_data} } ) ) {
            PiFlash::State->error("fork_exec($cmdname): failed to write child process input: $!");
        }
    }
    close $childio->{in}{write};

    # use IO::Poll to collect child output and error separately
    my @fd   = ( $childio->{out}{read}, $childio->{err}{read} );    # file descriptors for out(0) and err(1)
    my @text = ( undef, undef );                                    # received text for out(0) and err(1)
    my @done = ( 0,     0 );                                        # done flags for out(0) and err(1)
    my $poll = IO::Poll->new();
    $poll->mask( $fd[0] => POLLIN );
    $poll->mask( $fd[1] => POLLIN );
    while ( not $done[0] or not $done[1] ) {

        # wait for input
        if ( $poll->poll() == -1 ) {
            PiFlash::State->error("fork_exec($cmdname): poll failed: $!");
        }
        for ( my $i = 0 ; $i <= 1 ; $i++ ) {
            if ( !$done[$i] ) {
                my $events = $poll->events( $fd[$i] );
                if ( $events && ( POLLIN || POLLHUP ) ) {

                    # read all available input for input or hangup events
                    # we do this for hangup because Linux kernel doesn't report input when a hangup occurs
                    my $buffer;
                    while ( read( $fd[$i], $buffer, 1024 ) != 0 ) {
                        ( defined $text[$i] ) or $text[$i] = "";
                        $text[$i] .= $buffer;
                    }
                    if ( $events && (POLLHUP) ) {

                        # hangup event means this fd (out=0, err=1) was closed by the child
                        $done[$i] = 1;
                        $poll->remove( $fd[$i] );
                        close $fd[$i];
                    }
                }
            }
        }
    }

    # reap the child process status
    my $pid = $childio->{pid};
    waitpid( $pid, 0 );

    # return child status
    my $result = {};
    $result->{return_code} = $?;
    $result->{text}        = \@text;
    return $result;
}

# fork/exec wrapper to run child processes and collect output/error results
# used as lower level call by cmd() and cmd2str()
# adds more capability than qx()/backtick/system - wrapper lets us send input & capture output/error data
sub fork_exec
{
    my @args = @_;

    # input for child process may be provided as reference to array - use it and remove it from parameters
    my $input_ref;
    if ( ref $args[0] eq "ARRAY" ) {
        $input_ref = shift @args;
    }
    if ( PiFlash::State::verbose() ) {
        say STDERR "fork_exec running: " . join( " ", @args );
    }
    my $cmdname = shift @args;

    # open pipes for child process stdin, stdout, stderr
    my $childio = init_child_io($cmdname);
    if ( defined $input_ref ) {
        $childio->{in_data} = $input_ref;
    }

    # fork the child process
    $childio->{pid} = fork_child( sub { child_proc( $childio, @args ) } );

    # in parent process
    my $result = monitor_child($childio);

    # record all command return codes, stdout & stderr in a new top-level store in State
    # it's overhead but useful for problem-reporting, troubleshooting, debugging and testing
    cmd_log(
        cmdname    => $cmdname,
        cmdline    => [@args],
        returncode => $result->{return_code} >> 8,
        (
            ( $result->{return_code} & 127 )
            ? (
                signal => sprintf "signal %d%s",
                ( $result->{return_code} & 127 ),
                ( ( $result->{return_code} & 128 ) ? " with coredump" : "" )
                )
            : ()
        ),
        out => $result->{text}[0],
        err => $result->{text}[1]
    );

    # catch errors
    if ( $result->{return_code} == -1 ) {
        PiFlash::State->error("failed to execute $cmdname command: $!");
    } elsif ( $result->{return_code} & 127 ) {
        PiFlash::State->error(
            sprintf "%s command died with signal %d, %s coredump",
            $cmdname,
            ( $result->{return_code} & 127 ),
            ( $result->{return_code} & 128 ) ? 'with' : 'without'
        );
    } elsif ( $result->{return_code} != 0 ) {
        PiFlash::State->error( sprintf "%s command exited with value %d", $cmdname, $result->{return_code} >> 8 );
    }

    # return output/error
    return @{ $result->{text} };
}

# run a command
# usage: cmd( label, command_line)
#   label: a descriptive name of the action this is performing
#   command_line: shell command line (pipes and other shell metacharacters allowed)
# note: if there are no shell special characters then all command-line parameters need to be passed separately.
# If there are shell special characters then it will be given to the shell for parsing.
sub cmd
{
    my ( $cmdname, @args ) = @_;
    if ( PiFlash::State::verbose() ) {
        say STDERR "cmd running: " . join( " ", @args );
    }
    system(@args);
    cmd_log(
        cmdname    => $cmdname,
        cmdline    => [@args],
        returncode => $? >> 8,
        (
              ( $? & 127 )
            ? ( signal => sprintf "signal %d%s", ( $? & 127 ), ( ( $? & 128 ) ? " with coredump" : "" ) )
            : ()
        ),
    );
    if ( $? == -1 ) {
        PiFlash::State->error("failed to execute $cmdname command: $!");
    } elsif ( $? & 127 ) {
        PiFlash::State->error(
            sprintf "%s command died with signal %d, %s coredump",
            $cmdname,
            ( $? & 127 ),
            ( $? & 128 ) ? 'with' : 'without'
        );
    } elsif ( $? != 0 ) {
        PiFlash::State->error( sprintf "%s command exited with value %d", $cmdname, $? >> 8 );
    }
    return 1;
}

# run a command and return the output as a string
# This originally used qx() to fork child process and obtain output.  But Perl::Critic discourages use of qx/backtick.
# And it would be useful to provide input to child process, rather than using a wasteful echo-to-pipe shell command.
# So the fork_exec_wrapper() was added as a lower-level base for cmd() and cmd2str().
sub cmd2str
{
    my ( $cmdname, @args ) = @_;
    my ( $out,     $err )  = fork_exec( $cmdname, @args );
    if ( defined $err ) {
        carp( "$cmdname had error output:\n" . $err );
    }
    if (wantarray) {
        return split /\n/x, $out;
    }
    return $out;
}

# generate name of environment variable for where to find a command
# this is broken out as a separate function for tests to use it
sub envprog
{
    my $progname = shift;
    my $envprog  = ( uc $progname ) . "_PROG";
    $envprog =~ s/[\W-]+/_/xg;    # collapse any sequences of non-alphanumeric/non-underscore to a single underscore
    return $envprog;
}

# look up secure program path
sub prog
{
    my $progname = shift;

    if ( !PiFlash::State::has_system("prog") ) {
        PiFlash::State::system( "prog", {} );
    }
    my $prog = PiFlash::State::system("prog");

    # call with undef to initialize cache (mainly needed for testing because normal use will auto-create it)
    if ( !defined $progname ) {
        return;
    }

    # return value from cache if found
    if ( exists $prog->{$progname} ) {
        return $prog->{$progname};
    }

    # if we didn't have the location of the program, look for it and cache the result
    my $envprog = envprog($progname);
    if ( exists $ENV{$envprog} and -x $ENV{$envprog} ) {
        $prog->{$progname} = $ENV{$envprog};
        return $prog->{$progname};
    }

    # search paths in order emphasizing recent Linux Filesystem that prefers /usr/bin, then Unix PATH order
    for my $path ( "/usr/bin", "/sbin", "/usr/sbin", "/bin" ) {
        if ( -x "$path/$progname" ) {
            $prog->{$progname} = "$path/$progname";
            return $prog->{$progname};
        }
    }

    # if we get here, we didn't find a known secure location for the program
    PiFlash::State->error( "unknown secure location for $progname - install it or set " . "$envprog to point to it" );
}

1;
