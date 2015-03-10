package Bot::ZIRC::Plugin::GeoIP;

use Carp;
use Data::Validate::IP qw/is_ipv4 is_ipv6/;
use GeoIP2::Database::Reader;
use Scalar::Util qw/blessed weaken/;

use Moo 2;
use namespace::clean;

use constant GEOIP_FILE_MISSING =>
	"GeoIP plugin requires a readable GeoLite2 City database file located by the configuration option 'geoip_file' in section 'apis'\n" .
	"See http://dev.maxmind.com/geoip/geoip2/geolite2/ for more information on obtaining a GeoLite2 City database file.\n";

with 'Bot::ZIRC::Plugin';

has 'geoip' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_geoip {
	my $self = shift;
	my $file = $self->bot->config->get('apis', 'geoip_file');
	die GEOIP_FILE_MISSING unless defined $file and length $file and -r $file;
	local $@;
	my $geoip = eval { GeoIP2::Database::Reader->new(file => $file) };
	die $@ if $@;
	return $geoip;
}

sub geoip_locate {
	my ($self, $ip) = @_;
	die "Invalid IP address $ip\n" unless is_ipv4 $ip or is_ipv6 $ip;
	local $@;
	my $record = eval { $self->geoip->city(ip => $ip) };
	my $err;
	if ($@) {
		$err = $@;
		die $err unless blessed $err and $err->isa('Throwable::Error');
		$err = $err->message;
	}
	return ($err, $record);
}

sub geoip_locate_host {
	my ($self, $host, $cb) = @_;
	if ($cb) {
		return $cb->($self->bot->geoip_locate($host)) if is_ipv4 $host or is_ipv6 $host;
		return $cb->('DNS plugin is required to resolve hostnames')
			unless $self->bot->has_plugin_method('dns_resolve');
		weaken $self;
		$self->bot->dns_resolve($host, sub {
			$cb->($self->on_dns_host(@_));
		});
	} else {
		return $self->bot->geoip_locate($host) if is_ipv4 $host or is_ipv6 $host;
		return 'DNS plugin is required to resolve hostnames'
			unless $self->bot->has_plugin_method('dns_resolve');
		return $self->on_dns_host($self->bot->dns_resolve($host));
	}
}

sub on_dns_host {
	my ($self, $err, @results) = @_;
	return $err if $err;
	my $addrs = $self->bot->dns_ip_results(\@results);
	return 'No DNS results' unless @$addrs;
	my $last_err = 'No valid DNS results';
	my $best_record;
	foreach my $addr (@$addrs) {
		next unless is_ipv4 $addr or is_ipv6 $addr;
		my ($err, $record) = $self->bot->geoip_locate($addr);
		return (undef, $record) if !$err and defined $record->city->name;
		$best_record //= $record if !$err;
		$last_err = $err if $err;
	}
	return defined $best_record ? (undef, $best_record) : $last_err;
}

sub register {
	my ($self, $bot) = @_;
	my $file = $bot->config->get('apis','geoip_file');
	die GEOIP_FILE_MISSING unless defined $file and length $file and -r $file;
	
	$bot->add_plugin_method($self, 'geoip_locate');
	$bot->add_plugin_method($self, 'geoip_locate_host');
	
	$bot->add_command(
		name => 'locate',
		help_text => 'Locate user or hostname based on IP address',
		usage_text => '[<nick>|<hostname>]',
		on_run => sub {
			my ($network, $sender, $channel, $target) = @_;
			$target //= $sender;
			my $say_target = my $host = $target;
			if (exists $network->users->{lc $target}) {
				$host = $network->user($target)->host;
				return $network->reply($sender, $channel, "Could not find hostname for $target")
					unless defined $host;
				$say_target = "$target ($host)";
			}
			
			$network->bot->geoip_locate_host($host, sub {
				my ($err, $record) = @_;
				return $network->reply($sender, $channel, "Error locating $say_target: $err") if $err;
				return $network->reply($sender, $channel, "GeoIP location for $say_target: ".location_str($record));
			});
		},
	);
}

sub location_str {
	my $record = shift // croak 'No location record passed';
	my @subdivisions = reverse map { $_->name } $record->subdivisions;
	my @location_parts = grep { defined } $record->city->name, @subdivisions, $record->country->name;
	return join ', ', @location_parts;
}

1;