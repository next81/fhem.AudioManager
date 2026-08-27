# Copyright (c) 2026 Andreas Planer

package AudioManager::Module::TTS;

use strict;
use warnings;
use AudioManager::Config ();
use AudioManager::Core ();
use AudioManager::Module::Status ();

# Nutzt dieselbe Gatewayinstanz wie die Statusschicht des Managerdevices.
sub _gateway {
	my ($hash) = @_;
	return AudioManager::Module::Status::gateway($hash);
}

# Plant den FHEM-Worker ueber die uebergebene Fassade oder als FHEM-Fallback.
sub _schedule {
	my ($hash, $scheduler) = @_;
	return $scheduler->($hash) if ref($scheduler) eq 'CODE';
	return main::AudioManager_schedule_worker($hash)
		if defined &main::AudioManager_schedule_worker;
	return;
}

# Reiht einen vorbereiteten TTS-Request ein und startet bei freiem Provider sofort.
sub enqueue {
	my ($hash, $request, $scheduler) = @_;
	push @{ $hash->{helper}{tts_queue} }, $request->{id};
	start_next($hash, $scheduler);
	return;
}

# Startet den naechsten TTS-Rendererauftrag sofort, sofern der Provider frei ist.
sub start_next {
	my ($hash, $scheduler) = @_;
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
	my $gateway = _gateway($hash);
	my $tts_device = $gateway->attr_value($hash->{NAME}, 'ttsDevice', '');

	# Ohne expliziten Provider wird der Auftrag sichtbar beendet statt in der Queue zu haengen.
	my $tts_hash = $tts_device ne '' ? $gateway->device($tts_device) : undef;
	if (!$tts_hash || ($tts_hash->{TYPE} || '') ne 'Text2Speech') {
		$core->fail($id, 'ttsDevice fehlt oder existiert nicht');
		return start_next($hash, $scheduler);
	}

	my $request = $core->request($id);
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
		return start_next($hash, $scheduler);
	}

	# Ein synchron gesetztes playing=1 wird direkt erfasst. Dadurch reicht das
	# spaetere playing=0-Ereignis auch bei einer unveraenderten Cache-URI als Beleg.
	poll($hash, $scheduler);
	AudioManager::Module::Status::update_status($hash, $request);
	_schedule($hash, $scheduler);
	return;
}

# Korreliert TTS-Notify-Ereignisse mit dem aktuell erzeugten Einzeltext. Kurze
# playing-Wechsel gehen dadurch nicht mehr zwischen zwei Worker-Ticks verloren.
sub event {
	my ($hash, $device, $scheduler) = @_;
	my $current = $hash->{helper}{tts_current} or return;
	return if !$device || ($device->{NAME} || '') ne $current->{device};
	my @events = @{ main::deviceEvents($device, 1) || [] };
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
	poll($hash, $scheduler) if $relevant;
	return;
}

# Prueft den Text2Speech-Provider auf eine fertige URI und gibt den Renderer
# direkt danach fuer den naechsten Einzeltext frei.
sub poll {
	my ($hash, $scheduler) = @_;
	my $current = $hash->{helper}{tts_current} or return;
	my $core = $hash->{helper}{core};
	my $request = $core->request($current->{id});

	# Abgebrochene Auftraege duerfen ein spaeteres Renderergebnis nicht mehr abspielen.
	if (!$request || $request->{state} ne 'preparing') {
		delete $hash->{helper}{tts_current};
		return start_next($hash, $scheduler);
	}

	my $gateway = _gateway($hash);
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
		start_next($hash, $scheduler);
		return;
	}

	my $timeout = AudioManager::Config::configuration(
		$hash, $gateway, AudioManager::Core->default_priorities,
	)->{start_timeout};

	# Auch ein nicht reagierender TTS-Provider darf die Sprachhierarchie nicht dauerhaft blockieren.
	if ($age > $timeout) {
		delete $hash->{helper}{tts_current};
		$core->fail($current->{id}, 'Zeitueberschreitung bei der TTS-Erzeugung');
		start_next($hash, $scheduler);
	}

	return;
}

1;
