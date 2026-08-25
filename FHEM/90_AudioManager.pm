# Copyright (c) 2026 Andreas Planer

##############################################
# Priorisiertes, backendneutrales Audiomanagement fuer FHEM
package main;

use strict;
use warnings;
use lib './lib';
use JSON::PP qw(encode_json);
use AudioManager::Core ();
use AudioManager::Backend ();
use AudioManager::Backend::Sonos2mqtt ();
use AudioManager::FHEMGateway ();
use AudioManager::Supervisor ();
use vars qw(%defs %attr $readingFnAttributes);

our $AUDIOMANAGER_VERSION = '0.6.4';
our $AUDIOMANAGER_WORKER_DELAY = 0.25;

my %DEFAULT_VOLUMES = (
	alarm => 60,
	speak => 25,
	play => 20,
	queue => 15,
	stream => 12,
);
my %DEFAULT_VOLUME_POLICIES = (
	alarm => 'minimum',
	speak => 'fixed',
	play => 'fixed',
	queue => 'fixed',
	stream => 'fixed',
);

# Vorwaertsdeklarationen halten FHEMs prototypisierte Callbacknamen auch bei
# gegenseitigen Scheduler- und TTS-Aufrufen bereits zur Compilezeit sichtbar.
sub AudioManager_schedule_worker($);
sub AudioManager_tts_next($);
sub AudioManager_tts_poll($);

# Liefert pro Instanz genau ein austauschbares FHEM-Gateway.
sub AudioManager_gateway($) {
	my ($hash) = @_;
	return $hash->{helper}{gateway} ||= AudioManager::FHEMGateway->new();
}

# Schreibt ein einzelnes Reading ueber die testbare Gatewaygrenze.
sub AudioManager_reading($$$;$) {
	my ($hash, $reading, $value, $trigger) = @_;
	return AudioManager_gateway($hash)->update_reading($hash, $reading, $value, $trigger // 1);
}

# Schreibt eine begrenzte einzeilige Meldung gemaess dem FHEM-verbose-Attribut.
sub AudioManager_log($$$) {
	my ($hash, $level, $message) = @_;
	my $verbose = AudioManager_gateway($hash)->attr_value(
		$hash->{NAME}, 'verbose', AudioManager_gateway($hash)->attr_value('global', 'verbose', 3),
	);
	return if $verbose !~ /^\d+$/ || $verbose < $level;
	$message = '' if !defined $message;
	$message =~ s/[\r\n]+/ /g;
	$message = substr($message, 0, 4096) . '... <truncated>' if length($message) > 4096;
	AudioManager_gateway($hash)->log($hash->{NAME}, $level, "AudioManager $hash->{NAME}: $message");
	return;
}

# Registriert Lebenszyklus, Benutzerbefehle, Readings und validierte Attribute.
sub AudioManager_Initialize($) {
	my ($hash) = @_;
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
		. $readingFnAttributes;
}

# Parst kommaseparierte name:value-Zahlen und fuehrt partielle Werte mit Defaults zusammen.
sub AudioManager_parse_numeric_map($$$$) {
	my ($value, $defaults, $minimum, $maximum) = @_;
	my %result = %$defaults;
	return (\%result, undef) if !defined($value) || $value eq '';

	# Jeder Eintrag muss genau eine bekannte Klasse und eine begrenzte Ganzzahl enthalten.
	for my $entry (split /,/, $value) {
		$entry =~ s/^\s+|\s+$//g;
		return (undef, 'Leerer Listeneintrag ist nicht erlaubt') if $entry eq '';
		my ($name, $number) = split /:/, $entry, 2;
		return (undef, "Ungueltiger Eintrag: $entry")
			if !defined($number) || !exists($defaults->{$name}) || $number !~ /^\d+$/;
		return (undef, "$name muss zwischen $minimum und $maximum liegen")
			if $number < $minimum || $number > $maximum;
		$result{$name} = 0 + $number;
	}

	return (\%result, undef);
}

# Parst die Lautstaerkepolitik pro Audioart und behaelt nicht genannte Defaults.
sub AudioManager_parse_volume_policies($) {
	my ($value) = @_;
	my %result = %DEFAULT_VOLUME_POLICIES;
	return (\%result, undef) if !defined($value) || $value eq '';

	# Nur die bewusst implementierten festen, minimalen und unveraenderten Pegel sind erlaubt.
	for my $entry (split /,/, $value) {
		$entry =~ s/^\s+|\s+$//g;
		my ($type, $policy) = split /:/, $entry, 2;
		return (undef, "Ungueltige Lautstaerkepolitik: $entry")
			if !defined($policy) || !exists($result{$type}) || $policy !~ /^(?:fixed|minimum|keep)$/;
		$result{$type} = $policy;
	}

	return (\%result, undef);
}

# Prueft eine Tagesminute gegen ein halboffenes Zeitfenster, das Mitternacht ueberschreiten darf.
sub AudioManager_time_range_match($$$) {
	my ($start, $end, $minute_of_day) = @_;
	return $start < $end
		? $minute_of_day >= $start && $minute_of_day < $end
		: $minute_of_day >= $start || $minute_of_day < $end;
}

# Parst statische oder zeitabhaengige Sicherheitsgrenzen je Audioart.
sub AudioManager_parse_volume_limits($) {
	my ($value) = @_;
	my %result;
	return (\%result, undef) if !defined($value) || $value eq '';
	my $type;

	# Ein Eintrag mit Audioart beginnt deren Regelblock; Folgefenster duerfen die Art auslassen.
	for my $entry (split /,/, $value, -1) {
		$entry =~ s/^\s+|\s+$//g;
		return (undef, 'Leerer Lautstaerkebegrenzungseintrag ist nicht erlaubt') if $entry eq '';
		my $specification = $entry;

		# Bekannte Namen vor dem ersten Doppelpunkt wechseln zur naechsten Audioart.
		if ($entry =~ /^([A-Za-z_][A-Za-z0-9_.-]*):(.*)$/) {
			my ($new_type, $new_specification) = ($1, $2);
			return (undef, "Unbekannte Audioart: $new_type")
				if !exists($DEFAULT_VOLUMES{$new_type});
			return (undef, "Audioart $new_type ist mehrfach angegeben")
				if exists($result{$new_type});
			$type = $new_type;
			$result{$type} = [];
			$specification = $new_specification;
		}

		return (undef, "Ungueltige Lautstaerkebegrenzung: $entry") if !defined $type;
		my ($start, $end, $minimum, $maximum, $all_day);

		# Eine reine Pegelspanne gilt ganztags; die laengere Form beginnt mit dem Zeitfenster.
		if ($specification =~ /^(\d+)-(\d+)$/) {
			($minimum, $maximum, $all_day) = ($1, $2, 1);
		} elsif ($specification =~ /^([01]?\d|2[0-3])(?::([0-5]\d))?-([01]?\d|2[0-3])(?::([0-5]\d))?:(\d+)-(\d+)$/) {
			$start = 60 * $1 + ($2 // 0);
			$end = 60 * $3 + ($4 // 0);
			($minimum, $maximum, $all_day) = ($5, $6, 0);
			return (undef, "Zeitfenster $specification fuer $type hat keine Dauer")
				if $start == $end;
		} else {
			return (undef, "Ungueltige Lautstaerkebegrenzung fuer $type: $specification");
		}

		return (undef, "Lautstaerkebereich fuer $type muss zwischen 0 und 100 liegen")
			if $minimum > 100 || $maximum > 100;
		return (undef, "Lautstaerkebereich fuer $type hat Minimum groesser als Maximum")
			if $minimum > $maximum;
		my $rule = {
			minimum => 0 + $minimum,
			maximum => 0 + $maximum,
			all_day => $all_day,
		};
		($rule->{start}, $rule->{end}) = ($start, $end) if !$all_day;

		# Ueberlappende Regeln waeren reihenfolgeabhaengig und werden deshalb abgelehnt.
		for my $existing (@{ $result{$type} }) {
			my $overlaps = $all_day || $existing->{all_day}
				|| AudioManager_time_range_match($existing->{start}, $existing->{end}, $start)
				|| AudioManager_time_range_match($start, $end, $existing->{start});
			return (undef, "Lautstaerkefenster fuer $type ueberlappen sich") if $overlaps;
		}

		push @{ $result{$type} }, $rule;
	}

	return (\%result, undef);
}

# Liefert die fuer Audioart und lokale Tagesminute wirksame Sicherheitsgrenze.
sub AudioManager_volume_limit_at($$$) {
	my ($limits, $type, $minute_of_day) = @_;
	return undef if !exists($limits->{$type});

	# Pro Audioart sind die Regeln ueberlappungsfrei, daher kann hoechstens eine passen.
	for my $rule (@{ $limits->{$type} }) {
		return $rule if $rule->{all_day}
			|| AudioManager_time_range_match($rule->{start}, $rule->{end}, $minute_of_day);
	}

	return undef;
}

# Parst eine Kommaliste, in der Eintraege mit Gleichheitszeichen eine neue Audioart beginnen.
sub AudioManager_parse_quiet_hours($) {
	my ($value) = @_;
	my %result;
	return (\%result, undef) if !defined($value) || $value eq '';
	my $type;

	# Zeitfenster ohne Gleichheitszeichen werden der zuletzt genannten Audioart zugeordnet.
	for my $entry (split /,/, $value, -1) {
		$entry =~ s/^\s+|\s+$//g;
		return (undef, 'Leerer Ruhezeiteneintrag ist nicht erlaubt') if $entry eq '';
		my $window = $entry;

		# Ein Gleichheitszeichen startet die Fensterliste einer neuen Audioart.
		if ($entry =~ /=/) {
			my ($new_type, $new_window, $remainder) = split /=/, $entry, 3;
			$new_type =~ s/^\s+|\s+$//g if defined $new_type;
			$new_window =~ s/^\s+|\s+$//g if defined $new_window;
			return (undef, "Ungueltiger Ruhezeiteneintrag: $entry")
				if defined($remainder)
				|| !defined($new_window)
				|| !exists($DEFAULT_VOLUMES{$new_type})
				|| $new_window eq '';
			return (undef, "Audioart $new_type ist mehrfach angegeben")
				if exists $result{$new_type};
			$type = $new_type;
			$result{$type} = [];
			$window = $new_window;
		}

		# Stunden duerfen ein- oder zweistellig sein; Minuten muessen zweistellig angegeben werden.
		return (undef, "Ungueltiger Ruhezeiteneintrag: $entry") if !defined $type;
		return (undef, "Ungueltiges Ruhefenster fuer $type: $window")
			if $window !~ /^([01]?\d|2[0-3])(?::([0-5]\d))?-([01]?\d|2[0-3])(?::([0-5]\d))?$/;
		my $start = 60 * $1 + ($2 // 0);
		my $end = 60 * $3 + ($4 // 0);
		return (undef, "Ruhefenster $window fuer $type hat keine Dauer") if $start == $end;
		push @{ $result{$type} }, [$start, $end];
	}

	return (\%result, undef);
}

# Prueft eine lokale Tagesminute gegen normale und ueber Mitternacht laufende Ruhefenster.
sub AudioManager_quiet_hours_match($$$) {
	my ($quiet_hours, $type, $minute_of_day) = @_;
	return 0 if !exists $quiet_hours->{$type};

	# Das Ende ist exklusiv, damit angrenzende Fenster keine unklare Grenzminute erzeugen.
	for my $window (@{ $quiet_hours->{$type} }) {
		my ($start, $end) = @$window;
		return 1 if $start < $end
			? $minute_of_day >= $start && $minute_of_day < $end
			: $minute_of_day >= $start || $minute_of_day < $end;
	}

	return 0;
}

# Leitet die aktuelle lokale FHEM-Zeit auf eine Tagesminute fuer die Ruhezeitenpruefung ab.
sub AudioManager_quiet_hours_active($$$) {
	my ($hash, $quiet_hours, $type) = @_;
	my @local_time = localtime(AudioManager_gateway($hash)->now);
	my $minute_of_day = 60 * $local_time[2] + $local_time[1];
	return AudioManager_quiet_hours_match($quiet_hours, $type, $minute_of_day);
}

# Parst benannte logische Zonen, die backenduebergreifend aus FHEM-Playernamen bestehen duerfen.
sub AudioManager_parse_zones($) {
	my ($value) = @_;
	my %zones;
	return (\%zones, undef) if !defined($value) || $value eq '';

	# Semikolon trennt Zonen, Komma trennt deren Player und bleibt damit eindeutig.
	for my $entry (split /;/, $value) {
		$entry =~ s/^\s+|\s+$//g;
		my ($name, $players) = split /=/, $entry, 2;
		return (undef, "Ungueltige Zone: $entry")
			if !defined($players) || $name !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
		my @players = grep { $_ ne '' } split /,/, $players;
		return (undef, "Zone $name enthaelt keine Player") if !@players;
		$zones{$name} = \@players;
	}

	return (\%zones, undef);
}

# Parst optionale MQTT-Praefixzuordnungen auf bereits vorhandene FHEM-Readings.
sub AudioManager_parse_backend_availability($) {
	my ($value) = @_;
	my %mapping;
	return (\%mapping, undef) if !defined($value) || $value eq '';

	# Jeder Praefix darf genau einmal auf Device und optionales Reading zeigen.
	for my $entry (split /,/, $value) {
		$entry =~ s/^\s+|\s+$//g;
		my ($prefix, $source) = split /=/, $entry, 2;
		return (undef, "Ungueltige Backend-Availability: $entry")
			if !defined($source) || $prefix !~ /^[A-Za-z0-9_.-]+$/;
		my ($device, $reading, $remainder) = split /:/, $source, 3;
		$reading = 'connected' if !defined($reading) || $reading eq '';
		return (undef, "Ungueltige Backend-Availability: $entry")
			if defined($remainder)
			|| $device !~ /^[A-Za-z0-9_.-]+$/
			|| $reading !~ /^[A-Za-z][A-Za-z0-9_.-]*$/;
		return (undef, "MQTT-Praefix $prefix ist mehrfach angegeben") if $mapping{$prefix};
		$mapping{$prefix} = { device => $device, reading => $reading };
	}

	return (\%mapping, undef);
}

# Liefert Attributwerte und ihre Defaults als bereits validierte Laufzeitstruktur.
sub AudioManager_configuration($) {
	my ($hash) = @_;
	my $gateway = AudioManager_gateway($hash);
	my ($priorities) = AudioManager_parse_numeric_map(
		$gateway->attr_value($hash->{NAME}, 'priorities', ''),
		AudioManager::Core->default_priorities, 0, 10_000,
	);
	my ($volumes) = AudioManager_parse_numeric_map(
		$gateway->attr_value($hash->{NAME}, 'defaultVolumes', ''),
		\%DEFAULT_VOLUMES, 0, 100,
	);
	my ($policies) = AudioManager_parse_volume_policies(
		$gateway->attr_value($hash->{NAME}, 'volumePolicies', ''),
	);
	my ($volume_limits) = AudioManager_parse_volume_limits(
		$gateway->attr_value($hash->{NAME}, 'volumeLimits', ''),
	);
	my ($quiet_hours) = AudioManager_parse_quiet_hours(
		$gateway->attr_value($hash->{NAME}, 'quietHours', ''),
	);
	my ($zones) = AudioManager_parse_zones($gateway->attr_value($hash->{NAME}, 'zones', ''));
	my ($availability) = AudioManager_parse_backend_availability(
		$gateway->attr_value($hash->{NAME}, 'backendAvailability', ''),
	);
	return {
		priorities => $priorities,
		volumes => $volumes,
		policies => $policies,
		volume_limits => $volume_limits,
		quiet_hours => $quiet_hours,
		zones => $zones,
		availability => $availability,
		dedupe_window => 0 + $gateway->attr_value($hash->{NAME}, 'speakDedupeWindow', 5),
		start_timeout => 0 + $gateway->attr_value($hash->{NAME}, 'startTimeout', 15),
		stop_grace => 0 + $gateway->attr_value($hash->{NAME}, 'stopGrace', 2),
		group_timeout => 0 + $gateway->attr_value($hash->{NAME}, 'groupTimeout', 30),
		health_debounce => 0 + $gateway->attr_value($hash->{NAME}, 'healthDebounce', 3),
		health_verify_timeout => 0 + $gateway->attr_value($hash->{NAME}, 'healthVerifyTimeout', 15),
		health_recovery_cooldown => 0 + $gateway->attr_value($hash->{NAME}, 'healthRecoveryCooldown', 60),
		health_probe_interval => 0 + $gateway->attr_value($hash->{NAME}, 'healthProbeInterval', 900),
		auto_leave => 0 + $gateway->attr_value($hash->{NAME}, 'autoLeave', 0),
	};
}

# Leitet einen backendneutralen Anzeigenamen aus dem aktiven Managerauftrag ab.
sub AudioManager_media_source($) {
	my ($request) = @_;
	my $payload = $request->{payload} || {};
	return $payload->{favorite} if defined($payload->{favorite}) && $payload->{favorite} ne '';
	return $payload->{uri} if defined($payload->{uri}) && $payload->{uri} ne '';
	return 'Queue' if ($request->{type} || '') eq 'queue';
	return $payload->{text} if defined($payload->{text}) && $payload->{text} ne '';
	return $request->{type} || 'none';
}

# Spiegelt die Medienreadings des hoechstpriorisierten aktiven Auftrags auf das
# Managerdevice und vermeidet unveraenderte Events bei jedem Worker-Tick.
sub AudioManager_update_media_status($;$) {
	my ($hash, $active_override) = @_;
	my $core = $hash->{helper}{core};
	return if !$core;
	my @active = $active_override ? @$active_override : sort {
		$b->{priority} <=> $a->{priority} || $a->{sequence} <=> $b->{sequence}
	} @{ $core->active_requests };
	my %media = (
		mediaRequest => 'none',
		mediaType => 'none',
		mediaPlayer => 'none',
		source => 'none',
		title => '',
		artist => '',
		album => '',
		albumArtUri => '',
		transportState => 'STOPPED',
		volume => '',
		mute => 'false',
	);

	# Bei mehreren disjunkten Ausgaben bleibt die fachlich wichtigste Anzeige eindeutig.
	if (@active) {
		my $request = $active[0];
		$media{mediaRequest} = $request->{id};
		$media{mediaType} = $request->{type};
		$media{source} = AudioManager_media_source($request);

		# Der erste beteiligte Backendadapter mit Medienstatus liefert die Anzeige.
		for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
			my $players = $request->{backend_targets}{$backend_id} || [];
			next if !@$players;
			my $backend_status = $hash->{helper}{backends}{$backend_id}->media_status(
				$request, $players,
			);
			next if ref($backend_status) ne 'HASH' || !keys %$backend_status;

			# Nur bekannte normalisierte Felder gelangen als stabile Managerreadings nach FHEM.
			for my $reading (qw(title artist album albumArtUri transportState volume mute)) {
				$media{$reading} = $backend_status->{$reading}
					if exists($backend_status->{$reading});
			}

			$media{mediaPlayer} = $backend_status->{player}
				if defined($backend_status->{player}) && $backend_status->{player} ne '';
			last;
		}

	}

	# Readings werden nur bei echten Wertwechseln aktualisiert, damit FTUI keine
	# viertelsekuendlichen identischen Ereignisse verarbeiten muss.
	for my $reading (qw(mediaRequest mediaType mediaPlayer source title artist album albumArtUri transportState volume mute)) {
		my $current = AudioManager_gateway($hash)->reading_value(
			$hash->{NAME}, $reading, undef,
		);
		my $value = defined($media{$reading}) ? $media{$reading} : '';
		next if defined($current) && $current eq $value;
		AudioManager_reading($hash, $reading, $value);
	}

	return;
}

# Aktualisiert die kompakte Statusoberflaeche nach jedem Schedulerzustandswechsel.
sub AudioManager_update_status($;$) {
	my ($hash, $changed_request) = @_;
	my $core = $hash->{helper}{core};
	return if !$core;
	my $counts = $core->counts;
	my @active = sort {
		$b->{priority} <=> $a->{priority} || $a->{sequence} <=> $b->{sequence}
	} @{ $core->active_requests };
	my $disabled = AudioManager_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	AudioManager_reading($hash, 'state', $disabled ? 'disabled' : 'ready');
	AudioManager_reading($hash, 'activeRequests', $counts->{active});
	AudioManager_reading($hash, 'pendingRequests', $counts->{preparing} + $counts->{queued});
	AudioManager_reading($hash, 'suspendedRequests', $counts->{suspended});
	AudioManager_reading($hash, 'ttsQueueLength', scalar @{ $hash->{helper}{tts_queue} || [] });
	AudioManager_reading($hash, 'currentRequest', join(',', map { $_->{id} } @active));
	AudioManager_reading($hash, 'currentType', join(',', map { $_->{type} } @active));
	AudioManager_reading($hash, 'currentTargets', join(',', map { @{ $_->{play_targets} || $_->{targets} } } @active));
	AudioManager_update_media_status($hash, \@active);

	# Der zuletzt geaenderte Auftrag bleibt mit Ergebnis und Fehlergrund nachvollziehbar.
	if ($changed_request) {
		AudioManager_reading($hash, 'lastRequest', $changed_request->{id});
		AudioManager_reading($hash, 'lastRequestType', $changed_request->{type});
		AudioManager_reading($hash, 'lastRequestState', $changed_request->{state});
		AudioManager_reading($hash, 'lastError', $changed_request->{reason} || 'none')
			if $changed_request->{state} eq 'failed';
		AudioManager_reading($hash, 'deduplicatedRequests',
			0 + ($hash->{helper}{deduplicated_requests} || 0));
	}

	return;
}

# Liefert die tatsaechlichen Abspielziele eines Requests fuer eine Backendinstanz.
sub AudioManager_backend_targets($$) {
	my ($request, $backend_id) = @_;
	return $request->{backend_targets}{$backend_id} || [];
}

# Sichert pro beruehrtem Backendbereich den externen Ausgangszustand genau einmal.
sub AudioManager_capture_baselines($$) {
	my ($hash, $request) = @_;

	# Disjunkte Backendbereiche erhalten getrennte Baselines und koennen parallel laufen.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $targets = AudioManager_backend_targets($request, $backend_id);
		my %covered;

		# Bereits gesicherte Ressourcen behalten ihren aeltesten externen Ausgangszustand.
		for my $baseline (@{ $hash->{helper}{baselines}{$backend_id} ||= [] }) {

			for my $resource (@{ $baseline->{snapshot}{scope} || [] }) {
				$covered{$resource} = 1;
			}

		}

		my @uncovered_targets;

		# Ein groesserer Fan-out sichert nur Gruppen, die noch keine aktive Baseline besitzen.
		for my $target (@$targets) {
			my $resources = $backend->resource_targets([$target]);
			next if grep { $covered{$_} } @$resources;
			push @uncovered_targets, $target;
			$covered{$_} = 1 for @$resources;
		}

		next if !@uncovered_targets;
		push @{ $hash->{helper}{baselines}{$backend_id} }, {
			snapshot => $backend->snapshot(\@uncovered_targets),
		};
	}

	return;
}

# Startet einen Schedulerauftrag auf allen beteiligten Backendinstanzen.
sub AudioManager_core_start($$) {
	my ($hash, $request) = @_;
	# Seiteneffektfreie Backendpruefungen verhindern Snapshots und Restores fuer
	# Auftraege, die beispielsweise wegen autoLeave=0 gar nicht starten duerfen.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->preflight_start(
			$request, AudioManager_backend_targets($request, $backend_id),
		);
		return "$backend_id: $error" if $error;
	}
	AudioManager_capture_baselines($hash, $request);

	my @started;

	# Ein backenduebergreifender Auftrag bleibt ein Elternrequest; jeder Adapter
	# erhaelt nur seinen lokalen Playeranteil und darf parallel beginnen.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->start($request, AudioManager_backend_targets($request, $backend_id));

		# Bereits gestartete Teilbackends werden bei einem spaeteren Fehler bestmoeglich gestoppt.
		if ($error) {

			for my $started_id (@started) {
				my $started_backend = $hash->{helper}{backends}{$started_id};
				$started_backend->stop($request, AudioManager_backend_targets($request, $started_id));
			}

			return "$backend_id: $error";
		}
		push @started, $backend_id;
	}

	AudioManager_schedule_worker($hash);
	return undef;
}

# Pausiert alle Backendanteile eines aktiven Auftrags vor einer hoeheren Quelle.
sub AudioManager_core_suspend($$$) {
	my ($hash, $request, undef) = @_;

	# Jeder Adapter sichert unmittelbar vor Pause seinen aktuellen Lautstaerke- und Quellenstand.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->suspend($request, AudioManager_backend_targets($request, $backend_id));
		return "$backend_id: $error" if $error;
	}

	return undef;
}

# Setzt alle Backendanteile eines pausierten Auftrags ueber deren Snapshots fort.
sub AudioManager_core_resume($$) {
	my ($hash, $request) = @_;

	# Backends koennen ihre Gruppierung asynchron wiederherstellen; der Worker fuehrt sie fort.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->resume($request);
		return "$backend_id: $error" if $error;
	}

	AudioManager_schedule_worker($hash);
	return undef;
}

# Stoppt alle Backendanteile eines abgebrochenen oder fehlgeschlagenen Auftrags.
sub AudioManager_core_stop($$) {
	my ($hash, $request) = @_;

	# Stop bleibt auf die tatsaechlichen Abspielziele begrenzt.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->stop($request, AudioManager_backend_targets($request, $backend_id));
		return "$backend_id: $error" if $error;
	}

	AudioManager_schedule_worker($hash);
	return undef;
}

# Erzeugt den Scheduler mit allen FHEM- und Backendseiteneffekten als Callbacks.
sub AudioManager_build_core($) {
	my ($hash) = @_;
	my $configuration = AudioManager_configuration($hash);
	return AudioManager::Core->new(
		clock => sub { return AudioManager_gateway($hash)->now },
		priorities => $configuration->{priorities},
		dedupe_window => $configuration->{dedupe_window},
		callbacks => {
			on_start => sub { return AudioManager_core_start($hash, $_[0]) },
			on_suspend => sub { return AudioManager_core_suspend($hash, $_[0], $_[1]) },
			on_resume => sub { return AudioManager_core_resume($hash, $_[0]) },
			on_complete => sub { return AudioManager_core_stop($hash, $_[0]) },
			on_stop => sub { return AudioManager_core_stop($hash, $_[0]) },
			on_change => sub {
				my ($request) = @_;
				++$hash->{helper}{deduplicated_requests} if $request->{state} eq 'deduplicated';
				AudioManager_update_status($hash, $request);
				AudioManager_schedule_worker($hash);
			},
		},
	);
}

# Parst versionierbare Backendbeschreibungen vom Format treiber[@instanz]=device,device.
sub AudioManager_parse_backend_definition($$) {
	my ($hash, $descriptors) = @_;
	my %backends;
	my %player_backend;
	my $gateway = AudioManager_gateway($hash);
	my $configuration = AudioManager_configuration($hash);

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
				AudioManager_log($hash, 1, "Backend $id ignoriert nicht vorhandenen Player $player");
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
sub AudioManager_set_notify_devices($;$) {
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
		: AudioManager_gateway($hash)->attr_value($hash->{NAME}, 'ttsDevice', '');
	$devices{$tts} = 1 if $tts ne '';
	return AudioManager_gateway($hash)->set_notify_devices($hash, join(',', sort keys %devices));
}

# Aktualisiert die sichtbare Warnung fuer tolerierte Abweichungen der nativen Gruppen.
sub AudioManager_update_topology_warning($) {
	my ($hash) = @_;
	my @warnings;

	# Jeder Adapter liefert nur tolerierte Topologieabweichungen innerhalb seiner Gruppen.
	for my $backend_id (sort keys %{ $hash->{helper}{backends} || {} }) {
		my $backend_warnings = eval {
			$hash->{helper}{backends}{$backend_id}->topology_warnings;
		};
		next if $@ || ref($backend_warnings) ne 'ARRAY';
		push @warnings, map { "$backend_id: $_" }
			grep { defined($_) && $_ ne '' } @$backend_warnings;
	}

	my $value = @warnings ? join('; ', @warnings) : 'none';
	my $current = AudioManager_gateway($hash)->reading_value(
		$hash->{NAME}, 'topologyWarning', undef,
	);
	return if defined($current) && $current eq $value;
	AudioManager_reading($hash, 'topologyWarning', $value);
	return;
}

# Spiegelt den backendneutralen Healthbericht kompakt und als Detail-JSON in Readings.
sub AudioManager_update_health($) {
	my ($hash) = @_;
	my $supervisor = $hash->{helper}{supervisor};
	return if !$supervisor;
	my $report = $supervisor->report;
	my $json = JSON::PP->new->canonical(1)->allow_nonref(1);
	my @recoveries = grep { defined($_) } map { $_->{lastRecovery} } values %$report;
	my @errors = map { $_ . ':' . $report->{$_}{lastError} }
		grep { ($report->{$_}{lastError} // 'none') ne 'none' } sort keys %$report;
	my $recovery_count = 0;
	my $log_states = $hash->{helper}{backend_health_log_states} ||= {};
	my $active_errors = $hash->{helper}{backend_health_errors} ||= {};

	# Stabile Healthwechsel erzeugen genau eine Warnung beziehungsweise Entwarnung.
	for my $backend_id (sort keys %$report) {
		my $backend_report = $report->{$backend_id};
		$recovery_count += $backend_report->{recoveryCount} || 0;
		my $status = $backend_report->{status} || 'unknown';
		my @offline = sort grep {
			($backend_report->{details}{players}{$_}{status} || '') eq 'unavailable'
		} keys %{ $backend_report->{details}{players} || {} };

		if ($status eq 'degraded') {
			my $summary = @offline ? 'Player offline: ' . join(',', @offline)
				: ($backend_report->{lastError} || 'none') ne 'none'
					? $backend_report->{lastError}
					: 'Backend beeintraechtigt: ' . ($backend_report->{reason} || 'unknown');

			# Gleiche Fehlersignaturen werden nicht bei jedem Healthtermin erneut geloggt.
			if (!defined($active_errors->{$backend_id}) || $active_errors->{$backend_id} ne $summary) {
				AudioManager_log($hash, 2, "Backend $backend_id: $summary");
			}

			$active_errors->{$backend_id} = $summary;
			$log_states->{$backend_id} = 'degraded';
		} elsif ($status eq 'healthy') {
			# Erst die bestaetigte Gesundmeldung loescht den aktuellen Fehlerzustand.
			if (($log_states->{$backend_id} || '') eq 'degraded') {
				AudioManager_log($hash, 3, "Backend $backend_id wieder erreichbar");
			}

			delete $active_errors->{$backend_id};
			$log_states->{$backend_id} = 'healthy';
		}
	}

	AudioManager_reading($hash, 'backendHealth', join(',', map {
		$_ . ':' . $report->{$_}{status}
	} sort keys %$report));
	AudioManager_reading($hash, 'backendHealthDetails', $json->encode($report));
	AudioManager_reading($hash, 'backendRecoveryCount', $recovery_count);
	AudioManager_reading($hash, 'lastBackendRecovery',
		@recoveries ? (sort { $b <=> $a } @recoveries)[0] : 'none');
	AudioManager_reading($hash, 'lastBackendHealthError', @errors ? join(',', @errors) : 'none');
	AudioManager_reading($hash, 'backendHealthError', keys(%$active_errors) ? join('; ', map {
		$_ . ': ' . $active_errors->{$_}
	} sort keys %$active_errors) : 'none');
	return;
}

# Erzeugt den generischen Supervisor und bindet nur Zeitquelle und Reading-Callback an FHEM.
sub AudioManager_build_supervisor($) {
	my ($hash) = @_;
	my $configuration = AudioManager_configuration($hash);
	return AudioManager::Supervisor->new(
		backends => $hash->{helper}{backends},
		clock => sub { return AudioManager_gateway($hash)->now },
		debounce => $configuration->{health_debounce},
		verify_timeout => $configuration->{health_verify_timeout},
		cooldown => $configuration->{health_recovery_cooldown},
		probe_interval => $configuration->{health_probe_interval},
		on_change => sub { AudioManager_update_health($hash) },
	);
}

# Definiert einen Manager mit einer oder mehreren expliziten Backendinstanzen.
sub AudioManager_Define($$) {
	my ($hash, $definition) = @_;
	my @parts = split /[ \t]+/, $definition;
	return 'Usage: define <name> AudioManager <backend>[@<id>]=<player>[,<player>...] [...]'
		if @parts < 3;
	my ($name, undef, @descriptors) = @parts;
	$hash->{helper} ||= {};

	# Bei defmod wird erst nach erfolgreicher neuer Validierung der alte Timerzustand verworfen.
	my ($backends, $player_backend, $error) = AudioManager_parse_backend_definition($hash, \@descriptors);
	return "AudioManager: $error" if $error;
	AudioManager_gateway($hash)->cancel_timer($hash, 'AudioManager_Worker');
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
	$hash->{helper}{core} = AudioManager_build_core($hash);
	$hash->{helper}{supervisor} = AudioManager_build_supervisor($hash);
	AudioManager_set_notify_devices($hash);
	AudioManager_reading($hash, 'version', $AUDIOMANAGER_VERSION, 0);
	AudioManager_reading($hash, 'backendCount', scalar keys %$backends, 0);
	AudioManager_reading($hash, 'playerCount', scalar keys %$player_backend, 0);
	AudioManager_reading($hash, 'lastError', 'none', 0);
	AudioManager_update_topology_warning($hash);
	AudioManager_update_status($hash);
	AudioManager_update_health($hash);
	AudioManager_schedule_worker($hash);
	AudioManager_log($hash, 2, "defined; version=$AUDIOMANAGER_VERSION; backends=" . join(',', sort keys %$backends));
	return undef;
}

# Entfernt Timer und stoppt alle vom Manager noch gehaltenen Auftraege.
sub AudioManager_Undef($$) {
	my ($hash, undef) = @_;
	AudioManager_gateway($hash)->cancel_timer($hash, 'AudioManager_Worker');
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
sub AudioManager_Attr(@) {
	my ($operation, $name, $attribute, @values) = @_;
	return undef if $operation ne 'set' && $operation ne 'del';
	my $value = join(' ', @values);
	my $hash = $defs{$name};

	# Prioritaeten sind partielle Overrides und wirken nur auf danach angenommene Auftraege.
	if ($attribute eq 'priorities') {
		my ($parsed, $error) = AudioManager_parse_numeric_map(
			$operation eq 'set' ? $value : '', AudioManager::Core->default_priorities, 0, 10_000,
		);
		return "priorities: $error" if $error;
		$hash->{helper}{core}->configure_priorities($parsed) if $hash && $hash->{helper}{core};
		return undef;
	}

	# Standardlautstaerken werden beim Eingang eines neuen Requests festgeschrieben.
	if ($attribute eq 'defaultVolumes') {
		my (undef, $error) = AudioManager_parse_numeric_map(
			$operation eq 'set' ? $value : '', \%DEFAULT_VOLUMES, 0, 100,
		);
		return $error ? "defaultVolumes: $error" : undef;
	}

	# Lautstaerkepolitiken sind auf die implementierten Strategien begrenzt.
	if ($attribute eq 'volumePolicies') {
		my (undef, $error) = AudioManager_parse_volume_policies($operation eq 'set' ? $value : '');
		return $error ? "volumePolicies: $error" : undef;
	}

	# Lautstaerkebegrenzungen sind unabhaengige Sicherheitsgrenzen fuer Start und Resume.
	if ($attribute eq 'volumeLimits') {
		my (undef, $error) = AudioManager_parse_volume_limits($operation eq 'set' ? $value : '');
		return $error ? "volumeLimits: $error" : undef;
	}

	# Ruhezeiten werden pro Audioart angegeben und blockieren nur neue Auftraege dieser Art.
	if ($attribute eq 'quietHours') {
		my (undef, $error) = AudioManager_parse_quiet_hours($operation eq 'set' ? $value : '');
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
			AudioManager_schedule_worker($hash);
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
		my ($zones, $error) = AudioManager_parse_zones($operation eq 'set' ? $value : '');
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
		my ($mapping, $error) = AudioManager_parse_backend_availability(
			$operation eq 'set' ? $value : '',
		);
		return "backendAvailability: $error" if $error;

		if ($hash) {

			for my $backend_id (sort keys %{ $hash->{helper}{backends} || {} }) {
				$hash->{helper}{backends}{$backend_id}->configure(availability => $mapping);
				$hash->{helper}{supervisor}->request_probe($backend_id, 'availability_changed')
					if $hash->{helper}{supervisor};
			}

			AudioManager_set_notify_devices($hash);
			AudioManager_schedule_worker($hash);
		}
		return undef;
	}

	# Ein TTS-Provider darf beim Laden noch spaeter definiert werden; Notify wird dennoch aktualisiert.
	if ($attribute eq 'ttsDevice') {
		return 'ttsDevice darf nicht leer sein' if $operation eq 'set' && $value eq '';
		AudioManager_set_notify_devices($hash, $operation eq 'set' ? $value : '') if $hash;
		return undef;
	}

	# disable stoppt aktive Ausgaben, verwirft Warteschlangen und aktualisiert den Zustand sofort.
	if ($attribute eq 'disable') {
		return 'disable muss 0 oder 1 sein' if $operation eq 'set' && $value !~ /^(?:0|1)$/;

		if ($hash && $hash->{helper}{core}) {
			$hash->{helper}{core}->cancel_matching if $operation eq 'set' && $value eq '1';
			AudioManager_reading($hash, 'state', $operation eq 'set' && $value eq '1' ? 'disabled' : 'ready');
		}

		return undef;
	}

	return undef;
}

# Loest einen Zielausdruck in Abspiel- und erweiterte Schedulerziele je Backend auf.
sub AudioManager_resolve_targets($$) {
	my ($hash, $specification) = @_;
	$specification = 'all' if !defined($specification) || $specification eq '';

	# Die @-Schreibweise ist semantisch identisch zum Doppelpunkt und bleibt in
	# FTUI-button-states erhalten, die Doppelpunkte selbst als Trenner behandeln.
	$specification = "$1:$2"
		if $specification =~ /^(backend|group|player|zone)@(.+)$/;
	my $configuration = AudioManager_configuration($hash);

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
sub AudioManager_submit_request($$$) {
	my ($hash, $type, $options) = @_;
	return (undef, "Unbekannte Audioart: $type")
		if !defined($type) || $type !~ /^(?:alarm|speak|play|queue|stream)$/;
	return (undef, 'AudioManager ist deaktiviert')
		if AudioManager_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	my $configuration = AudioManager_configuration($hash);
	return (undef, "$type ist zur aktuellen Zeit durch quietHours gesperrt")
		if AudioManager_quiet_hours_active($hash, $configuration->{quiet_hours}, $type);
	my $target_specification = $options->{target} // 'all';
	my ($backend_targets, $resolved, $target_error) = AudioManager_resolve_targets(
		$hash, $target_specification,
	);
	return (undef, $target_error) if $target_error;
	my %payload = %$options;

	# all, Backend- und Gruppenziele spielen die vorhandenen nativen Gruppen als Einheit ab.
	$payload{target_mode} = 'existing_groups'
		if $target_specification eq 'all' || $target_specification =~ /^(?:backend|group)[:@]/;
	AudioManager_update_topology_warning($hash);
	$payload{volume} = $configuration->{volumes}{$type} if !defined $payload{volume};
	$payload{volume_policy} = $configuration->{policies}{$type}
		if !defined $payload{volume_policy};
	return (undef, 'volume muss zwischen 0 und 100 liegen')
		if ref($payload{volume}) || $payload{volume} !~ /^\d+$/ || $payload{volume} > 100;
	$payload{volume} = 0 + $payload{volume};
	delete @payload{qw(volume_min volume_max)};
	my @local_time = localtime(AudioManager_gateway($hash)->now);
	my $minute_of_day = 60 * $local_time[2] + $local_time[1];
	my $volume_limit = AudioManager_volume_limit_at(
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
		AudioManager_update_status($hash, $request);
		return ($request->{id}, undef);
	}

	# TTS-Auftraege werden sofort in die Renderer-Pipeline gestellt; ein freier
	# Provider beginnt noch im selben FHEM-Aufruf mit dem ersten Text.
	if ($deferred) {
		push @{ $hash->{helper}{tts_queue} }, $request->{id};
		AudioManager_tts_next($hash);
	}

	AudioManager_update_status($hash, $request);
	AudioManager_schedule_worker($hash);
	return ($request->{id}, undef);
}

# Startet den naechsten TTS-Rendererauftrag sofort, sofern der Provider frei ist.
sub AudioManager_tts_next($) {
	my ($hash) = @_;
	return if $hash->{helper}{tts_current};
	my $core = $hash->{helper}{core};
	my $id;

	# Abgebrochene oder anderweitig terminale Eintraege werden beim Entnehmen uebersprungen.
	while (@{ $hash->{helper}{tts_queue} || [] }) {
		my $candidate = shift @{ $hash->{helper}{tts_queue} };
		my $request = $core->request($candidate);
		next if !$request || $request->{state} ne 'preparing';
		$id = $candidate;
		last;
	}

	return if !$id;
	my $tts_device = AudioManager_gateway($hash)->attr_value($hash->{NAME}, 'ttsDevice', '');

	# Ohne expliziten Provider wird der Auftrag sichtbar beendet statt in der Queue zu haengen.
	my $tts_hash = $tts_device ne '' ? AudioManager_gateway($hash)->device($tts_device) : undef;
	if (!$tts_hash || ($tts_hash->{TYPE} || '') ne 'Text2Speech') {
		$core->fail($id, 'ttsDevice fehlt oder existiert nicht');
		return AudioManager_tts_next($hash);
	}

	my $request = $core->request($id);
	my $gateway = AudioManager_gateway($hash);
	my $now = $gateway->now;
	$hash->{helper}{tts_current} = {
		id => $id,
		device => $tts_device,
		started_at => $now,
		previous_uri => $gateway->reading_value($tts_device, 'httpName', ''),
		previous_file => $gateway->reading_value($tts_device, 'lastFilename', ''),
		seen_busy => 0,
		seen_completed => 0,
		seen_output_event => 0,
	};
	my $error = $gateway->set_command($tts_device, 'tts', $request->{payload}{text});

	# Ein synchroner Text2Speech-Fehler gibt den Renderer sofort fuer den naechsten Text frei.
	if ($error) {
		delete $hash->{helper}{tts_current};
		$core->fail($id, "TTS-Erzeugung fehlgeschlagen: $error");
		return AudioManager_tts_next($hash);
	}

	# Ein synchron gesetztes playing=1 wird direkt erfasst. Dadurch reicht das
	# spaetere playing=0-Ereignis auch bei einer unveraenderten Cache-URI als Beleg.
	AudioManager_tts_poll($hash);
	AudioManager_update_status($hash, $request);
	AudioManager_schedule_worker($hash);
	return;
}

# Korreliert TTS-Notify-Ereignisse mit dem aktuell erzeugten Einzeltext. Kurze
# playing-Wechsel gehen dadurch nicht mehr zwischen zwei Worker-Ticks verloren.
sub AudioManager_tts_event($$) {
	my ($hash, $device) = @_;
	my $current = $hash->{helper}{tts_current} or return;
	return if !$device || ($device->{NAME} || '') ne $current->{device};
	my @events = @{ deviceEvents($device, 1) || [] };
	my $relevant = 0;

	# Busy-, Abschluss- und Ausgabeevents liefern gemeinsam einen belastbaren
	# Nachweis, dass httpName wirklich zum gerade angeforderten Text gehoert.
	for my $event (@events) {
		if ($event =~ /^playing:\s*(-?\d+(?:[.]\d+)?)/) {
			$current->{seen_busy} = 1 if $1 > 0;
			$current->{seen_completed} = 1 if $1 <= 0 && $current->{seen_busy};
			$relevant = 1;
		} elsif ($event =~ /^(?:httpName|lastFilename):/) {
			$current->{seen_output_event} = 1;
			$relevant = 1;
		}
	}

	# Das fertige TTS-Ergebnis wird noch im Notify-Aufruf an den Scheduler gegeben.
	AudioManager_tts_poll($hash) if $relevant;
	return;
}

# Prueft den Text2Speech-Provider auf eine fertige URI und gibt den Renderer
# direkt danach fuer den naechsten Einzeltext frei.
sub AudioManager_tts_poll($) {
	my ($hash) = @_;
	my $current = $hash->{helper}{tts_current} or return;
	my $core = $hash->{helper}{core};
	my $request = $core->request($current->{id});

	# Abgebrochene Auftraege duerfen ein spaeteres Renderergebnis nicht mehr abspielen.
	if (!$request || $request->{state} ne 'preparing') {
		delete $hash->{helper}{tts_current};
		return AudioManager_tts_next($hash);
	}

	my $gateway = AudioManager_gateway($hash);
	my $playing = 0 + $gateway->reading_value($current->{device}, 'playing', 0);
	$current->{seen_busy} = 1 if $playing > 0;
	$current->{seen_completed} = 1 if $playing <= 0 && $current->{seen_busy};
	my $uri = $gateway->reading_value($current->{device}, 'httpName', '');
	my $file = $gateway->reading_value($current->{device}, 'lastFilename', '');
	my $age = $gateway->now - $current->{started_at};
	my $changed = $uri ne '' && ($uri ne $current->{previous_uri} || $file ne $current->{previous_file});
	my $correlated = $changed || $current->{seen_output_event} || $current->{seen_completed};
	my $ready = $uri ne '' && $playing <= 0
		&& ($correlated || $age >= 0.5);

	# Eine fertige URI wird atomar an den Scheduler uebergeben; danach darf der
	# Provider bereits den naechsten Text erzeugen, waehrend dieser Clip spielt.
	if ($ready) {
		delete $hash->{helper}{tts_current};
		my $duration = 0 + $gateway->reading_value($current->{device}, 'duration', 0);
		my $error = $core->ready(
			$current->{id},
			uri => $uri,
			tts_duration => $duration,
		);
		$core->fail($current->{id}, $error) if $error;
		AudioManager_tts_next($hash);
		return;
	}

	my $timeout = AudioManager_configuration($hash)->{start_timeout};

	# Auch ein nicht reagierender TTS-Provider darf die Sprachhierarchie nicht dauerhaft blockieren.
	if ($age > $timeout) {
		delete $hash->{helper}{tts_current};
		$core->fail($current->{id}, 'Zeitueberschreitung bei der TTS-Erzeugung');
		AudioManager_tts_next($hash);
	}

	return;
}

# Fuehrt alle asynchronen Backendphasen fort und erkennt Start sowie Ende endlicher Clips.
sub AudioManager_poll_requests($) {
	my ($hash) = @_;
	my $core = $hash->{helper}{core};
	my $configuration = AudioManager_configuration($hash);

	# Jeder aktive Elternrequest wird ueber alle beteiligten Backendanteile beobachtet.
	for my $request (@{ $core->active_requests }) {
		my $progress_error;

		for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
			my $backend = $hash->{helper}{backends}{$backend_id};
			my $error = $backend->progress($request);
			$progress_error = "$backend_id: $error" if $error;
		}

		if ($progress_error) {
			$core->fail($request->{id}, $progress_error);
			next;
		}
		next if $request->{type} eq 'stream' || $request->{type} eq 'queue';
		my ($all_seen, $any_playing) = (1, 0);

		# Ein backenduebergreifender Clip endet erst, wenn jeder Teil mindestens
		# einmal lief und anschliessend kein Teil mehr aktiv ist.
		for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
			my $backend = $hash->{helper}{backends}{$backend_id};
			my $targets = AudioManager_backend_targets($request, $backend_id);
			my $playing = $backend->is_playing($request, $targets);
			# Erst eine vom Backend bestaetigte Wiedergabe startet die fachliche Clipdauer.
			if ($playing) {
				$request->{runtime}{seen_playing}{$backend_id} = 1;
				$request->{runtime}{playback_confirmed_at}{$backend_id}
					//= AudioManager_gateway($hash)->now;
			}
			$all_seen = 0 if !$request->{runtime}{seen_playing}{$backend_id};
			$any_playing = 1 if $playing;
		}

		my $now = AudioManager_gateway($hash)->now;
		my @started_at = map {
			$request->{runtime}{backends}{$_}{playback_started_at}
		} grep {
			defined $request->{runtime}{backends}{$_}{playback_started_at}
		} keys %{ $request->{backend_targets} || {} };
		next if !@started_at;
		my $oldest_start = (sort { $a <=> $b } @started_at)[0];
		my @confirmed_at = values %{ $request->{runtime}{playback_confirmed_at} || {} };
		my $latest_confirmation = @confirmed_at
			? (sort { $b <=> $a } @confirmed_at)[0]
			: undef;
		my $tts_duration = 0 + ($request->{payload}{tts_duration} || 0);

		# Die Renderer-Dauer zaehlt erst ab der letzten Backendbestaetigung. Dadurch
		# stoppt eine kurze TTS keine noch nicht angelaufene, verzoegerte Sonos-Wiedergabe.
		if ($tts_duration > 0
			&& $request->{type} =~ /^(?:speak|alarm)$/
			&& $all_seen
			&& defined($latest_confirmation)
			&& $now - $latest_confirmation >= $tts_duration) {
			$request->{runtime}{playback_confirmation} = 'tts_duration';
			$core->complete($request->{id});
			next;
		}

		# Innerhalb der bekannten Clipdauer bleibt ein bestaetigter Transport aktiv.
		if ($any_playing) {
			$request->{runtime}{last_playing_at} = $now;
			next;
		}

		# Ein nie bestaetigter Start wird als Fehler sichtbar und gibt niedrigere Quellen frei.
		if (!$all_seen && $now - $oldest_start > $configuration->{start_timeout}) {
			$core->fail($request->{id}, 'Wiedergabestart wurde nicht bestaetigt');
			next;
		}

		# Kurze STOPPED-Events zwischen Transportwechseln werden durch stopGrace abgefedert.
		if ($all_seen && $now - ($request->{runtime}{last_playing_at} || $now) >= $configuration->{stop_grace}) {
			$core->complete($request->{id});
		}

	}

	return;
}

# Beginnt nach Freigabe des letzten Managerauftrags die Wiederherstellung externer Quellen.
sub AudioManager_reconcile_baselines($) {
	my ($hash) = @_;
	my $core = $hash->{helper}{core};

	# Jede disjunkte Baseline wird erst freigegeben, wenn keiner ihrer Player mehr belegt ist.
	for my $backend_id (sort keys %{ $hash->{helper}{baselines} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my @remaining;

		for my $baseline (@{ $hash->{helper}{baselines}{$backend_id} || [] }) {
			my $owned = grep { $core->target_is_owned($_) } @{ $baseline->{snapshot}{scope} || [] };

			if ($owned || $baseline->{restoring}) {
				push @remaining, $baseline;
				next;
			}

			my $restore_request = $backend->restore($baseline->{snapshot});

			if (!ref($restore_request)) {
				AudioManager_reading($hash, 'lastError', "$backend_id: $restore_request");
				next;
			}

			$baseline->{restoring} = 1;
			push @{ $hash->{helper}{restore_jobs} }, {
				backend_id => $backend_id,
				request => $restore_request,
				baseline => $baseline,
			};
			push @remaining, $baseline;
		}

		$hash->{helper}{baselines}{$backend_id} = \@remaining;
	}

	return;
}

# Fuehrt finale Baseline-Restores bis zur bestaetigten Topologie und Quelle fort.
sub AudioManager_poll_restores($) {
	my ($hash) = @_;
	my @remaining;

	# Jeder Restorejob verwendet denselben nichtblockierenden Backendautomaten wie Resume.
	for my $job (@{ $hash->{helper}{restore_jobs} || [] }) {
		my $backend = $hash->{helper}{backends}{ $job->{backend_id} };
		my $error = $backend->progress($job->{request});
		my $phase = $job->{request}{runtime}{backends}{ $job->{backend_id} }{phase} || '';

		if ($error) {
			AudioManager_reading($hash, 'lastError', "$job->{backend_id}: $error");
		} elsif ($phase eq 'restored') {
			my $baselines = $hash->{helper}{baselines}{ $job->{backend_id} } || [];
			$hash->{helper}{baselines}{ $job->{backend_id} } = [
				grep { $_ != $job->{baseline} } @$baselines
			];
		} else {
			push @remaining, $job;
		}
	}

	$hash->{helper}{restore_jobs} = \@remaining;
	return;
}

# Meldet Audioarbeit, die weiterhin den kurzen Pollingtakt benoetigt.
sub AudioManager_has_audio_work($) {
	my ($hash) = @_;
	return 1 if $hash->{helper}{tts_current};
	return 1 if @{ $hash->{helper}{tts_queue} || [] };
	return 1 if @{ $hash->{helper}{core}->active_requests };
	return 1 if @{ $hash->{helper}{restore_jobs} || [] };
	return 0;
}

# Meldet Audio- oder Supervisorarbeit mit geplantem Fortschritt.
sub AudioManager_has_work($) {
	my ($hash) = @_;
	return 1 if AudioManager_has_audio_work($hash);
	return 1 if $hash->{helper}{supervisor} && $hash->{helper}{supervisor}->has_work;
	return 0;
}

# Plant den Worker fuer Audio kurz getaktet, fuer Health dagegen exakt event- und fristgesteuert.
sub AudioManager_schedule_worker($) {
	my ($hash) = @_;
	return if !AudioManager_has_work($hash);
	my $gateway = AudioManager_gateway($hash);
	my $delay = AudioManager_has_audio_work($hash) ? $AUDIOMANAGER_WORKER_DELAY
		: $hash->{helper}{supervisor}->next_delay;
	return if !defined $delay;
	my $due_at = $gateway->now + $delay;

	# Ein bereits frueher geplanter Tick bleibt bestehen; nur dringlichere Events ziehen ihn vor.
	if ($hash->{helper}{worker_scheduled}) {
		return if defined($hash->{helper}{worker_at}) && $hash->{helper}{worker_at} <= $due_at;
		$gateway->cancel_timer($hash, 'AudioManager_Worker');
	}

	$hash->{helper}{worker_scheduled} = 1;
	$hash->{helper}{worker_at} = $due_at;
	$gateway->schedule($delay, $hash, 'AudioManager_Worker');
	return;
}

# Verarbeitet pro Tick Audiofortschritt sowie genau faellige Healthpruefungen.
sub AudioManager_Worker($) {
	my ($hash) = @_;
	delete $hash->{helper}{worker_scheduled};
	delete $hash->{helper}{worker_at};
	return if !defined($defs{ $hash->{NAME} }) || $defs{ $hash->{NAME} } != $hash;
	$hash->{helper}{supervisor}->tick if $hash->{helper}{supervisor};
	AudioManager_tts_poll($hash);
	AudioManager_poll_requests($hash);
	AudioManager_reconcile_baselines($hash);
	AudioManager_poll_restores($hash);
	AudioManager_update_status($hash);
	AudioManager_schedule_worker($hash);
	return;
}

# Extrahiert benannte Audiooptionen am Anfang eines Set-Aufrufs, ohne freien Inhalt zu zerlegen.
sub AudioManager_extract_options($) {
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
sub AudioManager_content_mode($) {
	my ($content) = @_;
	return 'uri' if defined($content) && $content =~ m{^[a-z][a-z0-9+.-]*://\S+$}i;
	return 'text';
}

# Steuert eine zustandsbehaftete Mute-Phase und bewahrt den ersten Zustand jedes
# Players, damit wiederholte oder ueberlappende mute-on-Aufrufe ihn nicht ueberschreiben.
sub AudioManager_set_mute($$$$) {
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
sub AudioManager_latest_failed_request($;$) {
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
sub AudioManager_stop_backend_targets($$) {
	my ($hash, $backend_targets) = @_;
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

	AudioManager_schedule_worker($hash);
	return undef;
}

# Verteilt die FHEM-Set-Kommandos auf Audioauftraege, Steuerung und Gruppenverwaltung.
sub AudioManager_Set($@) {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	my $choices = 'alarm:textField-long group speak:textField-long play:textField '
		. 'stream:textField queue:noArg stop transport mute volume volumeStep';
	return "Unknown argument ?, choose one of $choices" if !defined $command;

	# Endliche und dauerhafte Audioquellen teilen dieselbe Ziel- und Lautstaerkesyntax.
	if ($command =~ /^(?:speak|play|alarm|stream|queue)$/) {
		my $options = AudioManager_extract_options(\@arguments);
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
			my $mode = AudioManager_content_mode($content);
			$options->{ $mode eq 'uri' ? 'uri' : 'favorite' } = $content;
		} elsif ($command eq 'alarm') {
			my $content = join(' ', @arguments);
			my $mode = AudioManager_content_mode($content);

			# Ein benannter Inhaltstyp uebersteuert die automatische Erkennung und
			# nimmt den Wert hinter dem Gleichheitszeichen als Anfang des Inhalts auf.
			if (@arguments && $arguments[0] =~ /^(text|uri)=(.*)$/) {
				($mode, my $first) = ($1, $2);
				shift @arguments;
				$content = join(' ', grep { $_ ne '' } ($first, @arguments));
			}

			$options->{$mode} = $content;
		}

		my (undef, $error) = AudioManager_submit_request($hash, $command, $options);
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
			my ($backend_targets, $resolved, $error) = AudioManager_resolve_targets(
				$hash, $specification,
			);
			return $error if $error;
			my $cancelled = $core->cancel_matching(targets => $resolved->{resources});

			# Ohne nichtterminalen Treffer erreicht ein idempotenter Zielstopp das Backend direkt.
			return undef if $cancelled;
			return AudioManager_stop_backend_targets($hash, $backend_targets);
		}

		if ($selector eq 'all') {
			my $failed = AudioManager_latest_failed_request($core);
			$core->cancel_matching;

			# Ein bereits terminaler Timeout benoetigt einen erneuten physischen Backendstopp.
			return AudioManager_core_stop($hash, $failed) if $failed;
			return undef;
		}
		my $request = $core->request($selector);

		# Ein idempotenter Stopp muss auch nach einem fehlgeschlagenen Schedulerlauf
		# noch den Player erreichen, solange die exakte Request-ID bekannt ist.
		if ($request) {
			return AudioManager_core_stop($hash, $request) if ($request->{state} || '') eq 'failed';
			return $core->cancel($selector);
		}

		if ($selector =~ /^(?:alarm|speak|play|queue|stream)$/) {
			my $failed = AudioManager_latest_failed_request($core, $selector);
			$core->cancel_matching(type => $selector);

			# Auch ein typbezogener Stopp wiederholt den letzten fehlgeschlagenen Backendstopp.
			return AudioManager_core_stop($hash, $failed) if $failed;
			return undef;
		}

		return "Unbekannter Stop-Selektor: $selector";
	}

	# Transport und Lautstaerkeschritte laufen ueber dieselbe verwaltete Zielgrenze
	# wie Audioauftraege, ohne einen neuen Schedulerauftrag anzulegen.
	if ($command eq 'transport' || $command eq 'volumeStep') {
		my $options = AudioManager_extract_options(\@arguments);
		my $value = shift @arguments;
		my $usage = $command eq 'transport'
			? 'Usage: set <name> transport [target=<ziel>] <play|pause|previous|next>'
			: 'Usage: set <name> volumeStep [target=<ziel>] <up|down>';
		return $usage if grep { $_ ne 'target' } keys %$options;
		return $usage if !defined($value) || @arguments;
		return $usage if $command eq 'transport'
			&& $value !~ /^(?:play|pause|previous|next)$/;
		return $usage if $command eq 'volumeStep' && $value !~ /^(?:up|down)$/;
		my ($backend_targets, undef, $error) = AudioManager_resolve_targets(
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

		AudioManager_update_media_status($hash) if $command eq 'transport';
		return undef;
	}

	# Mute und Volume sind direkte Steuerbefehle, bleiben aber auf verwaltete Ziele begrenzt.
	if ($command eq 'mute' || $command eq 'volume') {
		my $options = AudioManager_extract_options(\@arguments);
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
		my ($backend_targets, undef, $error) = AudioManager_resolve_targets($hash, $options->{target});
		return $error if $error;
		return AudioManager_set_mute($hash, $backend_targets, $value, $force)
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
sub AudioManager_Get($@) {
	my ($hash, @arguments) = @_;
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
sub AudioManager_Notify($$) {
	my ($hash, $device) = @_;
	return undef if !$device || !defined($device->{NAME});
	my @events = @{ deviceEvents($device, 1) || [] };

	# Nach INITIALIZED werden Notifygrenzen nochmals gegen alle geladenen Devices synchronisiert.
	if ($device->{NAME} eq 'global') {

		# Nach dem FHEM-Lifecycle werden spaeter geladene Bridgezuordnungen erneut automatisch erkannt.
		if (grep { /^(?:INITIALIZED|REREADCFG)$/ } @events) {
			my ($mapping) = AudioManager_parse_backend_availability(
				AudioManager_gateway($hash)->attr_value($hash->{NAME}, 'backendAvailability', ''),
			);
			$_->configure(availability => $mapping)
				for values %{ $hash->{helper}{backends} || {} };
			AudioManager_set_notify_devices($hash);
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

		AudioManager_tts_event($hash, $device);
		my $topology_backends = $hash->{helper}{topology_device_backends}{ $device->{NAME} } || [];

		# Topologiewarnungen folgen auch fremden, Medienreadings nur verwalteten Playern.
		AudioManager_update_topology_warning($hash) if $backend_id || @$topology_backends;
		AudioManager_update_media_status($hash) if $backend_id;
	}

	AudioManager_schedule_worker($hash);
	return undef;
}

# Bietet FHEM-Perlcode eine sichere direkte API ohne fragile neu gequotete fhem()-Texte.
sub AudioManager_Submit($$$) {
	my ($manager, $type, $options) = @_;
	my $hash = $defs{$manager};
	return (undef, "AudioManager $manager existiert nicht")
		if !$hash || ($hash->{TYPE} || '') ne 'AudioManager';
	return (undef, 'Optionen muessen als Hash uebergeben werden') if ref($options) ne 'HASH';
	my (@answer, $ok);
	$ok = eval {
		@answer = AudioManager_submit_request($hash, $type, $options);
		1;
	};
	return (undef, $@ || 'Audioauftrag konnte nicht angenommen werden') if !$ok;
	return @answer;
}

# Ersetzt bestehende say-Helfer durch einen duennen, zentral verwalteten Kompatibilitaetsaufruf.
sub AudioManager_Say($$;$) {
	my ($manager, $text, $target) = @_;
	my @answer = AudioManager_Submit($manager, 'speak', {
		text => $text,
		target => defined($target) ? $target : 'all',
	});

	# Listenaufrufer erhalten den API-Vertrag; skalare Aliase zeigen nur echte Fehler an.
	return wantarray ? @answer : $answer[1];
}

1;

=pod

=head1 NAME

AudioManager - priorisiertes, backendneutrales Audiomanagement fuer FHEM

=head1 SYNOPSIS

	define Audio AudioManager sonos2mqtt=Sonos.FlurEG,Sonos.Kueche
	attr Audio ttsDevice SonosTTS
	set Audio speak Die Waschmaschine ist fertig.

=head1 SECURITY

Das Modul fuehrt kein C<save> aus. Es steuert nur die im Define explizit genannten Player.

=item device
=item summary Prioritized audio sessions with pluggable backends
=item summary_DE Priorisierte Audiositzungen mit austauschbaren Backends

=begin html

<a id="AudioManager"></a>
<h3>AudioManager</h3>
<p>Coordinates prioritized streams, queues, clips, speech and alarms through
versioned backend adapters. The initial backend supports sonos2mqtt speakers.</p>

<a id="AudioManager-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; AudioManager sonos2mqtt=&lt;speaker&gt;[,&lt;speaker&gt;...]</code></p>
<p>Missing FHEM devices in a mixed speaker list are ignored and reported at
error log level. At least one existing speaker is required. Existing devices
still have to satisfy the backend's speaker validation.</p>

<a id="AudioManager-set"></a>
<h4>Set</h4>
<p>Playback commands accept the leading options <code>target=...</code>,
<code>volume=0..100</code> and <code>fadein=0..86400</code>. Without
<code>target</code>, all managed players are addressed in their existing groups.
Targets may be <code>all</code>, <code>backend:&lt;id&gt;</code>,
<code>group:&lt;player&gt;</code>, <code>player:&lt;player&gt;</code>,
<code>players:&lt;player,...&gt;</code> or <code>zone:&lt;name&gt;</code>.</p>
<ul>
<a id="AudioManager-set-alarm"></a>
<li><code>alarm [target=...] [volume=...] [fadein=seconds] [text=|uri=]&lt;content&gt;</code><br>
Creates a finite, highest-priority alarm. Content with <code>scheme://</code> is
detected as a URI; other content is rendered through <code>ttsDevice</code>.
The optional prefix overrides this detection.</li>
<a id="AudioManager-set-group"></a>
<li><code>group create &lt;coordinator&gt; &lt;member&gt;[,&lt;member&gt;...]</code><br>
<code>group add &lt;player&gt; &lt;coordinator&gt;</code><br>
<code>group remove &lt;player&gt;</code><br>
<code>group dissolve &lt;coordinator&gt;</code><br>
Creates or changes a native group. Every player must be managed by the same
backend.</li>
<a id="AudioManager-set-speak"></a>
<li><code>speak [target=...] [volume=...] [fadein=seconds] &lt;text&gt;</code><br>
Renders the text through <code>ttsDevice</code> and queues it as a finite speech
request. Equal texts may be filtered by <code>speakDedupeWindow</code>.</li>
<a id="AudioManager-set-play"></a>
<li><code>play [target=...] [volume=...] [fadein=seconds] &lt;uri&gt;</code><br>
Plays one finite media URI and resumes the interrupted lower-priority source
after completion.</li>
<a id="AudioManager-set-stream"></a>
<li><code>stream [target=...] [volume=...] [fadein=seconds] &lt;favorite|uri&gt;</code><br>
Starts a persistent stream. Content with <code>scheme://</code> is used as a URI;
all other content is treated as a Sonos favorite name.</li>
<a id="AudioManager-set-queue"></a>
<li><code>queue [target=...] [volume=...] [fadein=seconds]</code><br>
Starts the media queue already present on the selected coordinator. Managed URI
lists are available through the Perl API.</li>
<a id="AudioManager-set-stop"></a>
<li><code>stop [all|target=...|&lt;request-id&gt;|alarm|speak|play|queue|stream]</code><br>
Cancels all requests, one exact request, one audio type or all requests that
overlap the selected target. A target stop also reaches the backend when no
nonterminal request remains.</li>
<a id="AudioManager-set-transport"></a>
<li><code>transport [target=...] &lt;play|pause|previous|next&gt;</code><br>
Sends a direct transport command to the selected managed players without
creating a scheduler request.</li>
<a id="AudioManager-set-mute"></a>
<li><code>mute [target=...] &lt;on|off&gt; [force]</code><br>
<code>on</code> remembers each player's previous mute state. <code>off</code>
restores that snapshot; <code>off force</code> unmutes every selected player.</li>
<a id="AudioManager-set-volume"></a>
<li><code>volume [target=...] &lt;0..100&gt;</code><br>
Sets the volume directly on all selected managed players.</li>
<a id="AudioManager-set-volumeStep"></a>
<li><code>volumeStep [target=...] &lt;up|down&gt;</code><br>
Changes the volume by the backend-specific step without creating a scheduler
request.</li>
</ul>
<p>Alarm content that looks like a URL with <code>scheme://</code> is used as a URI;
all other content is rendered as text. The optional <code>text=</code> and
<code>uri=</code> prefixes override this automatic detection.</p>
<p>Stream content with <code>scheme://</code> is played as a persistent URI;
all other stream content is treated as a Sonos favorite name.</p>
<p><code>mute on</code> stores each target player's previous mute state once.
A normal <code>mute off</code> restores only stored targets, while
<code>mute off force</code> unmutes all selected targets regardless of that state. Mute
snapshots are volatile and are discarded on redefine or restart.</p>
<p>The normalized readings <code>source</code>, <code>title</code>, <code>artist</code>,
<code>album</code>, <code>albumArtUri</code>, <code>transportState</code>,
<code>volume</code> and <code>mute</code> describe the highest-priority active
request and can be used directly by FTUI.</p>
<p>Existing <code>all</code>, backend and <code>group:</code> targets remain playable
when an unmanaged speaker joins through the Sonos app. Such a speaker participates
only as part of its native group and cannot be selected directly. The
<code>topologyWarning</code> reading reports the deviation until it leaves.</p>

<a id="AudioManager-get"></a>
<h4>Get</h4>
<ul>
<a id="AudioManager-get-topology"></a>
<li><code>topology</code><br>
Returns the current player and group topology as canonical JSON, separated by
backend instance.</li>
<a id="AudioManager-get-requests"></a>
<li><code>requests</code><br>
Returns all tracked scheduler requests as canonical JSON, including ID, type,
state, priority, targets, timestamps and terminal reason.</li>
<a id="AudioManager-get-priorities"></a>
<li><code>priorities</code><br>
Returns the effective priorities after merging configured partial overrides
with the defaults.</li>
<a id="AudioManager-get-health"></a>
<li><code>health</code><br>
Returns the detailed supervisor report for all backend instances as canonical
JSON.</li>
</ul>

<a id="AudioManager-attr"></a>
<h4>Attributes</h4>
<ul>
<a id="AudioManager-attr-priorities"></a>
<li><code>priorities &lt;type:value,...&gt;</code><br>
Overrides priorities from 0 to 10000 for selected audio types. Missing types
keep the defaults <code>alarm:400,speak:300,play:200,queue:100,stream:50</code>;
higher values win and equal values use FIFO.</li>
<a id="AudioManager-attr-defaultVolumes"></a>
<li><code>defaultVolumes &lt;type:0..100,...&gt;</code><br>
Overrides the request volume for selected audio types. Missing types keep
<code>alarm:60,speak:25,play:20,queue:15,stream:12</code>.</li>
<a id="AudioManager-attr-volumePolicies"></a>
<li><code>volumePolicies &lt;type:fixed|minimum|keep,...&gt;</code><br>
Selects whether the configured volume is set exactly, used only as a minimum,
or left unchanged. The defaults are <code>alarm:minimum</code> and
<code>fixed</code> for every other type.</li>
<a id="AudioManager-attr-volumeLimits"></a>
<li><code>volumeLimits &lt;type:min-max,...&gt;</code> or
<code>&lt;type:start-end:min-max,...&gt;</code><br>
Defines independent all-day or local-time safety limits. Following time windows
for the same type may omit the type, for example
<code>alarm:8-20:30-80,20-8:30-50</code>.</li>
<a id="AudioManager-attr-quietHours"></a>
<li><code>quietHours &lt;type=start-end[,start-end...],...&gt;</code><br>
Blocks new requests of the named types during local-time windows. Windows may
cross midnight; their start is inclusive and their end is exclusive.</li>
<a id="AudioManager-attr-speakDedupeWindow"></a>
<li><code>speakDedupeWindow &lt;seconds&gt;</code><br>
Filters equal normalized speech texts within this nonnegative interval. The
default is 5 seconds; 0 disables filtering.</li>
<a id="AudioManager-attr-ttsDevice"></a>
<li><code>ttsDevice &lt;device&gt;</code><br>
Names the FHEM Text2Speech provider used by <code>speak</code> and text-based
<code>alarm</code> requests.</li>
<a id="AudioManager-attr-zones"></a>
<li><code>zones &lt;name=player,player;other=player&gt;</code><br>
Defines logical <code>zone:</code> targets. Every player must be listed in the
AudioManager define; one logical zone may span multiple backends.</li>
<a id="AudioManager-attr-backendAvailability"></a>
<li><code>backendAvailability &lt;prefix=device[:reading],...&gt;</code><br>
Maps an MQTT prefix to an optional bridge availability reading. The reading
defaults to <code>connected</code>; without this attribute the adapter attempts
automatic discovery.</li>
<a id="AudioManager-attr-startTimeout"></a>
<li><code>startTimeout &lt;seconds&gt;</code><br>
Sets the positive timeout for TTS generation and playback-start confirmation.
The default is 15 seconds.</li>
<a id="AudioManager-attr-stopGrace"></a>
<li><code>stopGrace &lt;seconds&gt;</code><br>
Sets the positive grace period after the last confirmed playback before a
finite request completes. The default is 2 seconds.</li>
<a id="AudioManager-attr-groupTimeout"></a>
<li><code>groupTimeout &lt;seconds&gt;</code><br>
Limits how long the backend waits for native grouping phases. The default is
30 seconds.</li>
<a id="AudioManager-attr-healthDebounce"></a>
<li><code>healthDebounce &lt;seconds&gt;</code><br>
Debounces health checks after relevant backend events. The default is 3
seconds; 0 disables the delay.</li>
<a id="AudioManager-attr-healthVerifyTimeout"></a>
<li><code>healthVerifyTimeout &lt;seconds&gt;</code><br>
Sets the positive timeout for a player to confirm an active health probe. The
default is 15 seconds.</li>
<a id="AudioManager-attr-healthRecoveryCooldown"></a>
<li><code>healthRecoveryCooldown &lt;seconds&gt;</code><br>
Sets the minimum interval between subscription recovery attempts. The default
is 60 seconds; 0 disables the cooldown.</li>
<a id="AudioManager-attr-healthProbeInterval"></a>
<li><code>healthProbeInterval &lt;seconds&gt;</code><br>
Sets the positive interval between periodic player health probes. The default
is 900 seconds.</li>
<a id="AudioManager-attr-autoLeave"></a>
<li><code>autoLeave &lt;0|1&gt;</code><br>
Allows a request to split an existing native group temporarily and restore it
afterwards. The safe default is 0; explicit <code>group</code> commands are not
affected.</li>
<a id="AudioManager-attr-disable"></a>
<li><code>disable &lt;0|1&gt;</code><br>
With 1, cancels active requests, rejects new playback requests and sets the
manager state to <code>disabled</code>. The default is 0.</li>
</ul>
<p><code>volumeLimits</code> defines independent safety bounds per audio type.
A plain range such as <code>stream:10-40</code> applies all day. Timed rules use
<code>type:start-end:min-max</code>; following windows for the same type may omit
the type. Rules are selected from local time when a request is accepted and
their end is exclusive. The bounds also clamp explicit volume values,
<code>minimum</code>, <code>keep</code>, and volumes restored during resume.</p>
<p>The adapter actively checks every managed sonos2mqtt speaker with the
read-only <code>GetZoneInfo</code> command. Only a fresh player response confirms the
probe. If a response is missing, the adapter publishes exactly one
<code>&lt;prefix&gt;/cmd/check-subscriptions</code> and retries the affected player.</p>
<p>After the retry also fails, <code>backendHealthError</code> names the offline
player and one level 2 log entry is written. A confirmed recovery clears the
reading and creates one level 3 log entry. Repeated unchanged states are not logged.</p>
<p>A bridge device remains optional. The adapter automatically detects an exact
<code>&lt;prefix&gt;/connected</code> mapping in an existing MQTT2_DEVICE on the same
IODev, independent of MQTT2_Discovery. <code>backendAvailability</code> can provide
the mapping explicitly. Use <code>get &lt;name&gt; health</code> for the detailed report.</p>

=end html

=begin html_DE

<a id="AudioManager"></a>
<h3>AudioManager</h3>
<p>Koordiniert Streams, Media-Queues, Einzelclips, Sprache und Alarme ueber
versionierte Backendadapter. Der erste Adapter unterstuetzt sonos2mqtt-Speaker.</p>

<a id="AudioManager-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; AudioManager sonos2mqtt=&lt;speaker&gt;[,&lt;speaker&gt;...]</code></p>
<p>Ein Bridge-Device ist nicht erforderlich. Nur explizit genannte
<code>sonos2mqtt_speaker</code> werden verwaltet.</p>
<p>Nicht vorhandene FHEM-Devices in einer gemischten Playerliste werden ignoriert
und mit Fehler-Loglevel gemeldet. Mindestens ein vorhandener Player ist
erforderlich. Vorhandene Devices muessen die Playerpruefung des Backends weiterhin
erfuellen.</p>

<a id="AudioManager-set"></a>
<h4>Set</h4>
<p>Wiedergabebefehle akzeptieren am Anfang die Optionen
<code>target=...</code>, <code>volume=0..100</code> und
<code>fadein=0..86400</code>. Ohne <code>target</code> werden alle verwalteten
Player in ihren vorhandenen Gruppen angesprochen. Ziele sind <code>all</code>,
<code>backend:&lt;ID&gt;</code>, <code>group:&lt;Player&gt;</code>,
<code>player:&lt;Player&gt;</code>, <code>players:&lt;Player,...&gt;</code> oder
<code>zone:&lt;Name&gt;</code>.</p>
<ul>
<a id="AudioManager-set-alarm"></a>
<li><code>alarm [target=...] [volume=...] [fadein=Sekunden] [text=|uri=]&lt;Inhalt&gt;</code><br>
Erzeugt einen endlichen Alarm mit hoechster Prioritaet. Inhalt mit
<code>Schema://</code> wird als URI erkannt, anderer Inhalt ueber
<code>ttsDevice</code> gerendert. Das optionale Praefix uebersteuert die Erkennung.</li>
<a id="AudioManager-set-group"></a>
<li><code>group create &lt;Coordinator&gt; &lt;Mitglied&gt;[,&lt;Mitglied&gt;...]</code><br>
<code>group add &lt;Player&gt; &lt;Coordinator&gt;</code><br>
<code>group remove &lt;Player&gt;</code><br>
<code>group dissolve &lt;Coordinator&gt;</code><br>
Erstellt oder aendert eine native Gruppe. Alle Player muessen vom selben
Backend verwaltet werden.</li>
<a id="AudioManager-set-speak"></a>
<li><code>speak [target=...] [volume=...] [fadein=Sekunden] &lt;Text&gt;</code><br>
Rendert den Text ueber <code>ttsDevice</code> und reiht ihn als endliche Ansage
ein. Gleiche Texte koennen durch <code>speakDedupeWindow</code> gefiltert werden.</li>
<a id="AudioManager-set-play"></a>
<li><code>play [target=...] [volume=...] [fadein=Sekunden] &lt;URI&gt;</code><br>
Spielt eine einzelne endliche Medien-URI und setzt die unterbrochene Quelle mit
niedrigerer Prioritaet anschliessend fort.</li>
<a id="AudioManager-set-stream"></a>
<li><code>stream [target=...] [volume=...] [fadein=Sekunden] &lt;Favorit|URI&gt;</code><br>
Startet einen dauerhaften Stream. Inhalt mit <code>Schema://</code> gilt als URI,
jeder andere Inhalt als Sonos-Favoritenname.</li>
<a id="AudioManager-set-queue"></a>
<li><code>queue [target=...] [volume=...] [fadein=Sekunden]</code><br>
Startet die bereits auf dem ausgewaehlten Coordinator vorhandene Media-Queue.
Verwaltete URI-Listen sind ueber die Perl-API verfuegbar.</li>
<a id="AudioManager-set-stop"></a>
<li><code>stop [all|target=...|&lt;Request-ID&gt;|alarm|speak|play|queue|stream]</code><br>
Bricht alle Auftraege, einen bestimmten Auftrag, eine Audioart oder alle mit dem
Ziel ueberlappenden Auftraege ab. Ein Zielstopp erreicht das Backend auch ohne
verbleibenden nichtterminalen Auftrag.</li>
<a id="AudioManager-set-transport"></a>
<li><code>transport [target=...] &lt;play|pause|previous|next&gt;</code><br>
Sendet einen direkten Transportbefehl an die ausgewaehlten verwalteten Player,
ohne einen Schedulerauftrag anzulegen.</li>
<a id="AudioManager-set-mute"></a>
<li><code>mute [target=...] &lt;on|off&gt; [force]</code><br>
<code>on</code> merkt sich den vorherigen Mute-Zustand jedes Players.
<code>off</code> restauriert diesen Snapshot; <code>off force</code> entmutet alle
ausgewaehlten Player.</li>
<a id="AudioManager-set-volume"></a>
<li><code>volume [target=...] &lt;0..100&gt;</code><br>
Setzt die Lautstaerke direkt auf allen ausgewaehlten verwalteten Playern.</li>
<a id="AudioManager-set-volumeStep"></a>
<li><code>volumeStep [target=...] &lt;up|down&gt;</code><br>
Aendert die Lautstaerke um den backendspezifischen Schritt, ohne einen
Schedulerauftrag anzulegen.</li>
</ul>
<p>Alarm-Inhalt mit <code>Schema://</code> wird automatisch als URI verwendet;
jeder andere Inhalt wird als Text gerendert. Die optionalen Praefixe
<code>text=</code> und <code>uri=</code> uebersteuern diese Erkennung.</p>
<p>Stream-Inhalt mit <code>Schema://</code> wird als dauerhafte URI abgespielt;
jeder andere Stream-Inhalt gilt als Sonos-Favoritenname.</p>
<p><code>mute on</code> sichert pro Zielplayer einmalig den vorherigen Zustand.
Ein normales <code>mute off</code> restauriert nur gesicherte Ziele;
<code>mute off force</code> entmutet alle ausgewaehlten Ziele unabhaengig davon. Die
Mute-Snapshots sind fluechtig und entfallen bei Defmod oder Neustart.</p>
<p><code>fadein</code> ist optional, dauert 0 bis 86400 Sekunden und pausiert
zusammen mit einer prioritaetsbedingten Unterbrechung. Eine direkte
<code>AudioManager_Submit</code>-Queue kann zusaetzlich eine URI-Liste
<code>uris =&gt; [...]</code> uebergeben; der Adapter verwaltet dann Aufbau,
Wiederholung, Start und Stop der nativen Sonos-Queue.</p>
<p>Vorhandene <code>all</code>-, Backend- und <code>group:</code>-Ziele bleiben
abspielbar, wenn ueber die Sonos-App ein nicht verwalteter Player beitritt. Er
nimmt nur als Mitglied seiner nativen Gruppe teil und kann nicht direkt als Ziel
gewaehlt werden. Das Reading <code>topologyWarning</code> meldet die Abweichung bis
zu seinem Austritt.</p>

<a id="AudioManager-get"></a>
<h4>Get</h4>
<ul>
<a id="AudioManager-get-topology"></a>
<li><code>topology</code><br>
Liefert die aktuelle Player- und Gruppentopologie als kanonisches JSON,
getrennt nach Backendinstanz.</li>
<a id="AudioManager-get-requests"></a>
<li><code>requests</code><br>
Liefert alle bekannten Schedulerauftraege als kanonisches JSON mit ID, Art,
Status, Prioritaet, Zielen, Zeitpunkten und terminalem Grund.</li>
<a id="AudioManager-get-priorities"></a>
<li><code>priorities</code><br>
Liefert die wirksamen Prioritaeten nach dem Zusammenfuehren partieller
Attributwerte mit den Defaults.</li>
<a id="AudioManager-get-health"></a>
<li><code>health</code><br>
Liefert den detaillierten Supervisorbericht fuer alle Backendinstanzen als
kanonisches JSON.</li>
</ul>

<a id="AudioManager-attr"></a>
<h4>Attribute</h4>
<ul>
<a id="AudioManager-attr-priorities"></a>
<li><code>priorities &lt;Audioart:Wert,...&gt;</code><br>
Ueberschreibt Prioritaeten von 0 bis 10000 fuer einzelne Audioarten. Fehlende
Arten behalten <code>alarm:400,speak:300,play:200,queue:100,stream:50</code>;
hoehere Werte gewinnen, gleiche Werte werden FIFO verarbeitet.</li>
<a id="AudioManager-attr-defaultVolumes"></a>
<li><code>defaultVolumes &lt;Audioart:0..100,...&gt;</code><br>
Ueberschreibt die Auftragslautstaerke fuer einzelne Audioarten. Fehlende Arten
behalten <code>alarm:60,speak:25,play:20,queue:15,stream:12</code>.</li>
<a id="AudioManager-attr-volumePolicies"></a>
<li><code>volumePolicies &lt;Audioart:fixed|minimum|keep,...&gt;</code><br>
Waehlt, ob die Lautstaerke exakt gesetzt, nur als Minimum verwendet oder nicht
geaendert wird. Defaults sind <code>alarm:minimum</code> und <code>fixed</code> fuer
alle anderen Arten.</li>
<a id="AudioManager-attr-volumeLimits"></a>
<li><code>volumeLimits &lt;Audioart:Minimum-Maximum,...&gt;</code> oder
<code>&lt;Audioart:Start-Ende:Minimum-Maximum,...&gt;</code><br>
Definiert unabhaengige ganztaegige oder lokale zeitabhaengige
Sicherheitsgrenzen. Folgefenster derselben Art duerfen den Namen auslassen, zum
Beispiel <code>alarm:8-20:30-80,20-8:30-50</code>.</li>
<a id="AudioManager-attr-quietHours"></a>
<li><code>quietHours &lt;Audioart=Start-Ende[,Start-Ende...],...&gt;</code><br>
Blockiert neue Auftraege der genannten Arten in lokalen Zeitfenstern. Fenster
duerfen Mitternacht ueberschreiten; der Start ist inklusiv, das Ende exklusiv.</li>
<a id="AudioManager-attr-speakDedupeWindow"></a>
<li><code>speakDedupeWindow &lt;Sekunden&gt;</code><br>
Filtert gleiche normalisierte Sprachtexte innerhalb dieses nichtnegativen
Intervalls. Default sind 5 Sekunden; 0 deaktiviert den Filter.</li>
<a id="AudioManager-attr-ttsDevice"></a>
<li><code>ttsDevice &lt;Device&gt;</code><br>
Nennt den FHEM-Text2Speech-Provider fuer <code>speak</code> und textbasierte
<code>alarm</code>-Auftraege.</li>
<a id="AudioManager-attr-zones"></a>
<li><code>zones &lt;Name=Player,Player;Anderer=Player&gt;</code><br>
Definiert logische <code>zone:</code>-Ziele. Jeder Player muss im
AudioManager-Define stehen; eine logische Zone darf mehrere Backends umfassen.</li>
<a id="AudioManager-attr-backendAvailability"></a>
<li><code>backendAvailability &lt;Praefix=Device[:Reading],...&gt;</code><br>
Ordnet einem MQTT-Praefix optional ein Bridge-Availability-Reading zu. Ohne
Reading gilt <code>connected</code>; ohne dieses Attribut versucht der Adapter
die Zuordnung automatisch zu erkennen.</li>
<a id="AudioManager-attr-startTimeout"></a>
<li><code>startTimeout &lt;Sekunden&gt;</code><br>
Setzt die positive Frist fuer TTS-Erzeugung und Bestaetigung des
Wiedergabestarts. Default sind 15 Sekunden.</li>
<a id="AudioManager-attr-stopGrace"></a>
<li><code>stopGrace &lt;Sekunden&gt;</code><br>
Setzt die positive Nachlaufzeit nach der letzten bestaetigten Wiedergabe, bevor
ein endlicher Auftrag abgeschlossen wird. Default sind 2 Sekunden.</li>
<a id="AudioManager-attr-groupTimeout"></a>
<li><code>groupTimeout &lt;Sekunden&gt;</code><br>
Begrenzt die Wartezeit des Backends auf native Gruppenphasen. Default sind 30
Sekunden.</li>
<a id="AudioManager-attr-healthDebounce"></a>
<li><code>healthDebounce &lt;Sekunden&gt;</code><br>
Entprellt Healthpruefungen nach relevanten Backendereignissen. Default sind 3
Sekunden; 0 deaktiviert die Verzoegerung.</li>
<a id="AudioManager-attr-healthVerifyTimeout"></a>
<li><code>healthVerifyTimeout &lt;Sekunden&gt;</code><br>
Setzt die positive Frist, in der ein Player einen aktiven Healthprobe
bestaetigen muss. Default sind 15 Sekunden.</li>
<a id="AudioManager-attr-healthRecoveryCooldown"></a>
<li><code>healthRecoveryCooldown &lt;Sekunden&gt;</code><br>
Setzt den Mindestabstand zwischen Versuchen zur Wiederherstellung der
Subscriptions. Default sind 60 Sekunden; 0 deaktiviert den Abstand.</li>
<a id="AudioManager-attr-healthProbeInterval"></a>
<li><code>healthProbeInterval &lt;Sekunden&gt;</code><br>
Setzt das positive Intervall zwischen regelmaessigen Player-Healthprobes.
Default sind 900 Sekunden.</li>
<a id="AudioManager-attr-autoLeave"></a>
<li><code>autoLeave &lt;0|1&gt;</code><br>
Erlaubt einem Auftrag, eine bestehende native Gruppe temporaer aufzutrennen und
anschliessend wiederherzustellen. Sicherer Default ist 0; explizite
<code>group</code>-Befehle sind davon nicht betroffen.</li>
<a id="AudioManager-attr-disable"></a>
<li><code>disable &lt;0|1&gt;</code><br>
Mit 1 werden aktive Auftraege abgebrochen, neue Wiedergabeauftraege abgelehnt
und der Managerstatus auf <code>disabled</code> gesetzt. Default ist 0.</li>
</ul>
<p><code>volumeLimits</code> definiert unabhaengige Sicherheitsgrenzen je
Audioart. Eine reine Spanne wie <code>stream:10-40</code> gilt ganztags.
Zeitregeln verwenden <code>Audioart:Start-Ende:Minimum-Maximum</code>; weitere
Fenster derselben Audioart duerfen den Namen auslassen. Die lokale Uhrzeit beim
Annehmen des Requests waehlt die Regel, deren Ende jeweils exklusiv ist. Die
Grenzen klemmen auch explizite Lautstaerken, <code>minimum</code>,
<code>keep</code> und beim Resume restaurierte Pegel.</p>
<p>Der Adapter prueft jeden verwalteten sonos2mqtt-Speaker aktiv mit dem
nicht steuernden Kommando <code>GetZoneInfo</code>. Erst eine frische Playerantwort
bestaetigt den Probe. Fehlt sie, veroeffentlicht der Adapter genau einmal
<code>&lt;Praefix&gt;/cmd/check-subscriptions</code> und prueft den betroffenen Player erneut.</p>
<p>Bleibt auch der Wiederholungsprobe erfolglos, nennt
<code>backendHealthError</code> den offline erkannten Player und es entsteht genau
ein Logeintrag mit Level 2. Die bestaetigte Wiederkehr loescht das Reading und
erzeugt genau einen Logeintrag mit Level 3. Unveraenderte Zustaende werden nicht
erneut geloggt.</p>
<p>Ein Bridge-Device bleibt optional. Der Adapter erkennt unabhaengig von
MQTT2_Discovery automatisch eine exakte Zuordnung fuer
<code>&lt;Praefix&gt;/connected</code> in einem vorhandenen MQTT2_DEVICE am selben IODev.
<code>backendAvailability</code> kann die Zuordnung explizit vorgeben.
<code>get &lt;name&gt; health</code> liefert den Detailbericht.</p>

=end html_DE

=cut
