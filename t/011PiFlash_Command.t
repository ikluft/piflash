#!/usr/bin/perl
# 011PiFlash_Command.t - tests for PiFlash::Command module

use strict;
use warnings;
use autodie;

use Test::More tests => 3;                      # last test to print
use PiFlash::State;
use PiFlash::Command;

# initialize program state storage
my @top_level_params = ("system", "input", "output", "cli_opt", "log");
PiFlash::State->init(@top_level_params);

# test forking a simple process that returns a true value using fork_child()
{
	my $pid = PiFlash::Command::fork_child(sub {
		# in child process
		return 0; # 0 = success on exit of a program; test is successful if received by parent process
	});
	waitpid( $pid, 0 );
	my $returncode = $? >> 8;
	is($returncode, 0, "simple fork test");
}

# strings used for following tests
my $test_string = "Ad astra per alas porci";
my $cat_prog;
foreach my $pathdir ("/usr/bin", "/bin") {
	if ( -e "$pathdir/cat" ) {
		$cat_prog = "$pathdir/cat";
		last;
	}
}

# test capturing output from a program with fork_exec()
#{
#	my ($out, $err) = fork_exec($cmdname, @_);
#}

# test sending input and receiving output from a program with fork_exec()
{
	if (!defined $cat_prog) {
		skip "cat program not found", 2;
	}
	my ($out, $err) = PiFlash::Command::fork_exec([ $test_string ], $cat_prog);
	is ($out, $test_string, "fork_exec() test output capture");
	is ($err, undef, "fork_exec() test errors capture is empty");
}

1;
