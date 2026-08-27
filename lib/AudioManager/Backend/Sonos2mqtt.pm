package AudioManager::Backend::Sonos2mqtt;

use strict;
use warnings;
use parent qw(AudioManager::Backend::Sonos2mqtt::Health AudioManager::Backend::Sonos2mqtt::Topology AudioManager::Backend::Sonos2mqtt::Snapshot AudioManager::Backend::Sonos2mqtt::Controls AudioManager::Backend);
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

# Meldet, ob der Coordinator noch eine hoerbare oder gerade wechselnde Quelle ausgibt.
sub _transport_is_active {
	my ($self, $coordinator) = @_;
	my $transport = $self->_reading_first($coordinator, 'STOPPED', 'transportState');
	return $transport =~ /^(?:PLAYING|GROUP_PLAYING|TRANSITIONING)$/ ? 1 : 0;
}

# Setzt den eigentlichen Start fort, nachdem eine vorherige Quelle bestaetigt still ist.
sub _continue_start {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $targets = $runtime->{pending_start_targets} || [];

	# Vorhandene Gruppen behalten ihre Topologie und starten je aktuellem Coordinator.
	if ($self->_uses_existing_groups($request)) {
		$runtime->{targets} = [ @$targets ];
		$runtime->{fanout_coordinators} = $self->_coordinators($targets);
		$runtime->{coordinator} = $runtime->{fanout_coordinators}[0];
		return $self->_start_playback($request);
	}

	return $self->_begin_exact_group($request, $targets);
}

# Pausiert eine noch aktive Ausgangsquelle und wartet auf das Sonos-Reading,
# bevor Lautstaerke oder Quelle des neuen Auftrags geaendert werden.
sub _quiet_before_start {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $coordinators = $self->_coordinators($runtime->{pending_start_targets} || []);
	my @active = grep { $self->_transport_is_active($_) } @$coordinators;
	return $self->_continue_start($request) if !@active;

	# Pause ist idempotent und schuetzt auch eine externe, nicht vom Scheduler bekannte Quelle.
	for my $coordinator (@active) {
		my $error = $self->_command($coordinator, 'pause');
		return $error if $error;
	}

	$runtime->{quieting_coordinators} = [ @active ];
	$runtime->{deadline} = $self->{gateway}->now + $self->{group_timeout};
	$runtime->{phase} = 'start_quieting';

	# Synchron aktualisierende Templates duerfen ohne kuenstlichen Workerzyklus fortfahren.
	return undef if grep { $self->_transport_is_active($_) } @active;
	delete @{$runtime}{qw(quieting_coordinators deadline)};
	return $self->_continue_start($request);
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
	my $uri = $self->_reading_first($coordinator, '', 'currentTrack_trackUri');
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
	$runtime->{pending_start_targets} = [ @$targets ];
	return $self->_quiet_before_start($request);
}

# Fuehrt Gruppierungs- und Restorephasen anhand bestaetigter Device-Readings fort.
sub progress {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	my $phase = $runtime->{phase} || '';
	return $self->_progress_fade($request) if $phase eq 'starting' || $phase eq 'restored';
	return undef if $phase eq '';

	# Pegel und neue Quelle folgen erst auf die bestaetigte Pause der vorherigen Ausgabe.
	if ($phase eq 'start_quieting') {
		return 'Zeitueberschreitung beim Pausieren der vorherigen Sonos-Quelle'
			if $runtime->{deadline} && $self->{gateway}->now > $runtime->{deadline};
		return undef if grep {
			$self->_transport_is_active($_)
		} @{ $runtime->{quieting_coordinators} || [] };
		delete @{$runtime}{qw(quieting_coordinators deadline)};
		return $self->_continue_start($request);
	}

	# Resume und Baseline-Restore warten symmetrisch auf das bestaetigte Ende der Ausgabe.
	if ($phase eq 'resume_quieting' || $phase eq 'restore_quieting') {
		return $self->_finish_quiet_restore($request);
	}

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

# Prueft anhand Transportstatus, Quellenwechsel und Ausgangssnapshot, ob ein
# endlicher Auftrag bereits laeuft. Sonos darf die angeforderte HTTP-URI intern
# umschreiben, ohne dass eine tatsaechlich gestartete Ansage als Fehler endet.
sub is_playing {
	my ($self, $request, $targets) = @_;
	my $uri = $request->{payload}{uri} // '';
	my $runtime = $self->_runtime($request);
	my $phase = $runtime->{phase} || '';
	return 0 if $phase ne 'starting' && $phase ne 'restored';
	my $snapshot = $runtime->{initial_snapshot}{players} || {};
	my %seen;
	my @players = grep { defined($_) && $_ ne '' && !$seen{$_}++ }
		(@{ $runtime->{fanout_coordinators} || [] }, $runtime->{coordinator}, @$targets);

	# Der Coordinator wird zuerst geprueft, weil Gruppenmitglieder ihre Quelle je
	# nach sonos2mqtt-Version verzoegert oder als interne Gruppen-URI melden.
	for my $player (@players) {
		my $transport = $self->{gateway}->reading_value($player, 'transportState', '');
		next if $transport !~ /^(?:PLAYING|GROUP_PLAYING|TRANSITIONING)$/;
		my $current_uri = $self->{gateway}->reading_value($player, 'currentTrack_trackUri', '');
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

1;
