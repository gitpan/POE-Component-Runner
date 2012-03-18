#!/usr/bin/perl -Tw

=for Explanation

  Use this program to watch a directory for files with the .add extension.
  The files will be moved to the same name sans .add.

    $: perl -Tw example/file_mover.pl /tmp &
    $: for x in {0..9}; do y="/tmp/x$x.txt.add"; echo $y; touch $y; done; sleep 1; ls -l /tmp/x*.txt*

=cut

use strict;
use warnings;
{
    use Carp;
    use File::Copy qw( move );
    use POE qw( Component::DirWatch Component::Runner );
    use English qw( -no_match_vars $OS_ERROR );
}

my $Directory;
{
    ($Directory) = @ARGV;

    die "no directory given"
        if !$Directory;

    die "can't find $Directory"
        if !stat $Directory;

    die "$Directory is not a directory"
        if !-d $Directory;

    # detaint for security
    $Directory = join '/',
        grep { defined $_ } map { $_ =~ m{\A( [-.\w]* )\z}xms; $1 } split '/',
        $Directory;

    die "detaint failed for $Directory"
        if !-d $Directory || $Directory ne $ARGV[0];
}

my %sentry = (
    alias         => 'dir-sentry',
    directory     => $Directory,
    filter        => \&identify_file,
    file_callback => \&dispatch_file,
    interval      => 1,
);
POE::Component::DirWatch->new(%sentry);

my %runner = (
    alias       => 'runner',
    function_rc => \&move_file,
);
POE::Component::Runner->new(%runner);

print "this program will remove .add filename extensions\n";
print "watching $Directory\n";

POE::Kernel->run();

##                  ##
#   State Handlers   #
##                  ##

sub identify_file {
    my ($file) = @_;

    return 1
        if "$file" =~ m{ [.] add \z}xms;

    return;
}

sub dispatch_file {
    my ($file) = @_;

    my ($original_path) = $file =~ m{\A ($Directory/ [-.\w]+ [.] add) \z}xms;
    my ($revised_path) = $original_path =~ m{\A ( .+ ) [.] add \z}xms;

    my @args = ( $original_path, $revised_path, );

    return POE::Kernel->post( 'runner', 'run', \@args );
}

sub move_file {
    my ( $from, $to ) = @_;

    move( $from, $to )
        || croak "mv $from $to: $OS_ERROR";

    return 1;
}

__END__
