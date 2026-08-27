package AudioManager::Backend::Sonos2mqtt::Topology;

use strict;
use warnings;

# Meldet native Gruppen, die neben verwalteten auch fremde Sonos-Player enthalten.
sub topology_warnings {
	my ($self) = @_;
	my $topology = $self->topology;
	my @warnings;

	# Jede gemischte Gruppe wird genau einmal mit Coordinator und fremden Mitgliedern gemeldet.
	for my $coordinator_uuid (sort keys %{ $topology->{groups} || {} }) {
		my @members = @{ $topology->{groups}{$coordinator_uuid} || [] };
		next if !grep { $self->{managed}{$_} } @members;
		my @unmanaged = grep { !$self->{managed}{$_} } @members;
		next if !@unmanaged;
		my $coordinator = $topology->{by_uuid}{$coordinator_uuid} || $coordinator_uuid;
		push @warnings, 'Gruppe ' . $coordinator . ' enthaelt nicht verwaltete Player '
			. join(',', sort @unmanaged);
	}

	return \@warnings;
}

# Beobachtet auch fremde Speaker, damit Gruppenbeitritte und -austritte sofort sichtbar werden.
sub topology_devices {
	my ($self) = @_;
	return $self->_all_sonos_players;
}

# Liefert alle in FHEM bekannten sonos2mqtt-Speaker fuer Topologie und Schutzpruefung.
sub _all_sonos_players {
	my ($self) = @_;
	my @players;

	# Die globale Suche dient nur der Schutzpruefung; gesteuert werden weiterhin
	# ausschliesslich die im Define explizit verwalteten Devices.
	for my $name (@{ $self->{gateway}->device_names }) {
		my $device = $self->{gateway}->device($name);

		# Nur vollstaendige MQTT2-Devices koennen sonos2mqtt-Speaker sein.
		next if !$device || ($device->{TYPE} || '') ne 'MQTT2_DEVICE';
		push @players, $name
			if $self->{gateway}->attr_value($name, 'model', '') eq 'sonos2mqtt_speaker';
	}

	return \@players;
}

# Leitet Coordinatoren und Gruppen ausschliesslich aus uuid/coordinatorUuid ab;
# abgeleitete Anzeigenamen wie groupName oder Master sind nicht autoritativ.
sub topology {
	my ($self) = @_;
	my %players;
	my %by_uuid;

	# Zuerst werden UUIDs gesammelt, damit Coordinatoren im zweiten Schritt auf
	# konkrete FHEM-Devices aufgeloest werden koennen.
	for my $name (@{ $self->_all_sonos_players }) {
		my $uuid = $self->{gateway}->reading_value($name, 'uuid', '');
		$uuid = "device:$name" if $uuid eq '';
		$by_uuid{$uuid} = $name;
		$players{$name} = {
			name => $name,
			uuid => $uuid,
			managed => $self->{managed}{$name} ? 1 : 0,
		};
	}

	my %groups;

	# Leere Coordinator-Readings werden nur fuer den sicheren Startzustand als
	# standalone interpretiert; echte Gruppenentscheidungen verwenden reale UUIDs.
	for my $name (sort keys %players) {
		my $uuid = $players{$name}{uuid};
		my $coordinator_uuid = $self->{gateway}->reading_value($name, 'coordinatorUuid', '');
		$coordinator_uuid = $uuid if $coordinator_uuid eq '';
		$players{$name}{coordinator_uuid} = $coordinator_uuid;
		$players{$name}{coordinator} = $by_uuid{$coordinator_uuid};
		push @{ $groups{$coordinator_uuid} }, $name;
	}

	return {
		players => \%players,
		groups => { map { $_ => [ sort @{ $groups{$_} } ] } keys %groups },
		by_uuid => \%by_uuid,
	};
}

# Loest all, player, players, group und backend in die lokale Verwaltungsgrenze auf.
sub resolve_target {
	my ($self, $specification) = @_;
	$specification = 'all' if !defined($specification) || $specification eq '';
	my @targets;

	# Der Default und das passende Backendziel bedeuten alle explizit verwalteten Player.
	if ($specification eq 'all' || $specification eq "backend:$self->{id}"
		|| $specification eq 'backend:sonos2mqtt') {
		@targets = @{ $self->{players} };
	} elsif ($specification =~ /^player:(.+)$/) {
		@targets = ($1);
	} elsif ($specification =~ /^players:(.+)$/) {
		@targets = split /,/, $1;
	} elsif ($specification =~ /^group:(.+)$/) {
		my $anchor = $1;
		return (undef, "Unbekannter Gruppenanker: $anchor") if !$self->{managed}{$anchor};
		my $topology = $self->topology;
		my $coordinator_uuid = $topology->{players}{$anchor}{coordinator_uuid};
		@targets = grep { $self->{managed}{$_} } @{ $topology->{groups}{$coordinator_uuid} || [] };
	} else {
		@targets = split /,/, $specification;
	}

	my %seen;
	@targets = grep { defined($_) && $_ ne '' && !$seen{$_}++ } @targets;
	return (undef, 'Das Ziel enthaelt keinen Player') if !@targets;

	# Ein Ziel darf die beim Define festgelegte Verwaltungsgrenze nie erweitern.
	for my $target (@targets) {
		return (undef, "$target wird von Backend $self->{id} nicht verwaltet")
			if !$self->{managed}{$target};
	}

	return (\@targets, undef);
}

# Erweitert die Scheduler-Sperre um aktuelle Gruppenmitglieder, die fuer eine
# exakte Zielgruppe voruebergehend getrennt werden muessen.
sub resource_targets {
	my ($self, $targets) = @_;
	my $topology = $self->topology;
	my %resources = map { $_ => 1 } @$targets;

	# Alle verwalteten Mitglieder beruehrter Gruppen werden gesperrt, waehrend
	# disjunkte Sonos-Gruppen weiterhin parallel arbeiten duerfen.
	for my $target (@$targets) {
		my $coordinator_uuid = $topology->{players}{$target}{coordinator_uuid};

		for my $member (@{ $topology->{groups}{$coordinator_uuid} || [] }) {
			$resources{$member} = 1 if $self->{managed}{$member};
		}

	}

	return [ sort keys %resources ];
}

1;
