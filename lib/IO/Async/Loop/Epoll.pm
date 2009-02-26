#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008,2009 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Epoll;

use strict;

our $VERSION = '0.02';

use base qw( IO::Async::Loop );

use IO::Async::SignalProxy; # just for signame2num

use Carp;

use IO::Epoll qw(
   epoll_create epoll_ctl epoll_pwait 
   EPOLL_CTL_ADD EPOLL_CTL_MOD EPOLL_CTL_DEL
   EPOLLIN EPOLLOUT EPOLLHUP
);

use POSIX qw( EINTR SIG_BLOCK SIG_UNBLOCK sigprocmask );

=head1 NAME

L<IO::Async::Loop::Epoll> - a Loop using an C<IO::Epoll> object

=head1 SYNOPSIS

 use IO::Async::Loop::Epoll;

 my $loop = IO::Async::Loop::Epoll->new();

 $loop->add( ... );
 $loop->attach_signal( HUP => sub { ... } );

 $loop->loop_forever();

=head1 DESCRIPTION

This subclass of C<IO::Async::Loop> uses C<IO::Epoll> to perform read-ready
and write-ready tests so that the OZ<>(1) high-performance multiplexing of
Linux's C<epoll_pwait(2)> syscall can be used.

The C<epoll> Linux subsystem uses a registration system similar to the higher
level C<IO::Poll> object wrapper, meaning that better performance can be
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

   $self->{restore_SIG} = {};

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

   foreach my $signal ( keys %{ $self->{restore_SIG} } ) {
      $self->detach_signal( $signal );
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

   my $msec = defined $timeout ? $timeout * 1000 : -1;

   my $ret = epoll_pwait( $self->{epoll}, 20, $msec, $self->{sigmask} );

   return 0 if !$ret and $! == EINTR; # Caught signal
   return undef if !$ret;             # Some other error

   my $count = 0;

   foreach my $ev ( @$ret ) {
      my ( $fd, $bits ) = @$ev;
      my $notifier = $self->{fds}{$fd};

      if( $bits & EPOLLIN  or $notifier->want_readready  and $bits & EPOLLHUP ) {
         $notifier->on_read_ready;
         $count++;
      }

      if( $bits & EPOLLOUT or $notifier->want_writeready and $bits & EPOLLHUP ) {
         $notifier->on_write_ready;
         $count++;
      }
   }

   my $timequeue = $self->{timequeue};
   $count += $timequeue->fire if $timequeue;

   return $count;
}

sub _notifier_removed
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $epoll = $self->{epoll};

   my $read_fd;
   
   if( defined $notifier->read_handle ) {
      $read_fd = $notifier->read_fileno;

      delete $self->{fds}{$read_fd};
      epoll_ctl( $epoll, EPOLL_CTL_DEL, $read_fd, 0 );
   }

   if( defined $notifier->write_handle and $notifier->write_fileno != $read_fd ) {
      my $write_fd = $notifier->write_fileno;

      delete $self->{fds}{$write_fd};
      epoll_ctl( $epoll, EPOLL_CTL_DEL, $write_fd, 0 );
   }
}

sub __notifier_want_rw
{
   my $self = shift;
   my ( $notifier, $fd, $read, $write ) = @_;

   my $epoll = $self->{epoll};

   my $mask = ( $read ? EPOLLIN : 0 ) | ( $write ? EPOLLOUT : 0 );

   if( exists $self->{fds}{$fd} ) {
      epoll_ctl( $epoll, EPOLL_CTL_MOD, $fd, $mask );
   }
   else {
      $self->{fds}{$fd} = $notifier;
      epoll_ctl( $epoll, EPOLL_CTL_ADD, $fd, $mask );
   }
}

sub __notifier_want_readready
{
   my $self = shift;
   my ( $notifier, $want ) = @_;

   my $read_fd = $notifier->read_fileno;
   defined $read_fd or return;

   if( defined $notifier->write_fileno and $notifier->write_fileno == $read_fd ) {
      return $self->__notifier_want_rw( $notifier, $read_fd, $want, $notifier->want_writeready );
   }
   else {
      return $self->__notifier_want_rw( $notifier, $read_fd, $want, 0 );
   }
}

sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want ) = @_;

   my $write_fd = $notifier->write_fileno;
   defined $write_fd or return;

   if( defined $notifier->read_fileno and $notifier->read_fileno == $write_fd ) {
      return $self->__notifier_want_rw( $notifier, $write_fd, $notifier->want_readready, $want );
   }
   else {
      return $self->__notifier_want_rw( $notifier, $write_fd, 0, $want );
   }
}

# override
sub attach_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   # Don't allow anyone to trash an existing signal handler
   !defined $SIG{$signal} or !ref $SIG{$signal} or croak "Cannot override signal handler for $signal";

   $self->{restore_SIG}->{$signal} = $SIG{$signal};

   my $signum = IO::Async::SignalProxy::signame2num( $signal );

   sigprocmask( SIG_BLOCK, POSIX::SigSet->new( $signum ) );

   $SIG{$signal} = $code;
}

# override
sub detach_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   # When we saved the original value, we might have got an undef. But %SIG
   # doesn't like having undef assigned back in, so we need to translate
   $SIG{$signal} = $self->{restore_SIG}->{$signal} || 'DEFAULT';

   delete $self->{restore_SIG}->{$signal};
   
   my $signum = IO::Async::SignalProxy::signame2num( $signal );

   sigprocmask( SIG_UNBLOCK, POSIX::SigSet->new( $signum ) );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Epoll> - Scalable IO Multiplexing for Linux 2.5.44 and higher

=item *

L<IO::Async::Loop::IO_Poll> - a Loop using an IO::Poll object 

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
