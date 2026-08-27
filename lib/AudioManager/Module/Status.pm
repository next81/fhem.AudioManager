# Copyright (c) 2026 Andreas Planer

package AudioManager::Module::Status;

use strict;
use warnings;
use JSON::PP ();
use AudioManager::FHEMGateway ();

# Liefert pro Instanz genau ein austauschbares FHEM-Gateway.
sub gateway {
	my ($hash) = @_;
	return $hash->{helper}{gateway} ||= AudioManager::FHEMGateway->new();
}

# Schreibt ein einzelnes Reading ueber die testbare Gatewaygrenze.
sub reading {
	my ($hash, $reading, $value, $trigger) = @_;
	return gateway($hash)->update_reading($hash, $reading, $value, $trigger // 1);
}

# Leitet einen backendneutralen Anzeigenamen aus dem aktiven Managerauftrag ab.
sub media_source {
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
sub update_media_status {
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
		$media{source} = media_source($request);

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
		my $current = gateway($hash)->reading_value(
			$hash->{NAME}, $reading, undef,
		);
		my $value = defined($media{$reading}) ? $media{$reading} : '';
		next if defined($current) && $current eq $value;
		reading($hash, $reading, $value);
	}

	return;
}

# Aktualisiert die kompakte Statusoberflaeche nach jedem Schedulerzustandswechsel.
sub update_status {
	my ($hash, $changed_request) = @_;
	my $core = $hash->{helper}{core};
	return if !$core;
	my $counts = $core->counts;
	my @active = sort {
		$b->{priority} <=> $a->{priority} || $a->{sequence} <=> $b->{sequence}
	} @{ $core->active_requests };
	my $disabled = gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	reading($hash, 'state', $disabled ? 'disabled' : 'ready');
	reading($hash, 'activeRequests', $counts->{active});
	reading($hash, 'pendingRequests', $counts->{preparing} + $counts->{queued});
	reading($hash, 'suspendedRequests', $counts->{suspended});
	reading($hash, 'ttsQueueLength', scalar @{ $hash->{helper}{tts_queue} || [] });
	reading($hash, 'currentRequest', join(',', map { $_->{id} } @active));
	reading($hash, 'currentType', join(',', map { $_->{type} } @active));
	reading($hash, 'currentTargets', join(',', map { @{ $_->{play_targets} || $_->{targets} } } @active));
	update_media_status($hash, \@active);

	# Der zuletzt geaenderte Auftrag bleibt mit Ergebnis und Fehlergrund nachvollziehbar.
	if ($changed_request) {
		reading($hash, 'lastRequest', $changed_request->{id});
		reading($hash, 'lastRequestType', $changed_request->{type});
		reading($hash, 'lastRequestState', $changed_request->{state});
		reading($hash, 'lastError', $changed_request->{reason} || 'none')
			if $changed_request->{state} eq 'failed';
		reading($hash, 'deduplicatedRequests',
			0 + ($hash->{helper}{deduplicated_requests} || 0));
	}

	return;
}

# Aktualisiert die sichtbare Warnung fuer tolerierte Abweichungen der nativen Gruppen.
sub update_topology_warning {
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
	my $current = gateway($hash)->reading_value(
		$hash->{NAME}, 'topologyWarning', undef,
	);
	return if defined($current) && $current eq $value;
	reading($hash, 'topologyWarning', $value);
	return;
}

# Schreibt Healthwechsel ueber den FHEM-Logger, bleibt fuer reine Modultests aber optional.
sub _log {
	my ($hash, $logger, $level, $message) = @_;
	return $logger->($hash, $level, $message) if ref($logger) eq 'CODE';
	return AudioManager::Module::FHEM::log($hash, $level, $message)
		if defined &AudioManager::Module::FHEM::log;
	return;
}

# Spiegelt den backendneutralen Healthbericht kompakt und als Detail-JSON in Readings.
sub update_health {
	my ($hash, $logger) = @_;
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
				_log($hash, $logger, 2, "Backend $backend_id: $summary");
			}

			$active_errors->{$backend_id} = $summary;
			$log_states->{$backend_id} = 'degraded';
		} elsif ($status eq 'healthy') {
			# Erst die bestaetigte Gesundmeldung loescht den aktuellen Fehlerzustand.
			if (($log_states->{$backend_id} || '') eq 'degraded') {
				_log($hash, $logger, 3, "Backend $backend_id wieder erreichbar");
			}

			delete $active_errors->{$backend_id};
			$log_states->{$backend_id} = 'healthy';
		}
	}

	reading($hash, 'backendHealth', join(',', map {
		$_ . ':' . $report->{$_}{status}
	} sort keys %$report));
	reading($hash, 'backendHealthDetails', $json->encode($report));
	reading($hash, 'backendRecoveryCount', $recovery_count);
	reading($hash, 'lastBackendRecovery',
		@recoveries ? (sort { $b <=> $a } @recoveries)[0] : 'none');
	reading($hash, 'lastBackendHealthError', @errors ? join(',', @errors) : 'none');
	reading($hash, 'backendHealthError', keys(%$active_errors) ? join('; ', map {
		$_ . ': ' . $active_errors->{$_}
	} sort keys %$active_errors) : 'none');
	return;
}

1;
