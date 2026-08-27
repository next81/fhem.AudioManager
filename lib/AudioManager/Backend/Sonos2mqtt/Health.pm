package AudioManager::Backend::Sonos2mqtt::Health;

use strict;
use warnings;

# Leitet den bereits in den Speakerattributen gespeicherten sonos2mqtt-Praefix ab.
# Ohne erkennbare Konfiguration bleibt der offizielle Default sonos wirksam.
sub _mqtt_prefix {
	my ($self) = @_;

	# devicetopic ist im offiziellen FHEM-Template die autoritative Basisangabe.
	for my $player (@{ $self->{players} }) {
		my $device_topic = $self->{gateway}->attr_value($player, 'devicetopic', '');
		return $1 if $device_topic =~ /^([A-Za-z0-9_.-]+)(?:\/|$)/ && $1 ne 'homeassistant';
	}

	# Aeltere oder reduzierte Devices koennen den Praefix nur in readingList tragen.
	for my $player (@{ $self->{players} }) {
		my $reading_list = $self->{gateway}->attr_value($player, 'readingList', '');

		for my $line (split /\n/, $reading_list) {
			next if $line !~ /(?:^|:)\s*([A-Za-z0-9_.-]+)\//;
			my $prefix = $1;
			next if $prefix eq 'homeassistant';
			return $prefix;
		}

	}

	return 'sonos';
}

# Normalisiert die IODev-Identitaet, damit Autoerkennung keine fremde MQTT-Verbindung bindet.
sub _iodev_name {
	my ($self, $device) = @_;
	my $hash = $self->{gateway}->device($device);
	return '' if !$hash;
	my $iodev = $hash->{IODev};
	return $iodev->{NAME} || '' if ref($iodev) eq 'HASH';
	return $iodev if defined($iodev) && !ref($iodev) && $iodev ne '';
	return $self->{gateway}->attr_value($device, 'IODev', '');
}

# Findet die Readingzuordnung zu einem exakten MQTT-Topic in einer vorhandenen readingList.
sub _reading_for_topic {
	my ($self, $device, $topic) = @_;
	my $reading_list = $self->{gateway}->attr_value($device, 'readingList', '');
	my $device_topic = $self->{gateway}->attr_value($device, 'devicetopic', '');

	for my $line (split /\n/, $reading_list) {
		$line =~ s/\$\{?DEVICETOPIC\}?/$device_topic/g;
		next if $line !~ /^\s*(\S+?):\.\*\s+([A-Za-z][A-Za-z0-9_.-]*)\s*$/;
		my ($mapped_topic, $reading) = ($1, $2);
		$mapped_topic = $topic if $mapped_topic =~ /(?:^|:)\Q$topic\E$/;
		return $reading if $mapped_topic eq $topic;
	}

	return undef;
}

# Prueft, ob Kandidat und verwaltete Player am selben MQTT-IODev haengen.
sub _same_iodev {
	my ($self, $candidate) = @_;
	my $candidate_iodev = $self->_iodev_name($candidate);

	for my $player (@{ $self->{players} }) {
		my $player_iodev = $self->_iodev_name($player);
		return 1 if $candidate_iodev eq '' || $player_iodev eq '';
		return 1 if $candidate_iodev eq $player_iodev;
	}

	return 0;
}

# Erkennt ein vorhandenes FHEM-Device, das <Praefix>/connected bereits als Reading abbildet.
sub _detect_availability {
	my ($self, $prefix) = @_;
	my $topic = "$prefix/connected";
	my @candidates;

	for my $device (@{ $self->{gateway}->device_names }) {
		my $hash = $self->{gateway}->device($device);
		next if !$hash || ($hash->{TYPE} || '') ne 'MQTT2_DEVICE';
		next if !$self->_same_iodev($device);
		my $reading = $self->_reading_for_topic($device, $topic);
		next if !defined($reading);
		push @candidates, {
			device => $device,
			reading => $reading,
			preferred => $self->{gateway}->attr_value($device, 'model', '') eq 'sonos2mqtt_bridge' ? 0 : 1,
		};
	}

	return undef if !@candidates;
	@candidates = sort {
		$a->{preferred} <=> $b->{preferred} || $a->{device} cmp $b->{device}
	} @candidates;
	return $candidates[0];
}

# Bindet eine manuelle Praefixzuordnung oder erkennt eine vorhandene MQTT2-Zuordnung automatisch.
sub _configure_availability {
	my ($self, $mapping) = @_;
	$mapping = {} if ref($mapping) ne 'HASH';
	my $prefix = $self->_mqtt_prefix;
	my $selected;
	my $mode = 'unknown';

	if (ref($mapping->{$prefix}) eq 'HASH') {
		$selected = $mapping->{$prefix};
		$mode = 'configured';
	} else {
		$selected = $self->_detect_availability($prefix);
		$mode = 'auto' if $selected;
	}

	$self->{health}{availability} = {
		mode => $mode,
		prefix => $prefix,
		device => $selected ? $selected->{device} : undef,
		reading => $selected ? ($selected->{reading} || 'connected') : undef,
		status => 'unknown',
	};
	return undef;
}

# Liest den Bridgezustand nur aus der bereits vorhandenen FHEM-Zuordnung.
sub _availability_status {
	my ($self) = @_;
	my $availability = $self->{health}{availability};
	return 'unknown' if !$availability->{device};
	my $status = $self->{gateway}->reading_value(
		$availability->{device}, $availability->{reading}, '',
	);
	$status = 'missing' if !defined($status) || $status eq '';
	$availability->{status} = "$status";
	return "$status";
}

# Liefert eine eindeutige Bridgefehlermeldung oder undef bei 2 beziehungsweise unbekannter Zuordnung.
sub _availability_error {
	my ($self) = @_;
	my $status = $self->_availability_status;
	return undef if $status eq 'unknown' || $status eq '2';
	return {
		status => 'degraded',
		reason => $status eq '1' ? 'bridge_without_players' : 'bridge_offline',
		error => $status eq '1'
			? 'sonos2mqtt ist mit MQTT verbunden, erkennt aber keinen Player'
			: 'sonos2mqtt-Bridge ist nicht verbunden',
	};
}

# Beschreibt aktive Playerprobes, optionale Bridgeerkennung und Subscription-Recovery.
sub health_capabilities {
	return {
		events => [qw(IPAddress connected)],
		probe => 'GetZoneInfo',
		recovery => 'check-subscriptions',
		confirmation => 'fresh-IPAddress',
	};
}

# Liefert Bridge-Devices zusaetzlich zu den ohnehin verwalteten Playern an NOTIFYDEV.
sub health_devices {
	my ($self) = @_;
	my $device = $self->{health}{availability}{device};
	return $device ? [$device] : [];
}

# Uebersetzt Bridge- und GetZoneInfo-Ereignisse in neutrale Supervisor-Signale.
sub health_event {
	my ($self, $device, $events) = @_;
	my @signals;
	my $health = $self->{health};
	my $availability = $health->{availability};

	# Ein vorhandenes connected-Reading beschreibt nur den Dienst, nie einen Einzelplayer.
	if ($availability->{device} && $device eq $availability->{device}) {

		for my $event (@{ $events || [] }) {
			next if !defined($event) || $event !~ /^\Q$availability->{reading}\E:\s*(.*)$/s;
			my $status = $1;
			$status =~ s/\s+$//;
			$availability->{status} = $status;

			if ($status eq '2') {
				push @signals, { probe => 1, reason => 'bridge_connected' };
			} else {
				push @signals, {
					status => 'degraded',
					reason => $status eq '1' ? 'bridge_without_players' : 'bridge_offline',
				};
			}
		}

		return \@signals;
	}

	return [] if !$self->{managed}{$device};

	# IPAddress stammt aus der gezielten ZoneInfo-Antwort und bestaetigt genau diesen Player.
	for my $event (@{ $events || [] }) {
		next if !defined($event) || $event !~ /^IPAddress:\s*(.+)$/s;
		next if !$health->{expected}{$device};
		$health->{confirmed}{$device} = 1;
		$health->{last_response}{$device} = $self->{gateway}->now;
		push @signals, { activity => 1, reason => "zone_info_received:$device" };
	}

	return \@signals;
}

# Startet den offiziellen read-only GetZoneInfo-Befehl und merkt vorhandene Readingzeitstempel.
sub _begin_zone_info_probe {
	my ($self, $players) = @_;
	my %seen;
	my @expected = grep { $self->{managed}{$_} && !$seen{$_}++ } @{ $players || [] };
	return 'Health-Probe enthaelt keine verwalteten Player' if !@expected;
	my $health = $self->{health};
	$health->{expected} = { map { $_ => 1 } @expected };
	$health->{confirmed} = {};
	$health->{baseline_timestamps} = {
		map { $_ => $self->{gateway}->reading_timestamp($_, 'IPAddress', '') } @expected
	};
	$health->{probe_started} = $self->{gateway}->now;

	for my $player (@expected) {
		my $error = $self->_raw_command($player, 'adv-command', {
			cmd => 'GetZoneInfo',
			reply => 'ZoneInfo',
		});
		return $error if $error;
	}

	return undef;
}

# Startet die periodische Playerpruefung, sofern eine bekannte Bridge nicht offline ist.
sub health_probe {
	my ($self) = @_;
	my $availability_error = $self->_availability_error;
	return $availability_error if $availability_error;
	my $error = $self->_begin_zone_info_probe($self->{players});
	return {
		status => 'degraded',
		reason => 'zone_info_probe_failed',
		error => $error,
	} if $error;
	return { status => 'pending', reason => 'zone_info_probe_sent' };
}

# Ereignisse fordern beim Sonos-Adapter direkt einen Probe an; ein getrennter Check bleibt gesund.
sub health_check {
	return { status => 'healthy', reason => 'no_deferred_recovery' };
}

# Aktualisiert nach einem ausgefallenen oder wiedergekehrten Player die Subscriptions
# und wiederholt anschliessend den read-only Probe fuer genau die betroffenen Player.
sub health_recover {
	my ($self, $check) = @_;
	my @players = @{ $check->{players} || [] };
	return 'Subscription-Recovery enthaelt keine betroffenen Player' if !@players;
	my $publisher = $self->{players}[0];
	my $topic = $self->_mqtt_prefix . '/cmd/check-subscriptions';
	my $error = $self->{gateway}->mqtt_publish($publisher, $topic);
	return $error if $error;
	return $self->_begin_zone_info_probe(\@players);
}

# Gibt den fluechtigen Probe-Zustand frei, ohne die Diagnosehistorie zu verlieren.
sub _clear_health_probe {
	my ($self) = @_;
	$self->{health}{expected} = {};
	$self->{health}{confirmed} = {};
	$self->{health}{baseline_timestamps} = {};
	$self->{health}{probe_started} = undef;
	return;
}

# Bestaetigt jeden Player ueber ein IPAddress-Ereignis oder einen neuen Readingzeitstempel.
sub health_verify {
	my ($self, $context) = @_;
	my $availability_error = $self->_availability_error;
	return $availability_error if $availability_error;
	my $health = $self->{health};
	my @expected = sort keys %{ $health->{expected} };

	for my $player (@expected) {
		next if $health->{confirmed}{$player};
		my $before = $health->{baseline_timestamps}{$player} // '';
		my $current = $self->{gateway}->reading_timestamp($player, 'IPAddress', '');
		next if $current eq '' || $current eq $before;
		$health->{confirmed}{$player} = 1;
		$health->{last_response}{$player} = $self->{gateway}->now;
	}

	my @missing = grep { !$health->{confirmed}{$_} } @expected;

	# Ein zuvor ausgefallener und nun antwortender Player benoetigt einmalig frische Subscriptions.
	if (!@missing && @expected) {
		my @reconnected = grep { $health->{unavailable}{$_} } @expected;

		if (@reconnected && !$context->{recovery_attempted}) {
			return {
				status => 'degraded',
				recoverable => 1,
				reason => 'player_reconnected',
				players => \@reconnected,
			};
		}

		for my $player (@expected) {
			delete $health->{unavailable}{$player};
			$health->{last_response}{$player} ||= $self->{gateway}->now;
		}

		$self->_clear_health_probe;
		return { status => 'healthy', reason => 'zone_info_confirmed' };
	}

	# Erst am Fristende wird repariert; ein erfolgloser Wiederholungsprobe degradiert endgueltig.
	if ($self->{gateway}->now >= ($context->{deadline} || 0)) {
		$health->{unavailable}{$_} = 1 for @missing;
		my $error = @missing
			? 'Keine ZoneInfo-Antwort von ' . join(',', @missing)
			: 'Health-Probe erwartete keine Player';
		return {
			status => 'degraded',
			recoverable => $context->{recovery_attempted} ? 0 : 1,
			reason => $context->{recovery_attempted}
				? 'zone_info_retry_unconfirmed' : 'zone_info_unconfirmed',
			error => $error,
			players => \@missing,
		};
	}

	return {
		status => 'pending',
		recoverable => 1,
		reason => @missing ? 'Warte auf ZoneInfo von ' . join(',', @missing)
			: 'Warte auf ZoneInfo-Bestaetigung',
		players => \@missing,
	};
}

# Liefert Bridgebindung und letzten Playerstatus ohne interne Probe-Baselines.
sub health_details {
	my ($self) = @_;
	my $availability = $self->{health}{availability};
	my %players;

	for my $player (@{ $self->{players} }) {
		$players{$player} = {
			status => $self->{health}{unavailable}{$player} ? 'unavailable'
				: $self->{health}{last_response}{$player} ? 'reachable' : 'unknown',
			lastResponse => $self->{health}{last_response}{$player},
		};
	}

	return {
		availability => {
			mode => $availability->{mode},
			prefix => $availability->{prefix} || $self->_mqtt_prefix,
			device => $availability->{device},
			reading => $availability->{reading},
			status => $self->_availability_status,
		},
		players => \%players,
		topologyWarnings => $self->topology_warnings,
	};
}


1;
