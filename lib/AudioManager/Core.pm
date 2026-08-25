package AudioManager::Core;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(looks_like_number);

my %DEFAULT_PRIORITIES = (
	alarm => 400,
	speak => 300,
	play => 200,
	queue => 100,
	stream => 50,
);
my %KNOWN_TYPE = map { $_ => 1 } keys %DEFAULT_PRIORITIES;
my %TERMINAL_STATE = map { $_ => 1 } qw(completed failed cancelled replaced deduplicated);

# Erzeugt den reinen, FHEM-unabhaengigen Scheduler. Alle Seiteneffekte werden
# ueber Callbacks injiziert und bleiben dadurch vollstaendig testbar.
sub new {
	my ($class, %arguments) = @_;
	my $self = bless {
		clock => $arguments{clock} || sub { time },
		callbacks => $arguments{callbacks} || {},
		priorities => { %DEFAULT_PRIORITIES },
		dedupe_window => defined($arguments{dedupe_window}) ? $arguments{dedupe_window} : 5,
		history_limit => $arguments{history_limit} || 100,
		sequence => 0,
		requests => {},
		order => [],
		dedupe => {},
		dispatching => 0,
	}, $class;
	$self->configure_priorities($arguments{priorities}) if $arguments{priorities};
	return $self;
}

# Liefert eine Kopie der Standardprioritaeten fuer Attributparser und Dokumentation.
sub default_priorities {
	return { %DEFAULT_PRIORITIES };
}

# Vereinheitlicht Sprachtext nur fuer den Duplikatvergleich; der Originaltext
# am Auftrag und damit Aussprache sowie Satzmelodie bleiben unangetastet.
sub normalize_speech {
	my ($class, $text) = @_;
	$text = '' if !defined $text;
	$text =~ s/^\s+|\s+$//g;
	$text =~ s/\s+/ /g;
	$text =~ s/[.!?]+$//;
	return lc $text;
}

# Validiert und uebernimmt partielle Prioritaetswerte, waehrend nicht genannte
# Klassen ihren definierten Standard behalten.
sub configure_priorities {
	my ($self, $overrides) = @_;
	croak 'Prioritaeten muessen als Hash uebergeben werden' if ref($overrides) ne 'HASH';
	my %configured = %DEFAULT_PRIORITIES;

	# Jede bekannte Klasse darf genau einen nichtnegativen ganzzahligen Rang erhalten.
	for my $type (keys %$overrides) {
		croak "Unbekannte Audioart: $type" if !$KNOWN_TYPE{$type};
		my $value = $overrides->{$type};
		croak "Ungueltige Prioritaet fuer $type" if !defined($value) || $value !~ /^\d+$/;
		$configured{$type} = 0 + $value;
	}

	$self->{priorities} = \%configured;
	return { %configured };
}

# Aendert das Laufzeitfenster fuer gleiche Sprachtexte ohne vorhandene
# Zeitstempel nachtraeglich zu verschieben.
sub set_dedupe_window {
	my ($self, $seconds) = @_;
	croak 'speakDedupeWindow muss eine nichtnegative Zahl sein'
		if !defined($seconds) || !looks_like_number($seconds) || $seconds < 0;
	$self->{dedupe_window} = 0 + $seconds;
	$self->_prune_dedupe;
	return $self->{dedupe_window};
}

# Liefert den aktuell wirksamen Rang einer Audioart.
sub priority_for {
	my ($self, $type) = @_;
	return $self->{priorities}{$type};
}

# Vergibt eine monotone Request-ID, die auch bei mehreren Auftraegen innerhalb
# derselben Sekunde eindeutig und in Logs zeitlich lesbar bleibt.
sub _next_id {
	my ($self) = @_;
	my $sequence = ++$self->{sequence};
	return sprintf('audio-%010d-%06d', int($self->{clock}->()), $sequence);
}

# Prueft, ob zwei Auftraege mindestens einen physischen Player gemeinsam nutzen.
sub _overlaps {
	my ($left, $right) = @_;
	my %left = map { $_ => 1 } @{ $left->{targets} || [] };

	# Bereits der erste gemeinsame Player reicht fuer einen Ressourcenkonflikt.
	for my $target (@{ $right->{targets} || [] }) {
		return 1 if $left{$target};
	}

	return 0;
}

# Benachrichtigt den Adapter ueber Zustandswechsel, ohne die Schedulerlogik an
# Readings, Logging oder eine konkrete Benutzeroberflaeche zu koppeln.
sub _changed {
	my ($self, $request, $previous) = @_;
	my $callback = $self->{callbacks}{on_change};
	$callback->($request, $previous) if ref($callback) eq 'CODE';
	return;
}

# Setzt einen Zustand atomar und protokolliert seinen Zeitpunkt im Auftrag.
sub _transition {
	my ($self, $request, $state, $reason) = @_;
	my $previous = $request->{state};
	$request->{state} = $state;
	$request->{updated_at} = $self->{clock}->();
	$request->{reason} = $reason if defined $reason;
	push @{ $request->{transitions} }, {
		from => $previous,
		to => $state,
		at => $request->{updated_at},
	};
	$self->_changed($request, $previous);
	return;
}

# Entfernt abgelaufene Textschluessel; verworfene Duplikate erneuern deren
# Zeitstempel bewusst nicht und koennen die Sperrfrist daher nicht verlaengern.
sub _prune_dedupe {
	my ($self) = @_;
	my $window = $self->{dedupe_window};

	# Ein deaktivierter Filter benoetigt keinerlei gespeicherte Vergleichswerte.
	if (!$window) {
		$self->{dedupe} = {};
		return;
	}

	my $minimum = $self->{clock}->() - $window;

	# Nur noch wirksame Originalauftraege bleiben im kleinen Laufzeitcache.
	for my $key (keys %{ $self->{dedupe} }) {
		delete $self->{dedupe}{$key} if $self->{dedupe}{$key}{at} < $minimum;
	}

	return;
}

# Begrenzt ausschliesslich bereits abgeschlossene Historie; aktive und wartende
# Auftraege duerfen niemals wegen einer Anzeigegrenze verloren gehen.
sub _prune_history {
	my ($self) = @_;
	my @terminal = grep { $TERMINAL_STATE{ $self->{requests}{$_}{state} || '' } } @{ $self->{order} };
	my $excess = @terminal - $self->{history_limit};
	return if $excess <= 0;
	my %remove = map { $terminal[$_] => 1 } 0 .. $excess - 1;

	# Request-Hash und Reihenfolge werden gemeinsam bereinigt, damit keine
	# verwaisten IDs in Statusausgaben verbleiben.
	for my $id (keys %remove) {
		delete $self->{requests}{$id};
	}

	$self->{order} = [ grep { !$remove{$_} } @{ $self->{order} } ];
	return;
}

# Nimmt einen Audioauftrag an. Vorbereitete Quellen werden sofort geplant,
# waehrend TTS-Auftraege bis zur spaeteren URI-Freigabe im Zustand preparing bleiben.
sub submit {
	my ($self, %arguments) = @_;
	my $type = $arguments{type} // '';
	croak "Unbekannte Audioart: $type" if !$KNOWN_TYPE{$type};
	my @targets = @{ $arguments{targets} || [] };
	croak 'Mindestens ein Audioziel ist erforderlich' if !@targets;
	my %seen;
	@targets = grep { defined($_) && $_ ne '' && !$seen{$_}++ } @targets;
	croak 'Mindestens ein gueltiges Audioziel ist erforderlich' if !@targets;
	my $payload = ref($arguments{payload}) eq 'HASH' ? { %{ $arguments{payload} } } : {};
	my $now = $self->{clock}->();
	my $id = $self->_next_id;
	my $request = {
		id => $id,
		sequence => $self->{sequence},
		type => $type,
		priority => $self->{priorities}{$type},
		targets => \@targets,
		payload => $payload,
		backend_targets => $arguments{backend_targets} || {},
		play_targets => $arguments{play_targets} || \@targets,
		state => $arguments{deferred} ? 'preparing' : 'queued',
		created_at => $now,
		updated_at => $now,
		transitions => [],
	};
	$self->{requests}{$id} = $request;
	push @{ $self->{order} }, $id;

	# Nur Sprachtexte erhalten den konfigurierten Inhaltsfilter; Sounds und
	# Alarme benoetigen fuer eine Deduplizierung einen expliziten Aufrufer-Schluessel.
	if ($type eq 'speak' && $self->{dedupe_window} > 0 && !$payload->{force}) {
		$self->_prune_dedupe;
		my $key = __PACKAGE__->normalize_speech($payload->{text});

		# Leere Texte werden spaeter fachlich abgelehnt und duerfen nicht alle
		# folgenden fehlerhaften Aufrufe unter demselben leeren Schluessel sammeln.
		if ($key ne '' && $self->{dedupe}{$key}) {
			$request->{coalesced_into} = $self->{dedupe}{$key}{id};
			$self->_transition($request, 'deduplicated', 'identischer Sprachtext im Zeitfenster');
			$self->_prune_history;
			return $request;
		}
		$self->{dedupe}{$key} = { at => $now, id => $id } if $key ne '';
	}

	# Dauerhafte Quellen vertreten einen Sollzustand. Ein neuer Auftrag derselben
	# Art ersetzt deshalb aeltere, ueberlappende Sollzustaende statt sie aufzustauen.
	$self->_replace_persistent($request) if $type eq 'stream' || $type eq 'queue';
	$self->_changed($request, undef);
	$self->_dispatch if $request->{state} eq 'queued';
	$self->_prune_history;
	return $request;
}

# Ersetzt nur dieselbe dauerhafte Quellenart auf ueberlappenden Playern; eine
# Queue darf einen Stream weiterhin regulaer gemaess Prioritaet unterbrechen.
sub _replace_persistent {
	my ($self, $new_request) = @_;

	# Aeltere passende Sollzustaende werden geordnet beendet und nicht fortgesetzt.
	for my $id (@{ $self->{order} }) {
		my $request = $self->{requests}{$id};
		next if !$request || $request == $new_request || $request->{type} ne $new_request->{type};
		next if $TERMINAL_STATE{ $request->{state} || '' } || !_overlaps($request, $new_request);
		$self->_invoke('on_stop', $request) if _requires_cleanup($request);
		$self->_transition($request, 'replaced', "ersetzt durch $new_request->{id}");
	}

	return;
}

# Bereits gestartete und danach pausierte Auftraege koennen weiterhin
# backendseitige Ressourcen wie eine selbst aufgebaute Media-Queue besitzen.
sub _requires_cleanup {
	my ($request) = @_;
	my $state = $request->{state} || '';
	return $state eq 'active' || $state eq 'suspended' ? 1 : 0;
}

# Gibt einen vorbereiteten Auftrag fuer die eigentliche Wiedergabe frei und
# fuegt dabei Renderergebnisse wie die erzeugte TTS-URI zum Payload hinzu.
sub ready {
	my ($self, $id, %payload) = @_;
	my $request = $self->{requests}{$id} or return "Unbekannter Request: $id";
	return "Request $id ist nicht in Vorbereitung" if $request->{state} ne 'preparing';
	$request->{payload} = { %{ $request->{payload} }, %payload };
	$self->_transition($request, 'queued');
	$self->_dispatch;
	return undef;
}

# Ruft einen optionalen Seiteneffekt auf und normalisiert Exceptions zu einer
# sichtbaren Fehlermeldung, damit der Eventloop weiterarbeiten kann.
sub _invoke {
	my ($self, $name, @arguments) = @_;
	my $callback = $self->{callbacks}{$name};
	return undef if ref($callback) ne 'CODE';
	my ($answer, $ok);
	$ok = eval {
		$answer = $callback->(@arguments);
		1;
	};
	return $ok ? $answer : ($@ || "$name ist fehlgeschlagen");
}

# Liefert planbare Auftraege in stabiler Reihenfolge: zuerst Prioritaet, danach FIFO.
sub _candidates {
	my ($self) = @_;
	return sort {
		$b->{priority} <=> $a->{priority} || $a->{sequence} <=> $b->{sequence}
	} grep {
		($_->{state} || '') eq 'queued' || ($_->{state} || '') eq 'suspended'
	} values %{ $self->{requests} };
}

# Liefert alle aktuell aktiven Auftraege, die dieselben physischen Player belegen.
sub _active_conflicts {
	my ($self, $candidate) = @_;
	return grep {
		($_->{state} || '') eq 'active' && _overlaps($_, $candidate)
	} values %{ $self->{requests} };
}

# Verhindert die kurzzeitige Wiederaufnahme einer niedrigen Quelle, solange eine
# bereits angenommene hoehere TTS-Ansage fuer dasselbe Ziel noch erzeugt wird.
sub _blocked_by_preparation {
	my ($self, $candidate) = @_;

	# Nur tatsaechlich hoehere Vorbereitungen duerfen einen planbaren Auftrag blockieren.
	for my $request (values %{ $self->{requests} }) {
		next if ($request->{state} || '') ne 'preparing';
		return 1 if $request->{priority} > $candidate->{priority} && _overlaps($request, $candidate);
	}

	return 0;
}

# Plant so viele voneinander unabhaengige Auftraege wie moeglich. Der Guard
# verhindert rekursive Dispatchlaeufe durch synchrone Adapter-Callbacks.
sub _dispatch {
	my ($self) = @_;
	return if $self->{dispatching};
	local $self->{dispatching} = 1;
	my $progress = 1;

	# Nach jedem Start wird neu sortiert, weil eine Suspendierung weitere
	# unabhaengige Kandidaten freigeben kann.
	while ($progress) {
		$progress = 0;

		# Kandidaten mit belegten hoeher- oder gleichprioren Zielen bleiben stehen;
		# disjunkte Kandidaten dahinter duerfen trotzdem parallel beginnen.
		for my $candidate ($self->_candidates) {
			next if $self->_blocked_by_preparation($candidate);
			my @conflicts = $self->_active_conflicts($candidate);
			next if grep { $_->{priority} >= $candidate->{priority} } @conflicts;
			my $failed;

			# Alle niedriger priorisierten Konflikte werden vor dem neuen Start
			# gesichert und in den gemeinsamen Wiederaufnahmepool verschoben.
			for my $active (@conflicts) {
				my $error = $self->_invoke('on_suspend', $active, $candidate);

				# Ohne bestaetigte Pause darf der neue Auftrag die physische Ressource
				# nicht ebenfalls verwenden und dadurch zwei Quellen vermischen.
				if ($error) {
					$self->_transition($candidate, 'failed', "Unterbrechung fehlgeschlagen: $error");
					$failed = 1;
					last;
				}
				$self->_transition($active, 'suspended', "unterbrochen durch $candidate->{id}");
			}

			if ($failed) {
				$progress = 1;
				last;
			}

			my $callback = $candidate->{state} eq 'suspended' ? 'on_resume' : 'on_start';
			my $error = $self->_invoke($callback, $candidate);

			# Adapterfehler beenden nur den betroffenen Auftrag; danach darf der
			# Scheduler die zuvor pausierte Quelle wieder aufnehmen.
			if ($error) {
				$self->_transition($candidate, 'failed', $error);
			} else {
				$self->_transition($candidate, 'active');
			}
			$progress = 1;
			last;
		}

	}

	return;
}

# Beendet einen natuerlich ausgelaufenen Auftrag und gibt danach dessen Ziele
# fuer wartende oder pausierte Quellen frei.
sub complete {
	my ($self, $id) = @_;
	my $request = $self->{requests}{$id} or return "Unbekannter Request: $id";
	return undef if $TERMINAL_STATE{ $request->{state} || '' };
	return "Request $id ist nicht aktiv" if $request->{state} ne 'active';
	my $error = $self->_invoke('on_complete', $request);
	$self->_transition($request, $error ? 'failed' : 'completed', $error);
	$self->_dispatch;
	$self->_prune_history;
	return $error;
}

# Markiert einen Auftrag nach Renderer-, Timeout- oder Backendfehlern terminal
# und setzt die verbleibende Hierarchie anschliessend kontrolliert fort.
sub fail {
	my ($self, $id, $reason) = @_;
	my $request = $self->{requests}{$id} or return "Unbekannter Request: $id";
	return undef if $TERMINAL_STATE{ $request->{state} || '' };
	$self->_invoke('on_stop', $request) if _requires_cleanup($request);
	$self->_transition($request, 'failed', $reason || 'unbekannter Fehler');
	$self->_dispatch;
	$self->_prune_history;
	return undef;
}

# Bricht einen einzelnen Auftrag unabhaengig von seinem aktuellen nichtterminalen
# Zustand ab und startet anschliessend die naechste erlaubte Quelle.
sub cancel {
	my ($self, $id, $reason) = @_;
	my $request = $self->{requests}{$id} or return "Unbekannter Request: $id";
	return undef if $TERMINAL_STATE{ $request->{state} || '' };
	my $error = $self->_invoke('on_stop', $request) if _requires_cleanup($request);
	$self->_transition($request, $error ? 'failed' : 'cancelled', $error || $reason || 'abgebrochen');
	$self->_dispatch;
	$self->_prune_history;
	return $error;
}

# Bricht alle oder nach Typ und Ziel gefilterte Auftraege ab. Die eigentliche
# Wiederaufnahme erfolgt erst nach dem kompletten Batch und vermeidet Zwischenstarts.
sub cancel_matching {
	my ($self, %filter) = @_;
	my @matches = grep {
		my $request = $_;
		!$TERMINAL_STATE{ $request->{state} || '' }
			&& (!defined($filter{type}) || $request->{type} eq $filter{type})
			&& (!defined($filter{targets}) || _overlaps($request, { targets => $filter{targets} }))
	} values %{ $self->{requests} };
	local $self->{dispatching} = 1;

	# Hoeher priorisierte aktive Ausgaben werden zuerst gestoppt, damit kein
	# darunterliegender Zustand vorzeitig wieder anlaufen kann.
	for my $request (sort { $b->{priority} <=> $a->{priority} } @matches) {
		my $error = $self->_invoke('on_stop', $request) if _requires_cleanup($request);
		$self->_transition($request, $error ? 'failed' : 'cancelled', $error || 'abgebrochen');
	}

	$self->{dispatching} = 0;
	$self->_dispatch;
	$self->_prune_history;
	return scalar @matches;
}

# Liefert einen Auftrag als unveraenderte Laufzeitreferenz fuer den FHEM-Adapter.
sub request {
	my ($self, $id) = @_;
	return $self->{requests}{$id};
}

# Liefert alle Auftraege in ihrer stabilen Annahmereihenfolge.
sub requests {
	my ($self) = @_;
	return [ map { $self->{requests}{$_} } grep { $self->{requests}{$_} } @{ $self->{order} } ];
}

# Liefert nur gerade aktive Auftraege fuer Backend-Polling und Statusreadings.
sub active_requests {
	my ($self) = @_;
	return [ grep { ($_->{state} || '') eq 'active' } @{ $self->requests } ];
}

# Zaehlt die relevanten Schedulerzustaende fuer kompakte FHEM-Readings.
sub counts {
	my ($self) = @_;
	my %counts = map { $_ => 0 } qw(active preparing queued suspended terminal);

	# Terminalzustaende werden zusammengefasst, alle laufenden Zustaende bleiben einzeln sichtbar.
	for my $request (@{ $self->requests }) {
		my $state = $request->{state} || '';
		if ($TERMINAL_STATE{$state}) {
			++$counts{terminal};
		} elsif (exists $counts{$state}) {
			++$counts{$state};
		}
	}

	return \%counts;
}

# Meldet, ob ein Player noch von einem planbaren oder aktiven Managerauftrag
# belegt wird; reine TTS-Vorbereitung beansprucht den Ausgang noch nicht.
sub target_is_owned {
	my ($self, $target) = @_;

	# Erst ein vorbereiteter, wartender, pausierter oder aktiver Auftrag haelt
	# den physischen Sitzungs-Snapshot des Players offen.
	for my $request (@{ $self->requests }) {
		next if ($request->{state} || '') eq 'preparing' || $TERMINAL_STATE{ $request->{state} || '' };
		return 1 if grep { $_ eq $target } @{ $request->{targets} };
	}

	return 0;
}

1;
