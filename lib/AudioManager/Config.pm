package AudioManager::Config;

use strict;
use warnings;

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

# Liefert eine Kopie der Standardlautstaerken fuer Attributparser und Tests.
sub default_volumes {
	return { %DEFAULT_VOLUMES };
}

# Parst kommaseparierte name:value-Zahlen und fuehrt partielle Werte mit Defaults zusammen.
sub parse_numeric_map {
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
sub parse_volume_policies {
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
sub time_range_match {
	my ($start, $end, $minute_of_day) = @_;
	return $start < $end
		? $minute_of_day >= $start && $minute_of_day < $end
		: $minute_of_day >= $start || $minute_of_day < $end;
}

# Parst statische oder zeitabhaengige Sicherheitsgrenzen je Audioart.
sub parse_volume_limits {
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
				|| time_range_match($existing->{start}, $existing->{end}, $start)
				|| time_range_match($start, $end, $existing->{start});
			return (undef, "Lautstaerkefenster fuer $type ueberlappen sich") if $overlaps;
		}

		push @{ $result{$type} }, $rule;
	}

	return (\%result, undef);
}

# Liefert die fuer Audioart und lokale Tagesminute wirksame Sicherheitsgrenze.
sub volume_limit_at {
	my ($limits, $type, $minute_of_day) = @_;
	return undef if !exists($limits->{$type});

	# Pro Audioart sind die Regeln ueberlappungsfrei, daher kann hoechstens eine passen.
	for my $rule (@{ $limits->{$type} }) {
		return $rule if $rule->{all_day}
			|| time_range_match($rule->{start}, $rule->{end}, $minute_of_day);
	}

	return undef;
}

# Parst eine Kommaliste, in der Eintraege mit Gleichheitszeichen eine neue Audioart beginnen.
sub parse_quiet_hours {
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
sub quiet_hours_match {
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
sub quiet_hours_active {
	my ($gateway, $quiet_hours, $type) = @_;
	my @local_time = localtime($gateway->now);
	my $minute_of_day = 60 * $local_time[2] + $local_time[1];
	return quiet_hours_match($quiet_hours, $type, $minute_of_day);
}

# Parst benannte logische Zonen, die backenduebergreifend aus FHEM-Playernamen bestehen duerfen.
sub parse_zones {
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
sub parse_backend_availability {
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
sub configuration {
	my ($hash, $gateway, $default_priorities) = @_;
	my ($priorities) = parse_numeric_map(
		$gateway->attr_value($hash->{NAME}, 'priorities', ''),
		$default_priorities, 0, 10_000,
	);
	my ($volumes) = parse_numeric_map(
		$gateway->attr_value($hash->{NAME}, 'defaultVolumes', ''),
		default_volumes(), 0, 100,
	);
	my ($policies) = parse_volume_policies(
		$gateway->attr_value($hash->{NAME}, 'volumePolicies', ''),
	);
	my ($volume_limits) = parse_volume_limits(
		$gateway->attr_value($hash->{NAME}, 'volumeLimits', ''),
	);
	my ($quiet_hours) = parse_quiet_hours(
		$gateway->attr_value($hash->{NAME}, 'quietHours', ''),
	);
	my ($zones) = parse_zones($gateway->attr_value($hash->{NAME}, 'zones', ''));
	my ($availability) = parse_backend_availability(
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

1;
