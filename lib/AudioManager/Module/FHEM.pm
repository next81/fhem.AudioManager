# Copyright (c) 2026 Andreas Planer

package AudioManager::Module::FHEM;

use strict;
use warnings;
use JSON::PP ();
use AudioManager::Backend ();
use AudioManager::Backend::Sonos2mqtt ();
use AudioManager::Config ();
use AudioManager::Core ();
use AudioManager::FHEMGateway ();
use AudioManager::Module::Runtime ();
use AudioManager::Module::Status ();
use AudioManager::Module::TTS ();
use AudioManager::Supervisor ();
# Liefert pro Instanz genau ein austauschbares FHEM-Gateway.
sub gateway {
	my ($hash) = @_;
	return AudioManager::Module::Status::gateway($hash);
}

# Schreibt ein einzelnes Reading ueber die testbare Gatewaygrenze.
sub reading {
	my ($hash, $reading, $value, $trigger) = @_;
	return AudioManager::Module::Status::reading($hash, $reading, $value, $trigger);
}

# Schreibt eine begrenzte einzeilige Meldung gemaess dem FHEM-verbose-Attribut.
sub log {
	my ($hash, $level, $message) = @_;
	my $verbose = gateway($hash)->attr_value(
		$hash->{NAME}, 'verbose', gateway($hash)->attr_value('global', 'verbose', 3),
	);
	return if $verbose !~ /^\d+$/ || $verbose < $level;
	$message = '' if !defined $message;
	$message =~ s/[\r\n]+/ /g;
	$message = substr($message, 0, 4096) . '... <truncated>' if length($message) > 4096;
	gateway($hash)->log($hash->{NAME}, $level, "AudioManager $hash->{NAME}: $message");
	return;
}

# Plant den Worker ueber die FHEM-Fassade, wenn Lifecycle-Aenderungen Arbeit erzeugen.
sub _schedule {
	my ($hash, $scheduler) = @_;
	return $scheduler->($hash) if ref($scheduler) eq 'CODE';
	return main::AudioManager_schedule_worker($hash)
		if defined &main::AudioManager_schedule_worker;
	return;
}

# Registriert Lebenszyklus, Benutzerbefehle, Readings und validierte Attribute.
sub initialize {
	my ($hash, $reading_attributes) = @_;
	$hash->{DefFn} = 'AudioManager_Define';
	$hash->{UndefFn} = 'AudioManager_Undef';
	$hash->{SetFn} = 'AudioManager_Set';
	$hash->{GetFn} = 'AudioManager_Get';
	$hash->{AttrFn} = 'AudioManager_Attr';
	$hash->{NotifyFn} = 'AudioManager_Notify';
	$hash->{FW_deviceOverview} = 1;
	$hash->{AttrList} = 'priorities defaultVolumes volumePolicies volumeLimits quietHours speakDedupeWindow '
		. 'ttsDevice zones backendAvailability startTimeout stopGrace groupTimeout healthDebounce '
		. 'healthVerifyTimeout healthRecoveryCooldown healthProbeInterval autoLeave:0,1 disable:0,1 '
		. ($reading_attributes // '');
	return;
}

# Parst versionierbare Backendbeschreibungen vom Format treiber[@instanz]=device,device.
sub parse_backend_definition {
	my ($hash, $descriptors) = @_;
	my %backends;
	my %player_backend;
	my $gateway = gateway($hash);
	my $configuration = AudioManager::Config::configuration(
		$hash, $gateway, AudioManager::Core->default_priorities,
	);

	# Jede Instanz wird ueber die Registry erzeugt; neue Treiber benoetigen keine Coreaenderung.
	for my $descriptor (@$descriptors) {
		my ($driver, $id, $players) = $descriptor =~ /^([a-z][a-z0-9_]*)(?:\@([A-Za-z][A-Za-z0-9_.-]*))?=(.+)$/;
		return (undef, undef, "Ungueltiges Backend: $descriptor") if !defined $players;
		$id ||= $driver;
		return (undef, undef, "Backend-ID $id ist doppelt") if $backends{$id};
		my @configured_players = grep { $_ ne '' } split /,/, $players;
		my (@players, %seen_players);

		# Fehlende Player werden protokolliert und duerfen gueltige Player nicht blockieren.
		for my $player (@configured_players) {
			next if $seen_players{$player}++;

			# Nur nicht vorhandene Devices sind tolerierbar; vorhandene Devices prueft der Adapter weiter streng.
			if (!$gateway->device($player)) {
				AudioManager::Module::FHEM::log($hash, 1, "Backend $id ignoriert nicht vorhandenen Player $player");
				next;
			}
			push @players, $player;
		}

		return (undef, undef, "Backend $id enthaelt keinen vorhandenen Player") if !@players;
		my $backend;
		my $ok = eval {
			$backend = AudioManager::Backend->create(
				$driver,
				id => $id,
				players => \@players,
				gateway => $gateway,
				group_timeout => $configuration->{group_timeout},
				auto_leave => $configuration->{auto_leave},
			);
			1;
		};
		return (undef, undef, $@ || "Backend $descriptor konnte nicht erzeugt werden") if !$ok;
		my $error = $backend->validate;
		return (undef, undef, $error) if $error;
		$backend->configure(availability => $configuration->{availability});
		$backends{$id} = $backend;

		# Ein FHEM-Player darf nur genau einem Backendadapter gehoeren.
		for my $player (@{ $backend->managed_players }) {
			return (undef, undef, "$player ist mehreren Backends zugeordnet") if $player_backend{$player};
			$player_backend{$player} = $id;
		}

	}

	return (\%backends, \%player_backend, undef);
}

# Setzt NOTIFYDEV aus Lifecycle, TTS, Playern und optionalen Backend-Healthdevices zusammen.
sub set_notify_devices {
	my ($hash, $tts_override) = @_;
	my %devices = (global => 1);
	my %health_device_backends;
	my %topology_device_backends;

	# Playerreadings treiben Topologie-, Start- und Endebestaetigungen.
	for my $backend_id (sort keys %{ $hash->{helper}{backends} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		$devices{$_} = 1 for @{ $backend->managed_players };

		# Auch fremde Gruppenmitglieder duerfen Topologiewarnungen sofort aktualisieren.
		for my $device (@{ $backend->topology_devices }) {
			$devices{$device} = 1;
			push @{ $topology_device_backends{$device} }, $backend_id;
		}

		for my $device (@{ $backend->health_devices }) {
			$devices{$device} = 1;
			push @{ $health_device_backends{$device} }, $backend_id;
		}

	}

	$hash->{helper}{health_device_backends} = \%health_device_backends;
	$hash->{helper}{topology_device_backends} = \%topology_device_backends;
	my $tts = defined($tts_override) ? $tts_override
		: gateway($hash)->attr_value($hash->{NAME}, 'ttsDevice', '');
	$devices{$tts} = 1 if $tts ne '';
	return gateway($hash)->set_notify_devices($hash, join(',', sort keys %devices));
}

# Erzeugt den generischen Supervisor und bindet nur Zeitquelle und Reading-Callback an FHEM.
sub build_supervisor {
	my ($hash) = @_;
	my $configuration = AudioManager::Config::configuration(
		$hash, gateway($hash), AudioManager::Core->default_priorities,
	);
	return AudioManager::Supervisor->new(
		backends => $hash->{helper}{backends},
		clock => sub { return gateway($hash)->now },
		debounce => $configuration->{health_debounce},
		verify_timeout => $configuration->{health_verify_timeout},
		cooldown => $configuration->{health_recovery_cooldown},
		probe_interval => $configuration->{health_probe_interval},
		on_change => sub { AudioManager::Module::Status::update_health($hash, \&AudioManager::Module::FHEM::log) },
	);
}

# Definiert einen Manager mit einer oder mehreren expliziten Backendinstanzen.
sub define {
	my ($hash, $definition, $version, $worker_name, $scheduler) = @_;
	my @parts = split /[ \t]+/, $definition;
	return 'Usage: define <name> AudioManager <backend>[@<id>]=<player>[,<player>...] [...]'
		if @parts < 3;
	my (undef, undef, @descriptors) = @parts;
	$hash->{helper} ||= {};

	# Bei defmod wird erst nach erfolgreicher neuer Validierung der alte Timerzustand verworfen.
	my ($backends, $player_backend, $error) = parse_backend_definition($hash, \@descriptors);
	return "AudioManager: $error" if $error;
	gateway($hash)->cancel_timer($hash, $worker_name);
	delete $hash->{helper}{worker_scheduled};
	delete $hash->{helper}{worker_at};
	delete $hash->{helper}{backend_health_log_states};
	delete $hash->{helper}{backend_health_errors};
	$hash->{DEF} = join(' ', @descriptors);
	$hash->{helper}{backends} = $backends;
	$hash->{helper}{player_backend} = $player_backend;
	$hash->{helper}{tts_queue} = [];
	$hash->{helper}{baselines} = {};
	$hash->{helper}{restore_jobs} = [];
	$hash->{helper}{mute_snapshot} = {};
	$hash->{helper}{deduplicated_requests} = 0;
	$hash->{helper}{core} = AudioManager::Module::Runtime::build_core($hash, $scheduler);
	$hash->{helper}{supervisor} = build_supervisor($hash);
	set_notify_devices($hash);
	reading($hash, 'version', $version, 0);
	reading($hash, 'backendCount', scalar keys %$backends, 0);
	reading($hash, 'playerCount', scalar keys %$player_backend, 0);
	reading($hash, 'lastError', 'none', 0);
	AudioManager::Module::Status::update_topology_warning($hash);
	AudioManager::Module::Status::update_status($hash);
	AudioManager::Module::Status::update_health($hash, \&AudioManager::Module::FHEM::log);
	_schedule($hash, $scheduler);
	AudioManager::Module::FHEM::log($hash, 2, "defined; version=$version; backends=" . join(',', sort keys %$backends));
	return undef;
}

# Entfernt Timer und stoppt alle vom Manager noch gehaltenen Auftraege.
sub undefine {
	my ($hash, $worker_name) = @_;
	gateway($hash)->cancel_timer($hash, $worker_name);
	$hash->{helper}{core}->cancel_matching if $hash->{helper}{core};
	delete $hash->{helper}{tts_current};
	delete $hash->{helper}{tts_queue};
	delete $hash->{helper}{restore_jobs};
	delete $hash->{helper}{mute_snapshot};
	delete $hash->{helper}{supervisor};
	delete $hash->{helper}{worker_scheduled};
	delete $hash->{helper}{worker_at};
	return undef;
}

# Validiert alle verwalteten Attribute und aktualisiert wirksame Schedulerwerte sofort.
sub attr {
	my ($defs, $operation, $name, $attribute, $values, $scheduler) = @_;
	return undef if $operation ne 'set' && $operation ne 'del';
	my $value = join(' ', @$values);
	my $hash = $defs->{$name};

	# Prioritaeten sind partielle Overrides und wirken nur auf danach angenommene Auftraege.
	if ($attribute eq 'priorities') {
		my ($parsed, $error) = AudioManager::Config::parse_numeric_map(
			$operation eq 'set' ? $value : '', AudioManager::Core->default_priorities, 0, 10_000,
		);
		return "priorities: $error" if $error;
		$hash->{helper}{core}->configure_priorities($parsed) if $hash && $hash->{helper}{core};
		return undef;
	}

	# Standardlautstaerken werden beim Eingang eines neuen Requests festgeschrieben.
	if ($attribute eq 'defaultVolumes') {
		my (undef, $error) = AudioManager::Config::parse_numeric_map(
			$operation eq 'set' ? $value : '', AudioManager::Config::default_volumes(), 0, 100,
		);
		return $error ? "defaultVolumes: $error" : undef;
	}

	# Lautstaerkepolitiken sind auf die implementierten Strategien begrenzt.
	if ($attribute eq 'volumePolicies') {
		my (undef, $error) = AudioManager::Config::parse_volume_policies($operation eq 'set' ? $value : '');
		return $error ? "volumePolicies: $error" : undef;
	}

	# Lautstaerkebegrenzungen sind unabhaengige Sicherheitsgrenzen fuer Start und Resume.
	if ($attribute eq 'volumeLimits') {
		my (undef, $error) = AudioManager::Config::parse_volume_limits($operation eq 'set' ? $value : '');
		return $error ? "volumeLimits: $error" : undef;
	}

	# Ruhezeiten werden pro Audioart angegeben und blockieren nur neue Auftraege dieser Art.
	if ($attribute eq 'quietHours') {
		my (undef, $error) = AudioManager::Config::parse_quiet_hours($operation eq 'set' ? $value : '');
		return $error ? "quietHours: $error" : undef;
	}

	# Das Deduplizierungsfenster darf deaktiviert, aber niemals negativ werden.
	if ($attribute eq 'speakDedupeWindow') {
		my $seconds = $operation eq 'set' ? $value : 5;
		return 'speakDedupeWindow muss eine nichtnegative Zahl sein'
			if $seconds !~ /^\d+(?:\.\d+)?$/;
		$hash->{helper}{core}->set_dedupe_window($seconds) if $hash && $hash->{helper}{core};
		return undef;
	}

	# Automatisches Auftrennen bestehender Gruppen ist eine ausdrueckliche Freigabe.
	if ($attribute eq 'autoLeave') {
		return 'autoLeave muss 0 oder 1 sein'
			if $operation eq 'set' && $value !~ /^(?:0|1)$/;
		my $enabled = $operation eq 'set' ? $value : 0;

		# Jede geladene Backendinstanz erhaelt die Freigabe ohne Neudefinition.
		if ($hash) {
			for my $backend (values %{ $hash->{helper}{backends} || {} }) {
				$backend->configure(auto_leave => $enabled);
			}
		}

		return undef;
	}

	# Health-Zeitgrenzen halten Eventstuerme klein und begrenzen die Bestaetigungsphase.
	if ($attribute =~ /^(?:healthDebounce|healthVerifyTimeout|healthRecoveryCooldown|healthProbeInterval)$/) {
		my $seconds = $operation eq 'set' ? $value
			: $attribute eq 'healthDebounce' ? 3
			: $attribute eq 'healthVerifyTimeout' ? 15
			: $attribute eq 'healthRecoveryCooldown' ? 60 : 900;
		my $allow_zero = $attribute ne 'healthVerifyTimeout' && $attribute ne 'healthProbeInterval';
		return "$attribute muss eine " . ($allow_zero ? 'nichtnegative' : 'positive') . ' Zahl sein'
			if $seconds !~ /^\d+(?:\.\d+)?$/ || (!$allow_zero && $seconds <= 0);

		# Der Supervisor uebernimmt neue Grenzen fuer alle danach geplanten Healthlaeufe.
		if ($hash && $hash->{helper}{supervisor}) {
			my %mapping = (
				healthDebounce => 'debounce',
				healthVerifyTimeout => 'verify_timeout',
				healthRecoveryCooldown => 'cooldown',
				healthProbeInterval => 'probe_interval',
			);
			$hash->{helper}{supervisor}->configure($mapping{$attribute} => $seconds);
			_schedule($hash, $scheduler);
		}

		return undef;
	}

	# Zeitgrenzen muessen positiv bleiben, damit ausgefallene Player den Worker nicht festhalten.
	if ($attribute =~ /^(?:startTimeout|stopGrace|groupTimeout)$/) {
		return "$attribute muss eine positive Zahl sein"
			if $operation eq 'set' && ($value !~ /^\d+(?:\.\d+)?$/ || $value <= 0);

		# Der Gruppentimeout liegt im Adapter und wird fuer neue Operationen sofort aktualisiert.
		if ($attribute eq 'groupTimeout' && $hash) {
			my $timeout = $operation eq 'set' ? $value : 10;
			$_->configure(group_timeout => $timeout) for values %{ $hash->{helper}{backends} || {} };
		}

		return undef;
	}

	# Zonen werden syntaktisch und gegen die Define-Verwaltungsgrenze geprueft.
	if ($attribute eq 'zones') {
		my ($zones, $error) = AudioManager::Config::parse_zones($operation eq 'set' ? $value : '');
		return "zones: $error" if $error;

		if ($hash) {

			for my $zone (keys %$zones) {

				for my $player (@{ $zones->{$zone} }) {
					return "Zone $zone enthaelt nicht verwalteten Player $player"
						if !$hash->{helper}{player_backend}{$player};
				}

			}

		}
		return undef;
	}

	# Optionale Bridgezuordnungen werden syntaktisch geprueft und sofort backendweise gebunden.
	if ($attribute eq 'backendAvailability') {
		my ($mapping, $error) = AudioManager::Config::parse_backend_availability(
			$operation eq 'set' ? $value : '',
		);
		return "backendAvailability: $error" if $error;

		if ($hash) {

			for my $backend_id (sort keys %{ $hash->{helper}{backends} || {} }) {
				$hash->{helper}{backends}{$backend_id}->configure(availability => $mapping);
				$hash->{helper}{supervisor}->request_probe($backend_id, 'availability_changed')
					if $hash->{helper}{supervisor};
			}

			set_notify_devices($hash);
			_schedule($hash, $scheduler);
		}
		return undef;
	}

	# Ein TTS-Provider darf beim Laden noch spaeter definiert werden; Notify wird dennoch aktualisiert.
	if ($attribute eq 'ttsDevice') {
		return 'ttsDevice darf nicht leer sein' if $operation eq 'set' && $value eq '';
		set_notify_devices($hash, $operation eq 'set' ? $value : '') if $hash;
		return undef;
	}

	# disable stoppt aktive Ausgaben, verwirft Warteschlangen und aktualisiert den Zustand sofort.
	if ($attribute eq 'disable') {
		return 'disable muss 0 oder 1 sein' if $operation eq 'set' && $value !~ /^(?:0|1)$/;

		if ($hash && $hash->{helper}{core}) {
			$hash->{helper}{core}->cancel_matching if $operation eq 'set' && $value eq '1';
			reading($hash, 'state', $operation eq 'set' && $value eq '1' ? 'disabled' : 'ready');
		}

		return undef;
	}

	return undef;
}


# Leitet interne Helfer auf die zentrale FHEM-Gatewaygrenze.
sub _gateway {
	my ($hash) = @_;
	return gateway($hash);
}

# Plant den FHEM-Timer ueber die ausgelagerte Runtime-Schicht.
sub schedule_worker {
	my ($hash, $worker_delay, $worker_name) = @_;
	return AudioManager::Module::Runtime::schedule_worker($hash, $worker_delay, $worker_name);
}

# Fuehrt den FHEM-Timer-Callback ueber die ausgelagerte Runtime-Schicht aus.
sub worker {
	my ($hash, $defs, $scheduler) = @_;
	return AudioManager::Module::Runtime::worker($hash, $defs, $scheduler);
}
# Loest einen Zielausdruck in Abspiel- und erweiterte Schedulerziele je Backend auf.
sub resolve_targets {
	my ($hash, $specification) = @_;
	$specification = 'all' if !defined($specification) || $specification eq '';

	# Die @-Schreibweise ist semantisch identisch zum Doppelpunkt und bleibt in
	# FTUI-button-states erhalten, die Doppelpunkte selbst als Trenner behandeln.
	$specification = "$1:$2"
		if $specification =~ /^(backend|group|player|zone)@(.+)$/;
	my $gateway = _gateway($hash);
	my $configuration = AudioManager::Config::configuration(
		$hash, $gateway, AudioManager::Core->default_priorities,
	);

	# Logische Zonen werden vor der Backendzuordnung in konkrete globale Devicenamen expandiert.
	if ($specification =~ /^zone:(.+)$/) {
		my $zone = $1;
		return (undef, undef, "Unbekannte Audiozone: $zone") if !$configuration->{zones}{$zone};
		$specification = join(',', @{ $configuration->{zones}{$zone} });
	}

	my %backend_targets;
	my @play_targets;
	my @resource_targets;

	# all und backend:<id> werden direkt vom passenden Adapter aufgeloest.
	if ($specification eq 'all' || $specification =~ /^backend:/) {

		for my $backend_id (sort keys %{ $hash->{helper}{backends} }) {
			next if $specification =~ /^backend:(.+)$/ && $1 ne $backend_id
				&& !($1 eq 'sonos2mqtt' && ref($hash->{helper}{backends}{$backend_id}) =~ /Sonos2mqtt$/);
			my ($targets, $error) = $hash->{helper}{backends}{$backend_id}->resolve_target($specification);
			return (undef, undef, $error) if $error;
			$backend_targets{$backend_id} = $targets;
			push @play_targets, @$targets;
			push @resource_targets, @{ $hash->{helper}{backends}{$backend_id}->resource_targets($targets) };
		}

		return (undef, undef, "Kein Backend passt zu $specification") if !keys %backend_targets;
	} elsif ($specification =~ /^(?:player|group):(.+)$/) {
		my $anchor = $1;
		my $backend_id = $hash->{helper}{player_backend}{$anchor};
		return (undef, undef, "Unbekannter Audio-Player: $anchor") if !$backend_id;
		my ($targets, $error) = $hash->{helper}{backends}{$backend_id}->resolve_target($specification);
		return (undef, undef, $error) if $error;
		$backend_targets{$backend_id} = $targets;
		push @play_targets, @$targets;
		push @resource_targets, @{ $hash->{helper}{backends}{$backend_id}->resource_targets($targets) };
	} else {
		my $players = $specification;
		$players =~ s/^players://;

		# Explizite Player werden anhand der Define-Zuordnung auf mehrere Backends verteilt.
		for my $player (split /,/, $players) {
			my $backend_id = $hash->{helper}{player_backend}{$player};
			return (undef, undef, "Unbekannter Audio-Player: $player") if !$backend_id;
			push @{ $backend_targets{$backend_id} }, $player;
			push @play_targets, $player;
		}

		for my $backend_id (keys %backend_targets) {
			push @resource_targets,
				@{ $hash->{helper}{backends}{$backend_id}->resource_targets($backend_targets{$backend_id}) };
		}

	}

	my %seen;
	@resource_targets = grep { !$seen{$_}++ } @resource_targets;
	return (\%backend_targets, {
		play => \@play_targets,
		resources => \@resource_targets,
	}, undef);
}

# Nimmt einen validierten Audioauftrag an und startet TTS ohne kuenstliches Sammelfenster.
sub submit_request {
	my ($hash, $type, $options, $scheduler) = @_;
	return (undef, "Unbekannte Audioart: $type")
		if !defined($type) || $type !~ /^(?:alarm|speak|play|queue|stream)$/;
	my $gateway = _gateway($hash);
	return (undef, 'AudioManager ist deaktiviert')
		if $gateway->attr_value($hash->{NAME}, 'disable', 0);
	my $configuration = AudioManager::Config::configuration(
		$hash, $gateway, AudioManager::Core->default_priorities,
	);
	return (undef, "$type ist zur aktuellen Zeit durch quietHours gesperrt")
		if AudioManager::Config::quiet_hours_active($gateway, $configuration->{quiet_hours}, $type);
	my $target_specification = $options->{target} // 'all';
	my ($backend_targets, $resolved, $target_error) = resolve_targets(
		$hash, $target_specification,
	);
	return (undef, $target_error) if $target_error;
	my %payload = %$options;

	# all, Backend- und Gruppenziele spielen die vorhandenen nativen Gruppen als Einheit ab.
	$payload{target_mode} = 'existing_groups'
		if $target_specification eq 'all' || $target_specification =~ /^(?:backend|group)[:@]/;
	AudioManager::Module::Status::update_topology_warning($hash);
	$payload{volume} = $configuration->{volumes}{$type} if !defined $payload{volume};
	$payload{volume_policy} = $configuration->{policies}{$type}
		if !defined $payload{volume_policy};
	return (undef, 'volume muss zwischen 0 und 100 liegen')
		if ref($payload{volume}) || $payload{volume} !~ /^\d+$/ || $payload{volume} > 100;
	$payload{volume} = 0 + $payload{volume};
	delete @payload{qw(volume_min volume_max)};
	my @local_time = localtime($gateway->now);
	my $minute_of_day = 60 * $local_time[2] + $local_time[1];
	my $volume_limit = AudioManager::Config::volume_limit_at(
		$configuration->{volume_limits}, $type, $minute_of_day,
	);

	# Die Grenze klemmt auch explizite Requestwerte, bevor der Backendtreiber seine Policy anwendet.
	if ($volume_limit) {
		$payload{volume_min} = $volume_limit->{minimum};
		$payload{volume_max} = $volume_limit->{maximum};
		$payload{volume} = $payload{volume_min} if $payload{volume} < $payload{volume_min};
		$payload{volume} = $payload{volume_max} if $payload{volume} > $payload{volume_max};
	}

	$payload{mute_policy} = 'unmute' if !defined $payload{mute_policy};
	$payload{fadein} = 0 if !defined $payload{fadein};
	return (undef, 'volume_policy muss fixed, minimum oder keep sein')
		if $payload{volume_policy} !~ /^(?:fixed|minimum|keep)$/;
	return (undef, 'mute_policy muss unmute oder keep sein')
		if $payload{mute_policy} !~ /^(?:unmute|keep)$/;
	return (undef, 'fadein muss zwischen 0 und 86400 Sekunden liegen')
		if ref($payload{fadein}) || $payload{fadein} !~ /^\d+(?:[.]\d+)?$/
			|| $payload{fadein} > 86400;
	$payload{fadein} = 0 + $payload{fadein};
	return (undef, 'fadein kann nicht mit volume_policy=keep kombiniert werden')
		if $payload{fadein} > 0 && $payload{volume_policy} eq 'keep';

	# Eine URI-Liste ist ein vollstaendiger, vom AudioManager verwalteter Inhalt
	# der nativen Media-Queue und deshalb ausschliesslich fuer queue zulaessig.
	if (exists $payload{uris}) {
		return (undef, 'uris ist nur fuer queue zulaessig') if $type ne 'queue';
		return (undef, 'uris muss als nichtleere Liste uebergeben werden')
			if ref($payload{uris}) ne 'ARRAY' || !@{ $payload{uris} };

		for my $uri (@{ $payload{uris} }) {
			return (undef, 'Jeder Queue-Eintrag muss eine nichtleere URI sein')
				if !defined($uri) || ref($uri) || $uri !~ /\S/;
		}

		$payload{uris} = [ @{ $payload{uris} } ];
	}
	my $deferred = ($type eq 'speak' || ($type eq 'alarm' && defined($payload{text}))) ? 1 : 0;
	return (undef, "$type benoetigt Text") if $deferred && (!defined($payload{text}) || $payload{text} !~ /\S/);
	return (undef, 'play benoetigt eine URI')
		if $type eq 'play' && (!defined($payload{uri}) || $payload{uri} eq '');
	return (undef, 'alarm benoetigt URI oder Text')
		if $type eq 'alarm' && (!defined($payload{uri}) || $payload{uri} eq '')
			&& (!defined($payload{text}) || $payload{text} eq '');

	# Ein dauerhafter Stream besitzt genau eine fachliche Quelle: Favorit oder URI.
	if ($type eq 'stream') {
		my $has_favorite = defined($payload{favorite}) && $payload{favorite} ne '';
		my $has_uri = defined($payload{uri}) && $payload{uri} ne '';
		return (undef, 'stream benoetigt einen Favoritennamen oder eine URI')
			if !$has_favorite && !$has_uri;
		return (undef, 'stream akzeptiert nur einen Favoritennamen oder eine URI')
			if $has_favorite && $has_uri;
	}
	my $request = $hash->{helper}{core}->submit(
		type => $type,
		targets => $resolved->{resources},
		payload => \%payload,
		backend_targets => $backend_targets,
		play_targets => $resolved->{play},
		deferred => $deferred,
	);

	# Ein deduplizierter Text erzeugt weder TTS noch Backendarbeit, bleibt aber als Request sichtbar.
	if ($request->{state} eq 'deduplicated') {
		AudioManager::Module::Status::update_status($hash, $request);
		return ($request->{id}, undef);
	}

	# TTS-Auftraege werden sofort in die Renderer-Pipeline gestellt; ein freier
	# Provider beginnt noch im selben FHEM-Aufruf mit dem ersten Text.
	if ($deferred) {
		AudioManager::Module::TTS::enqueue($hash, $request, $scheduler);
	}

	AudioManager::Module::Status::update_status($hash, $request);
	_schedule($hash, $scheduler);
	return ($request->{id}, undef);
}

# Extrahiert benannte Audiooptionen am Anfang eines Set-Aufrufs, ohne freien Inhalt zu zerlegen.
sub extract_options {
	my ($arguments) = @_;
	my %options;

	# Nur eindeutig benannte fuehrende Optionen werden interpretiert; danach bleibt der Rest Inhalt.
	while (@$arguments && $arguments->[0] =~ /^(target|volume|fadein)=(.*)$/) {
		my ($name, $value) = ($1, $2);
		$options{$name} = $value;
		shift @$arguments;
	}

	return \%options;
}

# Erkennt eindeutig URL-foermige Inhalte, ohne Favoritennamen oder Ansagetext mit
# Doppelpunkten beziehungsweise Dateinamen versehentlich als URI zu behandeln.
sub content_mode {
	my ($content) = @_;
	return 'uri' if defined($content) && $content =~ m{^[a-z][a-z0-9+.-]*://\S+$}i;
	return 'text';
}

# Steuert eine zustandsbehaftete Mute-Phase und bewahrt den ersten Zustand jedes
# Players, damit wiederholte oder ueberlappende mute-on-Aufrufe ihn nicht ueberschreiben.
sub set_mute {
	my ($hash, $backend_targets, $value, $force) = @_;
	return 'mute muss on, off, true oder false sein'
		if !defined($value) || $value !~ /^(?:on|off|true|false)$/;
	my $mute_on = $value =~ /^(?:on|true)$/ ? 1 : 0;
	return 'force ist nur zusammen mit mute off zulaessig' if $mute_on && $force;
	my $snapshot = $hash->{helper}{mute_snapshot} ||= {};

	# Vor dem ersten Mute werden alle noch fehlenden Zustaende gelesen, ohne einen
	# teilweise aufgebauten Snapshot bei einem Lesefehler zu uebernehmen.
	if ($mute_on) {
		my %captured;

		for my $backend_id (sort keys %$backend_targets) {
			my $backend = $hash->{helper}{backends}{$backend_id};
			my @new_players = grep { !exists($snapshot->{$_}) } @{ $backend_targets->{$backend_id} };
			next if !@new_players;
			my $backend_snapshot = $backend->snapshot(\@new_players);

			for my $player (@new_players) {
				return "$backend_id: Mute-Zustand fuer $player konnte nicht gelesen werden"
					if !exists($backend_snapshot->{players}{$player}{mute});
				my $previous = $backend_snapshot->{players}{$player}{mute};
				$captured{$player} = defined($previous) && $previous =~ /^(?:1|on|true)$/i
					? 'true' : 'false';
			}

		}

		# Der Snapshot wird vor dem steuernden Befehl gesichert, damit auch ein
		# nachfolgender Backendfehler durch einen erneuten mute-off reparierbar bleibt.
		$snapshot->{$_} = $captured{$_} for keys %captured;

		for my $backend_id (sort keys %$backend_targets) {
			my $backend = $hash->{helper}{backends}{$backend_id};
			my $error = $backend->set_mute($backend_targets->{$backend_id}, 'on');
			return "$backend_id: $error" if $error;
		}

		return undef;
	}

	# force umgeht den Snapshot bewusst; ohne Force werden nur zuvor vom
	# AudioManager gemutete Player auf ihren individuellen Zustand zurueckgesetzt.
	for my $backend_id (sort keys %$backend_targets) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my @players = @{ $backend_targets->{$backend_id} };

		if ($force) {
			my $error = $backend->set_mute(\@players, 'off');
			return "$backend_id: $error" if $error;
			next;
		}

		my @restore_muted = grep { exists($snapshot->{$_}) && $snapshot->{$_} eq 'true' } @players;
		my @restore_unmuted = grep { exists($snapshot->{$_}) && $snapshot->{$_} eq 'false' } @players;
		my $error = $backend->set_mute(\@restore_muted, 'on') if @restore_muted;
		return "$backend_id: $error" if $error;
		$error = $backend->set_mute(\@restore_unmuted, 'off') if @restore_unmuted;
		return "$backend_id: $error" if $error;
	}

	# Erst nach vollstaendiger Wiederherstellung werden die betroffenen Eintraege
	# entfernt, damit ein fehlgeschlagener Aufruf gefahrlos wiederholt werden kann.
	for my $players (values %$backend_targets) {

		for my $player (@$players) {
			delete $snapshot->{$player};
		}

	}

	return undef;
}

# Liefert den juengsten fehlgeschlagenen Auftrag fuer einen erneuten physischen Stopp.
sub latest_failed_request {
	my ($core, $type) = @_;
	my @requests = @{ $core->requests };

	# Die rueckwaertige Suche begrenzt den Notstopp auf den fachlich letzten Fehler.
	for my $request (reverse @requests) {
		# Nur fehlgeschlagene Auftraege koennen nach einem terminalen Timeout weiterlaufen.
		next if ($request->{state} || '') ne 'failed';

		# Ein typbezogener Stopp darf keine andere Audioart beeinflussen.
		next if defined($type) && ($request->{type} || '') ne $type;
		return $request;
	}

	return undef;
}

# Stoppt bereits aufgeloeste Backendziele auch dann physisch, wenn kein
# nichtterminaler Schedulerauftrag mehr fuer den regulaeren Abbruch vorhanden ist.
sub stop_backend_targets {
	my ($hash, $backend_targets, $scheduler) = @_;
	my $request = {
		type => 'stop',
		payload => {},
		runtime => { backends => {} },
	};

	# Jeder Adapter erhaelt ausschliesslich seinen bereits validierten Zielanteil.
	for my $backend_id (sort keys %$backend_targets) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->stop($request, $backend_targets->{$backend_id});
		return "$backend_id: $error" if $error;
	}

	_schedule($hash, $scheduler);
	return undef;
}

# Verteilt die FHEM-Set-Kommandos auf Audioauftraege, Steuerung und Gruppenverwaltung.
sub set {
	my ($hash, $arguments, $scheduler) = @_;
	my @arguments = @$arguments;
	shift @arguments;
	my $command = shift @arguments;
	my $choices = 'alarm:textField-long group speak:textField-long play:textField '
		. 'stream:textField queue:noArg stop transport mute volume volumeStep';
	return "Unknown argument ?, choose one of $choices" if !defined $command;

	# Endliche und dauerhafte Audioquellen teilen dieselbe Ziel- und Lautstaerkesyntax.
	if ($command =~ /^(?:speak|play|alarm|stream|queue)$/) {
		my $options = extract_options(\@arguments);
		return 'volume muss zwischen 0 und 100 liegen'
			if defined($options->{volume}) && ($options->{volume} !~ /^\d+$/ || $options->{volume} > 100);
		return 'fadein muss zwischen 0 und 86400 Sekunden liegen'
			if defined($options->{fadein})
				&& ($options->{fadein} !~ /^\d+(?:[.]\d+)?$/ || $options->{fadein} > 86400);

		if ($command eq 'speak') {
			$options->{text} = join(' ', @arguments);
		} elsif ($command eq 'play') {
			$options->{uri} = join(' ', @arguments);
		} elsif ($command eq 'stream') {
			my $content = join(' ', @arguments);
			my $mode = content_mode($content);
			$options->{ $mode eq 'uri' ? 'uri' : 'favorite' } = $content;
		} elsif ($command eq 'alarm') {
			my $content = join(' ', @arguments);
			my $mode = content_mode($content);

			# Ein benannter Inhaltstyp uebersteuert die automatische Erkennung und
			# nimmt den Wert hinter dem Gleichheitszeichen als Anfang des Inhalts auf.
			if (@arguments && $arguments[0] =~ /^(text|uri)=(.*)$/) {
				($mode, my $first) = ($1, $2);
				shift @arguments;
				$content = join(' ', grep { $_ ne '' } ($first, @arguments));
			}

			$options->{$mode} = $content;
		}

		my (undef, $error) = submit_request($hash, $command, $options, $scheduler);
		return $error;
	}

	# stop akzeptiert all, eine Request-ID, eine Audioart oder ein verwaltetes Ziel.
	if ($command eq 'stop') {
		my $selector = shift(@arguments) // 'all';
		my $usage = 'Usage: set <name> stop [all|target=<ziel>|<requestId>|alarm|speak|play|queue|stream]';
		return $usage if @arguments;
		my $core = $hash->{helper}{core};

		# Zielstopps verwenden dieselbe Player-, Gruppen- und Zonensyntax wie Audioauftraege.
		if ($selector =~ /^target=(.*)$/) {
			my $specification = $1;
			return $usage if $specification eq '';
			my ($backend_targets, $resolved, $error) = resolve_targets(
				$hash, $specification,
			);
			return $error if $error;
			my $cancelled = $core->cancel_matching(targets => $resolved->{resources});

			# Ohne nichtterminalen Treffer erreicht ein idempotenter Zielstopp das Backend direkt.
			return undef if $cancelled;
			return stop_backend_targets($hash, $backend_targets, $scheduler);
		}

		if ($selector eq 'all') {
			my $failed = latest_failed_request($core);
			$core->cancel_matching;

			# Ein bereits terminaler Timeout benoetigt einen erneuten physischen Backendstopp.
			return AudioManager::Module::Runtime::core_stop($hash, $failed, $scheduler) if $failed;
			return undef;
		}
		my $request = $core->request($selector);

		# Ein idempotenter Stopp muss auch nach einem fehlgeschlagenen Schedulerlauf
		# noch den Player erreichen, solange die exakte Request-ID bekannt ist.
		if ($request) {
			return AudioManager::Module::Runtime::core_stop($hash, $request, $scheduler)
				if ($request->{state} || '') eq 'failed';
			return $core->cancel($selector);
		}

		if ($selector =~ /^(?:alarm|speak|play|queue|stream)$/) {
			my $failed = latest_failed_request($core, $selector);
			$core->cancel_matching(type => $selector);

			# Auch ein typbezogener Stopp wiederholt den letzten fehlgeschlagenen Backendstopp.
			return AudioManager::Module::Runtime::core_stop($hash, $failed, $scheduler) if $failed;
			return undef;
		}

		return "Unbekannter Stop-Selektor: $selector";
	}

	# Transport und Lautstaerkeschritte laufen ueber dieselbe verwaltete Zielgrenze
	# wie Audioauftraege, ohne einen neuen Schedulerauftrag anzulegen.
	if ($command eq 'transport' || $command eq 'volumeStep') {
		my $options = extract_options(\@arguments);
		my $value = shift @arguments;
		my $usage = $command eq 'transport'
			? 'Usage: set <name> transport [target=<ziel>] <play|pause|previous|next>'
			: 'Usage: set <name> volumeStep [target=<ziel>] <up|down>';
		return $usage if grep { $_ ne 'target' } keys %$options;
		return $usage if !defined($value) || @arguments;
		return $usage if $command eq 'transport'
			&& $value !~ /^(?:play|pause|previous|next)$/;
		return $usage if $command eq 'volumeStep' && $value !~ /^(?:up|down)$/;
		my ($backend_targets, undef, $error) = resolve_targets(
			$hash, $options->{target},
		);
		return $error if $error;

		# Jeder Adapter setzt den Befehl nur fuer seinen bereits validierten Zielanteil um.
		for my $backend_id (sort keys %$backend_targets) {
			my $backend = $hash->{helper}{backends}{$backend_id};
			my $set_error = $command eq 'transport'
				? $backend->transport_command($backend_targets->{$backend_id}, $value)
				: $backend->change_volume($backend_targets->{$backend_id}, $value);
			return "$backend_id: $set_error" if $set_error;
		}

		AudioManager::Module::Status::update_media_status($hash) if $command eq 'transport';
		return undef;
	}

	# Mute und Volume sind direkte Steuerbefehle, bleiben aber auf verwaltete Ziele begrenzt.
	if ($command eq 'mute' || $command eq 'volume') {
		my $options = extract_options(\@arguments);
		my $value = shift @arguments;
		my $force = 0;

		# Das Force-Flag ist absichtlich nur als letztes Wort nach dem Mute-Wert gueltig.
		if ($command eq 'mute' && @arguments && $arguments[0] eq 'force') {
			shift @arguments;
			$force = 1;
		}

		my $usage = $command eq 'mute'
			? 'Usage: set <name> mute [target=<ziel>] <on|off> [force]'
			: 'Usage: set <name> volume [target=<ziel>] <0..100>';
		return $usage if !defined($value) || @arguments;
		my ($backend_targets, undef, $error) = resolve_targets($hash, $options->{target});
		return $error if $error;
		return set_mute($hash, $backend_targets, $value, $force)
			if $command eq 'mute';

		for my $backend_id (sort keys %$backend_targets) {
			my $backend = $hash->{helper}{backends}{$backend_id};
			my $set_error = $backend->set_volume($backend_targets->{$backend_id}, $value);
			return "$backend_id: $set_error" if $set_error;
		}

		return undef;
	}

	# Gruppenoperationen duerfen niemals Player verschiedener Backends mischen.
	if ($command eq 'group') {
		my $operation = shift @arguments // '';
		@arguments = map { split /,/ } @arguments;
		my $anchor = $arguments[0];
		return 'Usage: set <name> group <create|add|remove|dissolve> ...' if !$anchor;
		my $backend_id = $hash->{helper}{player_backend}{$anchor};
		return "Unbekannter Audio-Player: $anchor" if !$backend_id;

		# Jeder weitere Player muss derselben nativen Gruppentechnologie angehoeren.
		for my $player (@arguments) {
			return "$player gehoert nicht zu Backend $backend_id"
				if !$hash->{helper}{player_backend}{$player}
				|| $hash->{helper}{player_backend}{$player} ne $backend_id;
		}

		return $hash->{helper}{backends}{$backend_id}->group_command($operation, @arguments);
	}

	return "Unknown argument $command, choose one of $choices";
}

# Liefert Topologie, Requests oder wirksame Prioritaeten als kanonisches JSON.
sub get {
	my ($hash, $arguments) = @_;
	my @arguments = @$arguments;
	shift @arguments;
	my $command = shift @arguments;
	return 'Unknown argument ?, choose one of topology:noArg requests:noArg priorities:noArg health:noArg'
		if !defined($command) || @arguments;
	my $json = JSON::PP->new->canonical(1)->allow_nonref(1);

	# Topologie bleibt backendweise getrennt und zeigt bei mehreren Technologien keine falsche Gruppe.
	if ($command eq 'topology') {
		return $json->encode({
			map { $_ => $hash->{helper}{backends}{$_}->topology } sort keys %{ $hash->{helper}{backends} }
		});
	}

	# Requestausgaben enthalten keine internen Backendobjekte, aber Status, Ziele und Zeitpunkte.
	if ($command eq 'requests') {
		return $json->encode([
			map {
				+{
					id => $_->{id}, type => $_->{type}, state => $_->{state},
					priority => $_->{priority}, targets => $_->{play_targets} || $_->{targets},
					createdAt => $_->{created_at}, reason => $_->{reason},
					coalescedInto => $_->{coalesced_into},
				}
			} @{ $hash->{helper}{core}->requests }
		]);
	}

	return $json->encode($hash->{helper}{core}{priorities}) if $command eq 'priorities';
	return $json->encode($hash->{helper}{supervisor}->report) if $command eq 'health';
	return "Unknown argument $command, choose one of topology:noArg requests:noArg priorities:noArg health:noArg";
}

# Reagiert sofort auf TTS- und Backendereignisse; Polling bleibt auf laufende
# Audioauftraege begrenzt, waehrend Health entprellt und ereignisbestaetigt arbeitet.
sub notify {
	my ($hash, $device, $scheduler, $notify_devices) = @_;
	return undef if !$device || !defined($device->{NAME});
	my @events = @{ main::deviceEvents($device, 1) || [] };
	my $gateway = _gateway($hash);

	# Nach INITIALIZED werden Notifygrenzen nochmals gegen alle geladenen Devices synchronisiert.
	if ($device->{NAME} eq 'global') {

		# Nach dem FHEM-Lifecycle werden spaeter geladene Bridgezuordnungen erneut automatisch erkannt.
		if (grep { /^(?:INITIALIZED|REREADCFG)$/ } @events) {
			my ($mapping) = AudioManager::Config::parse_backend_availability(
				$gateway->attr_value($hash->{NAME}, 'backendAvailability', ''),
			);
			$_->configure(availability => $mapping)
				for values %{ $hash->{helper}{backends} || {} };
			$notify_devices->($hash) if ref($notify_devices) eq 'CODE';
		}
	} else {
		my $backend_id = $hash->{helper}{player_backend}{ $device->{NAME} };

		# Nur das fuer diesen Player verantwortliche Backend darf dessen Healthsignal auswerten.
		$hash->{helper}{supervisor}->event($backend_id, $device->{NAME}, \@events)
			if $backend_id && $hash->{helper}{supervisor};

		# Ein Availability-Device darf von mehreren Backendinstanzen desselben Praefixes geteilt werden.
		for my $health_backend_id (@{ $hash->{helper}{health_device_backends}{ $device->{NAME} } || [] }) {
			next if defined($backend_id) && $health_backend_id eq $backend_id;
			$hash->{helper}{supervisor}->event($health_backend_id, $device->{NAME}, \@events)
				if $hash->{helper}{supervisor};
		}

		AudioManager::Module::TTS::event($hash, $device, $scheduler);
		my $topology_backends = $hash->{helper}{topology_device_backends}{ $device->{NAME} } || [];

		# Topologiewarnungen folgen auch fremden, Medienreadings nur verwalteten Playern.
		AudioManager::Module::Status::update_topology_warning($hash) if $backend_id || @$topology_backends;
		AudioManager::Module::Status::update_media_status($hash) if $backend_id;
	}

	_schedule($hash, $scheduler);
	return undef;
}

# Bietet FHEM-Perlcode eine sichere direkte API ohne fragile neu gequotete fhem()-Texte.
sub submit_api {
	my ($defs, $manager, $type, $options, $scheduler) = @_;
	my $hash = $defs->{$manager};
	return (undef, "AudioManager $manager existiert nicht")
		if !$hash || ($hash->{TYPE} || '') ne 'AudioManager';
	return (undef, 'Optionen muessen als Hash uebergeben werden') if ref($options) ne 'HASH';
	my (@answer, $ok);
	$ok = eval {
		@answer = submit_request($hash, $type, $options, $scheduler);
		1;
	};
	return (undef, $@ || 'Audioauftrag konnte nicht angenommen werden') if !$ok;
	return @answer;
}

# Ersetzt bestehende say-Helfer durch einen duennen, zentral verwalteten Kompatibilitaetsaufruf.
sub say_api {
	my ($defs, $manager, $text, $target, $scheduler) = @_;
	my @answer = submit_api($defs, $manager, 'speak', {
		text => $text,
		target => defined($target) ? $target : 'all',
	}, $scheduler);

	# Listenaufrufer erhalten den API-Vertrag; skalare Aliase zeigen nur echte Fehler an.
	return wantarray ? @answer : $answer[1];
}


1;
