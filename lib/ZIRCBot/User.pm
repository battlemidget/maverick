package ZIRCBot::User;

use strict;
use warnings;
use Carp;
use ZIRCBot::Access;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

has 'nick' => (
	is => 'rw',
	required => 1,
);

has 'host' => (
	is => 'rw',
);

has 'username' => (
	is => 'rw',
);

has 'realname' => (
	is => 'rw',
);

has 'is_away' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'away_message' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'is_registered' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'identity' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'is_bot' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'is_ircop' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'ircop_message' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'is_idle' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'idle_time' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'signon_time' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'bot_access' => (
	is => 'rw',
	lazy => 1,
	default => ACCESS_NONE,
	init_arg => undef,
	clearer => 1,
);

has 'channels' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

sub add_channel {
	my $self = shift;
	my $channel = shift // croak 'No channel name provided';
	$self->channels->{lc $channel} = {};
}

sub remove_channel {
	my $self = shift;
	my $channel = shift // croak 'No channel name provided';
	delete $self->channels->{lc $channel};
}

sub channel_access {
	my $self = shift;
	my $channel = shift // croak 'No channel name provided';
	if (@_) {
		$self->channels->{lc $channel}{access} = shift;
	}
	return undef unless exists $self->channels->{lc $channel};
	return $self->channels->{lc $channel}{access} // ACCESS_NONE;
}

1;
