#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Epoll;

use strict;

our $VERSION = '0.01';

use IO::Async::Loop::IO_Poll 0.17;
use base qw( IO::Async::Loop::IO_Poll );

use IO::Async::SignalProxy; # just for signame2num

use Carp;

use IO::Epoll;

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

This subclass of C<IO::Async::Loop::IO_Poll> uses an C<IO::Epoll> object 
instead of a C<IO::Poll> to perform read-ready and write-ready tests so that
the OZ<>(1) high-performance multiplexing of Linux's C<epoll_pwait(2)> syscall
can be used.

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

=head2 $loop = IO::Async::Loop::Epoll->new( %args )

This function returns a new instance of a C<IO::Async::Loop::Epoll> object. It
takes the following named arguments:

=over 8

=item C<poll>

The C<IO::Epoll> object to use for notification. Optional; if a value is not
given, a new C<IO::Epoll> object will be constructed.

=back

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $poll = delete $args{poll};

   $poll ||= IO::Epoll->new();

   # Switch IO::Epoll object into Ppoll-compatible mode by accessing its
   # signal mask. Don't need to actually change it, just calling this method
   # is sufficient
   $poll->sigmask;

   my $self = $class->SUPER::new( %args, poll => $poll );

   $self->{restore_SIG} = {};

   return $self;
}

=head1 METHODS

As this is a subclass of L<IO::Async::Loop::IO_Poll>, all of its methods are
inherited. Expect where noted below, all of the class's methods behave
identically to C<IO::Async::Loop::IO_Poll>.

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

   my $poll = $self->{poll};

   my $pollret = $poll->poll( $timeout );
   return undef unless defined $pollret;

   return 0 if $pollret == -1 and $! == EINTR; # Caught signal
   return undef if $pollret == -1;             # Some other error

   return $self->post_poll();
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
