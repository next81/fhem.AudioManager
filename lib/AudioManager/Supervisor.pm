package AudioManager::Supervisor;

use strict;
use warnings;
use Carp qw(croak);
use List::Util qw(min max);

# Validiert die Zeitgrenzen auch fuer direkte Bibliotheksnutzer ausserhalb des FHEM-Moduls.
sub _validate_timing {
	my (undef, $debounce, $verify_timeout, $cooldown, $probe_interval) = @_;
	croak 'Debounce muss nichtnegativ sein' if $debounce < 0;
	croak 'Verify-Timeout muss positiv sein' if $verify_timeout <= 0;
	croak 'Cooldown muss nichtnegativ sein' if $cooldown < 0;
	croak 'Probe-Intervall muss positiv sein' if $probe_interval <= 0;
	return;
}

# Erzeugt einen backendneutralen Zustandsautomaten fuer Health-Probes,
# Recovery und die ausdrueckliche Bestaetigung durch frische Backenddaten.
sub new {
	my ($class, %arguments) = @_;
	my $backends = $arguments{backends} || {};
	croak 'Supervisor benoetigt eine Backend-Map' if ref($backends) ne 'HASH';
	my $debounce = defined($arguments{debounce}) ? 0 + $arguments{debounce} : 3;
	my $verify_timeout = defined($arguments{verify_timeout}) ? 0 + $arguments{verify_timeout} : 15;
	my $cooldown = defined($arguments{cooldown}) ? 0 + $arguments{cooldown} : 60;
	my $probe_interval = defined($arguments{probe_interval}) ? 0 + $arguments{probe_interval} : 900;
	$class->_validate_timing($debounce, $verify_timeout, $cooldown, $probe_interval);
	my $self = bless {
		backends => $backends,
		clock => $arguments{clock} || sub { time },
		on_change => $arguments{on_change},
		debounce => $debounce,
		verify_timeout => $verify_timeout,
		cooldown => $cooldown,
		probe_interval => $probe_interval,
		states => {},
	}, $class;

	# Jede Backendinstanz erhaelt einen unabhaengigen Healthzustand und Langzeittermin.
	for my $backend_id (sort keys %$backends) {
		$self->{states}{$backend_id} = {
			status => 'healthy',
			reason => 'none',
			updated_at => $self->_now,
			cooldown_until => 0,
			recovery_count => 0,
			last_recovery => undef,
			last_probe => undef,
			last_error => 'none',
			probe_due_at => $self->_now + $probe_interval,
		};
	}

	return $self;
}

# Liefert die injizierte monotone beziehungsweise FHEM-nahe Zeitquelle.
sub _now {
	my ($self) = @_;
	return $self->{clock}->();
}

# Aktualisiert Laufzeitgrenzen, ohne bereits laufende Bestaetigungsfristen umzudeuten.
sub configure {
	my ($self, %arguments) = @_;
	my $debounce = defined($arguments{debounce}) ? 0 + $arguments{debounce} : $self->{debounce};
	my $verify_timeout = defined($arguments{verify_timeout})
		? 0 + $arguments{verify_timeout} : $self->{verify_timeout};
	my $cooldown = defined($arguments{cooldown}) ? 0 + $arguments{cooldown} : $self->{cooldown};
	my $probe_interval = defined($arguments{probe_interval})
		? 0 + $arguments{probe_interval} : $self->{probe_interval};
	$self->_validate_timing($debounce, $verify_timeout, $cooldown, $probe_interval);
	$self->{debounce} = $debounce;
	$self->{verify_timeout} = $verify_timeout;
	$self->{cooldown} = $cooldown;

	# Ein geaendertes Intervall gilt ab jetzt und zieht keinen laufenden Probe um.
	if ($probe_interval != $self->{probe_interval}) {
		$self->{probe_interval} = $probe_interval;

		for my $state (values %{ $self->{states} }) {
			$state->{probe_due_at} = $self->_now + $probe_interval
				if $state->{status} ne 'verifying' && $state->{status} ne 'suspect';
		}

	}
	return undef;
}

# Meldet Statusaenderungen nur ueber den injizierten Callback und haelt die
# Kernbibliothek dadurch frei von FHEM-Readings oder Logfunktionen.
sub _changed {
	my ($self, $backend_id) = @_;
	my $callback = $self->{on_change};
	$callback->($backend_id, $self->{states}{$backend_id}) if ref($callback) eq 'CODE';
	return;
}

# Setzt einen sichtbaren Zustand mit fachlichem Grund und optionalem Fehler.
sub _transition {
	my ($self, $backend_id, $status, $reason, $error) = @_;
	my $state = $self->{states}{$backend_id};
	$state->{status} = $status;
	$state->{reason} = defined($reason) && $reason ne '' ? $reason : 'none';
	$state->{updated_at} = $self->_now;
	$state->{last_error} = $error if defined($error) && $error ne '';
	$self->_changed($backend_id);
	return;
}

# Plant den naechsten regelmaessigen Probe nach einem abgeschlossenen Healthlauf.
sub _schedule_probe {
	my ($self, $backend_id) = @_;
	$self->{states}{$backend_id}{probe_due_at} = $self->_now + $self->{probe_interval};
	return;
}

# Plant eine geordnete Pruefung und fasst Ereignisstuerme bis zum Ende von
# Debounce und Recovery-Sperrzeit zu genau einem Lauf zusammen.
sub request_check {
	my ($self, $backend_id, $reason) = @_;
	my $state = $self->{states}{$backend_id}
		or croak "Unbekanntes Supervisor-Backend: $backend_id";
	my $now = $self->_now;
	$state->{due_at} = max($now + $self->{debounce}, $state->{cooldown_until} || 0);
	$state->{due_kind} = 'check';
	$state->{verification_dirty} = 0;
	$self->_transition($backend_id, 'suspect', $reason);
	return undef;
}

# Plant einen read-only Probe unabhaengig von der Recovery-Sperrzeit.
sub request_probe {
	my ($self, $backend_id, $reason) = @_;
	my $state = $self->{states}{$backend_id}
		or croak "Unbekanntes Supervisor-Backend: $backend_id";
	$state->{due_at} = $self->_now + $self->{debounce};
	$state->{due_kind} = 'probe';
	$state->{verification_dirty} = 0;
	$self->_transition($backend_id, 'suspect', $reason || 'probe_requested');
	return undef;
}

# Normalisiert Adapterereignisse und laesst konkrete Eventnamen ausschliesslich
# im jeweiligen Backendadapter entstehen.
sub event {
	my ($self, $backend_id, $device, $events) = @_;
	my $backend = $self->{backends}{$backend_id}
		or croak "Unbekanntes Supervisor-Backend: $backend_id";
	my $signals = eval { $backend->health_event($device, $events || []) };

	# Fehlerhafte Fremdadapter degradieren sichtbar, ohne den FHEM-Eventloop abzubrechen.
	if ($@ || ref($signals) ne 'ARRAY') {
		my $error = $@ || 'health_event lieferte keine Signalliste';
		$error =~ s/[\r\n]+/ /g;
		$self->_schedule_probe($backend_id);
		$self->_transition($backend_id, 'degraded', 'health_event_failed', $error);
		return $error;
	}

	# Ein einzelnes FHEM-Notify darf Status, Aktivitaet und Probe-Bedarf gemeinsam melden.
	for my $signal (@$signals) {
		next if ref($signal) ne 'HASH';
		my $state = $self->{states}{$backend_id};
		$state->{verification_dirty} = 1
			if $signal->{activity} && $state->{status} eq 'verifying';

		if ($signal->{status} && $signal->{status} eq 'degraded') {
			delete $state->{due_at};
			delete $state->{due_kind};
			delete $state->{verify_deadline};
			delete $state->{verification_kind};
			$self->_schedule_probe($backend_id);
			$self->_transition(
				$backend_id, 'degraded', $signal->{reason} || 'backend_degraded',
			);
		}

		$self->request_probe($backend_id, $signal->{reason} || 'backend_event')
			if $signal->{probe};
		$self->request_check($backend_id, $signal->{reason} || 'backend_event')
			if $signal->{check};
	}

	return undef;
}

# Kapselt Adapteraufrufe, damit eine Ausnahme denselben sichtbaren Fehlerpfad
# wie eine regulaer zurueckgegebene Backendfehlermeldung verwendet.
sub _call {
	my ($self, $backend_id, $method, @arguments) = @_;
	my $backend = $self->{backends}{$backend_id};
	my $answer = eval { $backend->$method(@arguments) };
	my $error = $@;
	$error =~ s/[\r\n]+/ /g if $error;
	return ($answer, $error);
}

# Startet einen read-only Backendprobe und wartet bei asynchronen Adaptern auf
# deren ausdrueckliche Bestaetigung durch neue Daten.
sub _probe {
	my ($self, $backend_id) = @_;
	my $state = $self->{states}{$backend_id};
	my $started_at = $self->_now;
	my ($probe, $call_error) = $self->_call(
		$backend_id, 'health_probe', { requested_at => $started_at },
	);
	delete $state->{due_at};
	delete $state->{due_kind};
	delete $state->{probe_due_at};

	if ($call_error || ref($probe) ne 'HASH') {
		my $error = $call_error || 'health_probe lieferte kein Ergebnis';
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_probe_failed', $error);
	}

	# Synchrone Backends duerfen den Probe unmittelbar abschliessen.
	if (($probe->{status} || '') eq 'healthy') {
		$state->{last_probe} = $started_at;
		$state->{last_error} = 'none';
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'healthy', $probe->{reason} || 'probe_confirmed');
	}

	# Nur ein explizit ausstehender Adapterprobe eroeffnet eine Bestaetigungsphase.
	if (($probe->{status} || '') ne 'pending') {
		my $error = $probe->{error} || $probe->{reason} || 'Backendprobe konnte nicht gestartet werden';
		$state->{last_probe} = $started_at;
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', $probe->{reason} || 'probe_degraded', $error);
	}

	$state->{last_probe} = $started_at;
	$state->{verify_deadline} = $started_at + $self->{verify_timeout};
	$state->{verification_dirty} = 0;
	$state->{verification_kind} = 'probe';
	$state->{recovery_attempted} = 0;
	$self->_transition($backend_id, 'verifying', $probe->{reason} || 'probe_sent');
	return;
}

# Fuehrt nach der Entprellung die Adapterpruefung und hoechstens eine Recovery
# fuer diesen Vorfall aus.
sub _check {
	my ($self, $backend_id) = @_;
	my $state = $self->{states}{$backend_id};
	my ($check, $call_error) = $self->_call(
		$backend_id, 'health_check',
		{ reason => $state->{reason}, requested_at => $state->{updated_at} },
	);

	if ($call_error || ref($check) ne 'HASH') {
		my $error = $call_error || 'health_check lieferte kein Ergebnis';
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_check_failed', $error);
	}

	# Ein nach der Entprellung bereits gesunder Adapter benoetigt keinen Refresh.
	if (($check->{status} || '') eq 'healthy') {
		delete $state->{due_at};
		delete $state->{due_kind};
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'healthy', $check->{reason} || 'check_ok');
	}

	if (!$check->{recoverable}) {
		delete $state->{due_at};
		delete $state->{due_kind};
		my $error = $check->{error} || $check->{reason} || 'Backendzustand ist nicht reparierbar';
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_unrecoverable', $error);
	}

	$self->_transition($backend_id, 'recovering', $check->{reason} || 'recovery_required');
	my ($recovery_error, $recovery_exception) = $self->_call(
		$backend_id, 'health_recover', $check,
	);
	my $error = $recovery_exception || $recovery_error;

	if ($error) {
		delete $state->{due_at};
		delete $state->{due_kind};
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_recovery_failed', $error);
	}

	my $now = $self->_now;
	delete $state->{due_at};
	delete $state->{due_kind};
	$state->{verify_deadline} = $now + $self->{verify_timeout};
	$state->{verification_dirty} = 0;
	$state->{verification_kind} = 'recovery';
	$state->{recovery_attempted} = 1;
	$state->{cooldown_until} = $now + $self->{cooldown};
	$state->{last_recovery} = $now;
	++$state->{recovery_count};
	$self->_transition($backend_id, 'verifying', $check->{reason} || 'recovery_sent');
	return;
}

# Fuehrt nach einem fehlgeschlagenen Probe genau einen adaptereigenen
# Reparaturversuch aus und startet dessen neue Bestaetigungsfrist.
sub _recover_verification {
	my ($self, $backend_id, $verification) = @_;
	my $state = $self->{states}{$backend_id};

	# Innerhalb des Cooldowns bleibt der Probe-Fehler sichtbar statt Befehle zu wiederholen.
	if ($self->_now < ($state->{cooldown_until} || 0)) {
		my $error = $verification->{error} || $verification->{reason} || 'Recovery-Cooldown ist aktiv';
		delete $state->{verify_deadline};
		delete $state->{verification_kind};
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_recovery_cooldown', $error);
	}

	$self->_transition($backend_id, 'recovering', $verification->{reason} || 'recovery_required');
	my ($recovery_error, $recovery_exception) = $self->_call(
		$backend_id, 'health_recover', $verification,
	);
	my $error = $recovery_exception || $recovery_error;

	if ($error) {
		delete $state->{verify_deadline};
		delete $state->{verification_kind};
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_recovery_failed', $error);
	}

	my $now = $self->_now;
	$state->{verify_deadline} = $now + $self->{verify_timeout};
	$state->{verification_dirty} = 0;
	$state->{verification_kind} = 'recovery';
	$state->{recovery_attempted} = 1;
	$state->{cooldown_until} = $now + $self->{cooldown};
	$state->{last_recovery} = $now;
	++$state->{recovery_count};
	$self->_transition($backend_id, 'verifying', $verification->{reason} || 'recovery_sent');
	return;
}

# Wertet frische Adapterdaten aus und akzeptiert Probe oder Recovery niemals
# allein aufgrund eines erfolgreich gesendeten Befehls.
sub _verify {
	my ($self, $backend_id) = @_;
	my $state = $self->{states}{$backend_id};
	my ($verification, $call_error) = $self->_call(
		$backend_id, 'health_verify',
		{
			started_at => ($state->{verification_kind} || '') eq 'recovery'
				? $state->{last_recovery} : $state->{last_probe},
			deadline => $state->{verify_deadline},
			kind => $state->{verification_kind},
			recovery_attempted => $state->{recovery_attempted} ? 1 : 0,
		},
	);
	$state->{verification_dirty} = 0;

	if ($call_error || ref($verification) ne 'HASH') {
		my $error = $call_error || 'health_verify lieferte kein Ergebnis';
		delete $state->{verify_deadline};
		delete $state->{verification_kind};
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_verify_failed', $error);
	}

	if (($verification->{status} || '') eq 'healthy') {
		delete $state->{verify_deadline};
		delete $state->{verification_kind};
		$state->{last_error} = 'none';
		$self->_schedule_probe($backend_id);
		return $self->_transition(
			$backend_id, 'healthy', $verification->{reason} || 'recovery_confirmed',
		);
	}

	if (($verification->{status} || '') eq 'degraded') {
		return $self->_recover_verification($backend_id, $verification)
			if $verification->{recoverable} && !$state->{recovery_attempted};
		delete $state->{verify_deadline};
		delete $state->{verification_kind};
		my $error = $verification->{error} || $verification->{reason} || 'Recovery blieb ohne Wirkung';
		$self->_schedule_probe($backend_id);
		return $self->_transition($backend_id, 'degraded', 'health_verify_failed', $error);
	}

	# Fehlende Ereignisse werden erst an der Frist zum Fehler oder Recoverygrund.
	if ($self->_now >= ($state->{verify_deadline} || 0)) {
		return $self->_recover_verification($backend_id, $verification)
			if $verification->{recoverable} && !$state->{recovery_attempted};
		delete $state->{verify_deadline};
		delete $state->{verification_kind};
		$self->_schedule_probe($backend_id);
		return $self->_transition(
			$backend_id, 'degraded', 'health_verify_timeout',
			$verification->{reason} || 'Keine frischen Backenddaten nach Healthbefehl',
		);
	}

	return;
}

# Verarbeitet alle faelligen Pruefungen, Probes und Bestaetigungen ohne blockierendes Warten.
sub tick {
	my ($self) = @_;
	my $now = $self->_now;

	for my $backend_id (sort keys %{ $self->{states} }) {
		my $state = $self->{states}{$backend_id};

		if ($state->{status} eq 'suspect' && $now >= ($state->{due_at} || 0)) {
			($state->{due_kind} || '') eq 'probe'
				? $self->_probe($backend_id) : $self->_check($backend_id);
			$state = $self->{states}{$backend_id};
		}

		# Gesunde und degradierte Backends bleiben mit einem einzelnen Langzeittimer ueberwacht.
		if (($state->{status} eq 'healthy' || $state->{status} eq 'degraded')
			&& $now >= ($state->{probe_due_at} || 0)) {
			$self->_probe($backend_id);
			$state = $self->{states}{$backend_id};
		}

		if ($state->{status} eq 'verifying'
			&& ($state->{verification_dirty} || $now >= ($state->{verify_deadline} || 0))) {
			$self->_verify($backend_id);
		}
	}

	return;
}

# Meldet Zustaende mit einem zukuenftigen Health- oder Supervisorfortschritt als Arbeit.
sub has_work {
	my ($self) = @_;

	for my $state (values %{ $self->{states} }) {
		return 1 if $state->{status} eq 'suspect' || $state->{status} eq 'verifying';
		return 1 if defined($state->{probe_due_at});
	}

	return 0;
}

# Liefert den naechsten erforderlichen Tick; zwischen den Probes bleibt kein Kurzzeittimer aktiv.
sub next_delay {
	my ($self) = @_;
	my $now = $self->_now;
	my @due;

	for my $state (values %{ $self->{states} }) {
		push @due, $state->{due_at} if $state->{status} eq 'suspect';
		push @due, $state->{probe_due_at}
			if ($state->{status} eq 'healthy' || $state->{status} eq 'degraded')
			&& defined($state->{probe_due_at});

		if ($state->{status} eq 'verifying') {
			return 0 if $state->{verification_dirty};
			push @due, $state->{verify_deadline};
		}
	}

	return undef if !@due;
	return max(0, min(@due) - $now);
}

# Liefert eine von internen Fristen getrennte Diagnosekopie fuer Readings und Get.
sub report {
	my ($self) = @_;
	my %report;

	for my $backend_id (sort keys %{ $self->{states} }) {
		my $state = $self->{states}{$backend_id};
		my $details = eval { $self->{backends}{$backend_id}->health_details };
		$details = {} if $@ || ref($details) ne 'HASH';
		$report{$backend_id} = {
			status => $state->{status},
			reason => $state->{reason},
			updatedAt => $state->{updated_at},
			recoveryCount => $state->{recovery_count},
			lastRecovery => $state->{last_recovery},
			lastProbe => $state->{last_probe},
			lastError => $state->{last_error},
			details => $details,
		};
	}

	return \%report;
}

1;
