use strict;
use warnings;
use Test2::V0;
use JSON::PP ();
use lib 'lib';
use AudioManager::Backend;
use AudioManager::Backend::Sonos2mqtt;
use AudioManager::FHEMGateway;

my (%devices, %attributes, %reading_timestamps, @commands, @publishes, $now);

# Loest den von sonos2mqtt verwendeten sichtbaren Namen zum FHEM-Testdevice auf.
sub device_by_sonos_name {
	my ($sonos_name) = @_;

	# Der echte Dienst adressiert den Ziel-Coordinator ueber dessen name-Reading.
	for my $device (sort keys %devices) {
		return $device if ($devices{$device}{READINGS}{name} // '') eq $sonos_name;
	}

	return undef;
}

# Erzeugt ein injiziertes Gateway mit direkt aktualisierten Testreadings.
sub gateway {
	return AudioManager::FHEMGateway->new(
		device => sub { return $devices{ $_[0] } },
		device_names => sub { return [ sort keys %devices ] },
		attr_value => sub { return $attributes{ $_[0] }{ $_[1] } // $_[2] },
		reading_value => sub { return $devices{ $_[0] }{READINGS}{ $_[1] } // $_[2] },
		reading_timestamp => sub { return $reading_timestamps{ $_[0] }{ $_[1] } // $_[2] },
		now => sub { return $now },
		mqtt_publish => sub {
			my ($device, $topic, $payload) = @_;
			push @publishes, join(' ', grep { defined($_) && $_ ne '' } $device, $topic, $payload);
			return undef;
		},
		command_set => sub {
			my ($definition) = @_;
			push @commands, $definition;
			my ($device, $command, $value) = split /\s+/, $definition, 3;
			# Rohbefehle aktualisieren dieselben Readingwerte wie direkte Setter.
			if ($command eq 'x_raw_payload') {
				my $payload = JSON::PP::decode_json($value);
				my $raw_command = $payload->{command} // '';
				my $input = $payload->{input};

				# Nur die fuer den Adapterablauf relevanten Befehle werden simuliert.
				if ($raw_command eq 'joingroup') {
					my $coordinator = device_by_sonos_name($input);
					return "Unknown coordinator $input" if !defined($coordinator);
					$devices{$device}{READINGS}{coordinatorUuid} = $devices{$coordinator}{READINGS}{uuid};
				} elsif ($raw_command eq 'leavegroup') {
					$devices{$device}{READINGS}{coordinatorUuid} = $devices{$device}{READINGS}{uuid};
				} elsif ($raw_command eq 'volume') {
					$devices{$device}{READINGS}{volume} = $input;
				} elsif ($raw_command eq 'mute' || $raw_command eq 'unmute') {
					$devices{$device}{READINGS}{mute} = $raw_command eq 'mute' ? 'true' : 'false';
				} elsif ($raw_command eq 'setavtransporturi') {
					$devices{$device}{READINGS}{currentTrack_TrackUri} = $input;
				} elsif ($raw_command eq 'switchtoqueue') {
					$devices{$device}{READINGS}{Input} = 'Queue';
				} elsif ($raw_command eq 'playmode') {
					$devices{$device}{READINGS}{playmode} = $input;
				} elsif ($raw_command eq 'selecttrack') {
					$devices{$device}{READINGS}{currentTrack_TrackNumber} = $input;
				} elsif ($raw_command eq 'play') {
					$devices{$device}{READINGS}{transportState} = 'PLAYING';
				} elsif ($raw_command eq 'pause') {
					$devices{$device}{READINGS}{transportState} = 'PAUSED_PLAYBACK';
				} elsif ($raw_command eq 'stop') {
					$devices{$device}{READINGS}{transportState} = 'STOPPED';
				}

				return undef;
			}
			if ($command eq 'leaveGroup') {
				$devices{$device}{READINGS}{coordinatorUuid} = $devices{$device}{READINGS}{uuid};
			} elsif ($command eq 'joinGroup') {
				my $coordinator = device_by_sonos_name($value);
				return "Unknown coordinator $value" if !defined($coordinator);
				$devices{$device}{READINGS}{coordinatorUuid} = $devices{$coordinator}{READINGS}{uuid};
			} elsif ($command eq 'volume' || $command eq 'mute') {
				$devices{$device}{READINGS}{$command} = $value;
			} elsif ($command eq 'volumeUp' || $command eq 'volumeDown') {
				my $current = 0 + ($devices{$device}{READINGS}{volume} || 0);
				my $next = $command eq 'volumeUp' ? $current + 1 : $current - 1;
				$next = 100 if $next > 100;
				$next = 0 if $next < 0;
				$devices{$device}{READINGS}{volume} = $next;
			} elsif ($command eq 'playUri') {
				$devices{$device}{READINGS}{currentTrack_TrackUri} = $value;
				$devices{$device}{READINGS}{transportState} = 'PLAYING';
			} elsif ($command eq 'input') {
				$devices{$device}{READINGS}{Input} = $value;
			} elsif ($command eq 'play') {
				$devices{$device}{READINGS}{transportState} = 'PLAYING';
			} elsif ($command eq 'pause') {
				$devices{$device}{READINGS}{transportState} = 'PAUSED_PLAYBACK';
			} elsif ($command eq 'stop') {
				$devices{$device}{READINGS}{transportState} = 'STOPPED';
			}
			return undef;
		},
	);
}

# Setzt Player, Attribute und Befehlsprotokoll fuer einen Subtest zurueck.
sub reset_backend_env {
	%devices = ();
	%attributes = ();
	%reading_timestamps = ();
	@commands = ();
	@publishes = ();
	$now = 10_000;
}

# Legt einen Speaker mit flachen Readingwerten fuer das injizierte Gateway an.
sub speaker {
	my ($name, $uuid, $coordinator, %extra) = @_;
	$devices{$name} = {
		NAME => $name,
		TYPE => 'MQTT2_DEVICE',
		IODev => 'MQTT',
		READINGS => {
			name => $extra{name} // $name,
			uuid => $uuid,
			coordinatorUuid => $coordinator || $uuid,
			transportState => $extra{transportState} || 'STOPPED',
			currentTrack_TrackUri => $extra{uri} || '',
			currentTrack_title => $extra{title} || '',
			currentTrack_Title => $extra{legacyTitle} || '',
			currentTrack_artist => $extra{artist} || '',
			currentTrack_Artist => $extra{legacyArtist} || '',
			currentTrack_album => $extra{album} || '',
			currentTrack_Album => $extra{legacyAlbum} || '',
			currentTrack_albumArtUri => $extra{albumArtUri} || '',
			currentTrack_AlbumArtUri => $extra{legacyAlbumArtUri} || '',
			Input => $extra{Input} || '',
			volume => defined($extra{volume}) ? $extra{volume} : 10,
			mute => $extra{mute} || 'false',
			playmode => 'NORMAL',
			deviceWatcherStatus => $extra{deviceWatcherStatus} // 'online',
			ts => $extra{ts} // 'initial',
			IPAddress => $extra{IPAddress} // '192.168.1.10',
		},
	};
	$attributes{$name}{model} = 'sonos2mqtt_speaker';
	$attributes{$name}{setList} = $extra{setList} // join("\n",
		'playUri:textField', 'playFav:textField', 'joinGroup:textField', 'leaveGroup:noArg',
		'mute:true,false', 'volume:slider', 'volumeUp:noArg', 'volumeDown:noArg',
		'input:Queue', 'play:noArg', 'pause:noArg', 'previous:noArg', 'next:noArg',
		'stop:noArg', 'x_raw_payload:textField',
	);
	$attributes{$name}{readingList} = $extra{readingList} if exists $extra{readingList};
	$reading_timestamps{$name}{IPAddress} = 'initial';
}

subtest 'Bridge ist weder erforderlich noch als Player erlaubt' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	$devices{'Sonos.Bridge'} = { NAME => 'Sonos.Bridge', READINGS => {} };
	$attributes{'Sonos.Bridge'}{model} = 'sonos2mqtt_bridge';
	my $valid = AudioManager::Backend->create('sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway());
	is($valid->validate, undef, 'Speakerbackend funktioniert ohne Bridgebindung');
	my $invalid = AudioManager::Backend->create('sonos2mqtt', id => 'bad', players => ['Sonos.Bridge'], gateway => gateway());
	like($invalid->validate, qr/kein sonos2mqtt_speaker/, 'Bridge wird als Player abgelehnt');
};

subtest 'Topologie verwendet UUIDs und Zielgruppen bleiben verwaltet' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	speaker('Sonos.B', 'uuid-b', 'uuid-a');
	speaker('Sonos.C', 'uuid-c');
	my $backend = AudioManager::Backend->create('sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway());
	my $topology = $backend->topology;
	is($topology->{players}{'Sonos.B'}{coordinator}, 'Sonos.A', 'Coordinator wird ueber UUID aufgeloest');
	my ($targets, $error) = $backend->resolve_target('group:Sonos.B');
	is($error, undef, 'Gruppenziel wird aufgeloest');
	is($targets, [qw(Sonos.A Sonos.B)], 'nur verwaltete Gruppenmitglieder werden geliefert');
	like(($backend->resolve_target('player:Sonos.C'))[1], qr/nicht verwaltet/, 'fremder Speaker bleibt ausserhalb der Grenze');
};

subtest 'bestehende Gruppe spielt immer ueber ihren wirklichen Coordinator' => sub {
	reset_backend_env();
	speaker('Sonos.AChild', 'uuid-child', 'uuid-master');
	speaker('Sonos.ZMaster', 'uuid-master');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.AChild Sonos.ZMaster)], gateway => gateway(),
	);
	my ($targets, $target_error) = $backend->resolve_target('group:Sonos.AChild');
	is($target_error, undef, 'Gruppe wird ueber ein Child als Anker aufgeloest');
	is($targets, [qw(Sonos.AChild Sonos.ZMaster)], 'alphabetische Zielreihenfolge beginnt absichtlich mit dem Child');
	my $request = {
		type => 'play',
		payload => { uri => 'clip.mp3', volume => 20, volume_policy => 'fixed' },
		runtime => {},
	};
	is($backend->start($request, $targets), undef, 'bereits passende Gruppe startet ohne Umbau');
	ok(grep($_ eq 'Sonos.ZMaster playUri clip.mp3', @commands), 'playUri wird am wirklichen Coordinator ausgefuehrt');
	ok(!grep($_ eq 'Sonos.AChild playUri clip.mp3', @commands), 'alphabetisch erstes Child startet die Quelle nicht');
	ok(!grep(/(?:leaveGroup|joinGroup)/, @commands), 'bestehende Gruppe bleibt unveraendert');

	# Auch die native Media-Queue wird nur am wirklichen Gruppencoordinator aktiviert.
	@commands = ();
	my $queue_request = {
		type => 'queue',
		payload => { volume => 15, volume_policy => 'fixed' },
		runtime => {},
	};
	is($backend->start($queue_request, $targets), undef, 'vorhandene Sonos-Queue wird gestartet');
	ok(grep($_ eq 'Sonos.ZMaster input Queue', @commands), 'Queue-Eingang wird am wirklichen Coordinator gesetzt');
	ok(grep($_ eq 'Sonos.ZMaster play', @commands), 'Queue startet am wirklichen Coordinator');
	ok(!grep(/^Sonos[.]AChild (?:input|play)/, @commands), 'Child erhaelt keinen Quellen- oder Play-Befehl');
};

subtest 'nicht verwaltetes Gruppenmitglied blockiert Seiteneffekt' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	speaker('Sonos.B', 'uuid-b', 'uuid-a');
	my $backend = AudioManager::Backend->create('sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway());
	my $request = { type => 'play', payload => { uri => 'clip.mp3', volume => 20, volume_policy => 'fixed' }, runtime => {} };
	like($backend->start($request, ['Sonos.A']), qr/nicht verwalteten Player Sonos.B/, 'unverwaltete Gruppe wird nicht veraendert');
	is(\@commands, [], 'bei Grenzfehler wurde kein Set gesendet');
};

subtest 'vorhandene Gruppe toleriert nicht verwaltete Mitglieder' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	speaker('Sonos.Fremd', 'uuid-fremd', 'uuid-a');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my ($targets, $target_error) = $backend->resolve_target('group:Sonos.A');
	is($target_error, undef, 'bestehende Gruppe wird ueber den verwalteten Anker aufgeloest');
	is($targets, ['Sonos.A'], 'fremdes Mitglied bleibt ausserhalb der direkten Zielmenge');
	my $request = {
		type => 'play',
		payload => {
			uri => 'clip.mp3', volume => 20, volume_policy => 'fixed',
			target_mode => 'existing_groups',
		},
		runtime => {},
	};
	is($backend->preflight_start($request, $targets), undef, 'Gruppenwiedergabe wird nicht blockiert');
	is($backend->start($request, $targets), undef, 'Clip startet auf der unveraenderten Gruppe');
	ok(grep($_ eq 'Sonos.A playUri clip.mp3', @commands), 'Coordinator erhaelt den Quellenbefehl');
	ok(!grep(/(?:leaveGroup|joinGroup)/, @commands), 'fremdes Mitglied wird nicht umgruppiert');
	is(
		$backend->topology_warnings,
		['Gruppe Sonos.A enthaelt nicht verwaltete Player Sonos.Fremd'],
		'gemischte Gruppe bleibt als Topologiewarnung sichtbar',
	);
};

subtest 'autoLeave blockiert vorhandene Gruppen standardmaessig und ist opt-in' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	speaker('Sonos.B', 'uuid-b', 'uuid-a');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway(),
	);
	my $request = {
		type => 'play',
		payload => { uri => 'clip.mp3', volume => 20, volume_policy => 'fixed' },
		runtime => {},
	};
	like(
		$backend->start($request, ['Sonos.A']), qr/autoLeave=0/,
		'Coordinator wird nicht automatisch aus seiner vorhandenen Gruppe isoliert',
	);
	is(\@commands, [], 'bei gesperrtem autoLeave wird kein Sonos-Kommando gesendet');
	my $group_request = {
		type => 'stream',
		payload => { favorite => 'Antenne', volume => 20, volume_policy => 'fixed' },
		runtime => {},
	};
	is(
		$backend->start($group_request, [qw(Sonos.A Sonos.B)]), undef,
		'eine bereits exakt passende Gruppe bleibt ohne autoLeave abspielbar',
	);
	ok(!grep(/leaveGroup/, @commands), 'passende Gruppe wird nicht aufgetrennt');
	$backend->configure(auto_leave => 1);
	is($backend->start($request, ['Sonos.A']), undef, 'explizites autoLeave gibt den Umbau frei');
	ok(grep($_ eq 'Sonos.B leaveGroup', @commands), 'bestehendes Child wird nach Freigabe getrennt');
};

subtest 'Alarmminimum und temporaere Gruppierung werden angewendet' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 70);
	speaker('Sonos.B', 'uuid-b', undef, volume => 10);
	my $backend = AudioManager::Backend->create('sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway());
	my $request = { type => 'alarm', payload => { uri => 'alarm.mp3', volume => 60, volume_policy => 'minimum' }, runtime => {} };
	is($backend->start($request, [qw(Sonos.A Sonos.B)]), undef, 'Gruppierungsautomat startet');
	is($backend->progress($request), undef, 'standalone Player werden zusammengefuehrt');
	is($backend->progress($request), undef, 'bestaetigte Gruppe startet den Alarm');
	ok(grep($_ eq 'Sonos.B joinGroup Sonos.A', @commands), 'zweiter Player tritt dem Coordinator bei');
	ok(grep($_ eq 'Sonos.A volume 70', @commands), 'bereits lauter Player wird nicht abgesenkt');
	ok(grep($_ eq 'Sonos.B volume 60', @commands), 'zu leiser Player wird auf Alarmminimum angehoben');
	ok(grep($_ eq 'Sonos.A playUri alarm.mp3', @commands), 'Alarm spielt am Coordinator');
};

subtest 'Sicherheitsgrenzen klemmen Minimum-Policy und Resume-Lautstaerke' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 70);
	speaker('Sonos.B', 'uuid-b', undef, volume => 10);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway(),
	);
	my $request = {
		type => 'alarm',
		payload => {
			uri => 'alarm.mp3', volume => 60, volume_policy => 'minimum',
			volume_min => 30, volume_max => 65,
		},
		runtime => {},
	};
	is($backend->start($request, [qw(Sonos.A Sonos.B)]), undef, 'begrenzter Alarm startet');
	is($backend->progress($request), undef, 'Alarmgruppe wird aufgebaut');
	is($backend->progress($request), undef, 'Alarm startet nach bestaetigter Gruppe');
	ok(grep($_ eq 'Sonos.A volume 65', @commands), 'lauter Player wird auf die Obergrenze abgesenkt');
	ok(grep($_ eq 'Sonos.B volume 60', @commands), 'leiser Player wird bis zum Alarmziel angehoben');

	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 90);
	$backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	$request = {
		type => 'stream',
		payload => {
			favorite => 'Antenne', volume => 12, volume_policy => 'fixed',
			volume_min => 10, volume_max => 40,
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'begrenzter Stream startet');
	$devices{'Sonos.A'}{READINGS}{volume} = 90;
	is($backend->suspend($request, ['Sonos.A']), undef, 'Stream wird bei noch veraltetem Volume-Reading pausiert');
	@commands = ();
	is($backend->resume($request), undef, 'Stream wird aus dem sicheren Snapshot fortgesetzt');
	ok(grep($_ eq 'Sonos.A volume 12', @commands), 'frisch gesendeter Streampegel gewinnt gegen das alte Reading');
	ok(!grep($_ eq 'Sonos.A volume 90', @commands), 'alter hoher Pegel wird beim Resume nicht restauriert');

	$now += 6;
	$devices{'Sonos.A'}{READINGS}{volume} = 30;
	is($backend->suspend($request, ['Sonos.A']), undef, 'spaetere manuelle Lautstaerke wird erneut gesichert');
	@commands = ();
	is($backend->resume($request), undef, 'Stream wird nach manueller Anpassung erneut fortgesetzt');
	ok(grep($_ eq 'Sonos.A volume 30', @commands), 'manueller Pegel innerhalb der Grenze bleibt erhalten');
};

subtest 'Raw-only Player tritt Favoritengruppe mit faehigem Coordinator bei' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	speaker('Sonos.TV', 'uuid-tv', undef, setList => 'x_raw_payload:textField');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.TV Sonos.A)], gateway => gateway(),
	);
	is($backend->validate, undef, 'Raw-only Speaker ist als verwaltetes Gruppenmitglied gueltig');
	my $request = {
		type => 'stream',
		payload => { favorite => 'Antenne', volume => 20, volume_policy => 'fixed' },
		runtime => {},
	};
	is($backend->start($request, [qw(Sonos.TV Sonos.A)]), undef, 'Gruppierungsautomat startet mit TV als erstem Ziel');
	is($backend->progress($request), undef, 'Raw-only TV tritt dem vollwertigen Speaker bei');
	is($backend->progress($request), undef, 'Favorit startet nach bestaetigter Gruppierung');
	ok(grep($_ eq 'Sonos.TV x_raw_payload {"command":"joingroup","input":"Sonos.A"}', @commands),
		'TV erhaelt den offiziellen joingroup-Rohbefehl');
	ok(grep($_ eq 'Sonos.A playFav Antenne', @commands),
		'vollwertiger Speaker wird trotz Zielreihenfolge Coordinator des Favoriten');
};

subtest 'Raw-only Player startet eine Stream-URI ohne Favoriten-Setter' => sub {
	reset_backend_env();
	speaker('Sonos.TV', 'uuid-tv', undef, setList => 'x_raw_payload:textField');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.TV'], gateway => gateway(),
	);
	my $request = {
		type => 'stream',
		payload => {
			uri => 'https://radio.example/live',
			volume => 20,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.TV']), undef, 'URI-Stream startet auf reduziertem Speaker');
	ok(
		grep(
			$_ eq 'Sonos.TV x_raw_payload {"command":"setavtransporturi","input":"https://radio.example/live"}',
			@commands,
		),
		'Stream-URI wird ueber das offizielle Rohkommando gesetzt',
	);
	ok(
		grep($_ eq 'Sonos.TV x_raw_payload {"command":"play"}', @commands),
		'URI-Stream wird nach dem Quellenwechsel gestartet',
	);
};

subtest 'Gruppenbeitritt verwendet den sichtbaren Sonos-Namen' => sub {
	reset_backend_env();
	speaker('Sonos.FlurEG', 'uuid-flur', undef, name => 'Flur EG');
	speaker('Sonos.Wohnen', 'uuid-wohnen', undef, name => 'Wohnen');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.FlurEG Sonos.Wohnen)], gateway => gateway(),
	);
	is(
		$backend->group_command('add', 'Sonos.Wohnen', 'Sonos.FlurEG'),
		undef,
		'AudioManager-Gruppenbefehl wird angenommen',
	);
	ok(
		grep($_ eq 'Sonos.Wohnen joinGroup Flur EG', @commands),
		'joinGroup erhaelt den sichtbaren Namen statt des FHEM-Devicenamens',
	);
	is(
		$devices{'Sonos.Wohnen'}{READINGS}{coordinatorUuid},
		'uuid-flur',
		'der Testplayer tritt der richtigen UUID-Gruppe bei',
	);
};

subtest 'Startbestaetigung toleriert Sonos-URI-Umschreibung ohne Fremdquelle zu akzeptieren' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, transportState => 'STOPPED');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $request = {
		type => 'speak',
		payload => { uri => 'http://fhem/speech.mp3', volume => 20, volume_policy => 'fixed' },
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'Sprachclip wird gestartet');
	$devices{'Sonos.A'}{READINGS}{currentTrack_TrackUri} = 'x-rincon-mp3radio://speech';
	is($backend->is_playing($request, ['Sonos.A']), 1, 'umgeschriebene Quelle bestaetigt den Start');
	is(
		$request->{runtime}{backends}{home}{playback_confirmation},
		'source_changed:Sonos.A',
		'Bestaetigungsgrund bleibt fuer die Diagnose erhalten',
	);

	# Eine bereits vorher laufende unveraenderte Fremdquelle darf keinen verlorenen Befehl bestaetigen.
	reset_backend_env();
	speaker('Sonos.B', 'uuid-b', undef, transportState => 'PLAYING', uri => 'favorite:Radio');
	$backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.B'], gateway => gateway(),
	);
	$request = {
		type => 'speak',
		payload => { uri => 'http://fhem/speech.mp3', volume => 20, volume_policy => 'fixed' },
		runtime => {},
	};
	is($backend->start($request, ['Sonos.B']), undef, 'Befehl wird an bereits spielenden Player gesendet');
	$devices{'Sonos.B'}{READINGS}{currentTrack_TrackUri} = 'favorite:Radio';
	is($backend->is_playing($request, ['Sonos.B']), 0, 'unveraenderte Fremdquelle gilt nicht als Start');
};

subtest 'verwaltete URI-Queue startet als Schleife und pausiert ihren Fade' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 20);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $request = {
		type => 'queue',
		payload => {
			uris => ['http://fhem/vogel/a.mp3', 'http://fhem/vogel/b.mp3'],
			volume => 20,
			volume_policy => 'fixed',
			fadein => 10,
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'Queue-Aufbau wird angenommen');
	ok(grep($_ eq 'Sonos.A volume 2', @commands), 'Fade beginnt bei zehn Prozent des Zielpegels');
	is(
		scalar(grep(/AVTransportService[.]AddURIToQueue/, @commands)),
		2,
		'beide URIs werden in ihrer Reihenfolge an die native Queue uebergeben',
	);
	ok(grep(/AVTransportService[.]RemoveAllTracksFromQueue/, @commands), 'vorhandene Media-Queue wird ersetzt');
	ok(grep($_ eq 'Sonos.A input Queue', @commands), 'Queue-Eingang wird aktiviert');
	ok(!grep($_ eq 'Sonos.A play', @commands), 'Play wartet auf die bestaetigte Queue-Quelle');

	is($backend->progress($request), undef, 'bestaetigte Queue wird konfiguriert und gestartet');
	ok(grep(/"command":"playmode","input":"REPEAT_ALL"/, @commands), 'Queue laeuft in Endlosschleife');
	ok(grep(/"command":"selecttrack","input":1/, @commands), 'Queue beginnt bei Titel eins');
	ok(grep($_ eq 'Sonos.A play', @commands), 'Play folgt erst nach Queue-Konfiguration');

	$now += 5;
	is($backend->progress($request), undef, 'Fade wird nach halber Dauer fortgeschrieben');
	ok(grep($_ eq 'Sonos.A volume 11', @commands), 'linearer Halbzeitpegel wird gesetzt');
	is($backend->suspend($request, ['Sonos.A']), undef, 'Queue und Fade werden gemeinsam pausiert');
	$now += 20;
	is($backend->resume($request), undef, 'Queue wird nach der Unterbrechung zur Wiederaufnahme vorbereitet');
	is($backend->progress($request), undef, 'Standalone-Topologie wird wiederhergestellt');
	is($backend->progress($request), undef, 'Queue-Quelle wird wieder gestartet');
	$now += 5;
	is($backend->progress($request), undef, 'nur aktive Fade-Zeit wird angerechnet');
	ok(grep($_ eq 'Sonos.A volume 20', @commands), 'Fade erreicht nach insgesamt zehn aktiven Sekunden das Ziel');

	is($backend->stop($request, ['Sonos.A']), undef, 'verwaltete Queue wird kontrolliert beendet');
	is(
		scalar(grep(/AVTransportService[.]RemoveAllTracksFromQueue/, @commands)),
		2,
		'nur die selbst verwaltete Queue wird beim Stop wieder geleert',
	);
};

subtest 'Ansage unterbricht REPEAT_ALL-Queue einmalig und setzt sie bestaetigt fort' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 15);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $queue = {
		type => 'queue',
		payload => {
			uris => ['http://fhem/vogel/a.mp3'],
			volume => 15,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	is($backend->start($queue, ['Sonos.A']), undef, 'Vogel-Queue wird aufgebaut');
	is($backend->progress($queue), undef, 'Vogel-Queue startet in der Schleife');
	is($backend->suspend($queue, ['Sonos.A']), undef, 'Vogel-Queue wird fuer die Ansage pausiert');
	my $speak = {
		type => 'speak',
		payload => {
			uri => 'http://fhem/speech/test.mp3',
			volume => 25,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	@commands = ();
	is($backend->start($speak, ['Sonos.A']), undef, 'Ansage startet auf dem Queue-Coordinator');
	ok(
		grep(/"command":"playmode","input":"NORMAL"/, @commands),
		'Ansage hebt den geerbten Wiederholungsmodus auf',
	);
	ok(!grep(/playUri/, @commands), 'Ansage startet nicht im selben Zyklus wie der Playmode-Wechsel');
	$devices{'Sonos.A'}{READINGS}{playmode} = 'REPEAT_ALL';
	is($backend->progress($speak), undef, 'verzoegertes Playmode-Reading haelt die Ansage zurueck');
	ok(!grep(/playUri/, @commands), 'ohne NORMAL-Bestaetigung wird keine TTS-URI gestartet');
	$devices{'Sonos.A'}{READINGS}{playmode} = 'NORMAL';
	is($backend->progress($speak), undef, 'NORMAL-Bestaetigung gibt die Ansage frei');
	ok(grep($_ eq 'Sonos.A playUri http://fhem/speech/test.mp3', @commands), 'Ansage wird danach genau als Clip gestartet');
	$devices{'Sonos.A'}{READINGS}{transportState} = 'STOPPED';
	$devices{'Sonos.A'}{READINGS}{playmode} = 'REPEAT_ALL';
	@commands = ();
	is($backend->resume($queue), undef, 'Queue-Resume fordert zuerst den Quellenwechsel an');
	ok(
		grep(/"command":"playmode","input":"REPEAT_ALL"/, @commands),
		'Resume bestaetigt den Queue-Modus auch gegen ein verzoegertes Reading',
	);
	ok(grep($_ eq 'Sonos.A input Queue', @commands), 'Queue-Eingang wird erneut angefordert');
	ok(!grep($_ eq 'Sonos.A play', @commands), 'Play wird nicht im selben Zyklus zu frueh gesendet');
	$devices{'Sonos.A'}{READINGS}{Input} = 'Radio';
	$devices{'Sonos.A'}{READINGS}{currentTrack_TrackUri} = 'http://fhem/speech/test.mp3';
	is($backend->progress($queue), undef, 'veraltete TTS-Quelle bestaetigt den Queue-Wechsel noch nicht');
	ok(!grep($_ eq 'Sonos.A play', @commands), 'Queue bleibt bis zur Quellenbestaetigung pausiert');
	$devices{'Sonos.A'}{READINGS}{currentTrack_TrackUri} = 'http://fhem/vogel/a.mp3';
	is($backend->progress($queue), undef, 'Vogel-URI bestaetigt die wiederhergestellte Queue');
	ok(grep($_ eq 'Sonos.A play', @commands), 'Queue startet erst nach der Bestaetigung wieder');
	is($devices{'Sonos.A'}{READINGS}{playmode}, 'REPEAT_ALL', 'Vogel-Queue behaelt ihren Wiederholungsmodus');
};

subtest 'Cleanup einer pausierten URI-Queue laesst die hoehere Ausgabe laufen' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 15);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $request = {
		type => 'queue',
		payload => {
			uris => ['http://fhem/vogel/a.mp3'],
			volume => 15,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'verwaltete Queue wird aufgebaut');
	is($backend->progress($request), undef, 'Queue startet nach Quellenbestaetigung');
	is($backend->suspend($request, ['Sonos.A']), undef, 'Queue wird fuer eine hoehere Ausgabe pausiert');
	$devices{'Sonos.A'}{READINGS}{transportState} = 'PLAYING';
	my $stop_count = scalar(grep($_ eq 'Sonos.A stop', @commands));
	my $remove_count = scalar(grep(/AVTransportService[.]RemoveAllTracksFromQueue/, @commands));
	is($backend->stop($request, ['Sonos.A']), undef, 'pausierter Queue-Request wird bereinigt');
	is(
		scalar(grep($_ eq 'Sonos.A stop', @commands)),
		$stop_count,
		'aktuell laufende hoehere Ausgabe erhaelt keinen Stop-Befehl',
	);
	is(
		scalar(grep(/AVTransportService[.]RemoveAllTracksFromQueue/, @commands)),
		$remove_count + 1,
		'nur der nicht mehr benoetigte Queue-Inhalt wird geleert',
	);
};

subtest 'Queue-Bestaetigung verwendet Request-URI trotz veraltetem Radio-Input' => sub {
	reset_backend_env();
	speaker(
		'Sonos.A', 'uuid-a', undef,
		Input => 'Radio',
		uri => 'favorite:Alt',
	);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $request = {
		type => 'queue',
		payload => {
			uris => ['http://fhem/vogel/a.mp3'],
			volume => 15,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'Queue-Wechsel wird angefordert');
	$devices{'Sonos.A'}{READINGS}{Input} = 'Radio';
	$devices{'Sonos.A'}{READINGS}{currentTrack_TrackUri} = 'http://fhem/vogel/a.mp3';
	is($backend->progress($request), undef, 'URI-Wechsel bestaetigt die verwaltete Queue');
	ok(grep($_ eq 'Sonos.A play', @commands), 'Queue startet trotz unzutreffendem Input-Reading');
	is(
		$request->{runtime}{backends}{home}{deadline},
		$now + 30,
		'lange sonos2mqtt-Rueckmeldungen erhalten mindestens dreissig Sekunden',
	);
};

subtest 'unveraenderte Snapshotgruppe restauriert Audio ohne Leave und Join' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a', undef, volume => 25, transportState => 'PLAYING', uri => 'favorite:Alt');
	speaker('Sonos.B', 'uuid-b', 'uuid-a', volume => 30, transportState => 'GROUP_PLAYING');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway(),
	);
	my $snapshot = $backend->snapshot([qw(Sonos.A Sonos.B)]);
	$devices{'Sonos.A'}{READINGS}{volume} = 2;
	$devices{'Sonos.B'}{READINGS}{volume} = 2;
	@commands = ();
	my $restore_request = $backend->restore($snapshot);
	ref_ok($restore_request, 'HASH', 'Restore liefert seinen Laufzeitrequest');
	is(
		$restore_request->{runtime}{backends}{home}{phase},
		'restored',
		'bereits passende Topologie wird unmittelbar restauriert',
	);
	ok(!grep(/(?:leaveGroup|joinGroup)/, @commands), 'bestehende Gruppe wird nicht auseinandergerissen');
	ok(grep($_ eq 'Sonos.A volume 25', @commands), 'Coordinator erhaelt seine Lautstaerke zurueck');
	ok(grep($_ eq 'Sonos.B volume 30', @commands), 'Gruppenmitglied erhaelt seine Lautstaerke zurueck');
};

subtest 'Stream-Resume verwendet Favorit statt veraltetem Trackreading' => sub {
	reset_backend_env();
	speaker(
		'Sonos.A', 'uuid-a', undef,
		transportState => 'PLAYING',
		Input => 'Radio',
		uri => 'http://fhem/vogel/alt.mp3',
	);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $request = {
		type => 'stream',
		payload => {
			favorite => 'Antenne.Muenster',
			volume => 15,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'Favoritenstream wird gestartet');
	$devices{'Sonos.A'}{READINGS}{currentTrack_TrackUri} = 'http://fhem/vogel/alt.mp3';
	is($backend->suspend($request, ['Sonos.A']), undef, 'verspaetetes Vogelreading landet im Suspend-Snapshot');
	@commands = ();
	is($backend->resume($request), undef, 'Stream wird aus seinem fachlichen Request fortgesetzt');
	ok(
		grep($_ eq 'Sonos.A playFav Antenne.Muenster', @commands),
		'Resume startet erneut den gespeicherten Sonos-Favoriten',
	);
	ok(
		!grep($_ eq 'Sonos.A playUri http://fhem/vogel/alt.mp3', @commands),
		'alte Vogel-URI wird nicht als Streamquelle wiederverwendet',
	);
};

subtest 'Stream-Resume verwendet Request-URI statt veraltetem Trackreading' => sub {
	reset_backend_env();
	speaker(
		'Sonos.A', 'uuid-a', undef,
		transportState => 'PLAYING',
		Input => 'Radio',
		uri => 'https://radio.example/live',
	);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	my $request = {
		type => 'stream',
		payload => {
			uri => 'https://radio.example/live',
			volume => 15,
			volume_policy => 'fixed',
		},
		runtime => {},
	};
	is($backend->start($request, ['Sonos.A']), undef, 'URI-Stream wird gestartet');
	$devices{'Sonos.A'}{READINGS}{currentTrack_TrackUri} = 'http://fhem/vogel/alt.mp3';
	is($backend->suspend($request, ['Sonos.A']), undef, 'verspaetetes Reading wird im Snapshot sichtbar');
	@commands = ();
	is($backend->resume($request), undef, 'URI-Stream wird aus seinem Request fortgesetzt');
	ok(
		grep($_ eq 'Sonos.A playUri https://radio.example/live', @commands),
		'Resume startet erneut die gespeicherte Stream-URI',
	);
	ok(
		!grep($_ eq 'Sonos.A playUri http://fhem/vogel/alt.mp3', @commands),
		'alte Track-URI ersetzt die Streamquelle nicht',
	);
};

subtest 'all verteilt endliche Ausgabe ohne Gruppenumbau auf bestehende Coordinatoren' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	speaker('Sonos.B', 'uuid-b', 'uuid-a');
	speaker('Sonos.C', 'uuid-c');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B Sonos.C)], gateway => gateway(),
	);
	my $request = {
		type => 'play',
		payload => {
			uri => 'http://fhem/gong.mp3',
			volume => 40,
			volume_policy => 'fixed',
			target_mode => 'existing_groups',
		},
		runtime => {},
	};
	is($backend->preflight_start($request, [qw(Sonos.A Sonos.B Sonos.C)]), undef, 'autoLeave=0 blockiert all nicht');
	is($backend->start($request, [qw(Sonos.A Sonos.B Sonos.C)]), undef, 'Fan-out startet ohne Gruppenumbau');
	ok(grep($_ eq 'Sonos.A playUri http://fhem/gong.mp3', @commands), 'erste Gruppe startet am Coordinator');
	ok(grep($_ eq 'Sonos.C playUri http://fhem/gong.mp3', @commands), 'Standalone-Gruppe startet separat');
	ok(!grep($_ eq 'Sonos.B playUri http://fhem/gong.mp3', @commands), 'Child erhaelt keinen doppelten Quellenbefehl');
	ok(!grep(/(?:leaveGroup|joinGroup)/, @commands), 'bestehende Topologie bleibt unveraendert');
};
subtest 'GetZoneInfo prueft Player read-only und bestaetigt Antworten ohne Watcher' => sub {
	reset_backend_env();
	speaker(
		'Sonos.A', 'uuid-a', undef,
		readingList => "homeassistant/player/config:.* ignored\nmusic/RINCON_A/renderingcontrol:.* status",
	);
	speaker('Sonos.B', 'uuid-b');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway(),
	);
	is($backend->validate, undef, 'Standard-Speaker besitzen den erforderlichen Rohbefehl');
	is($backend->health_capabilities->{probe}, 'GetZoneInfo', 'Adapter beschreibt seinen read-only Probe');
	is($backend->health_probe({ requested_at => $now })->{status}, 'pending', 'Probe wartet auf Antworten');
	is(
		\@commands,
		[
			'Sonos.A x_raw_payload {"command":"adv-command","input":{"cmd":"GetZoneInfo","reply":"ZoneInfo"}}',
			'Sonos.B x_raw_payload {"command":"adv-command","input":{"cmd":"GetZoneInfo","reply":"ZoneInfo"}}',
		],
		'jeder verwaltete Player erhaelt genau den offiziellen GetZoneInfo-Befehl',
	);
	is(
		$backend->health_verify({ deadline => $now + 15, recovery_attempted => 0 })->{status},
		'pending',
		'gesendete Befehle allein gelten nicht als Erfolg',
	);
	my $fresh_a = $backend->health_event('Sonos.A', ['IPAddress: 192.168.1.11']);
	my $fresh_b = $backend->health_event('Sonos.B', ['IPAddress: 192.168.1.12']);
	ok($fresh_a->[0]{activity} && $fresh_b->[0]{activity}, 'IPAddress-Ereignisse bestaetigen beide Player');
	is(
		$backend->health_verify({ deadline => $now + 15, recovery_attempted => 0 })->{status},
		'healthy',
		'alle direkten Antworten bestaetigen den Probe',
	);
	is($backend->health_details->{players}{'Sonos.A'}{status}, 'reachable', 'Playerstatus bleibt diagnostizierbar');

	# Ein neuer Readingzeitstempel muss auch ohne FHEM-Event als Antwort genuegen.
	@commands = ();
	$backend->health_probe({ requested_at => $now });
	$reading_timestamps{'Sonos.A'}{IPAddress} = 'later-a';
	$reading_timestamps{'Sonos.B'}{IPAddress} = 'later-b';
	is(
		$backend->health_verify({ deadline => $now + 15, recovery_attempted => 0 })->{status},
		'healthy',
		'event-on-change-reading kann die Zeitstempelbestaetigung nicht blockieren',
	);
};

subtest 'fehlende ZoneInfo-Antwort repariert Subscriptions und prueft genau einmal erneut' => sub {
	reset_backend_env();
	speaker(
		'Sonos.A', 'uuid-a', undef,
		readingList => "homeassistant/player/config:.* ignored\nmusic/RINCON_A/renderingcontrol:.* status",
	);
	speaker('Sonos.B', 'uuid-b');
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.A Sonos.B)], gateway => gateway(),
	);
	$backend->health_probe({ requested_at => $now });
	$backend->health_event('Sonos.A', ['IPAddress: 192.168.1.11']);
	$now += 16;
	my $failed = $backend->health_verify({ deadline => $now - 1, recovery_attempted => 0 });
	is($failed->{status}, 'degraded', 'fehlende Antwort wird am Fristende sichtbar');
	ok($failed->{recoverable}, 'erster Ausfall darf eine Subscription-Recovery ausloesen');
	is($failed->{players}, ['Sonos.B'], 'nur der unbeantwortete Player wird erneut geprueft');
	is($backend->health_recover($failed), undef, 'Subscription-Refresh und Retry werden gestartet');
	is(
		\@publishes,
		['Sonos.A music/cmd/check-subscriptions'],
		'globaler Refresh nutzt das IODev eines Speakers und dessen vorhandenen Praefix',
	);
	is(
		$commands[-1],
		'Sonos.B x_raw_payload {"command":"adv-command","input":{"cmd":"GetZoneInfo","reply":"ZoneInfo"}}',
		'nur der fehlende Player erhaelt den Wiederholungsprobe',
	);
	$backend->health_event('Sonos.B', ['IPAddress: 192.168.1.12']);
	is(
		$backend->health_verify({ deadline => $now + 15, recovery_attempted => 1 })->{status},
		'healthy',
		'direkte Antwort bestaetigt die Recovery',
	);
};

subtest 'Bridge-Availability wird automatisch oder explizit gebunden' => sub {
	reset_backend_env();
	speaker('Sonos.A', 'uuid-a');
	$attributes{'Sonos.A'}{devicetopic} = 'sonos';
	$devices{'Sonos.Bridge'} = {
		NAME => 'Sonos.Bridge', TYPE => 'MQTT2_DEVICE', IODev => 'MQTT',
		READINGS => { connected => 0 },
	};
	$attributes{'Sonos.Bridge'}{model} = 'sonos2mqtt_bridge';
	$attributes{'Sonos.Bridge'}{devicetopic} = 'sonos';
	$attributes{'Sonos.Bridge'}{readingList} = '$DEVICETOPIC/connected:.* connected';
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => ['Sonos.A'], gateway => gateway(),
	);
	$backend->configure(availability => {});
	is($backend->health_devices, ['Sonos.Bridge'], 'Autoerkennung findet die exakte Topiczuordnung am selben IODev');
	is($backend->health_details->{availability}{mode}, 'auto', 'automatische Bindung bleibt sichtbar');
	is($backend->health_probe({ requested_at => $now })->{reason}, 'bridge_offline', 'connected=0 blockiert den Playerprobe');
	$devices{'Sonos.Bridge'}{READINGS}{connected} = 2;
	my $online = $backend->health_event('Sonos.Bridge', ['connected: 2']);
	ok($online->[0]{probe}, 'connected=2 fordert sofort einen Playerprobe an');
	is($backend->health_probe({ requested_at => $now })->{status}, 'pending', 'verbundene Bridge gibt GetZoneInfo frei');

	$devices{'Custom.Bridge'} = {
		NAME => 'Custom.Bridge', TYPE => 'MQTT2_DEVICE', IODev => 'MQTT',
		READINGS => { serviceState => 2 },
	};
	$backend->configure(availability => {
		sonos => { device => 'Custom.Bridge', reading => 'serviceState' },
	});
	is($backend->health_devices, ['Custom.Bridge'], 'explizite Zuordnung uebersteuert die Autoerkennung');
	is($backend->health_details->{availability}{mode}, 'configured', 'manuelle Bindung bleibt sichtbar');
};
subtest 'Medienstatus und direkte Bedienung verwenden den wirklichen Coordinator' => sub {
	reset_backend_env();
	speaker('Sonos.AChild', 'uuid-child', 'uuid-master', volume => 10);
	speaker(
		'Sonos.ZMaster', 'uuid-master', undef,
		transportState => 'PLAYING',
		title => 'Aktueller Titel', legacyTitle => 'vogel06.mp3',
		artist => 'Aktueller Artist', legacyArtist => 'Veraltet',
		album => 'Aktuelles Album', albumArtUri => 'https://radio.example/logo.png',
	);
	my $backend = AudioManager::Backend->create(
		'sonos2mqtt', id => 'home', players => [qw(Sonos.AChild Sonos.ZMaster)], gateway => gateway(),
	);
	my $request = {
		type => 'stream',
		payload => { favorite => 'Radio 7' },
		runtime => { backends => { home => { coordinator => 'Sonos.ZMaster' } } },
	};
	my $status = $backend->media_status($request, [qw(Sonos.AChild Sonos.ZMaster)]);
	is($status->{player}, 'Sonos.ZMaster', 'Medienstatus stammt vom wirklichen Coordinator');
	is($status->{title}, 'Aktueller Titel', 'kleingeschriebenes aktuelles Titelreading gewinnt');
	is($status->{artist}, 'Aktueller Artist', 'kleingeschriebenes aktuelles Artistreading gewinnt');
	is($status->{albumArtUri}, 'https://radio.example/logo.png', 'Cover-URI wird normalisiert');
	is($status->{transportState}, 'PLAYING', 'Transportzustand wird normalisiert');

	@commands = ();
	is(
		$backend->transport_command([qw(Sonos.AChild Sonos.ZMaster)], 'previous'),
		undef,
		'Transportbefehl wird angenommen',
	);
	is(\@commands, ['Sonos.ZMaster previous'], 'Gruppe erhaelt genau einen Befehl am Coordinator');
	@commands = ();
	is($backend->change_volume(['Sonos.AChild'], 'up'), undef, 'nativer Lautstaerkeschritt wird angenommen');
	is(\@commands, ['Sonos.AChild volumeUp'], 'Lautstaerkeschritt bleibt auf den Zielplayer begrenzt');
	is($devices{'Sonos.AChild'}{READINGS}{volume}, 11, 'simulierter Pegel wurde angehoben');
};

done_testing;
