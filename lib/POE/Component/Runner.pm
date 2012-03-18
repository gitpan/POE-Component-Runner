package POE::Component::Runner;

our $VERSION = '0.03';

use 5.008;
use strict;
use warnings;
{
    use Carp;
    use Data::GUID qw( guid );
    use POE qw( Session Wheel::Run );
    use Data::Dumper;
}

sub new {
    my $class = shift @_;

    my %arg;

    if ( @_ == 1 && ref $_[0] eq 'HASH' ) {

        %arg = %{ $_[0] };
    }
    elsif ( @_ % 2 == 0 ) {

        %arg = @_;
    }
    else {

        croak __PACKAGE__, ' constructor expects a hash or a hash ref';
    }

    my $alias = defined $arg{alias} ? delete $arg{alias} : 'runner';
    my $func_rc = defined $arg{function_rc} ? delete $arg{function_rc} : 0;
    my $cb_rh   = defined $arg{callback_rh} ? delete $arg{callback_rh} : {};
    my $debug   = defined $arg{debug}       ? delete $arg{debug}       : 0;

    $alias =~ s{[^-.\w]}{.}xmsg;
    ($alias) = $alias =~ m{\A ( [-.\w]+ ) \z}xms;    # detaint

    croak 'the function_rc parameter must be a code reference'
        if ref $func_rc ne 'CODE';

    my %callback_for;

    for my $state (qw( stdout stderr close signal )) {

        if ( defined $cb_rh->{$state} ) {

            if ( ref $cb_rh->{$state} eq 'CODE' ) {

                $callback_for{$state} = delete $cb_rh->{$state};
            }
            else {

                carp "callback_rh->{$state} parameter ",
                    'should be a code reference';
            }
        }
    }

    for my $unsupported ( keys %{$cb_rh} ) {

        carp "$unsupported is not a supported callback state";
    }
    for my $unsupported ( keys %arg ) {

        carp "$unsupported is not a supported parameter";
    }

    my %heap = (
        alias       => $alias,
        func_rc     => $func_rc,
        callback_rh => \%callback_for,
        debug       => $debug,
    );
    my $self = bless \%heap, $class;

    my %runner = (
        heap          => \%heap,
        object_states => [
            $self => [
                qw(
                    _start
                    run
                    process_stdout
                    process_stderr
                    process_close
                    process_cleanup
                    _stop
                    )
            ],
        ],
    );
    POE::Session->create(%runner);

    return $self;
}

sub _start {
    my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];

    $kernel->alias_set( $heap_rh->{alias} );

    $heap_rh->{in_process_rh}   = {};
    $heap_rh->{task_key_for_rh} = {};
    $heap_rh->{proc_for_wid_rh} = {};
    $heap_rh->{proc_for_pid_rh} = {};

    return;
}

sub run {
    my ( $kernel, $heap_rh, $sender ) = @_[ KERNEL, HEAP, SENDER ];

    my @args = grep { defined $_ } @_[ ARG0, ARG1, ARG2, ARG3 ];

    my ( $postback, $arg_ra, $baggage );

    if ( @args > 2 ) {

        ( $postback, $arg_ra, $baggage ) = @args;
    }
    elsif ( @args == 2 ) {

        if ( ref $args[0] ) {

            ( $arg_ra, $baggage ) = @args;
        }
        elsif ( ref $args[1] ) {

            ( $postback, $arg_ra ) = @args;
        }
    }
    elsif ( @args == 1 ) {

        $arg_ra = ref $args[0] eq 'ARRAY' ? $args[0] : [ $args[0] ];
    }
    else {

        return;
    }

    if ( ref $arg_ra ne 'ARRAY' ) {

        $arg_ra = [$arg_ra];
    }

    my $task_key;

    if (   $baggage
        && ref $baggage eq 'HASH'
        && exists $baggage->{task_key} )
    {
        $task_key = $baggage->{task_key};
    }

    if ( !defined $task_key ) {

        $task_key = join '|', map {"$_"} grep { defined $_ } @{$arg_ra};
        $task_key ||= guid()->as_string();
    }

    if ( $heap_rh->{debug} ) {
        print Dumper( { $task_key => $arg_ra } );
    }

    return
        if $heap_rh->{in_process_rh}->{$task_key};

    if ($postback) {

        $heap_rh->{postback_rh}->{$task_key} = {
            postback => $postback,
            sender   => $sender,
            arg_ra   => $arg_ra,
            baggage  => $baggage,
            err_ra   => [],
            out_ra   => [],
        };
    }

    my $program_rc = sub {
        my $result = $heap_rh->{func_rc}->( @{$arg_ra} );
        $result = defined $result ? $result : "";
        return print "$result\n";
    };

    my $process = POE::Wheel::Run->new(
        Program     => $program_rc,
        StdoutEvent => 'process_stdout',
        StderrEvent => 'process_stderr',
        CloseEvent  => 'process_close',
    );

    my ( $pid, $wid ) = ( $process->PID, $process->ID );

    $kernel->sig_child( $pid, 'process_signal' );

    $heap_rh->{in_process_rh}->{$task_key} = $wid;
    $heap_rh->{task_key_for_rh}->{$wid}    = $task_key;
    $heap_rh->{proc_for_pid_rh}->{$pid}    = $process;
    $heap_rh->{proc_for_wid_rh}->{$wid}    = $process;

    my $callback_rc = $heap_rh->{callback_rh}->{start};

    if ($callback_rc) {

        $callback_rc->( $pid, $task_key );
    }
    elsif ( $heap_rh->{debug} ) {

        printf "PID %d started as wheel %d\n", $pid, $wid;
    }

    return;
}

sub _stop {
    my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];

    return $kernel->call('process_cleanup');
}

##                          ##
#   Process State Handlers   #
##                          ##

sub process_stdout {
    my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];
    my ( $line,   $wid )     = @_[ ARG0,   ARG1 ];

    my $process = $heap_rh->{proc_for_wid_rh}->{$wid};

    my $pid = defined $process ? $process->PID : 0;

    return
        if !$pid;

    my $callback_rc = $heap_rh->{callback_rh}->{stdout};

    if ($callback_rc) {

        $callback_rc->( $pid, $line );
    }
    elsif ( $heap_rh->{debug} ) {

        printf "PID %d OUT: %s\n", $pid, $line;
    }

    my $task_key = $heap_rh->{task_key_for_rh}->{$wid};

    if ( exists $heap_rh->{postback_rh}->{$task_key} ) {

        push @{ $heap_rh->{postback_rh}->{$task_key}->{out_ra} }, $line;
    }

    return;
}

sub process_stderr {
    my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];
    my ( $line,   $wid )     = @_[ ARG0,   ARG1 ];

    my $process = $heap_rh->{proc_for_wid_rh}->{$wid};

    my $pid = defined $process ? $process->PID : 0;

    return
        if !$pid;

    my $callback_rc = $heap_rh->{callback_rh}->{stderr};

    if ($callback_rc) {

        $callback_rc->( $pid, $line );
    }
    elsif ( $heap_rh->{debug} ) {

        printf "PID %d ERR: %s\n", $pid, $line;
    }

    my $task_key = $heap_rh->{task_key_for_rh}->{$wid};

    if ( exists $heap_rh->{postback_rh}->{$task_key} ) {

        push @{ $heap_rh->{postback_rh}->{$task_key}->{err_ra} }, $line;
    }

    return;
}

sub process_close {
    my ( $kernel, $heap_rh, $wid ) = @_[ KERNEL, HEAP, ARG0 ];

    my $process = $heap_rh->{proc_for_wid_rh}->{$wid};

    my $pid = defined $process ? $process->PID : 0;

    if ($pid) {

        my $callback_rc = $heap_rh->{callback_rh}->{close};

        if ($callback_rc) {

            $callback_rc->($pid);
        }
        elsif ( $heap_rh->{debug} ) {

            printf "PID %d closed all pipes.\n", $pid;
        }
    }
    elsif ( $heap_rh->{debug} ) {

        printf "WID %d closed all pipes.\n", $wid;
    }

    my $task_key = $heap_rh->{task_key_for_rh}->{$wid};

    if ( exists $heap_rh->{postback_rh}->{$task_key} ) {

        my $postback_rh = delete $heap_rh->{postback_rh}->{$task_key};

        my ( $sender, $postback ) = @{$postback_rh}{qw( sender postback )};
        my ( $arg_ra, $baggage )  = @{$postback_rh}{qw( arg_ra baggage )};
        my ( $err_ra, $out_ra )   = @{$postback_rh}{qw( err_ra out_ra )};

        my %result = (
            arg_ra => $arg_ra,
            err_ra => $err_ra,
            out_ra => $out_ra,
        );
        $kernel->post( $sender, $postback, \%result, $baggage );
    }

    return $kernel->delay_add( process_cleanup => 1, $pid, $wid );
}

sub process_cleanup {
    my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];
    my ( $pid,    $wid )     = @_[ ARG0,   ARG1 ];

    my @pids = defined $pid ? ($pid) : ();
    my @wids = defined $wid ? ($wid) : ();

    if ( !@wids ) {

        @wids = keys %{ $heap_rh->{task_key_for_rh}->{$wid} };
    }

    for my $wid (@wids) {

        my $task_key = $heap_rh->{task_key_for_rh}->{$wid};

        delete $heap_rh->{task_key_for_rh}->{$wid};
        delete $heap_rh->{in_process_rh}->{$task_key};
        delete $heap_rh->{proc_for_wid_rh}->{$wid};
    }

    if ( !@pids ) {

        @pids = keys %{ $heap_rh->{proc_for_pid_rh} };
    }

    for my $pid (@pids) {

        delete $heap_rh->{proc_for_pid_rh}->{$pid};
    }

    return;
}

sub process_signal {
    my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];
    my ( $pid,    $status )  = @_[ ARG1,   ARG2 ];

    my $callback_rc = $heap_rh->{callback_rh}->{signal};

    if ($callback_rc) {

        $callback_rc->( $pid, $status );
    }
    elsif ( $heap_rh->{debug} ) {

        printf "PID %d exited with status %s.\n", $pid, $status;
    }

    return
        if !exists $heap_rh->{proc_for_pid_rh}->{$pid};

    my $process = delete $heap_rh->{proc_for_pid_rh}->{$pid};

    return
        if !defined $process;

    my $wid = $process->ID;

    return
        if !exists $heap_rh->{proc_for_wid_rh}->{$wid};

    return $wid;
}

1;

__END__

=head1 NAME

POE::Component::Runner - Create a session for running an arbitrary process.

=head1 SYNOPSIS

  use POE qw( Component::Runner );

  my %runner = (
      alias       => 'runner',
      function_rc => \&arbitrary_function,

      # optional
      callback_rh => {
          stdout => \&stdout_handler,
          stderr => \&stderr_handler,
          close  => \&close_handler,
          signal => \&signal_handler,
      },
      debug => 0,
  );
  POE::Component::Runner->new( \%runner );

    ...

  POE::Kernel->post( runner => 'run', \@args );

    ...

  POE::Kernel->post( runner => 'run', 'return_state', \@args );

    ...

  my %baggage = (
      task_key => 'blah',    # optional task key used to reject redundant calls
  );
  POE::Kernel->post( runner => 'run', 'return_state', \@args, \%baggage );

The return_state handler will receive ARG0 and ARG1. 

=over

=item ARG0

Contains a hash ref with:

  {
      arg_ra => \@args,    # As posted
      out_ra => \@std_out, # Lines written to STDOUT
      err_ra => \@std_err, # Lines written to STDERR
  }

=item ARG1

Contains the baggage reference.

=back

=head1 DESCRIPTION

This component provides a session with a 'run' state for facilitating
asynchronous calls to otherwise blocking code. You can optionally provide
callback handlers for the various underlying POE::Wheel::Run states.

Take a look in the example directory to see how to use it with
POE::Component::DirWatch to asynchronously move files.

=head1 SEE ALSO

POE::Wheel::Run

=head1 ACKNOWLEDGEMENT

This module was inspired by the synopsis on
Rocco Caputo's POE::Wheel::Run.

=head1 AUTHOR

Dylan Doxey, E<lt>dylan.doxey@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Dylan Doxey

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10 or,
at your option, any later version of Perl 5 you may have available.


=cut
