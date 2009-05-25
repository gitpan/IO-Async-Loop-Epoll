#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;
use Test::Exception;

use IO::Async::Loop::Epoll;

my $loop = IO::Async::Loop::Epoll->new();

ok( defined $loop, '$loop defined' );
isa_ok( $loop, "IO::Async::Loop::Epoll", '$loop isa IO::Async::Loop::Epoll' );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;

$loop->watch_io(
   handle => $S1,
   on_read_ready  => sub { $readready = 1 },
);

$S2->syswrite( "data\n" );

# We should still wait a little while even thought we expect to be ready
# immediately, because talking to ourself with 0 poll timeout is a race
# condition - we can still race with the kernel.

$loop->loop_once( 0.1 );

is( $readready, 1, '$readready after loop_once' );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

# Write-ready

my $writeready = 0;

$loop->watch_io(
   handle => $S1,
   on_write_ready => sub { $writeready = 1 },
);

$loop->loop_once( 0.1 );

is( $writeready, 1, '$writeready after loop_once' );

# loop_forever

$loop->watch_io(
   handle => $S2,
   on_write_ready => sub { $loop->loop_stop() },
);

$writeready = 0;

$SIG{ALRM} = sub { die "Test timed out"; };
alarm( 1 );

$loop->loop_forever();

alarm( 0 );

is( $writeready, 1, '$writeready after loop_forever' );

$loop->unwatch_io(
   handle => $S2,
   on_write_ready => 1,
);

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 0, '$readready before HUP' );

close( $S2 );

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 1, '$readready after HUP' );

$loop->unwatch_io(
   handle => $S1,
   on_read_ready => 1,
);

# HUP of pipe

my ( $P1, $P2 ) = $loop->pipepair() or die "Cannot pipepair - $!";

$loop->watch_io(
   handle => $P1,
   on_read_ready => sub { $readready = 1 },
);

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 0, '$readready before pipe HUP' );

close( $P2 );

$readready = 0;
$loop->loop_once( 0.1 );

is( $readready, 1, '$readready after pipe HUP' );

$loop->unwatch_io(
   handle => $P1,
   on_read_ready => 1,
);
