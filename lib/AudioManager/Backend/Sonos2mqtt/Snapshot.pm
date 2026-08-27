package AudioManager::Backend::Sonos2mqtt::Snapshot;

use strict;
use warnings;
use List::Util qw(max);

my $VOLUME_READING_GRACE = 5;

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
			uri => $self->_reading_first($player, '', 'currentTrack_trackUri'),
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

# Beginnt Resume oder finales Restore erst, wenn die vorherige Ausgabe
# bestaetigt still ist und ihr letzter Audiorest nicht mehr vom Pegelwechsel betroffen wird.
sub _continue_restore {
	my ($self, $request, $snapshot, $mode) = @_;
	my $runtime = $self->_runtime($request);

	# Die Wartezeit auf das Ende der hoeheren Quelle bleibt Teil der Unterbrechung.
	if ($mode eq 'resume' && $runtime->{fade} && $runtime->{fade}{paused_at}) {
		$runtime->{fade}{started_at} += $self->{gateway}->now - $runtime->{fade}{paused_at};
		delete $runtime->{fade}{paused_at};
	}

	return $self->_begin_restore($request, $snapshot, $mode);
}

# Wartet nach dem Stop einer hoeheren Ausgabe auf die Sonos-Bestaetigung, bevor
# der vorherige Pegel und die vorherige Quelle wiederhergestellt werden.
sub _quiet_before_restore {
	my ($self, $request, $snapshot, $mode) = @_;
	my $runtime = $self->_runtime($request);
	my $coordinators = $self->_coordinators($snapshot->{scope} || []);
	my @active = grep { $self->_transport_is_active($_) } @$coordinators;
	return $self->_continue_restore($request, $snapshot, $mode) if !@active;

	# Stop ist idempotent und verhindert, dass ein auslaufender Ansagerest den alten Pegel erhaelt.
	for my $coordinator (@active) {
		my $error = $self->_command($coordinator, 'stop');
		return $error if $error;
	}

	$runtime->{pending_restore_snapshot} = $snapshot;
	$runtime->{pending_restore_mode} = $mode;
	$runtime->{quieting_coordinators} = [ @active ];
	$runtime->{deadline} = $self->{gateway}->now + $self->{group_timeout};
	$runtime->{phase} = "${mode}_quieting";
	return $self->_finish_quiet_restore($request);
}

# Fuehrt einen wartenden Resume-/Restore-Schritt nach bestaetigtem STOPPED fort.
sub _finish_quiet_restore {
	my ($self, $request) = @_;
	my $runtime = $self->_runtime($request);
	return 'Zeitueberschreitung beim Beenden der vorherigen Sonos-Quelle'
		if $runtime->{deadline} && $self->{gateway}->now > $runtime->{deadline};
	return undef if grep {
		$self->_transport_is_active($_)
	} @{ $runtime->{quieting_coordinators} || [] };
	my $snapshot = delete $runtime->{pending_restore_snapshot};
	my $mode = delete $runtime->{pending_restore_mode};
	delete @{$runtime}{qw(quieting_coordinators deadline)};
	return $self->_continue_restore($request, $snapshot, $mode);
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
	return $self->_quiet_before_restore($request, $runtime->{resume_snapshot}, 'resume');
}

# Stellt einen externen Baseline-Snapshot nach dem letzten Managerauftrag wieder her.
sub restore {
	my ($self, $snapshot) = @_;
	my $fake_request = { runtime => { backends => {} } };
	my $error = $self->_quiet_before_restore($fake_request, $snapshot, 'restore');
	return $error if $error;

	# Finales Restore wird vom Modulworker weitergefuehrt; das Hilfsobjekt muss
	# deshalb fuer den Aufrufer erreichbar bleiben.
	return $fake_request;
}

1;
