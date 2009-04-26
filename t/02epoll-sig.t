#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;

use POSIX qw( SIGHUP );

use IO::Async::Loop::Epoll;

my $loop = IO::Async::Loop::Epoll->new();

is( $SIG{HUP}, undef, '$SIG{HUP} default before watch' );

my $SIGHUP_count = 0;
$loop->watch_signal( HUP => sub { $SIGHUP_count++ } );

ok( defined $SIG{HUP}, '$SIG{HUP} defined after watch' );

kill SIGHUP, $$;

is( $SIGHUP_count, 0, 'Not caught SIGHUP before loop_once' );

my $count = $loop->loop_once( 0.1 );

is( $count, 0, '$count is 0 after loop_once' );

is( $SIGHUP_count, 1, 'Caught SIGHUP after loop_once' );

undef $loop;

is( $SIG{HUP}, 'DEFAULT', '$SIG{HUP} restored after $loop unref' );
