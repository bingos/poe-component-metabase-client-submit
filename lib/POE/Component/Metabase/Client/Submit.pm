package POE::Component::Metbase::Client::Submit;

use strict;
use warnings;
use Carp;
use HTTP::Request::Common ();
use JSON;
use POE qw(Component::Client::HTTP);
use URI;
use vars qw($VERSION);

$VERSION = '0.02';

sub submit {
  my $package = shift;
  my %opts = @_;
  $opts{lc $_} = delete $opts{$_} for keys %opts;
  my $options = delete $opts{options};
  my $self = bless \%opts, $package;
  $self->{session_id} = POE::Session->create(
	object_states => [
	   $self => [ qw(_start _submit _response) ],
	],
	heap => $self,
	( ref($options) eq 'HASH' ? ( options => $options ) : () ),
  )->ID();
  return $self;
}

sub _start {
  my ($kernel,$session,$sender,$self) = @_[KERNEL,SESSION,SENDER,OBJECT];
  $self->{session_id} = $session->ID();
  if ( $kernel == $sender and !$self->{session} ) {
        croak "Not called from another POE session and 'session' wasn't set\n";
  }
  my $sender_id;
  if ( $self->{session} ) {
    if ( my $ref = $kernel->alias_resolve( $self->{session} ) ) {
        $sender_id = $ref->ID();
    }
    else {
        croak "Could not resolve 'session' to a valid POE session\n";
    }
  }
  else {
    $sender_id = $sender->ID();
  }
  $kernel->refcount_increment( $sender_id, __PACKAGE__ );
  $kernel->detach_myself;
  $self->{sender_id} = $sender_id;
  if ( $self->{http_alias} ) {
     my $http_ref = $kernel->alias_resolve( $self->{http_alias} );
     $self->{http_id} = $http_ref->ID() if $http_ref;
  }
  unless ( $self->{http_id} ) {
    $self->{http_id} = 'metabaseclient' . $$ . $self->{session_id};
    POE::Component::Client::HTTP->spawn(
	Alias           => $self->{http_id},
	FollowRedirects => 2,
        Timeout         => 60,
        Agent           => 'Mozilla/5.0 (X11; U; Linux i686; en-US; '
                . 'rv:1.1) Gecko/20020913 Debian/1.1-1',
    );
  }
  $kernel->yield( '_submit' );
  return;
}

sub _submit {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $profile = $self->{profile};
  my $fact = $self->{fact};
  my $path = sprintf 'submit/%s', $fact->type;
  # XXX: should be $self->profile->guid
  $fact->set_creator_id($profile->{metadata}{core}{guid}[1]);
  my $req_url = $self->_abs_url($path);
  my $request = HTTP::Request::Common::POST(
    $req_url,
    Content_Type => 'application/json',
    Accept => 'application/json',
    Content => JSON->new->encode({
      fact => $fact->as_struct,
      submitter => $profile->as_struct,
    }),
  );
  $kernel->post(
    $self->{http_id},        # posts to the 'ua' alias
    'request',   # posts to ua's 'request' state
    '_response',  # which of our states will receive the response
    $request,    # an HTTP::Request object
  );
  return;
}

sub _response {
  my ($kernel,$self,$request_packet,$response_packet) = @_[KERNEL,OBJECT,ARG0,ARG1];
  my $response = $response_packet->[0];
  return;
}

sub _abs_url {
  my ($self, $str) = @_;
  my $req_url = URI->new($str)->abs($self->url);
}

'Submit this';
__END__
