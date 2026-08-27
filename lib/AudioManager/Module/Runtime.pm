# Copyright (c) 2026 Andreas Planer

package AudioManager::Module::Runtime;

use strict;
use warnings;
use AudioManager::Config ();
use AudioManager::Core ();
use AudioManager::Module::Status ();
use AudioManager::Module::TTS ();

# Nutzt dieselbe Gatewayinstanz wie die anderen FHEM-nahen Modulschichten.
sub _gateway {
	my ($hash) = @_;
	return AudioManager::Module::Status::gateway($hash);
}

# Plant den naechsten FHEM-Worker ueber die schmale Fassade der 90er-Datei.
sub _schedule {
	my ($hash, $scheduler) = @_;
	return $scheduler->($hash) if ref($scheduler) eq 'CODE';
	return main::AudioManager_schedule_worker($hash)
		if defined &main::AudioManager_schedule_worker;
	return;
}

# Liefert die tatsaechlichen Abspielziele eines Requests fuer eine Backendinstanz.
sub backend_targets {
	my ($request, $backend_id) = @_;
	return $request->{backend_targets}{$backend_id} || [];
}

# Sichert pro beruehrtem Backendbereich den externen Ausgangszustand genau einmal.
sub capture_baselines {
	my ($hash, $request) = @_;

	# Disjunkte Backendbereiche erhalten getrennte Baselines und koennen parallel laufen.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $targets = backend_targets($request, $backend_id);
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
sub core_start {
	my ($hash, $request, $scheduler) = @_;

	# Seiteneffektfreie Backendpruefungen verhindern Snapshots und Restores fuer
	# Auftraege, die beispielsweise wegen autoLeave=0 gar nicht starten duerfen.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->preflight_start(
			$request, backend_targets($request, $backend_id),
		);
		return "$backend_id: $error" if $error;
	}
	capture_baselines($hash, $request);

	my @started;

	# Ein backenduebergreifender Auftrag bleibt ein Elternrequest; jeder Adapter
	# erhaelt nur seinen lokalen Playeranteil und darf parallel beginnen.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->start($request, backend_targets($request, $backend_id));

		# Bereits gestartete Teilbackends werden bei einem spaeteren Fehler bestmoeglich gestoppt.
		if ($error) {

			for my $started_id (@started) {
				my $started_backend = $hash->{helper}{backends}{$started_id};
				$started_backend->stop($request, backend_targets($request, $started_id));
			}

			return "$backend_id: $error";
		}
		push @started, $backend_id;
	}

	_schedule($hash, $scheduler);
	return undef;
}

# Pausiert alle Backendanteile eines aktiven Auftrags vor einer hoeheren Quelle.
sub core_suspend {
	my ($hash, $request, undef) = @_;

	# Jeder Adapter sichert unmittelbar vor Pause seinen aktuellen Lautstaerke- und Quellenstand.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->suspend($request, backend_targets($request, $backend_id));
		return "$backend_id: $error" if $error;
	}

	return undef;
}

# Setzt alle Backendanteile eines pausierten Auftrags ueber deren Snapshots fort.
sub core_resume {
	my ($hash, $request, $scheduler) = @_;

	# Backends koennen ihre Gruppierung asynchron wiederherstellen; der Worker fuehrt sie fort.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->resume($request);
		return "$backend_id: $error" if $error;
	}

	_schedule($hash, $scheduler);
	return undef;
}

# Stoppt alle Backendanteile eines abgebrochenen oder fehlgeschlagenen Auftrags.
sub core_stop {
	my ($hash, $request, $scheduler) = @_;

	# Stop bleibt auf die tatsaechlichen Abspielziele begrenzt.
	for my $backend_id (sort keys %{ $request->{backend_targets} || {} }) {
		my $backend = $hash->{helper}{backends}{$backend_id};
		my $error = $backend->stop($request, backend_targets($request, $backend_id));
		return "$backend_id: $error" if $error;
	}

	_schedule($hash, $scheduler);
	return undef;
}

# Erzeugt den Scheduler mit allen FHEM- und Backendseiteneffekten als Callbacks.
sub build_core {
	my ($hash, $scheduler) = @_;
	my $gateway = _gateway($hash);
	my $configuration = AudioManager::Config::configuration(
		$hash, $gateway, AudioManager::Core->default_priorities,
	);
	return AudioManager::Core->new(
		clock => sub { return _gateway($hash)->now },
		priorities => $configuration->{priorities},
		dedupe_window => $configuration->{dedupe_window},
		callbacks => {
			on_start => sub { return core_start($hash, $_[0], $scheduler) },
			on_suspend => sub { return core_suspend($hash, $_[0], $_[1]) },
			on_resume => sub { return core_resume($hash, $_[0], $scheduler) },
			on_complete => sub { return core_stop($hash, $_[0], $scheduler) },
			on_stop => sub { return core_stop($hash, $_[0], $scheduler) },
			on_change => sub {
				my ($request) = @_;
				++$hash->{helper}{deduplicated_requests} if $request->{state} eq 'deduplicated';
				AudioManager::Module::Status::update_status($hash, $request);
				_schedule($hash, $scheduler);
			},
		},
	);
}

# Fuehrt alle asynchronen Backendphasen fort und erkennt Start sowie Ende endlicher Clips.
sub poll_requests {
	my ($hash) = @_;
	my $core = $hash->{helper}{core};
	my $gateway = _gateway($hash);
	my $configuration = AudioManager::Config::configuration(
		$hash, $gateway, AudioManager::Core->default_priorities,
	);

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
			my $targets = backend_targets($request, $backend_id);
			my $playing = $backend->is_playing($request, $targets);

			# Erst eine vom Backend bestaetigte Wiedergabe startet die fachliche Clipdauer.
			if ($playing) {
				$request->{runtime}{seen_playing}{$backend_id} = 1;
				$request->{runtime}{playback_confirmed_at}{$backend_id}
					//= $gateway->now;
			}
			$all_seen = 0 if !$request->{runtime}{seen_playing}{$backend_id};
			$any_playing = 1 if $playing;
		}

		my $now = $gateway->now;
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
sub reconcile_baselines {
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
				AudioManager::Module::Status::reading($hash, 'lastError', "$backend_id: $restore_request");
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
sub poll_restores {
	my ($hash) = @_;
	my @remaining;

	# Jeder Restorejob verwendet denselben nichtblockierenden Backendautomaten wie Resume.
	for my $job (@{ $hash->{helper}{restore_jobs} || [] }) {
		my $backend = $hash->{helper}{backends}{ $job->{backend_id} };
		my $error = $backend->progress($job->{request});
		my $phase = $job->{request}{runtime}{backends}{ $job->{backend_id} }{phase} || '';

		if ($error) {
			AudioManager::Module::Status::reading($hash, 'lastError', "$job->{backend_id}: $error");
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
sub has_audio_work {
	my ($hash) = @_;
	return 1 if $hash->{helper}{tts_current};
	return 1 if @{ $hash->{helper}{tts_queue} || [] };
	return 1 if @{ $hash->{helper}{core}->active_requests };
	return 1 if @{ $hash->{helper}{restore_jobs} || [] };
	return 0;
}

# Meldet Audio- oder Supervisorarbeit mit geplantem Fortschritt.
sub has_work {
	my ($hash) = @_;
	return 1 if has_audio_work($hash);
	return 1 if $hash->{helper}{supervisor} && $hash->{helper}{supervisor}->has_work;
	return 0;
}

# Plant den Worker fuer Audio kurz getaktet, fuer Health dagegen exakt event- und fristgesteuert.
sub schedule_worker {
	my ($hash, $worker_delay, $worker_name) = @_;
	return if !has_work($hash);
	my $gateway = _gateway($hash);
	my $delay = has_audio_work($hash) ? $worker_delay
		: $hash->{helper}{supervisor}->next_delay;
	return if !defined $delay;
	my $due_at = $gateway->now + $delay;

	# Ein bereits frueher geplanter Tick bleibt bestehen; nur dringlichere Events ziehen ihn vor.
	if ($hash->{helper}{worker_scheduled}) {
		return if defined($hash->{helper}{worker_at}) && $hash->{helper}{worker_at} <= $due_at;
		$gateway->cancel_timer($hash, $worker_name);
	}

	$hash->{helper}{worker_scheduled} = 1;
	$hash->{helper}{worker_at} = $due_at;
	$gateway->schedule($delay, $hash, $worker_name);
	return;
}

# Verarbeitet pro Tick Audiofortschritt sowie genau faellige Healthpruefungen.
sub worker {
	my ($hash, $defs, $scheduler) = @_;
	delete $hash->{helper}{worker_scheduled};
	delete $hash->{helper}{worker_at};
	return if !defined($defs->{ $hash->{NAME} }) || $defs->{ $hash->{NAME} } != $hash;
	$hash->{helper}{supervisor}->tick if $hash->{helper}{supervisor};
	AudioManager::Module::TTS::poll($hash, $scheduler);
	poll_requests($hash);
	reconcile_baselines($hash);
	poll_restores($hash);
	AudioManager::Module::Status::update_status($hash);
	_schedule($hash, $scheduler);
	return;
}

1;
