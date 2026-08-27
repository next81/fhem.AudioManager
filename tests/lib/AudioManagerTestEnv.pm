package AudioManagerTestEnv;

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();

our @EXPORT_OK = qw(reset_env add_sonos add_bridge add_tts define_manager command_log log_messages timers run_next_timer advance_time reading_value set_reading);
our @COMMAND_LOG;
our @LOG_MESSAGES;
our @TIMERS;
our $NOW = 1_800_000_000;

# Setzt die simulierte FHEM-Laufzeit und alle Protokolle reproduzierbar zurueck.
sub reset_env {
	%main::defs = ();
	%main::attr = (global => { verbose => 3 });
	%main::modules = (AudioManager => {});
	$main::readingFnAttributes = '';
	$main::init_done = 1;
	@COMMAND_LOG = ();
	@LOG_MESSAGES = ();
	@TIMERS = ();
	$NOW = 1_800_000_000;
	main::AudioManager_Initialize($main::modules{AudioManager});
}

# Legt einen minimalen sonos2mqtt-Speaker mit autoritativen Gruppenreadings an.
sub add_sonos {
	my ($name, $uuid, $coordinator_uuid, %readings) = @_;
	$coordinator_uuid ||= $uuid;
	$main::defs{$name} = {
		NAME => $name,
		TYPE => 'MQTT2_DEVICE',
		IODev => 'MQTT',
		READINGS => {
			name => { VAL => $readings{name} // $name },
			uuid => { VAL => $uuid },
			coordinatorUuid => { VAL => $coordinator_uuid },
			transportState => { VAL => $readings{transportState} // 'STOPPED' },
			currentTrack_trackUri => { VAL => $readings{uri} // '' },
			currentTrack_title => { VAL => $readings{title} // '' },
			currentTrack_Title => { VAL => $readings{legacyTitle} // '' },
			currentTrack_artist => { VAL => $readings{artist} // '' },
			currentTrack_Artist => { VAL => $readings{legacyArtist} // '' },
			currentTrack_album => { VAL => $readings{album} // '' },
			currentTrack_Album => { VAL => $readings{legacyAlbum} // '' },
			currentTrack_albumArtUri => { VAL => $readings{albumArtUri} // '' },
			currentTrack_AlbumArtUri => { VAL => $readings{legacyAlbumArtUri} // '' },
			Input => { VAL => $readings{Input} // '' },
			volume => { VAL => $readings{volume} // 10 },
			mute => { VAL => $readings{mute} // 'false' },
			playmode => { VAL => $readings{playmode} // 'NORMAL' },
			deviceWatcherStatus => { VAL => $readings{deviceWatcherStatus} // 'online' },
			ts => { VAL => $readings{ts} // 'initial' },
			IPAddress => { VAL => $readings{IPAddress} // '192.168.1.10', TIME => "time:$NOW" },
		},
	};
	$main::attr{$name}{model} = 'sonos2mqtt_speaker';
	$main::attr{$name}{setList} = join("\n",
		'playUri:textField', 'playFav:textField', 'joinGroup:textField', 'leaveGroup:noArg',
		'mute:true,false', 'volume:slider', 'volumeUp:noArg', 'volumeDown:noArg',
		'input:Queue', 'play:noArg', 'pause:noArg', 'previous:noArg', 'next:noArg',
		'stop:noArg', 'x_raw_payload:textField',
	);
	return $main::defs{$name};
}

# Legt eine vorhandene sonos2mqtt-Bridgezuordnung fuer Auto- und Attributtests an.
sub add_bridge {
	my ($name, $prefix, $connected) = @_;
	$prefix ||= 'sonos';
	$connected = 2 if !defined($connected);
	$main::defs{$name} = {
		NAME => $name,
		TYPE => 'MQTT2_DEVICE',
		IODev => 'MQTT',
		READINGS => {
			connected => { VAL => $connected, TIME => "time:$NOW" },
		},
	};
	$main::attr{$name}{model} = 'sonos2mqtt_bridge';
	$main::attr{$name}{devicetopic} = $prefix;
	$main::attr{$name}{readingList} = "$prefix/connected:.* connected";
	return $main::defs{$name};
}
# Legt einen Text2Speech-Provider mit den vom Modul beobachteten Readings an.
sub add_tts {
	my ($name) = @_;
	$main::defs{$name} = {
		NAME => $name,
		TYPE => 'Text2Speech',
		READINGS => {
			playing => { VAL => 0 },
			httpName => { VAL => '' },
			lastFilename => { VAL => '' },
			duration => { VAL => 3 },
		},
	};
	return $main::defs{$name};
}

# Definiert eine AudioManager-Instanz ueber dieselbe DefFn wie FHEM.
sub define_manager {
	my ($name, @descriptors) = @_;
	my $hash = { NAME => $name, TYPE => 'AudioManager', READINGS => {}, helper => {} };
	$main::defs{$name} = $hash;
	my $error = main::AudioManager_Define($hash, join(' ', $name, 'AudioManager', @descriptors));
	return ($hash, $error);
}

# Liefert alle simulierten Set-Kommandos in Ausfuehrungsreihenfolge.
sub command_log { return \@COMMAND_LOG; }

# Liefert FHEM-Logmeldungen mit Level und Modulnamen fuer Regressionstests.
sub log_messages { return \@LOG_MESSAGES; }

# Liefert die aktuell geplanten InternalTimer.
sub timers { return \@TIMERS; }

# Fuehrt den zeitlich naechsten Timer aus und setzt die Testzeit auf seinen Termin.
sub run_next_timer {
	return if !@TIMERS;
	@TIMERS = sort { $a->{at} <=> $b->{at} } @TIMERS;
	my $timer = shift @TIMERS;
	$NOW = $timer->{at} if $timer->{at} > $NOW;
	my $function = $timer->{function};
	no strict 'refs';
	&{"main::$function"}($timer->{hash});
	return;
}

# Verschiebt die deterministische Testzeit ohne blockierendes Warten.
sub advance_time {
	my ($seconds) = @_;
	$NOW += $seconds;
	return $NOW;
}

# Liefert ein Reading mit optionalem Fallbackwert.
sub reading_value {
	my ($device, $reading, $default) = @_;
	return exists($main::defs{$device}{READINGS}{$reading})
		? $main::defs{$device}{READINGS}{$reading}{VAL} : $default;
}

# Setzt ein Reading fuer simulierte MQTT- oder TTS-Ereignisse.
sub set_reading {
	my ($device, $reading, $value) = @_;
	$main::defs{$device}{READINGS}{$reading} = { VAL => $value, TIME => "time:$NOW" };
	return;
}

package main;

our (%defs, %attr, %modules, $readingFnAttributes, $init_done);

# Bildet FHEMs Attributzugriff einschliesslich Default ab.
sub AttrVal($$$) {
	my ($device, $attribute, $default) = @_;
	return exists($attr{$device}) && exists($attr{$device}{$attribute})
		? $attr{$device}{$attribute} : $default;
}

# Bildet FHEMs Readingzugriff einschliesslich Default ab.
sub ReadingsVal($$$) {
	my ($device, $reading, $default) = @_;
	return exists($defs{$device}) && exists($defs{$device}{READINGS}{$reading})
		? $defs{$device}{READINGS}{$reading}{VAL} : $default;
}

# Aktualisiert ein Reading mit reproduzierbarem Zeitstempel.
sub readingsSingleUpdate($$$$) {
	my ($hash, $reading, $value, undef) = @_;
	$hash->{READINGS}{$reading} = { VAL => $value, TIME => '2027-01-15 08:00:00' };
	return undef;
}

# Begrenzt das Notify auf die vom Modul angegebenen Devices.
sub setNotifyDev($$) {
	my ($hash, $devices) = @_;
	$hash->{NOTIFYDEV} = $devices;
	return undef;
}

# Liefert die am Device simulierten Ereignisse.
sub deviceEvents($$) {
	my ($device, undef) = @_;
	return $device->{CHANGED};
}

# Liefert die deterministische hochaufloesende FHEM-Zeit.
sub gettimeofday() { return $AudioManagerTestEnv::NOW; }

# Plant einen Testtimer, ohne ihn automatisch auszufuehren.
sub InternalTimer($$$$) {
	my ($at, $function, $hash, undef) = @_;
	push @AudioManagerTestEnv::TIMERS, { at => $at, function => $function, hash => $hash };
	return undef;
}

# Loest den von sonos2mqtt verwendeten sichtbaren Sonos-Namen zum FHEM-Device auf.
sub AudioManagerTest_device_by_sonos_name($) {
	my ($sonos_name) = @_;

	# Der Simulator bildet dieselbe Namensgrenze wie der echte joingroup-Befehl ab.
	for my $device (sort keys %defs) {
		my $name = ReadingsVal($device, 'name', '');
		return $device if $name eq $sonos_name;
	}

	return undef;
}

# Entfernt passende Testtimer fuer eine Modulinstanz.
sub RemoveInternalTimer($;$) {
	my ($hash, $function) = @_;
	@AudioManagerTestEnv::TIMERS = grep {
		$_->{hash} != $hash || (defined($function) && $_->{function} ne $function)
	} @AudioManagerTestEnv::TIMERS;
	return undef;
}

# Protokolliert Set-Kommandos und simuliert die wesentlichen sonos2mqtt-/TTS-Readings.
sub CommandSet($$) {
	my (undef, $definition) = @_;
	push @AudioManagerTestEnv::COMMAND_LOG, "set $definition";
	my ($device, $command, $value) = split /\s+/, $definition, 3;
	return "Unknown device $device" if !$defs{$device};

	# Text2Speech signalisiert eine gestartete Erzeugung ueber playing=1.
	if (($defs{$device}{TYPE} || '') eq 'Text2Speech' && $command eq 'tts') {
		$defs{$device}{READINGS}{playing}{VAL} = 1;
		return undef;
	}


	# Reduzierte Speaker verwenden die dokumentierten sonos2mqtt-JSON-Kommandos.
	if ($command eq 'x_raw_payload') {
		my $payload = eval { JSON::PP::decode_json($value) };
		return "Invalid raw payload: $@" if !$payload;
		my $raw_command = $payload->{command} // '';
		my $input = $payload->{input};

		# Der Simulator spiegelt die fuer Folgeschritte relevanten Readings sofort.
		if ($raw_command eq 'joingroup') {
			my $coordinator = AudioManagerTest_device_by_sonos_name($input);
			return "Unknown coordinator $input" if !defined($coordinator);
			$defs{$device}{READINGS}{coordinatorUuid}{VAL} = $defs{$coordinator}{READINGS}{uuid}{VAL};
		} elsif ($raw_command eq 'leavegroup') {
			$defs{$device}{READINGS}{coordinatorUuid}{VAL} = $defs{$device}{READINGS}{uuid}{VAL};
		} elsif ($raw_command eq 'volume') {
			$defs{$device}{READINGS}{volume}{VAL} = $input;
		} elsif ($raw_command eq 'mute' || $raw_command eq 'unmute') {
			$defs{$device}{READINGS}{mute}{VAL} = $raw_command eq 'mute' ? 'true' : 'false';
		} elsif ($raw_command eq 'pause') {
			$defs{$device}{READINGS}{transportState}{VAL} = 'PAUSED_PLAYBACK';
		} elsif ($raw_command eq 'stop') {
			$defs{$device}{READINGS}{transportState}{VAL} = 'STOPPED';
		} elsif ($raw_command eq 'setavtransporturi') {
			$defs{$device}{READINGS}{currentTrack_trackUri}{VAL} = $input;
		} elsif ($raw_command eq 'switchtoqueue') {
			$defs{$device}{READINGS}{Input}{VAL} = 'Queue';
		} elsif ($raw_command eq 'playmode') {
			$defs{$device}{READINGS}{playmode}{VAL} = $input;
		} elsif ($raw_command eq 'selecttrack') {
			$defs{$device}{READINGS}{currentTrack_TrackNumber}{VAL} = $input;
		} elsif ($raw_command eq 'play') {
			$defs{$device}{READINGS}{transportState}{VAL} = 'PLAYING';
		}

		return undef;
	}
	# Direkte Playerwerte werden fuer nachfolgende Snapshots synchron aktualisiert.
	if ($command eq 'mute' || $command eq 'volume') {
		$defs{$device}{READINGS}{$command}{VAL} = $value;
	} elsif ($command eq 'volumeUp' || $command eq 'volumeDown') {
		my $current = 0 + ReadingsVal($device, 'volume', 0);
		my $next = $command eq 'volumeUp' ? $current + 1 : $current - 1;
		$next = 100 if $next > 100;
		$next = 0 if $next < 0;
		$defs{$device}{READINGS}{volume}{VAL} = $next;
	} elsif ($command eq 'leaveGroup') {
		$defs{$device}{READINGS}{coordinatorUuid}{VAL} = $defs{$device}{READINGS}{uuid}{VAL};
	} elsif ($command eq 'joinGroup') {
		my $coordinator = AudioManagerTest_device_by_sonos_name($value);
		return "Unknown coordinator $value" if !defined($coordinator);
		$defs{$device}{READINGS}{coordinatorUuid}{VAL} = $defs{$coordinator}{READINGS}{uuid}{VAL};
	} elsif ($command eq 'pause') {
		$defs{$device}{READINGS}{transportState}{VAL} = 'PAUSED_PLAYBACK';
	} elsif ($command eq 'stop') {
		$defs{$device}{READINGS}{transportState}{VAL} = 'STOPPED';
	} elsif ($command eq 'playUri') {
		$defs{$device}{READINGS}{currentTrack_trackUri}{VAL} = $value;
		$defs{$device}{READINGS}{transportState}{VAL} = 'PLAYING';
	} elsif ($command eq 'playFav') {
		$defs{$device}{READINGS}{currentTrack_trackUri}{VAL} = "favorite:$value";
		$defs{$device}{READINGS}{Input}{VAL} = 'Radio';
		$defs{$device}{READINGS}{transportState}{VAL} = 'PLAYING';
	} elsif ($command eq 'input') {
		$defs{$device}{READINGS}{Input}{VAL} = $value;
	} elsif ($command eq 'play') {
		$defs{$device}{READINGS}{transportState}{VAL} = 'PLAYING';
	}

	return undef;
}

# Simuliert MQTT2_DEVICEs direkten Publish ueber sein IODev und protokolliert das Topic.
sub IOWrite($$$) {
	my ($hash, $command, $message) = @_;
	push @AudioManagerTestEnv::COMMAND_LOG, "$command $hash->{NAME} $message";
	return undef;
}

# Nimmt Logmeldungen in Tests ohne weitere Seiteneffekte auf.
sub Log3($$$) {
	my ($name, $level, $message) = @_;
	push @AudioManagerTestEnv::LOG_MESSAGES, {
		name => $name,
		level => $level,
		message => $message,
	};
	return undef;
}

package AudioManagerTestEnv;

1;

