#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008,2009 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Epoll;

use strict;

our $VERSION = '0.04';

use base qw( IO::Async::Loop );

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

 $loop->add( IO::Async::Signal->new(
       name =< 'HUP',
       on_receipt => sub { ... },
 ) );

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

   my $iowatches = $self->{iowatches};

   foreach my $ev ( @$ret ) {
      my ( $fd, $bits ) = @$ev;

      my $watch = $iowatches->{$fd};

      if( $bits & (EPOLLIN|EPOLLHUP) ) {
         $watch->[1]->() if $watch->[1];
         $count++;
      }

      if( $bits & (EPOLLOUT|EPOLLHUP) ) {
         $watch->[2]->() if $watch->[2];
         $count++;
      }
   }

   my $timequeue = $self->{timequeue};
   $count += $timequeue->fire if $timequeue;

   return $count;
}

# override
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

   if( !$curmask ) {
      epoll_ctl( $epoll, EPOLL_CTL_ADD, $fd, $mask ) == 0
         or carp "Cannot EPOLL_CTL_ADD($fd,$mask) - $!";
   }
   elsif( $mask != $curmask ) {
      epoll_ctl( $epoll, EPOLL_CTL_MOD, $fd, $mask ) == 0
         or carp "Cannot EPOLL_CTL_MOD($fd,$mask) - $!";
   }

   $self->{masks}->{$fd} = $mask;
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

   if( $mask ) {
      epoll_ctl( $epoll, EPOLL_CTL_MOD, $fd, $mask ) == 0
         or carp "Cannot EPOLL_CTL_MOD($fd,$mask) - $!";
      $self->{masks}->{$fd} = $mask;
   }
   else {
      epoll_ctl( $epoll, EPOLL_CTL_DEL, $fd, 0 ) == 0
         or carp "Cannot EPOLL_CTL_DEL($fd) - $!";
      delete $self->{masks}->{$fd};
   }
}

# override
sub watch_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   $self->{restore_SIG}->{$signal} = $SIG{$signal};

   my $signum = $self->signame2num( $signal );

   sigprocmask( SIG_BLOCK, POSIX::SigSet->new( $signum ) );

   $SIG{$signal} = $code;
}

# override
sub unwatch_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   exists $SIG{$signal} or croak "Unrecognised signal name $signal";

   # When we saved the original value, we might have got an undef. But %SIG
   # doesn't like having undef assigned back in, so we need to translate
   $SIG{$signal} = $self->{restore_SIG}->{$signal} || 'DEFAULT';

   delete $self->{restore_SIG}->{$signal};
   
   my $signum = $self->signame2num( $signal );

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
