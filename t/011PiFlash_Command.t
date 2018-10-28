#!/usr/bin/perl
# 011PiFlash_Command.t - tests for PiFlash::Command module

use strict;
use warnings;
use autodie;

use Test::More tests => 8;                      # last test to print
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
my %prog_path;
my @prog_names = qw(cat echo sh);
my $cat_prog; # path remains undefined if program not found
foreach my $progname (@prog_names) {
	foreach my $pathdir ("/usr/bin", "/bin") {
		if ( -e "$pathdir/$progname" ) {
			$prog_path{$progname} = "$pathdir/$progname";
			last;
		}
	}
}

# test capturing output of a fixed string from a program with fork_exec()
# effectively runs this command: echo "$test_string"
SKIP: {
	my ($out, $err);
	if (exists $prog_path{echo}) {
		($out, $err) = PiFlash::Command::fork_exec("fork an echo", $prog_path{echo}, $test_string);
	} else {
		skip "echo program not found", 2;
	}
	chomp $out;
	is ($out, $test_string, "fork_exec() test output capture 1 is correct");
	is ($err, undef, "fork_exec() test error capture 1 is empty");
}

# test sending input and receiving the same string back as output from a program with fork_exec()
# effectively runs this command: cat
# input piped to the program: $test_string
SKIP: {
	my ($out, $err);
	if (exists $prog_path{cat}) {
		($out, $err) = PiFlash::Command::fork_exec([ $test_string ], "fork a cat", $prog_path{cat});
	} else {
		skip "cat program not found", 2;
	}
	chomp $out;
	is ($out, $test_string, "fork_exec() test output capture 2 is correct");
	is ($err, undef, "fork_exec() test error capture 2 is empty");
}

# test capturing an error output
SKIP: {
	my ($out, $err);
	if (exists $prog_path{sh}) {
		($out, $err) = PiFlash::Command::fork_exec("fork a shell", $prog_path{sh}, "-c", qq{echo $test_string >&2});
	} else {
		skip "sh program not found", 2;
	}
	is ($out, undef, "fork_exec() test output capture 1 is empty");
	chomp $err;
	is ($err, $test_string, "fork_exec() test error capture 1 contains test string");
}

# test capturing an error result
SKIP: {
	my ($out, $err);
	my $expected_exception = 0;
	if (exists $prog_path{sh}) {
		eval { PiFlash::Command::fork_exec("fork a shell", $prog_path{sh}, "-c", qq{exit 1}) };
		if ( $@ =~ /fork a shell command exited with value 1/ ) {
			$expected_exception = 1;
		}
	} else {
		skip "sh program not found", 2;
	}
	is($expected_exception, 1, "intentional error result");
}



# TODO: more tests which deliberately capture  error results

1;
