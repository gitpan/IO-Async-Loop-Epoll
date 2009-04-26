#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use Test::Exception;

use IO::Async::Notifier;

use IO::Async::Loop::Epoll;

my $loop = IO::Async::Loop::Epoll->new();

ok( defined $loop, '$loop defined' );
isa_ok( $loop, "IO::Async::Loop::Epoll", '$loop isa IO::Async::Loop::Epoll' );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

$loop->add( $notifier );

$S2->syswrite( "data\n" );

# We should still wait a little while even thought we expect to be ready
# immediately, because talking to ourself with 0 poll timeout is a race
# condition - we can still race with the kernel.

$loop->loop_once( 0.1 );

is( $readready, 1, '$readready after loop_once' );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

# Write-ready
$notifier->want_writeready( 1 );

$loop->loop_once( 0.1 );

is( $writeready, 1, '$writeready after loop_once' );

# loop_forever

my $stdout_notifier = IO::Async::Notifier->new( handle => \*STDOUT,
   on_read_ready => sub { },
   on_write_ready => sub { $loop->loop_stop() },
   want_writeready => 1,
);
$loop->add( $stdout_notifier );

$writeready = 0;

$SIG{ALRM} = sub { die "Test timed out"; };
alarm( 1 );

$loop->loop_forever();

alarm( 0 );

is( $writeready, 1, '$writeready after loop_forever' );

$loop->remove( $stdout_notifier );

$notifier->want_writeready( 0 );
$readready = 0;

$loop->loop_once( 0.1 );

is( $readready, 0, '$readready before HUP' );

close( $S2 );

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 1, '$readready after HUP' );

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->__memberof_set is undef' );

# HUP of pipe

my ( $P1, $P2 ) = $loop->pipepair() or die "Cannot pipepair - $!";
my ( $N1, $N2 ) = map {
   IO::Async::Notifier->new( read_handle => $_,
      on_read_ready   => sub { $readready = 1; },
      want_writeready => 0,
   ) } ( $P1, $P2 );

$loop->add( $N1 );

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 0, '$readready before pipe HUP' );

undef $N2;
close( $P2 );

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 1, '$readready after pipe HUP' );

$loop->remove( $N1 );
