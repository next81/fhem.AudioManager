use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use AudioManager::Supervisor;

{
	package Local::AudioManager::HealthBackend;

	# Erzeugt einen deterministischen Backend-Dummy fuer den Supervisorvertrag.
	sub new {
		return bless {
			check => {
				status => 'degraded',
				recoverable => 1,
				reason => 'refresh_required',
			},
			verify => { status => 'pending', reason => 'still waiting' },
			probe => { status => 'pending', reason => 'probe sent' },
			probes => 0,
			recoveries => 0,
		}, shift;
	}

	# Reicht neutrale Testsignale durch oder simuliert einen fehlerhaften Fremdadapter.
	sub health_event {
		my ($self, undef, $events) = @_;
		die "event failed\n" if $self->{event_error};
		return $events;
	}

	# Startet den im jeweiligen Test konfigurierten read-only Probe.
	sub health_probe {
		my ($self) = @_;
		++$self->{probes};
		return $self->{probe};
	}
	# Liefert das im jeweiligen Test konfigurierte Pruefergebnis.
	sub health_check {
		my ($self) = @_;
		return $self->{check};
	}

	# Zaehlt Recoveryaufrufe und liefert einen optionalen Backendfehler.
	sub health_recover {
		my ($self) = @_;
		++$self->{recoveries};
		return $self->{recover_error};
	}

	# Liefert die im jeweiligen Test konfigurierte Bestaetigung.
	sub health_verify {
		my ($self) = @_;
		return $self->{verify};
	}
}

subtest 'Debounce, Recovery und frische Bestaetigung bilden einen Lauf' => sub {
	my $now = 100;
	my $backend = Local::AudioManager::HealthBackend->new;
	my @changes;
	my $supervisor = AudioManager::Supervisor->new(
		backends => { home => $backend },
		clock => sub { return $now },
		debounce => 3,
		verify_timeout => 15,
		cooldown => 60,
		on_change => sub { push @changes, $_[1]{status} },
	);
	$supervisor->event('home', 'Player.A', [{ check => 1, reason => 'reconnected' }]);
	is($supervisor->report->{home}{status}, 'suspect', 'Reconnect plant eine Pruefung');
	is($supervisor->next_delay, 3, 'Pruefung wartet die Entprellung ab');
	$now += 2;
	$supervisor->tick;
	is($backend->{recoveries}, 0, 'vor Fristende wird nichts repariert');
	$supervisor->event('home', 'Player.A', [{ check => 1, reason => 'event_storm' }]);
	is($supervisor->next_delay, 3, 'weiteres Ereignis startet das Debouncefenster neu');
	$now += 3;
	$supervisor->tick;
	is($backend->{recoveries}, 1, 'Ereignissturm fuehrt zu genau einer Recovery');
	is($supervisor->report->{home}{status}, 'verifying', 'erfolgreicher Befehl wartet auf Bestaetigung');
	is($supervisor->report->{home}{recoveryCount}, 1, 'Recovery wird gezaehlt');
	$backend->{verify} = { status => 'healthy', reason => 'fresh_data' };
	$supervisor->event('home', 'Player.A', [{ activity => 1, reason => 'fresh_data' }]);
	is($supervisor->next_delay, 0, 'frische Daten werden sofort ausgewertet');
	$supervisor->tick;
	is($supervisor->report->{home}{status}, 'healthy', 'frische Daten bestaetigen die Recovery');
	$now += 1;
	$supervisor->event('home', 'Player.A', [{ check => 1, reason => 'duplicate_online' }]);
	is($supervisor->next_delay, 59, 'Cooldown begrenzt einen erneuten Recoverylauf');
	ok(grep($_ eq 'recovering', @changes), 'Statuscallback beobachtet die Recoveryphase');
};

subtest 'fehlende Bestaetigung degradiert am Sicherheitszeitpunkt' => sub {
	my $now = 200;
	my $backend = Local::AudioManager::HealthBackend->new;
	my $supervisor = AudioManager::Supervisor->new(
		backends => { home => $backend },
		clock => sub { return $now },
		debounce => 0,
		verify_timeout => 5,
		cooldown => 0,
	);
	$supervisor->event('home', 'Player.A', [{ check => 1, reason => 'reconnected' }]);
	$supervisor->tick;
	is($supervisor->report->{home}{status}, 'verifying', 'Recovery wartet ohne Polling auf ihre Frist');
	is($supervisor->next_delay, 5, 'nur der Sicherheitszeitpunkt bleibt geplant');
	$now += 5;
	$supervisor->tick;
	is($supervisor->report->{home}{status}, 'degraded', 'Timeout wird sichtbar degradiert');
	is($supervisor->report->{home}{reason}, 'health_verify_timeout', 'Timeoutgrund ist eindeutig');
	like($supervisor->report->{home}{lastError}, qr/still waiting/, 'Backendgrund bleibt diagnostizierbar');
	ok($supervisor->has_work, 'nach dem Timeout bleibt der naechste Langzeitprobe geplant');
	is($supervisor->next_delay, 900, 'degradierter Zustand wird erst zum Probeintervall erneut geprueft');
};

subtest 'Backend-Ausnahmen verlassen den FHEM-Eventloop kontrolliert' => sub {
	my $backend = Local::AudioManager::HealthBackend->new;
	$backend->{event_error} = 1;
	my $supervisor = AudioManager::Supervisor->new(backends => { home => $backend });
	like(
		$supervisor->event('home', 'Player.A', [{ check => 1 }]),
		qr/event failed/,
		'Adapterausnahme wird als normale Fehlermeldung geliefert',
	);
	is($supervisor->report->{home}{status}, 'degraded', 'Adapterausnahme degradiert nur das Backend');
	like($supervisor->report->{home}{lastError}, qr/event failed/, 'Fehler bleibt im Report erhalten');
};

subtest 'Zeitgrenzen werden auch am direkten Bibliotheksvertrag validiert' => sub {
	like(
		dies { AudioManager::Supervisor->new(backends => {}, debounce => -1) },
		qr/Debounce muss nichtnegativ/,
		'negativer Debounce wird direkt abgelehnt',
	);
	like(
		dies { AudioManager::Supervisor->new(backends => {}, verify_timeout => 0) },
		qr/Verify-Timeout muss positiv/,
		'leere Bestaetigungsfrist wird direkt abgelehnt',
	);
	my $supervisor = AudioManager::Supervisor->new(backends => {});
	like(
		dies { $supervisor->configure(cooldown => -0.5) },
		qr/Cooldown muss nichtnegativ/,
		'ungueltige Laufzeitkonfiguration wird abgelehnt',
	);
	like(
		dies { $supervisor->configure(probe_interval => 0) },
		qr/Probe-Intervall muss positiv/,
		'leeres Probeintervall wird direkt abgelehnt',
	);
};

subtest 'periodischer Probe bleibt read-only und zaehlt nicht als Recovery' => sub {
	my $now = 300;
	my $backend = Local::AudioManager::HealthBackend->new;
	my $supervisor = AudioManager::Supervisor->new(
		backends => { home => $backend },
		clock => sub { return $now },
		probe_interval => 10,
		verify_timeout => 5,
	);
	is($supervisor->next_delay, 10, 'erster Langzeitprobe ist exakt terminiert');
	$now += 10;
	$supervisor->tick;
	is($backend->{probes}, 1, 'faelliger Termin startet genau einen Backendprobe');
	is($supervisor->report->{home}{status}, 'verifying', 'asynchroner Probe wartet auf Daten');
	is($supervisor->report->{home}{recoveryCount}, 0, 'read-only Probe ist keine Recovery');
	$backend->{verify} = { status => 'healthy', reason => 'probe confirmed' };
	$supervisor->event('home', 'Player.A', [{ activity => 1, reason => 'fresh probe data' }]);
	$supervisor->tick;
	is($supervisor->report->{home}{status}, 'healthy', 'frische Daten bestaetigen den Probe');
	is($supervisor->next_delay, 10, 'naechster Probe verwendet wieder das Langzeitintervall');
};
done_testing;
