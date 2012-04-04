#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2012 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Epoll;

use strict;
use warnings;

our $VERSION = '0.12';
use constant API_VERSION => '0.33';

# Only Linux is known always to be able to report EOF conditions on
# filehandles using EPOLLHUP
# This is probably redundant as epoll is probably Linux-only also, but it
# doesn't harm anything to test specially.
use constant _CAN_ON_HANGUP => ( $^O eq "linux" );

use base qw( IO::Async::Loop );

use Carp;

use IO::Epoll qw(
   epoll_create epoll_ctl epoll_pwait 
   EPOLL_CTL_ADD EPOLL_CTL_MOD EPOLL_CTL_DEL
   EPOLLIN EPOLLOUT EPOLLHUP EPOLLERR
);

use POSIX qw( EINTR EPERM SIG_BLOCK SIG_UNBLOCK sigprocmask sigaction ceil );

=head1 NAME

L<IO::Async::Loop::Epoll> - use C<IO::Async> with C<epoll> on Linux

=head1 SYNOPSIS

 use IO::Async::Loop::Epoll;

 use IO::Async::Stream;
 use IO::Async::Signal;

 my $loop = IO::Async::Loop::Epoll->new();

 $loop->add( IO::Async::Stream->new(
       read_handle => \*STDIN,
       on_read => sub {
          my ( $self, $buffref ) = @_;
          while( $$buffref =~ s/^(.*)\r?\n// ) {
             print "You said: $1\n";
          }
       },
 ) );

 $loop->add( IO::Async::Signal->new(
       name => 'INT',
       on_receipt => sub {
          print "SIGINT, will now quit\n";
          $loop->loop_stop;
       },
 ) );

 $loop->loop_forever();

=head1 DESCRIPTION

This subclass of L<IO::Async::Loop> uses L<IO::Epoll> to perform read-ready
and write-ready tests so that the OZ<>(1) high-performance multiplexing of
Linux's C<epoll_pwait(2)> syscall can be used.

The C<epoll> Linux subsystem uses a registration system similar to the higher
level L<IO::Poll> object wrapper, meaning that better performance can be
achieved in programs using a large number of filehandles. Each
C<epoll_pwait(2)> syscall only has an overhead proportional to the number of
ready filehandles, rather than the total number being watched. For more
detail, see the C<epoll(7)> manpage.

This class uses the C<epoll_pwait(2)> system call, which atomically switches
the process's signal mask, performs a wait exactly as C<epoll_wait(2)> would,
then switches it back. This allows a process to block the signals it cares
about, but switch in an empty signal mask during the poll, allowing it to 
handle file IO and signals concurrently.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $loop = IO::Async::Loop::Epoll->new()

This function returns a new instance of a C<IO::Async::Loop::Epoll> object.

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $epoll = epoll_create(10); # Just made up 10. Kernel will readjust
   defined $epoll or croak "Cannot create epoll handle - $!";

   my $self = $class->SUPER::__new( %args );

   $self->{epoll} = $epoll;
   $self->{sigmask} = POSIX::SigSet->new();
   $self->{maxevents} = 8;

   $self->{fakeevents} = {};

   $self->{signals} = {};

   return $self;
}

=head1 METHODS

As this is a subclass of L<IO::Async::Loop>, all of its methods are inherited.
Expect where noted below, all of the class's methods behave identically to
C<IO::Async::Loop>.

=cut

sub DESTROY
{
   my $self = shift;

   foreach my $signal ( keys %{ $self->{signals} } ) {
      $self->unwatch_signal( $signal );
   }
}

=head2 $count = $loop->loop_once( $timeout )

This method calls the C<poll()> method on the stored C<IO::Epoll> object,
passing in the value of C<$timeout>, and processes the results of that call.
It returns the total number of C<IO::Async::Notifier> callbacks invoked, or
C<undef> if the underlying C<epoll_pwait()> method returned an error. If the
C<epoll_pwait()> was interrupted by a signal, then 0 is returned instead.

=cut

sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   $self->_adjust_timeout( \$timeout );

   # Round up to next milisecond to avoid zero timeouts
   my $msec = defined $timeout ? ceil( $timeout * 1000 ) : -1;

   my $ret = epoll_pwait( $self->{epoll}, $self->{maxevents}, $msec, $self->{sigmask} );

   return undef if !$ret and $! != EINTR;

   my $count = 0;

   my $iowatches = $self->{iowatches};

   my $fakeevents = $self->{fakeevents};
   my @fakeevents = map { [ $_ => $fakeevents->{$_} ] } keys %$fakeevents;

   foreach my $ev ( @$ret, @fakeevents ) {
      my ( $fd, $bits ) = @$ev;

      my $watch = $iowatches->{$fd};

      if( $bits & (EPOLLIN|EPOLLHUP|EPOLLERR) ) {
         $watch->[1]->() if $watch->[1];
         $count++;
      }

      if( $bits & (EPOLLOUT|EPOLLHUP) ) {
         $watch->[2]->() if $watch->[2];
         $count++;
      }

      if( $bits & (EPOLLHUP|EPOLLERR) ) {
         $watch->[3]->() if $watch->[3];
         $count++;
      }
   }

   my $signals = $self->{signals};
   foreach my $sigslot ( values %$signals ) {
      if( $sigslot->[1] ) {
         $sigslot->[0]->();
         $sigslot->[1] = 0;
         $count++;
      }
   }

   $count += $self->_manage_queues;

   # If we entirely filled the event buffer this time, we may have missed some
   # Lets get a bigger buffer next time
   $self->{maxevents} *= 2 if @$ret == $self->{maxevents};

   return $count;
}

sub watch_io
{
   my $self = shift;
   my %params = @_;

   my $epoll = $self->{epoll};

   $self->__watch_io( %params );

   my $handle = $params{handle};
   my $fd = $handle->fileno;

   my $curmask = $self->{masks}->{$fd} || 0;

   my $mask = $curmask;
   $params{on_read_ready}  and $mask |= EPOLLIN;
   $params{on_write_ready} and $mask |= EPOLLOUT;
   $params{on_hangup}      and $mask |= EPOLLHUP;

   my $fakeevents = $self->{fakeevents};

   if( !$curmask ) {
      if( epoll_ctl( $epoll, EPOLL_CTL_ADD, $fd, $mask ) == 0 ) {
         # All OK
      }
      elsif( $! == EPERM ) {
         # The filehandle isn't epoll'able. This means kernel thinks it should
         # always be ready.
         $fakeevents->{$fd} = $mask;
      }
      else {
         croak "Cannot EPOLL_CTL_ADD($fd,$mask) - $!";
      }

      $self->{masks}->{$fd} = $mask;
   }
   elsif( $mask != $curmask ) {
      if( exists $fakeevents->{$fd} ) {
         $fakeevents->{$fd} = $mask;
      }
      else {
         epoll_ctl( $epoll, EPOLL_CTL_MOD, $fd, $mask ) == 0
            or croak "Cannot EPOLL_CTL_MOD($fd,$mask) - $!";
      }

      $self->{masks}->{$fd} = $mask;
   }
}

sub unwatch_io
{
   my $self = shift;
   my %params = @_;

   $self->__unwatch_io( %params );

   my $epoll = $self->{epoll};

   my $handle = $params{handle};
   my $fd = $handle->fileno;

   my $curmask = $self->{masks}->{$fd} or return;

   my $mask = $curmask;
   $params{on_read_ready}  and $mask &= ~EPOLLIN;
   $params{on_write_ready} and $mask &= ~EPOLLOUT;
   $params{on_hangup}      and $mask &= ~EPOLLHUP;

   my $fakeevents = $self->{fakeevents};

   if( $mask ) {
      if( exists $fakeevents->{$fd} ) {
         $fakeevents->{$fd} = $mask;
      }
      else {
         epoll_ctl( $epoll, EPOLL_CTL_MOD, $fd, $mask ) == 0
            or croak "Cannot EPOLL_CTL_MOD($fd,$mask) - $!";
      }

      $self->{masks}->{$fd} = $mask;
   }
   else {
      if( exists $fakeevents->{$fd} ) {
         delete $fakeevents->{$fd};
      }
      else {
         epoll_ctl( $epoll, EPOLL_CTL_DEL, $fd, 0 ) == 0
            or croak "Cannot EPOLL_CTL_DEL($fd) - $!";
      }

      delete $self->{masks}->{$fd};
   }
}

# override
sub watch_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   # We cannot simply set $SIG{$signal} = $code here, because of perl bug
   #   http://rt.perl.org/rt3/Ticket/Display.html?id=82040
   # Instead, we'll store a tiny piece of code that just sets a flag, and
   # check the flags on return from the epoll_pwait call.

   $self->{signals}{$signal} = [ $code, 0, $SIG{$signal} ];
   my $pending = \$self->{signals}{$signal}[1];

   my $signum = $self->signame2num( $signal );
   sigprocmask( SIG_BLOCK, POSIX::SigSet->new( $signum ) );

   # Note this is an unsafe signal handler, and as such it should do as little
   # as possible.
   my $sigaction = POSIX::SigAction->new( sub { $$pending = 1 } );
   sigaction( $signum, $sigaction ) or croak "Unable to sigaction - $!";
}

# override
sub unwatch_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   # When we saved the original value, we might have got an undef. But %SIG
   # doesn't like having undef assigned back in, so we need to translate
   $SIG{$signal} = $self->{signals}{$signal}[2] || 'DEFAULT';

   delete $self->{signals}{$signal};
   
   my $signum = $self->signame2num( $signal );

   sigprocmask( SIG_UNBLOCK, POSIX::SigSet->new( $signum ) );
}

=head1 SEE ALSO

=over 4

=item *

L<IO::Epoll> - Scalable IO Multiplexing for Linux 2.5.44 and higher

=item *

L<IO::Async::Loop::Poll> - use IO::Async with poll(2)

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
