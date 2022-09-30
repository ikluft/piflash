# PiFlash::Hook - named dispatch/hook library for PiFlash
# by Ian Kluft

# pragmas to silence some warnings from Perl::Critic
## no critic (Modules::RequireExplicitPackage)
# This solves a catch-22 where parts of Perl::Critic want both package and use-strict to be first
use strict;
use warnings;
use utf8;
use 5.01400;    # require 2011 or newer version of Perl
## use critic (Modules::RequireExplicitPackage)

package PiFlash::Hook;

use Carp qw(confess);
use autodie;   # report errors instead of silently continuing ("die" actions are used as exceptions - caught & reported)
use parent 'PiFlash::Object';
use PiFlash::State;

# ABSTRACT: named dispatch/hook library for PiFlash

=head1 SYNOPSIS

 PiFlash::Hook::add( "hook1", sub { ... code ... });
 PiFlash::Hook::hook1();
 PiFlash::Hook::add( "hook2", \&function_name);
 PiFlash::Hook::hook2();

=head1 DESCRIPTION

=head1 SEE ALSO

L<piflash>, L<PiFlash::Command>, L<PiFlash::Inspector>, L<PiFlash::MediaWriter>, L<PiFlash::State>

=head1 BUGS AND LIMITATIONS

Report bugs via GitHub at L<https://github.com/ikluft/piflash/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/piflash/pulls>

=cut

# initialize hooks hash as empty
## no critic (ProhibitPackageVars)
our %hooks;
## use critic

# required parameter list
# used by PiFlash::Object for new() method
sub object_params
{
    return qw(name code origin);
}

# use AUTOLOAD to call a named hook as if it were a class method
## no critic (ClassHierarchies::ProhibitAutoloading)
# TODO: pre-generate hook functions to remove AUTOLOAD and its perlcritic exception
our $AUTOLOAD;

sub AUTOLOAD
{
    my ( $self, @args ) = @_;

    # Remove qualifier from original method name...
    my $called = $AUTOLOAD =~ s/.*:://rx;

    # differentiate between class and instance methods
    if ( defined $self and ref $self eq "PiFlash::Hook" ) {

        # handle instance accessor
        # if likely to be used a lot, optimize this by creating accessor function upon first access
        if ( exists $self->{$called} ) {
            return $self->{$called};
        }
    } else {

        # autoloaded class methods run hooks by name
        run( $called, @args );
    }
    return;
}
## critic (ClassHierarchies::ProhibitAutoloading)

# add a code reference to a named hook
sub add
{
    my $name    = shift;
    my $coderef = shift;
    if ( ref $coderef ne "CODE" ) {
        confess "PiFlash::Hook::add_hook(): can't add $name hook with non-code reference";
    }
    if ( !exists $hooks{$name} ) {
        $hooks{$name} = [];
    }
    push @{ $hooks{$name} }, PiFlash::Hook::new( { name => $name, code => $coderef, origin => [caller] } );
    return;
}

# check if there are any hooks registered for a name
sub has
{
    my $name = shift;
    return exists $hooks{$name};
}

# run the hook code
sub run
{
    my ( $name, @args ) = @_;

    # Is there a hook of that name?
    if ( !exists $hooks{$name} ) {
        if ( PiFlash::State::verbose() ) {
            say "PiFlash::Hook dispatch: no such hook $name - ignored";
        }
        return;
    }

    # call all functions registered in the list for this hook
    my @result;
    if ( ref $hooks{$name} eq "ARRAY" ) {
        foreach my $hook ( @{ $hooks{$name} } ) {
            push @result, $hook->{code}(@args);
        }
    }
    return @result;
}

1;
