package ZIRCBot::IRC;

use Carp;
use List::Util 'any';
use Mojo::IRC;
use Mojo::Util 'dumper';
use Parse::IRC;
use Scalar::Util 'weaken';
use ZIRCBot::Access;
use ZIRCBot::Channel;
use ZIRCBot::User;

use Moo::Role;
use warnings NONFATAL => 'all';

my @irc_events = qw/irc_333 irc_335 irc_422 irc_rpl_motdstart irc_rpl_endofmotd
	irc_rpl_notopic irc_rpl_topic irc_rpl_namreply irc_rpl_whoreply irc_rpl_endofwho
	irc_rpl_whoisuser irc_rpl_whoischannels irc_rpl_away irc_rpl_whoisoperator
	irc_rpl_whoisaccount irc_rpl_whoisidle irc_rpl_endofwhois
	irc_notice irc_public irc_privmsg irc_invite irc_kick irc_join
	irc_part irc_quit irc_nick irc_mode irc_default/;
sub get_irc_events { @irc_events }

has 'channels' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub channel {
	my $self = shift;
	my $name = shift // croak "No channel name provided";
	return $self->channels->{lc $name} //= ZIRCBot::Channel->new(name => $name);
}

has 'users' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub user {
	my $self = shift;
	my $nick = shift // croak "No user nick provided";
	return $self->users->{lc $nick} //= ZIRCBot::User->new(nick => $nick);
}

has 'irc' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_irc {
	my $self = shift;
	my $irc = Mojo::IRC->new($self->_connect_options);
	$irc->parser(Parse::IRC->new(ctcp => 1, public => 1));
	return $irc;
}

sub _connect_options {
	my $self = shift;
	my ($server, $port, $server_pass, $ssl, $nick, $realname) = 
		@{$self->config->{irc}}{qw/server port server_pass ssl nick realname/};
	die "IRC server is not configured\n" unless defined $server and length $server;
	$server .= ":$port" if defined $port and length $port;
	$nick //= 'ZIRCBot',
	$realname = sprintf 'ZIRCBot %s by %s', $self->bot_version, 'Grinnz'
		unless defined $realname and length $realname;
	my %options = (
		server => $server,
		nick => $nick,
		user => $nick,
		name => $realname,
	);
	$options{tls} = {} if $ssl;
	$options{pass} = $server_pass if defined $server_pass and length $server_pass;
	return %options;
}

before 'start' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$irc->register_default_event_handlers;
	weaken $self;
	foreach my $event ($self->get_irc_events) {
		my $handler = $self->can($event) // die "No handler found for IRC event $event\n";
		$irc->on($event => sub { $self->$handler(@_) });
	}
	$irc->on(close => sub { $self->irc_disconnected($_[0]) });
	$irc->on(error => sub { $self->logger->error($_[1]); $_[0]->disconnect; });
	
	my $server = $irc->server;
	$self->logger->debug("Connecting to $server");
	$irc->connect(sub { $self->irc_connected(@_) });
};

before 'stop' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$self->logger->debug("Disconnecting from server");
	$irc->disconnect(sub {});
};

# IRC methods

sub irc_connected {
	my ($self, $irc, $err) = @_;
	if ($err) {
		$self->logger->error($err);
	} else {
		$self->irc_identify($irc);
		$self->irc_autojoin($irc);
	}
}

sub irc_identify {
	my ($self, $irc) = @_;
	my $nick = $self->config->{irc}{nick};
	my $pass = $self->config->{irc}{password};
	if (defined $nick and length $nick and defined $pass and length $pass) {
		$self->("Identifying with NickServ as $nick");
		$irc->write(quote => "NICKSERV identify $nick $pass");
	}
}

sub irc_autojoin {
	my ($self, $irc) = @_;
	my @channels = split /[\s,]+/, $self->config->{channels}{autojoin};
	return unless @channels;
	my $channels_str = join ', ', @channels;
	$self->logger->debug("Joining channels: $channels_str");
	$irc->write(join => $_) for @channels;
}

sub irc_disconnected {
	my $self = shift;
	my $irc = $self->irc;
	$self->logger->debug("Disconnected from server");
	if (!$self->is_stopping and ($self->config->{irc}{reconnect}//1)) {
		my $server = $irc->server;
		$self->logger->debug("Reconnecting to $server");
		weaken $self;
		Mojo::IOLoop->next_tick(sub { $irc->connect(sub { $self->irc_connected(@_) }) });
	}
}

# IRC event callbacks

sub irc_default {
	my ($self, $irc, $message) = @_;
	my $command = $message->{command} // '';
	my $params_str = join ', ', map { "'$_'" } @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("[$command] <$from> [ $params_str ]");
}

sub irc_rpl_motdstart { # RPL_MOTDSTART
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_endofmotd { # RPL_ENDOFMOTD
	my ($self, $irc, $message) = @_;
}

sub irc_422 { # ERR_NOMOTD
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_notopic { # RPL_NOTOPIC
	my ($self, $irc, $message) = @_;
	my ($channel) = @{$message->{params}};
	$self->logger->debug("No topic set for $channel");
	$self->channel($channel)->topic(undef);
}

sub irc_rpl_topic { # RPL_TOPIC
	my ($self, $irc, $message) = @_;
	my ($to, $channel, $topic) = @{$message->{params}};
	$self->logger->debug("Topic for $channel: $topic");
	$self->channel($channel)->topic($topic);
}

sub irc_333 { # topic info
	my ($self, $irc, $message) = @_;
	my ($to, $channel, $changed_by, $changed_at) = @{$message->{params}};
	my $changed_at_str = localtime($changed_at);
	$self->logger->debug("Topic for $channel was changed at $changed_at_str by $changed_by");
}

sub irc_rpl_namreply { # RPL_NAMREPLY
	my ($self, $irc, $message) = @_;
	my ($to, $sym, $channel, $nicks) = @{$message->{params}};
	$self->logger->debug("Received names for $channel: $nicks");
	foreach my $nick (split /\s+/, $nicks) {
		my $access = ACCESS_NONE;
		if ($nick =~ s/^([-~&@%+])//) {
			$access = channel_access_level($1);
		}
		my $user = $self->user($nick);
		$user->add_channel($channel);
		$user->channel_access($channel => $access);
		$self->channel($channel)->add_user($nick);
	}
}

sub irc_rpl_whoreply { # RPL_WHOREPLY
	my ($self, $irc, $message) = @_;
	my ($to, $channel, $username, $host, $server, $nick, $state, $realname) = @{$message->{params}};
	$realname =~ s/^\d+\s+//;
	
	my ($away, $reg, $bot, $ircop, $access);
	if ($state =~ /([HG])(r?)(B?)(\*?)([-~&@%+]?)/) {
		$away = ($1 eq 'G') ? 1 : 0;
		$reg = $2 ? 1 : 0;
		$bot = $3 ? 1 : 0;
		$ircop = $4 ? 1 : 0;
		$access = $5 ? channel_access_level($5) : ACCESS_NONE;
	}
	
	$self->logger->debug("Received who reply for $nick in $channel");
	my $user = $self->user($nick);
	$user->host($host);
	$user->username($username);
	$user->realname($realname);
	$user->is_away($away);
	$user->is_registered($reg);
	$user->is_bot($bot);
	$user->is_ircop($ircop);
	$user->channel_access($channel => $access);
}

sub irc_rpl_endofwho { # RPL_ENDOFWHO
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoisuser { # RPL_WHOISUSER
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $username, $host, $star, $realname) = @{$message->{params}};
	$self->logger->debug("Received user info for $nick!$username\@$host: $realname");
	my $user = $self->user($nick);
	$user->host($host);
	$user->username($username);
	$user->realname($realname);
	$user->clear_is_registered;
	$user->clear_identity;
	$user->clear_bot_access;
	$user->clear_is_away;
	$user->clear_away_message;
	$user->clear_is_ircop;
	$user->clear_ircop_message;
	$user->clear_is_bot;
	$user->clear_is_idle;
	$user->clear_idle_time;
	$user->clear_signon_time;
	$user->clear_channels;
}

sub irc_rpl_whoischannels { # RPL_WHOISCHANNELS
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $channels) = @{$message->{params}};
	$self->logger->debug("Received channels for $nick: $channels");
	my $user = $self->user($nick);
	foreach my $channel (split /\s+/, $channels) {
		my $access = ACCESS_NONE;
		if ($channel =~ s/^([-~&@%+])//) {
			$access = channel_access_level($1);
		}
		$user->add_channel($channel);
		$user->channel_access($channel => $access);
		$self->channel($channel)->add_user($nick);
	}
}

sub irc_rpl_away { # RPL_AWAY
	my ($self, $irc, $message) = @_;
	my $msg = pop @{$message->{params}};
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received away message for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_away(1);
	$user->away_message($msg);
}

sub irc_rpl_whoisoperator { # RPL_WHOISOPERATOR
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $msg) = @{$message->{params}};
	$self->logger->debug("Received IRC Operator privileges for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_ircop(1);
	$user->ircop_message($msg);
}

sub irc_rpl_whoisaccount { # RPL_WHOISACCOUNT
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $identity) = @{$message->{params}};
	$self->logger->debug("Received identity for $nick: $identity");
	my $user = $self->user($nick);
	$user->is_registered(1);
	$user->identity($identity);
	$user->bot_access($self->user_access_level($identity));
}

sub irc_335 { # whois bot string
	my ($self, $irc, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received bot status for $nick");
	my $user = $self->user($nick);
	$user->is_bot(1);
}

sub irc_rpl_whoisidle { # RPL_WHOISIDLE
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $seconds, $signon) = @{$message->{params}};
	$self->logger->debug("Received idle status for $nick: $seconds, $signon");
	my $user = $self->user($nick);
	$user->is_idle(1);
	$user->idle_time($seconds);
	$user->signon_time($signon);
}

sub irc_rpl_endofwhois { # RPL_ENDOFWHOIS
	my ($self, $irc, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("End of whois reply for $nick");
}

sub irc_notice {
	my ($self, $irc, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->info("[notice $to] <$from> $msg") if $self->config->{main}{echo};
}

sub irc_public {
	my ($self, $irc, $message) = @_;
	my ($channel, $msg) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->info("[$channel] <$from> $msg") if $self->config->{main}{echo};
}

sub irc_privmsg {
	my ($self, $irc, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->info("[private] <$from> $msg") if $self->config->{main}{echo};
}

sub irc_invite {
	my ($self, $irc, $message) = @_;
	my ($to, $channel) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("User $from has invited $to to $channel");
}

sub irc_kick {
	my ($self, $irc, $message) = @_;
	my ($channel, $to) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("User $from has kicked $to from $channel");
	$self->channel($channel)->remove_user($to);
	$self->user($to)->remove_channel($channel);
	if (lc $to eq lc $irc->nick and any { lc $_ eq lc $channel }
			split /[\s,]+/, $self->config->{channels}{autojoin}) {
		$irc->write(join => $channel);
	}
}

sub irc_join {
	my ($self, $irc, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("User $from joined $channel");
	if ($from eq $irc->nick) {
		$self->channel($channel);
	}
	$self->channel($channel)->add_user($from);
	$self->user($from)->add_channel($channel);
	$irc->write(whois => $from);
}

sub irc_part {
	my ($self, $irc, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("User $from parted $channel");
	if ($from eq $irc->nick) {
	}
	$self->channel($channel)->remove_user($from);
	$self->user($from)->remove_channel($channel);
}

sub irc_quit {
	my ($self, $irc, $message) = @_;
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("User $from has quit");
	$_->remove_user($from) foreach values %{$self->channels};
	$self->user($from)->clear_channels;
}

sub irc_nick {
	my ($self, $irc, $message) = @_;
	my ($to) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->debug("User $from changed nick to $to");
	$_->rename_user($from => $to) foreach values %{$self->channels};
	$self->user($from)->nick($to);
}

sub irc_mode {
	my ($self, $irc, $message) = @_;
	my ($to, $mode, @params) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	my $params_str = join ' ', @params;
	if ($to =~ /^#/) {
		my $channel = $to;
		$self->logger->debug("User $from changed mode of $channel to $mode $params_str");
		if (@params and $mode =~ /[qaohvbe]/) {
			if ($mode =~ /[qaohv]/) {
				$irc->write('who', '+cn', $channel, $_)
					for grep { lc $_ ne lc $irc->nick } @params;
			}
		}
	} else {
		my $user = $to;
		$self->logger->debug("User $from changed mode of $user to $mode $params_str");
	}
}

# Helper functions

sub parse_from_nick {
	my $prefix = shift // return undef;
	$prefix =~ /^([^!]+)/ and return $1;
	return '';
}

1;
