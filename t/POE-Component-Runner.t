#!/usr/bin/perl -Tw

use strict;
use warnings;

use Test::More qw( no_plan );
BEGIN { use_ok('POE::Component::Runner') }

use POE qw( Session );

my %Is_Result    = ();
my $Start_Time   = 0;
my $Count        = 0;
my $Expect_Count = 100;

POE::Component::Runner->new(
    {   alias       => 'runner',
        function_rc => sub {
            print "two\n";
            warn "four\n";
            sleep 1;    # sleeps for every call
            return 'three';
        },
        debug => 0,
    }
);

POE::Session->create(
    inline_states => {
        _start => \&_start,
        done   => \&done,
    },
);

POE::Kernel->run();

## Tests
{
    my $elapsed = time - $Start_Time;

    cmp_ok(
        $elapsed, '<=',
        ( $Expect_Count / 5 ),
        "$elapsed seconds is much less than $Expect_Count"
    );

    is( $Count, $Expect_Count, "called function $Expect_Count times" );

    is_deeply(
        \%Is_Result,
        { 'one,two,three,four' => 1 },
        'got expected output'
    );
}

## States
{

    sub _start {
        my ( $kernel, $heap_rh ) = @_[ KERNEL, HEAP ];

        $kernel->alias_set('test-session');

        $Start_Time = time;

        for my $i ( 1 .. $Expect_Count ) {

            $kernel->post(
                'runner',
                'run',
                'done',
                ['one'],
                { task_key => $i }
            );
        }

        return;
    }

    sub done {
        my ( $kernel,    $heap_rh )    = @_[ KERNEL, HEAP ];
        my ( $result_rh, $baggage_rh ) = @_[ ARG0,   ARG1 ];

        my @arg = @{ $result_rh->{arg_ra} };
        my @out = @{ $result_rh->{out_ra} };
        my @err = @{ $result_rh->{err_ra} };

        my $csv = join ',', @arg, @out, @err;

        $Is_Result{$csv} = 1;

        $Count++;

        return;
    }
}

__END__
