package AudioManager::Backend::Sonos2mqtt;

use strict;
use warnings;
use parent 'AudioManager::Backend';
use List::Util qw(max min);
use JSON::PP ();

my $VOLUME_READING_GRACE = 5;

# Erzeugt einen Adapter fuer genau die im Define genannte Verwaltungsgrenze.
sub new {
	my ($class, %arguments) = @_;
	my %seen;
	my @players = grep { defined($_) && $_ ne '' && !$seen{$_}++ } @{ $arguments{players} || [] };
	return bless {
		id => $arguments{id} || 'sonos2mqtt',
		gateway => $arguments{gateway},
		players => \@players,
		managed => { map { $_ => 1 } @players },
		group_timeout => $arguments{group_timeout} || 30,
		auto_leave => $arguments{auto_leave} ? 1 : 0,
		health => {
			availability => {
				mode => 'unknown',
				prefix => undef,
				device => undef,
				reading => undef,
				status => 'unknown',
			},
			expected => {},
			confirmed => {},
			baseline_timestamps => {},
			unavailable => {},
			last_response => {},
			probe_started => undef,
		},
	}, $class;
}

# Registriert den ersten konkreten Treiber am versionierten Backendvertrag.
BEGIN {
	AudioManager::Backend->register(sonos2mqtt => sub {
		return __PACKAGE__->new(@_);
	});
}

# Liefert die Backend-Instanzkennung fuer Zielausdruecke und Laufzeitdaten.
sub id { return $_[0]{id}; }

# Liefert die explizit im Define aufgefuehrten Player in stabiler Reihenfolge.
sub managed_players {
	my ($self) = @_;
	return [ @{ $self->{players} } ];
}

# Aktualisiert sichere Adapterparameter fuer danach gestartete Gruppenoperationen.
sub configure {
	my ($self, %arguments) = @_;
	$self->{group_timeout} = $arguments{group_timeout}
		if defined($arguments{group_timeout}) && $arguments{group_timeout} > 0;
	$self->{auto_leave} = $arguments{auto_leave} ? 1 : 0
		if exists($arguments{auto_leave});
	$self->_configure_availability($arguments{availability})
		if exists($arguments{availability});
	return undef;
}

# Erkennt einen direkt am MQTT2-Device angebotenen Setter. Dadurch bleibt der
# Adapter mit unterschiedlich umfangreichen sonos2mqtt-Templates kompatibel.
sub _supports {
	my ($self, $player, $command) = @_;
	my $set_list = $self->{gateway}->attr_value($player, 'setList', '');
	return $set_list =~ /(?:^|\n)\Q$command\E(?::|\s|$)/m ? 1 : 0;
}

# Prueft, ob ein reduziertes Speaker-Device offizielle JSON-Rohbefehle annimmt.
sub _supports_raw {
	my ($self, $player) = @_;
	return $self->_supports($player, 'x_raw_payload');
}

# Sendet einen dokumentierten sonos2mqtt-Rohbefehl mit kanonischem JSON. Die
# stabile Schluesselreihenfolge erleichtert Diagnose und reproduzierbare Tests.
sub _raw_command {
	my ($self, $player, $command, $input) = @_;
	my %payload = (command => $command);
	$payload{input} = $input if defined($input);
	my $json = JSON::PP->new->canonical(1)->encode(\%payload);
	return $self->{gateway}->set_command($player, 'x_raw_payload', $json);
}

# Nutzt bevorzugt den sprechenden FHEM-Setter und greift nur bei reduzierten
# Devices auf die von sonos2mqtt dokumentierten Rohkommandos zurueck.
sub _command {
	my ($self, $player, $command, $value) = @_;
	return $self->{gateway}->set_command($player, $command, $value)
		if $self->_supports($player, $command);
	return "$player unterstuetzt weder $command noch x_raw_payload"
		if !$self->_supports_raw($player);

	# playUri besteht im Rohprotokoll aus Quellenwechsel und explizitem Start.
	if ($command eq 'playUri') {
		my $error = $self->_raw_command($player, 'setavtransporturi', $value);
		return $error if $error;
		return $self->_raw_command($player, 'play', undef);
	}

	# Boolean-Mute wird auf die getrennten Rohkommandos normalisiert.
	if ($command eq 'mute') {
		my $raw_command = defined($value) && $value =~ /^(?:1|true|on)$/i ? 'mute' : 'unmute';
		return $self->_raw_command($player, $raw_command, undef);
	}

	return "$player kann playFav nur als Gruppenmitglied eines vollstaendigen Speakers nutzen"
		if $command eq 'playFav';
	my %mapping = (
		volume => 'volume',
		joinGroup => 'joingroup',
		leaveGroup => 'leavegroup',
		pause => 'pause',
		play => 'play',
		previous => 'previous',
		next => 'next',
		stop => 'stop',
	);
	return "$player bietet keinen kompatiblen sonos2mqtt-Befehl fuer $command"
		if !exists($mapping{$command}) && $command ne 'input';

	# Der Queue-Eingang besitzt im Rohprotokoll einen eigenen Befehl.
	if ($command eq 'input') {
		return "$player unterstuetzt nur den Queue-Eingang" if !defined($value) || $value ne 'Queue';
		return $self->_raw_command($player, 'switchtoqueue', undef);
	}

	my $raw_value = $command =~ /^(?:leaveGroup|pause|play|stop)$/ ? undef : $value;
	return $self->_raw_command($player, $mapping{$command}, $raw_value);
}

# Ermittelt den nativen Sonos-Befehl aus der fachlichen Quelle eines dauerhaften Streams.
sub _stream_source {
	my ($self, $request) = @_;
	my $favorite = $request->{payload}{favorite} // '';
	my $uri = $request->{payload}{uri} // '';

	# Mehrdeutige Requests werden auch an der Backendgrenze nicht stillschweigend priorisiert.
	return (undef, undef, 'stream akzeptiert nur einen Sonos-Favoriten oder eine URI')
		if $favorite ne '' && $uri ne '';
	return ('playUri', $uri, undef) if $uri ne '';
	return ('playFav', $favorite, undef) if $favorite ne '';
	return (undef, undef, 'stream benoetigt einen Sonos-Favoriten oder eine URI');
}

# Waehlt einen Coordinator, der die jeweilige Quelle tatsaechlich starten kann.
# Eingeschraenkte Player koennen trotzdem als Mitglieder der Zielgruppe dienen.
sub _choose_coordinator {
	my ($self, $request, $targets) = @_;
	my $type = $request->{type};
	my $required = $type eq 'queue' ? 'input' : 'playUri';

	# Bei Streams entscheidet die konkrete Quelle zwischen Favoriten- und URI-Setter.
	if ($type eq 'stream') {
		my ($stream_command, $stream_value, $stream_error) = $self->_stream_source($request);
		return (undef, $stream_error) if $stream_error;
		$required = $stream_command;
	}

	my $topology = $self->topology;
	my %target = map { $_ => 1 } @$targets;
	my %current_coordinators;

	# Wenn alle Ziele bereits dieselbe Sonos-Gruppe bilden, wird deren ueber
	# coordinatorUuid bestimmter Coordinator vor jeder Ersatzwahl bevorzugt.
	for my $player (@$targets) {
		my $coordinator = $topology->{players}{$player}{coordinator};
		$current_coordinators{$coordinator} = 1 if defined($coordinator) && $coordinator ne '';
	}

	# Nur ein tatsaechlich zum Ziel gehoerender gemeinsamer Coordinator darf die
	# Quelle ohne temporaeren Gruppenumbau starten.
	if (keys(%current_coordinators) == 1) {
		my ($coordinator) = keys %current_coordinators;

		if ($target{$coordinator}) {
			return ($coordinator, undef) if $self->_supports($coordinator, $required);
			return ($coordinator, undef) if $required ne 'playFav' && $self->_supports_raw($coordinator);
		}

	}

	# Fehlt ein geeigneter aktueller Coordinator, wird fuer eine neu zu bildende
	# Gruppe der erste Player mit direktem Quellen-Setter verwendet.
	for my $player (@$targets) {
		return ($player, undef) if $self->_supports($player, $required);
	}

	# Rohbefehle decken URI und Queue ab, aber keinen Favoritennamen.
	if ($required ne 'playFav') {

		for my $player (@$targets) {
			return ($player, undef) if $self->_supports_raw($player);
		}

	}

	return (undef, "Kein Zielplayer kann die Quelle fuer $type starten");
}

# Prueft, dass ausschliesslich sonos2mqtt-Speaker und niemals Bridge- oder
# Hilfsdevices in die Verwaltungsgrenze aufgenommen wurden.
sub validate {
	my ($self) = @_;
	return 'Das sonos2mqtt-Backend benoetigt mindestens einen Player' if !@{ $self->{players} };

	# Jeder konfigurierte Name muss beim Define bereits eindeutig als Speaker erkennbar sein.
	for my $player (@{ $self->{players} }) {
		my $device = $self->{gateway}->device($player);
		return "Sonos-Player $player existiert nicht" if !$device;
		my $model = $self->{gateway}->attr_value($player, 'model', '');
		return "$player ist kein sonos2mqtt_speaker" if $model ne 'sonos2mqtt_speaker';
		return "$player bietet weder playUri noch x_raw_payload"
			if !$self->_supports($player, 'playUri') && !$self->_supports_raw($player);
		return "$player bietet kein x_raw_payload fuer den read-only Health-Probe"
			if !$self->_supports_raw($player);
	}

	return undef;
}

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
		push @players, $name
			if $self->{gateway}->attr_value($name, 'model', '') eq 'sonos2mqtt_speaker';
	}

	return \@players;
}

# Liest den ersten vorhandenen, nichtleeren Wert aus mehreren kompatiblen Readingnamen.
sub _reading_first {
	my ($self, $player, $fallback, @readings) = @_;

	# Verschiedene sonos2mqtt-Templates benennen insbesondere Lautstaerke und
	# Tracknummer leicht unterschiedlich; der Adapter normalisiert diese Grenze.
	for my $reading (@readings) {
		my $value = $self->{gateway}->reading_value($player, $reading, '');
		return $value if defined($value) && $value ne '';
	}

	return $fallback;
}

# Uebersetzt den FHEM-Devicenamen in den von sonos2mqtt fuer joingroup
# erwarteten sichtbaren Sonos-Namen und kapselt damit alle Gruppenbeitritte.
sub _join_group {
	my ($self, $player, $coordinator) = @_;
	my $coordinator_name = $self->_reading_first($coordinator, '', 'name');
	return "$coordinator meldet keinen Sonos-Namen im Reading name"
		if $coordinator_name eq '';
	return $self->_command($player, 'joinGroup', $coordinator_name);
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

# Erstellt einen fluechtigen Snapshot aller von der Zielgruppe beruehrten
# verwalteten Player; FHEM-Readings bleiben die dauerhafte Wahrheitsquelle.
sub snapshot {
	my ($self, $targets) = @_;
	my $topology = $self->topology;
	my %scope = map { $_ => 1 } @{ $self->resource_targets($targets) };
	my %players;

	# Lautstaerke, Mute, Quelle und Transport werden je Player gesichert, weil
	# Gruppenmitglieder unterschiedliche Lautstaerken und Mute-Zustaende besitzen.
	for my $player (sort keys %scope) {
		my $topology_player = $topology->{players}{$player};
		$players{$player} = {
			uuid => $topology_player->{uuid},
			coordinator_uuid => $topology_player->{coordinator_uuid},
			volume => 0 + $self->_reading_first($player, 0, 'volume', 'CurrentVolume'),
			mute => $self->_reading_first($player, 'false', 'mute'),
			transport => $self->_reading_first($player, 'STOPPED', 'transportState'),
			input => $self->_reading_first($player, '', 'Input'),
			uri => $self->_reading_first($player, '', 'currentTrack_TrackUri'),
			playmode => $self->_reading_first($player, 'NORMAL', 'playmode'),
			track => 0 + $self->_reading_first($player, 0, 'currentTrack_TrackNumber', 'currentTrack'),
			position => $self->_reading_first($player, '', 'currentTrack_Position', 'currentTrack_position'),
		};
	}

	return {
		backend => $self->{id},
		scope => [ sort keys %scope ],
		players => \%players,
	};
}

# Liefert die Runtimeablage dieses Backends innerhalb eines Managerauftrags.
sub _runtime {
	my ($self, $request) = @_;
	return $request->{runtime}{backends}{ $self->{id} } ||= {};
}

# Meldet, ob ein all-Ziel auf die vorhandenen nativen Gruppen verteilt werden soll.
sub _uses_existing_groups {
	my ($self, $request) = @_;
	return ($request->{payload}{target_mode} || '') eq 'existing_groups' ? 1 : 0;
}

# Ermittelt eindeutige aktuelle Coordinator-Devices fuer die angegebene Playerliste.
sub _coordinators {
	my ($self, $targets) = @_;
	my $topology = $self->topology;
	my %seen;
	my @coordinators;

	# Standalone-Player und echte Gruppencoordinatoren werden nur einmal angesteuert.
	for my $target (@$targets) {
		my $coordinator = $topology->{players}{$target}{coordinator} || $target;
		push @coordinators, $coordinator if !$seen{$coordinator}++;
	}

	return \@coordinators;
}

# Stellt sicher, dass keine exakte Zielbildung ein nicht verwaltetes Mitglied
# derselben bestehenden Sonos-Gruppe veraendern wuerde.
sub _check_management_boundary {
	my ($self, $targets) = @_;
	my $topology = $self->topology;
	my %groups;

	# Nur Gruppen, die mindestens einen Zielplayer enthalten, sind betroffen.
	for my $target (@$targets) {
		$groups{ $topology->{players}{$target}{coordinator_uuid} } = 1;
	}

	# Ein nicht verwaltetes Gruppenmitglied erzwingt eine explizite Erweiterung
	# des Defines statt eines ueberraschenden Seiteneffekts.
	for my $coordinator_uuid (keys %groups) {

		for my $member (@{ $topology->{groups}{$coordinator_uuid} || [] }) {
			return "Sonos-Gruppe enthaelt nicht verwalteten Player $member"
				if !$self->{managed}{$member};
		}

	}

	return undef;
}

# Prueft, ob die Zielplayer bereits exakt eine gemeinsame Gruppe ohne weitere
# Mitglieder bilden und daher ohne Gruppierungsbefehle gestartet werden koennen.
sub _is_exact_group {
	my ($self, $targets, $coordinator) = @_;
	my $topology = $self->topology;
	my $coordinator_uuid = $topology->{players}{$coordinator}{uuid};
	my @actual = sort @{ $topology->{groups}{$coordinator_uuid} || [] };
	my @desired = sort @$targets;
	return 0 if @actual != @desired;

	# Der elementweise Vergleich vermeidet Abhaengigkeiten von Serialisierungsformaten.
	for my $index (0 .. $#actual) {
		return 0 if $actual[$index] ne $desired[$index];
	}

	return 1;
}

# Prueft vor der Snapshot-Erfassung, ob der Zielumbau eine bestehende
# Sonos-Gruppe automatisch auftrennen muesste.
sub preflight_start {
	my ($self, $request, $targets) = @_;

	# Vorhandene Gruppen werden als Einheit abgespielt und dabei nicht veraendert.
	return undef if $self->_uses_existing_groups($request);

	my $boundary_error = $self->_check_management_boundary($targets);
	return $boundary_error if $boundary_error;

	my ($coordinator, $coordinator_error) = $self->_choose_coordinator($request, $targets);
	return $coordinator_error if $coordinator_error;
	return undef if $self->_is_exact_group($targets, $coordinator);
	return undef if $self->{auto_leave};
	my $topology = $self->topology;
	my %affected = map { $_ => 1 } @{ $self->resource_targets($targets) };

	# Standalone-Player duerfen temporaer gruppiert werden. Blockiert werden nur
	# bereits vorhandene Child-Beziehungen, die ein leaveGroup erfordern wuerden.
	for my $player (sort keys %affected) {
		my $state = $topology->{players}{$player};
		next if !$state || $state->{coordinator_uuid} eq $state->{uuid};
		my $group_coordinator = $state->{coordinator} || $state->{coordinator_uuid};
		return "autoLeave=0 verhindert das automatische Auftrennen der Sonos-Gruppe "
			. "um $group_coordinator (Mitglied: $player)";
	}

	return undef;
}

# Beginnt die nichtblockierende Bildung einer exakten temporaeren Sonos-Gruppe.
sub _begin_exact_group {
	my ($self, $request, $targets) = @_;
	my $preflight_error = $self->preflight_start($request, $targets);
	return $preflight_error if $preflight_error;
	my $runtime = $self->_runtime($request);
	my ($coordinator, $coordinator_error) = $self->_choose_coordinator($request, $targets);
	return $coordinator_error if $coordinator_error;
	$runtime->{targets} = [ @$targets ];
	$runtime->{coordinator} = $coordinator;
	$runtime->{deadline} = $self->{gateway}->now + $self->{group_timeout};

	# Eine bereits passende Gruppe kann ohne MQTT-Rundreise unmittelbar spielen.
	if ($self->_is_exact_group($targets, $coordinator)) {
		return $self->_start_playback($request);
	}

	my $topology = $self->topology;
	my %affected = map { $_ => 1 } @{ $self->resource_targets($targets) };
	$runtime->{affected} = [ sort keys %affected ];
	$runtime->{phase} = 'separating_start';

	# Alle Child-Player beruehrter Gruppen werden zuerst standalone; Coordinatoren
	# bleiben stehen und koennen im anschliessenden Schritt selbst beitreten.
	for my $player (sort keys %affected) {
		my $state = $topology->{players}{$player};
		next if $state->{coordinator_uuid} eq $state->{uuid};
		my $error = $self->_command($player, 'leaveGroup');
		return $error if $error;
	}

	return undef;
}

# Meldet, ob alle vom Umbau beruehrten Player bereits standalone sind.
sub _all_standalone {
	my ($self, $players) = @_;
	my $topology = $self->topology;

	# Jeder Child-Status muss per Reading bestaetigt sein, bevor Join-Befehle folgen.
	for my $player (@$players) {
		my $state = $topology->{players}{$player};
		return 0 if !$state || $state->{coordinator_uuid} ne $state->{uuid};
	}

	return 1;
}

# Sendet Join-Befehle fuer alle Zielplayer ausser dem gewaehlten Coordinator.
sub _join_exact_group {
	my ($self, $runtime) = @_;

	# Der zuvor nach Quellenfaehigkeit gewaehlte Player bleibt stabiler Coordinator.
	for my $player (@{ $runtime->{targets} }) {
		next if $player eq $runtime->{coordinator};
		my $error = $self->_join_group($player, $runtime->{coordinator});
		return $error if $error;
	}

	$runtime->{phase} = 'grouping_start';
	return undef;
}

# Klemmt einen Pegel auf die vom Request mitgegebenen, bereits validierten Sicherheitsgrenzen.
sub _bounded_volume {
	my ($self, $request, $volume) = @_;
	my $minimum = $request->{payload}{volume_min};
	my $maximum = $request->{payload}{volume_max};
	$volume = max($volume, $minimum) if defined $minimum;
	$volume = min($volume, $maximum) if defined $maximum;
	return $volume;
}

# Merkt den letzten gesendeten Pegel kurzzeitig gegen noch veraltete sonos2mqtt-Readings.
sub _remember_volume_command {
	my ($self, $request, $player, $volume) = @_;
	my $runtime = $self->_runtime($request);
	$runtime->{commanded_volumes}{$player} = {
		value => int($volume),
		at => $self->{gateway}->now,
	};
	return;
}

# Wendet die konfigurierte Lautstaerkepolitik je Player unmittelbar vor der Ausgabe an.
sub _apply_audio_levels {
	my ($self, $request, $targets) = @_;
	my $volume = $request->{payload}{volume};
	my $policy = $request->{payload}{volume_policy} || 'fixed';
	my $mute_policy = $request->{payload}{mute_policy} || 'unmute';
	my $fadein = 0 + ($request->{payload}{fadein} || 0);
	my (%from, %to, %last);

	# Die direkte API darf Mute fuer spezielle Queue-Automationen unveraendert
	# lassen; normale Sets entmuten weiterhin nur ihre tatsaechlichen Zielplayer.
	for my $player (@$targets) {
		if ($mute_policy ne 'keep') {
			my $mute_error = $self->_command($player, 'mute', 'false');
			return $mute_error if $mute_error;
		}

		my $current = 0 + $self->_reading_first($player, 0, 'volume', 'CurrentVolume');
		my $desired = defined($volume) ? $volume : $current;

		# Alarmminimum hebt nur zu leise Player an und senkt keine bereits hoehere Lautstaerke.
		if ($policy eq 'minimum' && defined $volume) {
			$desired = max($current, $volume);
		} elsif ($policy eq 'keep') {
			$desired = $current;
		}
		$desired = $self->_bounded_volume($request, $desired);
		my $must_set = defined($volume) && $policy ne 'keep' ? 1 : 0;
		$must_set = 1 if int($desired) != int($current);

		# Ein Fade startet bei zehn Prozent des Zielpegels und wird spaeter vom
		# normalen Backend-Progress ohne zusaetzliche FHEM-Timer fortgeschrieben.
		my $start = $fadein > 0
			? ($desired > 0 ? max(1, int($desired * 0.10 + 0.5)) : 0)
			: int($desired);
		next if $fadein <= 0 && !$must_set;
		my $volume_error = $self->_command($player, 'volume', $start);
		return $volume_error if $volume_error;
		$self->_remember_volume_command($request, $player, $start);
		$from{$player} = $start;
		$to{$player} = int($desired);
		$last{$player} = $start;
	}

	# Die Fade-Uhr beginnt erst mit dem tatsaechlichen Play-Befehl und kann bei
	# einer hoeher priorisierten Unterbrechung verlustfrei angehalten werden.
	if ($fadein > 0) {
		my $runtime = $self->_runtime($request);
		$runtime->{fade} = {
			duration => $fadein,
			from => \%from,
			to => \%to,
			last => \%last,
		};
	}

	return undef;
}

# Startet die Fade-Uhr genau mit dem erfolgreichen Quellenstart.
sub _activate_playback {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $now = $self->{gateway}->now;
	$runtime->{phase} = 'starting';
	$runtime->{playback_started_at} = $now;
	$runtime->{uri} = $request->{payload}{uri} if defined $request->{payload}{uri};
	$runtime->{fade}{started_at} = $now
		if $runtime->{fade} && !defined($runtime->{fade}{started_at});
	return undef;
}

# Fuehrt einen aktiven Fade nur bei einer tatsaechlichen Pegelstufe weiter.
sub _progress_fade {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $fade = $runtime->{fade};
	return undef if !$fade || $fade->{done} || $fade->{paused_at} || !defined($fade->{started_at});
	my $duration = $fade->{duration} || 0;
	my $progress = $duration > 0 ? ($self->{gateway}->now - $fade->{started_at}) / $duration : 1;
	$progress = 0 if $progress < 0;
	$progress = 1 if $progress > 1;

	# Ganzzahlige Lautstaerkestufen begrenzen die MQTT-Last auch bei langen Fades.
	for my $player (sort keys %{ $fade->{to} || {} }) {
		my $from = $fade->{from}{$player};
		my $to = $fade->{to}{$player};
		my $desired = int($from + ($to - $from) * $progress + 0.5);
		next if defined($fade->{last}{$player}) && $fade->{last}{$player} == $desired;
		my $error = $self->_command($player, 'volume', $desired);
		return $error if $error;
		$self->_remember_volume_command($request, $player, $desired);
		$fade->{last}{$player} = $desired;
	}

	$fade->{done} = 1 if $progress >= 1;
	return undef;
}

# Ersetzt die native Sonos-Queue durch die vom Auftrag gelieferten URIs.
sub _replace_managed_queue {
	my ($self, $request, $coordinator) = @_;
	my $uris = $request->{payload}{uris};
	return undef if ref($uris) ne 'ARRAY';
	return "$coordinator kann keine verwaltete Sonos-Queue aufbauen"
		if !$self->_supports_raw($coordinator);
	my $error = $self->_raw_command($coordinator, 'adv-command', {
		cmd => 'AVTransportService.RemoveAllTracksFromQueue',
	});
	return $error if $error;
	$self->_runtime($request)->{managed_queue} = 1;

	# Jede URI wird in der vom Aufrufer gelieferten Reihenfolge an die leere Queue angehaengt.
	for my $uri (@$uris) {
		$error = $self->_raw_command($coordinator, 'adv-command', {
			cmd => 'AVTransportService.AddURIToQueue',
			val => {
				InstanceID => 0,
				DesiredFirstTrackNumberEnqueued => 0,
				EnqueueAsNext => JSON::PP::true,
				EnqueuedURI => $uri,
				EnqueuedURIMetaData => '',
			},
		});

		if ($error) {
			$self->_clear_managed_queue($request);
			return $error;
		}
	}

	return undef;
}

# Leert ausschliesslich eine von diesem Request beanspruchte native Queue.
sub _clear_managed_queue {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	return undef if !$runtime->{managed_queue};
	my $coordinator = $runtime->{coordinator};
	return 'Coordinator der verwalteten Sonos-Queue ist unbekannt'
		if !defined($coordinator) || $coordinator eq '';
	my $error = $self->_raw_command($coordinator, 'adv-command', {
		cmd => 'AVTransportService.RemoveAllTracksFromQueue',
	});
	delete $runtime->{managed_queue} if !$error;
	return $error;
}

# Erkennt den Queue-Wechsel auch bei aus Trackdaten abgeleiteten, veralteten Input-Readings.
sub _queue_ready {
	my ($self, $request, $coordinator) = @_;
	my $runtime = $self->_runtime($request);
	$coordinator = $runtime->{coordinator} if !defined($coordinator) || $coordinator eq '';
	my $input = $self->_reading_first($coordinator, '', 'Input');
	my $uri = $self->_reading_first($coordinator, '', 'currentTrack_TrackUri');
	return 1 if $input eq 'Queue' || $input eq 'Playlist' || $uri =~ /^x-rincon-queue:/;
	my %managed_uri = map { $_ => 1 } @{ $request->{payload}{uris} || [] };
	return 0 if !$managed_uri{$uri};
	my $initial_uri = $runtime->{initial_snapshot}{players}{$coordinator}{uri} // '';

	# sonos2mqtt meldet bei Queue-Titeln deren HTTP-URI statt x-rincon-queue.
	# Der Wechsel von der Snapshotquelle auf eine URI genau dieses Requests ist
	# deshalb eine staerkere Bestaetigung als das lokale Input-UserReading.
	return $uri ne $initial_uri ? 1 : 0;
}

# Startet eine fortzusetzende Queue erst, nachdem Sonos den zuvor angeforderten
# Quellenwechsel bestaetigt hat; ein zu fruehes play kann sonst wirkungslos bleiben.
sub _finish_queue_resume {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $coordinators = $runtime->{resume_queue_coordinators} || [];

	# Jede betroffene Sonos-Gruppe muss bereits wieder ihre Queue melden.
	for my $coordinator (@$coordinators) {
		return undef if !$self->_queue_ready($request, $coordinator);
	}

	# Erst nach der Quellenbestaetigung wird die Queue je Coordinator gestartet.
	for my $coordinator (@$coordinators) {
		my $error = $self->_command($coordinator, 'play');
		return $error if $error;
	}

	delete $runtime->{resume_queue_coordinators};
	$runtime->{phase} = 'restored';
	return $self->_progress_fade($request);
}

# Konfiguriert eine verwaltete URI-Queue nach bestaetigtem Eingang als Schleife
# ab Titel eins und uebergibt erst dann den Start an die normale Wiedergabelogik.
sub _finish_managed_queue_start {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $coordinator = $runtime->{coordinator};
	my $error = $self->_raw_command($coordinator, 'playmode', 'REPEAT_ALL');
	return $error if $error;
	$error = $self->_raw_command($coordinator, 'selecttrack', 1);
	return $error if $error;
	$error = $self->_command($coordinator, 'play');
	return $error if $error;
	return $self->_activate_playback($request);
}

# Startet einen endlichen Clip auf allen Zielgruppen, nachdem der Playmode
# bereits separat bestaetigt wurde.
sub _start_finite_playback {
	my ($self, $request, $coordinators) = @_;
	my $uri = $request->{payload}{uri} // '';
	return "$request->{type} benoetigt eine abspielbare URI" if $uri eq '';
	my @started;

	# Jede bestehende Gruppe erhaelt den Clip genau einmal an ihrem Coordinator.
	for my $coordinator (@$coordinators) {
		my $error = $self->_command($coordinator, 'playUri', $uri);

		# Bereits gestartete Gruppen werden bei einem spaeteren Teilfehler gestoppt.
		if ($error) {

			for my $started_coordinator (@started) {
				$self->_command($started_coordinator, 'stop');
			}

			return $error;
		}
		push @started, $coordinator;
	}

	delete $self->_runtime($request)->{finite_playback_coordinators};
	return $self->_activate_playback($request);
}

# Wartet bei einem unterbrechenden Clip auf die bestaetigte Aufhebung eines
# geerbten Wiederholungsmodus, bevor die URI an Sonos uebergeben wird.
sub _finish_playmode_wait {
	my ($self, $request) = @_;
	my $coordinators = $self->_runtime($request)->{finite_playback_coordinators} || [];

	# Jeder raw-faehige Coordinator muss NORMAL tatsaechlich zurueckgemeldet haben.
	for my $coordinator (@$coordinators) {
		next if !$self->_supports_raw($coordinator);
		return undef if $self->_reading_first($coordinator, '', 'playmode') ne 'NORMAL';
	}

	return $self->_start_finite_playback($request, $coordinators);
}

# Sendet den eigentlichen sonos2mqtt-Abspielbefehl erst nach bestaetigter Gruppierung.
sub _start_playback {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $targets = $runtime->{targets};
	my @coordinators = @{ $runtime->{fanout_coordinators} || [] };
	@coordinators = ($runtime->{coordinator}) if !@coordinators && $runtime->{coordinator};
	return 'Kein Sonos-Coordinator fuer die Wiedergabe verfuegbar' if !@coordinators;
	my $level_error = $self->_apply_audio_levels($request, $targets);
	return $level_error if $level_error;
	my $type = $request->{type};

	# Eine verwaltete URI-Queue besitzt ihren Inhalt nativ pro Coordinator und
	# wird deshalb nicht unbemerkt auf mehrere bestehende Gruppen dupliziert.
	if ($type eq 'queue' && ref($request->{payload}{uris}) eq 'ARRAY') {
		return 'Verwaltete URI-Queues benoetigen genau eine Sonos-Zielgruppe'
			if @coordinators != 1;
		my $coordinator = $coordinators[0];
		$runtime->{coordinator} = $coordinator;
		my $error = $self->_replace_managed_queue($request, $coordinator);
		return $error if $error;
		$error = $self->_command($coordinator, 'input', 'Queue');

		# Bei einem Quellenfehler wird nur die von diesem Auftrag erzeugte Queue bereinigt.
		if ($error) {
			my $cleanup_error = $self->_clear_managed_queue($request);
			return $cleanup_error ? "$error; Queue-Cleanup fehlgeschlagen: $cleanup_error" : $error;
		}

		$runtime->{phase} = 'queue_waiting';
		$runtime->{deadline} = $self->{gateway}->now + max(30, $self->{group_timeout});
		return undef;
	}

	# Endliche Clips duerfen den REPEAT_ALL-Modus einer pausierten Queue nicht
	# erben. Der eigentliche URI-Start wartet auf das bestaetigte NORMAL-Reading.
	if ($type =~ /^(?:alarm|play|speak)$/) {
		my $waiting_for_playmode = 0;

		for my $coordinator (@coordinators) {
			next if !$self->_supports_raw($coordinator);
			my $playmode = $self->_reading_first($coordinator, 'NORMAL', 'playmode');
			next if $playmode eq 'NORMAL';
			my $error = $self->_raw_command($coordinator, 'playmode', 'NORMAL');
			return $error if $error;
			$waiting_for_playmode = 1;
		}

		if ($waiting_for_playmode) {
			$runtime->{finite_playback_coordinators} = [ @coordinators ];
			$runtime->{deadline} = $self->{gateway}->now + max(30, $self->{group_timeout});
			$runtime->{phase} = 'playmode_waiting';
			return undef;
		}

		return $self->_start_finite_playback($request, \@coordinators);
	}

	my @started;

	# Jede bestehende Gruppe erhaelt genau einen Quellenbefehl an ihrem Coordinator.
	for my $coordinator (@coordinators) {
		my $error;

		# Streams starten je nach Requestquelle einen Favoriten oder eine dauerhafte URI.
		if ($type eq 'stream') {
			my ($stream_command, $stream_value, $stream_error) = $self->_stream_source($request);
			return $stream_error if $stream_error;
			$error = $self->_command($coordinator, $stream_command, $stream_value);
		} else {
			$error = $self->_command($coordinator, 'input', 'Queue');
			$error ||= $self->_command($coordinator, 'play') if !$error;
		}

		# Bereits gestartete Gruppen werden bei einem spaeteren Teilfehler gestoppt.
		if ($error) {

			for my $started_coordinator (@started) {
				$self->_command($started_coordinator, 'stop');
			}

			return $error;
		}
		push @started, $coordinator;
	}

	return $self->_activate_playback($request);
}

# Startet einen neuen Auftrag und speichert die vor dem Umbau beobachtete
# Laufzeitquelle fuer eine spaetere verschachtelte Unterbrechung.
sub start {
	my ($self, $request, $targets) = @_;
	my $runtime = $self->_runtime($request);
	$runtime->{initial_snapshot} = $self->snapshot($targets);

	# all spielt parallel auf der unveraenderten aktuellen Sonos-Topologie.
	if ($self->_uses_existing_groups($request)) {
		$runtime->{targets} = [ @$targets ];
		$runtime->{fanout_coordinators} = $self->_coordinators($targets);
		$runtime->{coordinator} = $runtime->{fanout_coordinators}[0];
		return $self->_start_playback($request);
	}

	return $self->_begin_exact_group($request, $targets);
}

# Baut aus einem Snapshot eine Liste gewuenschter Gruppen innerhalb seines Scopes.
sub _snapshot_groups {
	my ($self, $snapshot) = @_;
	my %by_uuid = map { $snapshot->{players}{$_}{uuid} => $_ } keys %{ $snapshot->{players} || {} };
	my %groups;

	# Der urspruengliche Coordinator kann ausserhalb des Scopes liegen; dieser
	# Fall wurde bereits durch die Verwaltungsgrenze ausgeschlossen und bleibt sichtbar.
	for my $player (keys %{ $snapshot->{players} || {} }) {
		my $coordinator_uuid = $snapshot->{players}{$player}{coordinator_uuid};
		push @{ $groups{$coordinator_uuid} }, $player;
	}

	my @plans;

	# Jede Snapshotgruppe erhaelt ihren damaligen Coordinator als ersten Join-Anker.
	for my $coordinator_uuid (sort keys %groups) {
		my $coordinator = $by_uuid{$coordinator_uuid};
		return (undef, "Snapshot-Coordinator $coordinator_uuid ist nicht verwaltet")
			if !$coordinator;
		push @plans, {
			coordinator => $coordinator,
			members => [ sort @{ $groups{$coordinator_uuid} } ],
		};
	}

	return (\@plans, undef);
}

# Beginnt die Wiederherstellung einer zuvor gesicherten Topologie in getrennten
# Leave- und Join-Phasen, ohne den FHEM-Eventloop mit sleep zu blockieren.
sub _begin_restore {
	my ($self, $request, $snapshot, $mode) = @_;
	my ($plans, $plan_error) = $self->_snapshot_groups($snapshot);
	return $plan_error if $plan_error;
	my $runtime = $self->_runtime($request);
	$runtime->{restore_snapshot} = $snapshot;
	$runtime->{restore_plans} = $plans;
	$runtime->{restore_mode} = $mode;
	$runtime->{affected} = [ @{ $snapshot->{scope} || [] } ];
	$runtime->{deadline} = $self->{gateway}->now + $self->{group_timeout};
	$runtime->{phase} = "separating_$mode";
	my $topology = $self->topology;

	# Eine bereits passende Gruppe darf nicht nur fuer das Restaurieren von
	# Lautstaerke, Mute und Quelle auseinandergerissen und neu aufgebaut werden.
	if ($self->_snapshot_topology_matches($runtime)) {
		return $self->_restore_audio($request);
	}

	# Zuerst verlassen alle Child-Player im Scope ihre aktuelle Gruppe; damit
	# sind die folgenden Join-Befehle unabhaengig vom vorherigen Coordinator.
	for my $player (@{ $runtime->{affected} }) {
		my $state = $topology->{players}{$player};
		next if !$state || $state->{coordinator_uuid} eq $state->{uuid};
		my $error = $self->_command($player, 'leaveGroup');
		return $error if $error;
	}

	return undef;
}

# Sendet alle Join-Befehle eines gespeicherten Topologieplans.
sub _join_snapshot_groups {
	my ($self, $runtime, $mode) = @_;

	# Standalone-Gruppen bestehen nur aus ihrem Coordinator und benoetigen keinen Befehl.
	for my $plan (@{ $runtime->{restore_plans} || [] }) {

		for my $player (@{ $plan->{members} }) {
			next if $player eq $plan->{coordinator};
			my $error = $self->_join_group($player, $plan->{coordinator});
			return $error if $error;
		}

	}

	$runtime->{phase} = "grouping_$mode";
	return undef;
}

# Prueft, ob jede gespeicherte Gruppe anhand der aktuellen UUID-Readings wieder besteht.
sub _snapshot_topology_matches {
	my ($self, $runtime) = @_;
	my $topology = $self->topology;

	# Alle Mitglieder eines Plans muessen dieselbe Coordinator-UUID wie ihr Anker melden.
	for my $plan (@{ $runtime->{restore_plans} || [] }) {
		my $coordinator_state = $topology->{players}{ $plan->{coordinator} };
		return 0 if !$coordinator_state;
		my $coordinator_uuid = $coordinator_state->{uuid};

		for my $player (@{ $plan->{members} }) {
			return 0 if !$topology->{players}{$player}
				|| $topology->{players}{$player}{coordinator_uuid} ne $coordinator_uuid;
		}

	}

	return 1;
}

# Stellt Lautstaerke, Mute und die von sonos2mqtt unterstuetzte Quelle je
# urspruenglicher Gruppe bestmoeglich wieder her.
sub _restore_audio {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $snapshot = $runtime->{restore_snapshot};
	my @queue_resume_coordinators;

	# Erst die individuellen Pegel wiederherstellen, bevor eine Quelle erneut startet.
	for my $player (@{ $snapshot->{scope} || [] }) {
		my $state = $snapshot->{players}{$player};
		my $restore_volume = int($state->{volume});
		$restore_volume = int($self->_bounded_volume($request, $restore_volume))
			if ($runtime->{restore_mode} || '') eq 'resume';
		my $volume_error = $self->_command($player, 'volume', $restore_volume);
		return $volume_error if $volume_error;
		$self->_remember_volume_command($request, $player, $restore_volume);
		my $mute = $state->{mute} =~ /^(?:1|true|on)$/i ? 'true' : 'false';
		my $mute_error = $self->_command($player, 'mute', $mute);
		return $mute_error if $mute_error;
	}

	# Pro Snapshotgruppe reicht ein Quellenbefehl am damaligen Coordinator.
	for my $plan (@{ $runtime->{restore_plans} || [] }) {
		my $coordinator = $plan->{coordinator};
		my $state = $snapshot->{players}{$coordinator};
		my $playmode = $state->{playmode} || 'NORMAL';

		# Resume bestaetigt den gespeicherten Modus auch bei einem verzoegerten
		# Reading; beim finalen Baseline-Restore genuegt weiterhin ein echter Wechsel.
		if ($self->_supports_raw($coordinator)) {
			my $current_playmode = $self->_reading_first($coordinator, 'NORMAL', 'playmode');

			if (($runtime->{restore_mode} || '') eq 'resume' || $current_playmode ne $playmode) {
				my $playmode_error = $self->_raw_command($coordinator, 'playmode', $playmode);
				return $playmode_error if $playmode_error;
			}
		}

		my $error;

		# Beim Resume ist der Request selbst die Wahrheitsquelle. Ein verzoegertes
		# Trackreading darf weder Favorit noch Stream-URI durch eine alte URI ersetzen.
		if (($runtime->{restore_mode} || '') eq 'resume' && $request->{type} eq 'stream') {
			my ($stream_command, $stream_value, $stream_error) = $self->_stream_source($request);
			return $stream_error if $stream_error;
			$error = $self->_command($coordinator, $stream_command, $stream_value);
		} elsif (($runtime->{restore_mode} || '') eq 'resume' && $request->{type} eq 'queue') {
			$error = $self->_command($coordinator, 'input', 'Queue');
			push @queue_resume_coordinators, $coordinator if !$error;
		} elsif (($runtime->{restore_mode} || '') eq 'resume'
			&& ($request->{payload}{uri} || '') ne '') {
			$error = $self->_command($coordinator, 'playUri', $request->{payload}{uri});
		} else {
			next if ($state->{transport} || '') !~ /^(?:PLAYING|GROUP_PLAYING|TRANSITIONING)$/;

			# Ein finales Baseline-Restore bleibt auf die im Snapshot tatsaechlich
			# beobachtete, von sonos2mqtt unterstuetzte Quelle begrenzt.
			if (($state->{input} || '') eq 'Queue') {
				$error = $self->_command($coordinator, 'input', 'Queue');
				$error ||= $self->_command($coordinator, 'play') if !$error;
			} elsif (($state->{uri} || '') ne '') {
				$error = $self->_command($coordinator, 'playUri', $state->{uri});
			} else {
				$error = $self->_command($coordinator, 'play');
			}
		}
		return $error if $error;
	}

	# Der Queue-Start folgt asynchron, weil Sonos switchtoqueue und play nicht
	# verlaesslich innerhalb desselben Befehlszyklus verarbeitet.
	if (@queue_resume_coordinators) {
		$runtime->{resume_queue_coordinators} = \@queue_resume_coordinators;
		$runtime->{deadline} = $self->{gateway}->now + max(30, $self->{group_timeout});
		$runtime->{phase} = 'resume_queue_waiting';
		return undef;
	}

	$runtime->{phase} = 'restored';
	return undef;
}

# Fuehrt Gruppierungs- und Restorephasen anhand bestaetigter Device-Readings fort.
sub progress {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $phase = $runtime->{phase} || '';
	return $self->_progress_fade($request) if $phase eq 'starting' || $phase eq 'restored';
	return undef if $phase eq '';

	# Eine verwaltete Queue startet erst nach bestaetigtem Queue-Eingang.
	if ($phase eq 'queue_waiting') {
		return 'Zeitueberschreitung beim Aktivieren der Sonos-Queue'
			if $runtime->{deadline} && $self->{gateway}->now > $runtime->{deadline};
		return undef if !$self->_queue_ready($request);
		return $self->_finish_managed_queue_start($request);
	}

	# Auch beim Resume darf play erst nach der bestaetigten Queue-Quelle folgen.
	if ($phase eq 'resume_queue_waiting') {
		return 'Zeitueberschreitung beim Wiederaufnehmen der Sonos-Queue'
			if $runtime->{deadline} && $self->{gateway}->now > $runtime->{deadline};
		return $self->_finish_queue_resume($request);
	}

	# Ein endlicher Clip startet erst nach der bestaetigten Playmode-Normalisierung.
	if ($phase eq 'playmode_waiting') {
		return 'Zeitueberschreitung beim Normalisieren des Sonos-Playmodes'
			if $runtime->{deadline} && $self->{gateway}->now > $runtime->{deadline};
		return $self->_finish_playmode_wait($request);
	}

	return 'Zeitueberschreitung bei der Sonos-Gruppierung'
		if $runtime->{deadline} && $self->{gateway}->now > $runtime->{deadline};

	# Start- und Restorepfade trennen zuerst alle betroffenen Child-Player.
	if ($phase =~ /^separating_(start|resume|restore)$/) {
		return undef if !$self->_all_standalone($runtime->{affected});
		my $mode = $1;
		return $mode eq 'start'
			? $self->_join_exact_group($runtime)
			: $self->_join_snapshot_groups($runtime, $mode);
	}

	# Nach einer Startgruppierung wird unmittelbar der eigentliche Audioauftrag ausgefuehrt.
	if ($phase eq 'grouping_start') {
		return undef if !$self->_is_exact_group($runtime->{targets}, $runtime->{coordinator});
		return $self->_start_playback($request);
	}

	# Resume und finales Restore teilen dieselbe gespeicherte Topologie und Audioquelle.
	if ($phase eq 'grouping_resume' || $phase eq 'grouping_restore') {
		return undef if !$self->_snapshot_topology_matches($runtime);
		return $self->_restore_audio($request);
	}

	return "Unbekannte Sonos-Laufzeitphase: $phase";
}

# Pausiert den tatsaechlichen Coordinator und speichert unmittelbar davor den
# aktuellen Zustand, einschliesslich manuell angepasster Lautstaerken.
sub suspend {
	my ($self, $request, $targets) = @_;
	my $runtime = $self->_runtime($request);
	my $fade_error = $self->_progress_fade($request);
	return $fade_error if $fade_error;
	$runtime->{resume_snapshot} = $self->snapshot($targets);
	my $now = $self->{gateway}->now;

	# Kurz nach einem Volume-Befehl ist das Reading gelegentlich noch alt. Nur in
	# diesem engen Fenster gewinnt der gesendete Wert; spaetere manuelle Aenderungen bleiben erhalten.
	for my $player (@{ $runtime->{resume_snapshot}{scope} || [] }) {
		my $commanded = $runtime->{commanded_volumes}{$player};
		next if !$commanded;
		my $observed = int($runtime->{resume_snapshot}{players}{$player}{volume});

		if ($observed == $commanded->{value}) {
			delete $runtime->{commanded_volumes}{$player};
		} elsif ($now - $commanded->{at} <= $VOLUME_READING_GRACE) {
			$runtime->{resume_snapshot}{players}{$player}{volume} = $commanded->{value};
		} else {
			delete $runtime->{commanded_volumes}{$player};
		}
	}

	# Jeder aktuelle Coordinator wird genau einmal pausiert.
	for my $coordinator (@{ $self->_coordinators($targets) }) {
		my $error = $self->_command($coordinator, 'pause');
		return $error if $error;
	}

	$runtime->{fade}{paused_at} = $self->{gateway}->now
		if $runtime->{fade} && !$runtime->{fade}{done} && !$runtime->{fade}{paused_at};
	$runtime->{phase} = 'suspended';
	return undef;
}

# Setzt einen unterbrochenen Auftrag ueber dessen frischen Suspend-Snapshot fort.
sub resume {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	return 'Kein Sonos-Snapshot fuer die Wiederaufnahme vorhanden'
		if ref($runtime->{resume_snapshot}) ne 'HASH';

	# Die Unterbrechungsdauer zaehlt nicht zur fachlich gewuenschten Fade-Dauer.
	if ($runtime->{fade} && $runtime->{fade}{paused_at}) {
		$runtime->{fade}{started_at} += $self->{gateway}->now - $runtime->{fade}{paused_at};
		delete $runtime->{fade}{paused_at};
	}

	return $self->_begin_restore($request, $runtime->{resume_snapshot}, 'resume');
}

# Stoppt alle aktuellen Coordinatoren der tatsaechlichen Auftragsziele.
sub stop {
	my ($self, $request, $targets) = @_;
	my $runtime = $self->_runtime($request);

	# Eine pausierte Sitzung besitzt den Coordinator gerade nicht; ihr Cleanup
	# darf deshalb eine darueberliegende Ansage oder einen Alarm nicht stoppen.
	if (($runtime->{phase} || '') ne 'suspended') {

		for my $coordinator (@{ $self->_coordinators($targets) }) {
			my $error = $self->_command($coordinator, 'stop');
			return $error if $error;
		}

	}

	# Nur eine vom AudioManager selbst aufgebaute Queue wird beim Ende geleert.
	my $cleanup_error = $self->_clear_managed_queue($request);
	return $cleanup_error if $cleanup_error;

	return undef;
}

# Stellt einen externen Baseline-Snapshot nach dem letzten Managerauftrag wieder her.
sub restore {
	my ($self, $snapshot) = @_;
	my $fake_request = { runtime => { backends => {} } };
	my $error = $self->_begin_restore($fake_request, $snapshot, 'restore');
	return $error if $error;

	# Finales Restore wird vom Modulworker weitergefuehrt; das Hilfsobjekt muss
	# deshalb fuer den Aufrufer erreichbar bleiben.
	return $fake_request;
}

# Prueft anhand Transportstatus, Quellenwechsel und Ausgangssnapshot, ob ein
# endlicher Auftrag bereits laeuft. Sonos darf die angeforderte HTTP-URI intern
# umschreiben, ohne dass eine tatsaechlich gestartete Ansage als Fehler endet.
sub is_playing {
	my ($self, $request, $targets) = @_;
	my $uri = $request->{payload}{uri} // '';
	my $runtime = $self->_runtime($request);
	my $snapshot = $runtime->{initial_snapshot}{players} || {};
	my %seen;
	my @players = grep { defined($_) && $_ ne '' && !$seen{$_}++ }
		(@{ $runtime->{fanout_coordinators} || [] }, $runtime->{coordinator}, @$targets);

	# Der Coordinator wird zuerst geprueft, weil Gruppenmitglieder ihre Quelle je
	# nach sonos2mqtt-Version verzoegert oder als interne Gruppen-URI melden.
	for my $player (@players) {
		my $transport = $self->{gateway}->reading_value($player, 'transportState', '');
		next if $transport !~ /^(?:PLAYING|GROUP_PLAYING|TRANSITIONING)$/;
		my $current_uri = $self->{gateway}->reading_value($player, 'currentTrack_TrackUri', '');
		my $initial = $snapshot->{$player} || {};
		my $initial_uri = $initial->{uri} // '';
		my $initial_transport = $initial->{transport} // '';
		my ($confirmed, $reason) = (0, '');

		# Exakte URI, ein nach dem Quellenbefehl beobachteter Quellenwechsel oder ein
		# echter STOPPED->PLAYING-Wechsel sind jeweils eigenstaendige Startbelege.
		if ($uri eq '' || $current_uri eq $uri) {
			($confirmed, $reason) = (1, $uri eq '' ? 'active_transport' : 'exact_uri');
		} elsif ($current_uri ne '' && $current_uri ne $initial_uri) {
			($confirmed, $reason) = (1, 'source_changed');
		} elsif ($transport =~ /^(?:PLAYING|GROUP_PLAYING)$/
			&& $initial_transport !~ /^(?:PLAYING|GROUP_PLAYING|TRANSITIONING)$/) {
			($confirmed, $reason) = (1, 'transport_started');
		}

		if ($confirmed) {
			$runtime->{playback_confirmed_at} ||= $self->{gateway}->now;
			$runtime->{playback_confirmation} ||= "$reason:$player";
			return 1;
		}
	}

	return 0;
}

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

