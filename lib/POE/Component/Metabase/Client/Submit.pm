package POE::Component::Metabase::Client::Submit;

use strict;
use warnings;
use Carp ();
use HTTP::Status qw[:constants];
use HTTP::Request::Common ();
use JSON;
use POE qw[Component::Client::HTTP];
use URI;
use vars qw[$VERSION];

$VERSION = '0.02';

my @valid_args;
BEGIN {
  @valid_args = qw(profile secret uri fact event session http_alias);

  for my $arg (@valid_args) {
    no strict 'refs';
    *$arg = sub { $_[0]->{$arg}; }
  }
}

sub submit {
  my ($class,%opts) = @_;
  $opts{lc $_} = delete $opts{$_} for keys %opts;
  my $options = delete $opts{options};
  my $args = $class->__validate_args(
    [ %opts ],
    { 
      ( map { $_ => 0 } @valid_args ), 
      ( map { $_ => 1 } qw(profile secret uri event) ) 
    } # hehe
  );

  my $self = bless $args, $class;

  Carp::confess( "'profile' argument for $class must be a Metabase::User::Profile" )
    unless $self->profile->isa('Metabase::User::Profile');
  Carp::confess( "'profile' argument for $class must be a Metabase::User::secret" )
    unless $self->secret->isa('Metabase::User::Secret');

  $self->{session_id} = POE::Session->create(
	  object_states => [
	    $self => [ qw(_start _dispatch _submit _response _register _guid_exists _http_req) ],
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
        Carp::confess "Not called from another POE session and 'session' wasn't set\n";
  }
  my $sender_id;
  if ( $self->{session} ) {
    if ( my $ref = $kernel->alias_resolve( $self->{session} ) ) {
        $sender_id = $ref->ID();
    }
    else {
        Carp::confess "Could not resolve 'session' to a valid POE session\n";
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
    $self->{my_httpc} = 1;
  }
  $kernel->yield( '_submit' );
  return;
}

sub _submit {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $fact = $self->fact;
  my $path = sprintf 'submit/%s', $fact->type;

  $fact->set_creator($self->profile->resource)
    unless $fact->creator;

  my $req_uri = $self->_abs_uri($path);

  my $req = HTTP::Request::Common::POST(
    $req_uri,
    Content_Type => 'application/json',
    Accept       => 'application/json',
    Content      => JSON->new->encode($fact->as_struct),
  );
  $req->authorization_basic($self->profile->resource->guid, $self->secret->content);
  $kernel->yield( '_http_req', $req, 'submit' );
  return;
}

sub _guid_exists {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $path = sprintf 'guid/%s', $self->profile->guid;
  my $req_uri = $self->_abs_uri($path);
  my $req = HTTP::Request::Common::HEAD( $req_uri );
  $kernel->yield( '_http_req', $req, 'guid' );
  return;
}

sub _register {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $req_uri = $self->_abs_uri('register');

  for my $type ( qw/profile secret/ ) {
    $self->$type->set_creator( $self->$type->resource ) 
      unless $self->$type->creator;
  }

  my $req = HTTP::Request::Common::POST(
    $req_uri,
    Content_Type => 'application/json',
    Accept       => 'application/json',
    Content      => JSON->new->encode([
      $self->profile->as_struct, $self->secret->as_struct
    ]),
  );

  $kernel->yield( '_http_req', $req, 'register' );
  return;
}

sub _http_req {
  my ($self,$req,$id) = @_[OBJECT,ARG0,ARG1];
  $poe_kernel->post(
    $self->{http_id},
    'request',
    '_response',
    $req,
    $id,
  );
  return;
}

sub _response {
  my ($kernel,$self,$request_packet,$response_packet) = @_[KERNEL,OBJECT,ARG0,ARG1];
  my $tag = $request_packet->[1];
  my $res = $response_packet->[0];
  # and punt an event back to the requesting session
  if ( $tag eq 'submit' and $res->code == HTTP_UNAUTHORIZED ) {
    $kernel->yield( '_guid_exists' );
    return;
  }
  if ( $tag eq 'guid' ) { 
    if ( $res->is_success ) {
      $self->{_error} = 'authentication failed';
      # dispatch
      return;
    }
    $kernel->yield( '_register' );
    return;
  }
  if ( $tag eq 'register' ) {
    unless ( $res->is_success ) {
      $self->{_error} = 'registration failed';
      # dispatch
      return;
    }
    $kernel->yield( '_submit' );
    return;
  }
  unless ( $res->is_success ) {
    $self->{_error} = 'fact submission failed';
  }
  else {
    $self->{success} = 1;
  }
  $kernel->yield( '_dispatch' );
  return;
}

sub _dispatch {
  
}

#--------------------------------------------------------------------------#
# private methods
#--------------------------------------------------------------------------#

# Stolen from ::Fact.
# XXX: Should refactor this into something in Fact, which we can then rely on.
# -- rjbs, 2009-03-30
sub __validate_args {
  my ($self, $args, $spec) = @_;
  my $hash = (@$args == 1 and ref $args->[0]) ? { %{ $args->[0]  } }
           : (@$args == 0)                    ? { }
           :                                    { @$args };

  my @errors;

  for my $key (keys %$hash) {
    push @errors, qq{unknown argument "$key" when constructing $self}
      unless exists $spec->{ $key };
  }

  for my $key (grep { $spec->{ $_ } } keys %$spec) {
    push @errors, qq{missing required argument "$key" when constructing $self}
      unless defined $hash->{ $key };
  }

  Carp::confess(join qq{\n}, @errors) if @errors;

  return $hash;
}

sub _abs_uri {
  my ($self, $str) = @_;
  my $req_uri = URI->new($str)->abs($self->uri);
}

sub _error {
  my ($self, $res, $prefix) = @_;
  $prefix ||= "unrecognized error";
  if ( ref($res) && $res->header('Content-Type') eq 'application/json') {
    my $entity = JSON->new->decode($res->content);
    return "$prefix\: $entity->{error}";
  } 
  else {
    return "$prefix\: " . $res->message;
  }
}

'Submit this';
__END__
