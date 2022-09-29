# PiFlash::Object - object functions for PiFlash classes
# by Ian Kluft

# pragmas to silence some warnings from Perl::Critic
## no critic (Modules::RequireExplicitPackage)
# This solves a catch-22 where parts of Perl::Critic want both package and use-strict to be first
use strict;
use warnings;
use utf8;
use 5.01400; # require 2011 or newer version of Perl
## use critic (Modules::RequireExplicitPackage)

package PiFlash::Object;

use autodie; # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)
use Carp qw(confess);

# ABSTRACT:object functions for PiFlash classes

=head1 SYNOPSIS

 package PiFlash::Example;
 use parent 'PiFlash::Object';

 sub object_params
 (
	return qw(name type); # and any other required object parameter names
 }

 my $obj = PiFlash::Example->new( {name => "foo", type => "bar");

=head1 DESCRIPTION

PiFlash::Object was written so that L<PiFlash::Hook> and L<PiFlash::Plugin> could inherit and share the same new() class method, rather than have similar and separate implementations. It isn't of interest to most PiFlash users.

In order to use it, the class must define a class method called object_params() which returns a list of the required parameter names for each object of the class.

=head1 SEE ALSO

L<piflash>, L<PiFlash::Hook>, L<PiFlash::Plugin>

=head1 BUGS AND LIMITATIONS

Report bugs via GitHub at L<https://github.com/ikluft/piflash/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/piflash/pulls>

=cut

# new() - internal function to instantiate hook object
# this should only be called from add() with coderef/caller/origin parameters
sub new
{
        my ( $class, $params, @args ) = @_;

		# instantiate an object of the class
        my $self = {};
        bless $self, $class;

        # initialize parameters
        foreach my $key (keys %$params) {
			$self->{$key} = $params->{$key};
        }

		# chack for missing required parameters
        my @missing;
        foreach my $required ($class->object_params()) {
			exists $self->{$required} or push @missing, $required;
        }
        if (@missing) {
			confess $class."->new() missing required parameters: ".join(" ", @missing);
        }

		# if init() class method exists, call it with any remaining parameters
		if ($class->can("init")) {
			$self->init(@args);
		}

        return $self;
}

1;
