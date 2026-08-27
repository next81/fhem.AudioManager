package AudioManager::Backend::Sonos2mqtt::Controls;

use strict;
use warnings;
use List::Util qw(max min);

# Fuehrt kontrollierte create/add/remove/dissolve-Operationen nur innerhalb der
# explizit verwalteten Playergrenze aus.
sub group_command {
	my ($self, $command, @arguments) = @_;

	# Create bildet aus Coordinator und Mitgliedern eine neue native Sonos-Gruppe.
	if ($command eq 'create') {
		my ($coordinator, @members) = @arguments;
		return 'group create benoetigt Coordinator und mindestens ein Mitglied'
			if !defined($coordinator) || !@members;
		return "$coordinator wird nicht verwaltet" if !$self->{managed}{$coordinator};

		for my $member (@members) {
			return "$member wird nicht verwaltet" if !$self->{managed}{$member};
			my $error = $self->_join_group($member, $coordinator);
			return $error if $error;
		}

		return undef;
	}

	# Add fuegt genau einen verwalteten Player zu einem verwalteten Coordinator hinzu.
	if ($command eq 'add') {
		my ($player, $coordinator) = @arguments;
		return 'group add benoetigt Player und Coordinator' if !defined($coordinator);
		return "$player wird nicht verwaltet" if !$self->{managed}{$player};
		return "$coordinator wird nicht verwaltet" if !$self->{managed}{$coordinator};
		return $self->_join_group($player, $coordinator);
	}

	# Remove trennt genau einen verwalteten Player aus seiner aktuellen Gruppe.
	if ($command eq 'remove') {
		my ($player) = @arguments;
		return 'group remove benoetigt einen Player' if !defined($player);
		return "$player wird nicht verwaltet" if !$self->{managed}{$player};
		return $self->_command($player, 'leaveGroup');
	}

	# Dissolve trennt alle verwalteten Child-Player des angegebenen Coordinators.
	if ($command eq 'dissolve') {
		my ($coordinator) = @arguments;
		return 'group dissolve benoetigt einen Coordinator' if !defined($coordinator);
		return "$coordinator wird nicht verwaltet" if !$self->{managed}{$coordinator};
		my $topology = $self->topology;
		my $uuid = $topology->{players}{$coordinator}{uuid};

		for my $member (@{ $topology->{groups}{$uuid} || [] }) {
			next if $member eq $coordinator;
			return "$member wird nicht verwaltet" if !$self->{managed}{$member};
			my $error = $self->_command($member, 'leaveGroup');
			return $error if $error;
		}

		return undef;
	}

	return "Unbekanntes Gruppenkommando: $command";
}

# Setzt Mute auf allen aufgeloesten Playern und validiert den booleschen Wert.
sub set_mute {
	my ($self, $players, $value) = @_;
	return 'mute muss on, off, true oder false sein' if $value !~ /^(?:on|off|true|false)$/;
	my $normalized = $value =~ /^(?:on|true)$/ ? 'true' : 'false';

	# Individuelle Mute-Zustaende werden absichtlich pro Player und nicht am Coordinator gesetzt.
	for my $player (@$players) {
		my $error = $self->_command($player, 'mute', $normalized);
		return $error if $error;
	}

	return undef;
}

# Setzt eine validierte ganzzahlige Lautstaerke auf allen aufgeloesten Playern.
sub set_volume {
	my ($self, $players, $value) = @_;
	return 'volume muss zwischen 0 und 100 liegen'
		if !defined($value) || $value !~ /^\d+$/ || $value < 0 || $value > 100;

	# Gruppenlautstaerke wird nicht verwendet, damit jede Playerlautstaerke nachvollziehbar bleibt.
	for my $player (@$players) {
		my $error = $self->_command($player, 'volume', int($value));
		return $error if $error;
	}

	return undef;
}

# Liefert die Metadaten des tatsaechlichen Coordinators einer aktiven Ausgabe.
sub media_status {
	my ($self, $request, $players) = @_;
	my $runtime = $self->_runtime($request);
	my @coordinators = @{ $runtime->{fanout_coordinators} || [] };
	@coordinators = ($runtime->{coordinator})
		if !@coordinators && $runtime->{coordinator};
	@coordinators = @{ $self->_coordinators($players) } if !@coordinators;
	my $player = $coordinators[0];
	return {} if !defined($player) || $player eq '';

	return {
		player => $player,
		title => $self->_reading_first(
			$player, '', 'currentTrack_title', 'currentTrack_Title',
		),
		artist => $self->_reading_first(
			$player, '', 'currentTrack_artist', 'currentTrack_Artist',
		),
		album => $self->_reading_first(
			$player, '', 'currentTrack_album', 'currentTrack_Album',
		),
		albumArtUri => $self->_reading_first(
			$player, '', 'currentTrack_albumArtUri', 'currentTrack_AlbumArtUri',
		),
		transportState => $self->_reading_first($player, 'STOPPED', 'transportState'),
		volume => $self->_reading_first($player, '', 'volume', 'CurrentVolume'),
		mute => $self->_reading_first($player, 'false', 'mute'),
	};
}

# Sendet einen Transportbefehl je betroffener nativer Sonos-Gruppe genau einmal.
sub transport_command {
	my ($self, $players, $command) = @_;
	return 'transport muss play, pause, previous oder next sein'
		if !defined($command) || $command !~ /^(?:play|pause|previous|next)$/;
	my $boundary_error = $self->_check_management_boundary($players);
	return $boundary_error if $boundary_error;
	my $coordinators = $self->_coordinators($players);

	# Gruppenmitglieder werden ueber ihren Coordinator gesteuert und erhalten keine Doppelbefehle.
	for my $coordinator (@$coordinators) {
		my $error = $self->_command($coordinator, $command);
		return $error if $error;
	}

	return undef;
}

# Aendert jeden Zielplayer um einen nativen Schritt und faellt bei reduzierten
# Devices auf einen aus dem aktuellen Reading berechneten absoluten Pegel zurueck.
sub change_volume {
	my ($self, $players, $direction) = @_;
	return 'volumeStep muss up oder down sein'
		if !defined($direction) || $direction !~ /^(?:up|down)$/;
	my $command = $direction eq 'up' ? 'volumeUp' : 'volumeDown';

	# Direkte Setter bewahren die vom Sonos-Template festgelegte Schrittweite.
	for my $player (@$players) {
		my $error;

		# Raw-only-Devices erhalten einen begrenzten absoluten Ersatzwert.
		if (!$self->_supports($player, $command)) {
			my $current = $self->_reading_first($player, '', 'volume', 'CurrentVolume');
			return "$player meldet keine gueltige Lautstaerke"
				if !defined($current) || $current !~ /^\d+$/ || $current > 100;
			my $next = $direction eq 'up' ? min(100, $current + 1) : max(0, $current - 1);
			$error = $self->_command($player, 'volume', $next);
		} else {
			$error = $self->{gateway}->set_command($player, $command);
		}

		return $error if $error;
	}

	return undef;
}


1;
