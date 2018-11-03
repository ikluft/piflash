# PiFlash::Hook - named dispatch/hook library for PiFlash
# by Ian Kluft

use strict;
use warnings;
use v5.18.0; # require 2014 or newer version of Perl

package PiFlash::Hook;
use PiFlash::State;
use Carp qw(confess);
use autodie; # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)

# ABSTRACT: named dispatch/hook library for PiFlash

=head1 SYNOPSIS

 PiFlash::Hook::add( "hook1", sub { ... code ... });
 PiFlash::Hook::hook1();
 PiFlash::Hook::add( "hook2", \&function_name);
 PiFlash::Hook::hook2();

=head1 DESCRIPTION

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::Inspector>, L<PiFlash::MediaWriter>, L<PiFlash::State>

=cut

# initialize hooks hash as empty
## no critic (ProhibitPackageVars)
our %hooks;
## use critic

# use AUTOLOAD to call a named hook as if it were a class method
our $AUTOLOAD;
sub AUTOLOAD {
	my $self = shift;

	# Remove qualifier from original method name...
	my $called =  $AUTOLOAD =~ s/.*:://r;

	# Is there a hook of that name?
	if (!exists $hooks{$called}) {
		confess "PiFlash::Hook dispatch: No such hook $called";
	}

	# call all functions registered in the list for this hook
	my @result;
	if (ref $hooks{$called} eq "ARRAY") {
		foreach my $hook (@{$hooks{$called}}) {
			my @hook_return = $hook->();
			push @result, [@hook_return];
		}
	}
	return @result;
}

# add a code reference to a named hook
sub add
{
	my $name = shift;
	my $coderef = shift;
	if (ref $coderef ne "CODE") {
		confess "PiFlash::Hook::add_hook(): can't add $name hook with non-code reference";
	}
	if (!exists $hooks{$name}) {
		$hooks{$name} = [];
	}
	push @{$hooks{$name}}, $coderef;
}

1;
