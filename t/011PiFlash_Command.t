#!/usr/bin/perl
# 011PiFlash_Command.t - tests for PiFlash::Command module

use strict;
use warnings;
use autodie;

use Test::More tests => 41;                      # last test to print
use PiFlash::State;
use PiFlash::Command;

# detect debug mode from environment
# run as "DEBUG=1 perl -Ilib t/011PiFlash_Command.t" to get debug output to STDERR
my $debug_mode = exists $ENV{DEBUG};

# function to check log results in last command in log
sub check_cmd_log
{
	my $key = shift;
	my $expected_value = shift;

	# fetch the log value for comparison
	my $log = PiFlash::State::log("cmd");
	my $log_entry = $log->[(scalar @$log)-1];
	my $log_value = $log_entry->{$key};

	# if it's an array, loop through to compare elements
	if (ref $expected_value eq "ARRAY") {
		if (ref $log_value ne "ARRAY") {
			# mismatch if both are not array refs
			$debug_mode and warn "mismatch ref type: log value not ARRAY";
			return 0;
		}
		if ($log_value->[(scalar @$log_value)-1] eq "") {
			# eliminate blank last line for comparison due to appended newline
			pop @$log_value;
		}
		if ((scalar @$expected_value) != (scalar @$log_value)) {
			# mismatch if result arrays are different numbers of lines
			$debug_mode and warn "mismatch array length ".(scalar @$expected_value)." != ".(scalar @$log_value);
			return 0;
		}
		my $i;
		for ($i=0; $i<scalar @$expected_value; $i++) {
			if ($expected_value->[$i] ne $log_value->[$i]) {
				# mismatch if any lines aren't equal
				$debug_mode and warn "mismatch line: $expected_value->[$i] ne $log_value->[$i]";
				return 0;
			}
		}
		return 1; # if we got here, it's a match
	}

	# if both values are undefined, that's a special case match because eq operator doesn't like them
	if ((!defined $expected_value) and (!defined $log_value)) {
		return 1;
	}

	# with previous case tested, they are not both undefined; so undef in either is a mismatch
	if ((!defined $expected_value) or (!defined $log_value)) {
		$debug_mode and warn "mismatch on one undef";
		return 0;
	}

	# otherwise compare values
	chomp $log_value;
	return $expected_value eq $log_value;
}

# expand parameter variable names in parameters
sub expand
{
	my $varhash = shift;
	my $varname = shift;
	my $varname_re = join('|', keys %$varhash);
	my $value = $varhash->{$varname};
	if (ref $value eq "ARRAY") {
		for (my $i=0; $i<scalar @$value; $i++) {
			(defined $value->[$i]) or next;
			while ($value->[$i] =~ /\$($varname_re)/) {
				my $match = $1;
				my $subst = $varhash->{$match};
				$value->[$i] =~ s/\$$match/$subst/g;
			}
		}
	} else {
		while ($value =~ /\$($varname_re)/) {
			my $match = $1;
			my $subst = $varhash->{$match};
			$value =~ s/\$$match/$subst/g;
		}
	}
	return $value;
}

# function to run a set of tests on a fork_exec command
sub test_fork_exec
{
	my $params = shift; # hash structure of test parameters

	SKIP: {
		my ($out, $err, $exception);
		my $cmdname = expand($params, "cmdname");
		my $cmdline = expand($params, "cmdline");

		# run command
		if (defined $cmdline->[0]) {
			$debug_mode and warn "running '$cmdname' as: ".join(" ", @$cmdline);
			eval { ($out, $err) = PiFlash::Command::fork_exec(($params->{input} // ()), $cmdname, @$cmdline) };
			$exception = $@;
		} else {
			# update the skip count here when any tests are added to this function
			skip "program not found", 8;
		}

		# tweak captured data for comparison
		chomp $out if defined $out;
		chomp $err if defined $err;

		# test and report results
		my $test_set = "fork_exec() ".$params->{test_set_suffix};
		ok(check_cmd_log("cmdname", $cmdname), "$test_set command name log match: '$cmdname'");
		ok(check_cmd_log("cmdline", $cmdline), "$test_set command line log match: ".join(" ", @$cmdline));
		if (exists $params->{expected_exception}) {
			my $expected_exception = expand($params, "expected_exception");
			like($exception, qr/$expected_exception/, "$test_set expected exception");
		} else {
			is($exception, '', "$test_set no exceptions");
		}
		ok(check_cmd_log("returncode", $params->{returncode}), "$test_set returncode is $params->{returncode}");
		is($out, $params->{expected_out}, "$test_set output capture match");
		ok(check_cmd_log("out", $params->{expected_out}), "$test_set output log match");
		is($err, $params->{expected_err}, "$test_set error capture match");
		ok(check_cmd_log("err", $params->{expected_err}), "$test_set error log match");
	}
}

# initialize program state storage
my @top_level_params = ("system", "input", "output", "cli_opt", "log");
PiFlash::State->init(@top_level_params);
PiFlash::State::cli_opt("verbose", 1);

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
my $test_string = "Ad astra per alas porci"; # test string: random text intended to look different from normal output
my %prog_path;
my @prog_names = qw(cat echo sh);
foreach my $progname (@prog_names) {
	foreach my $pathdir ("/bin", "/usr/bin") {
		if ( -e "$pathdir/$progname" ) {
			$prog_path{$progname} = "$pathdir/$progname";
			last;
		}
	}
}

# data for fork_exec() test sets
my @fork_exec_tests = (
	# test capturing output of a fixed string from a program with fork_exec()
	# runs command: echo "$test_string"
	{
		cmdname => "echo string to stdout",
		cmdline => [$prog_path{echo}, $test_string],
		returncode => 0,
		expected_out => $test_string,
		expected_err => undef,
	},

	# test sending input and receiving the same string back as output from a program with fork_exec()
	# runs command: cat
	# input piped to the program: $test_string
	{
		input => [ $test_string ],
		cmdname => "cat input to output",
		cmdline => [$prog_path{cat}],
		returncode => 0,
		expected_out => $test_string,
		expected_err => undef,
	},

	# test capturing an error output
	{
		cmdname => "echo string to stderr",
		cmdline => [$prog_path{sh}, "-c", qq{echo $test_string >&2}],
		returncode => 0,
		expected_out => undef,
		expected_err => $test_string,
	},

	# test capturing an error 1 result
	# exception expected during this test
	{
		cmdname => "return errorcode \$returncode",
		cmdline => [$prog_path{sh}, "-c", qq{exit \$returncode}],
		returncode => 1,
		expected_out => undef,
		expected_err => undef,
		expected_exception => "\$cmdname command exited with value \$returncode",
	},

	# test capturing an error 2 result
	# exception expected during this test
	{
		cmdname => "return errorcode \$returncode",
		cmdline => [$prog_path{sh}, "-c", qq{exit \$returncode}],
		returncode => 2,
		expected_out => undef,
		expected_err => undef,
		expected_exception => "\$cmdname command exited with value \$returncode",
	},
);

# run fork_exec() tests
my $count = 0;
foreach my $fe_test (@fork_exec_tests) {
	$count++;
	$fe_test->{test_set_suffix} = $count;
	test_fork_exec($fe_test);
}

$debug_mode and warn PiFlash::State::odump($PiFlash::State::state,0);

1;
