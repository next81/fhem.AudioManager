package AudioManager::FHEMGateway;

use strict;
use warnings;

# Kapselt alle globalen FHEM-Zugriffe hinter injizierbaren Callbacks. Der
# Scheduler und die Backends lassen sich dadurch ohne laufende FHEM-Instanz testen.
sub new {
	my ($class, %callbacks) = @_;
	return bless { callbacks => \%callbacks }, $class;
}

# Waehlt bevorzugt den Testcallback und ansonsten die produktive Implementierung.
sub _callback {
	my ($self, $name, $fallback) = @_;
	return $self->{callbacks}{$name} if ref($self->{callbacks}{$name}) eq 'CODE';
	return $fallback;
}

# Liefert einen Device-Hash oder undef, wenn der Name in FHEM nicht existiert.
sub device {
	my ($self, $name) = @_;
	my $callback = $self->_callback(device => sub { return $main::defs{ $_[0] } });
	return $callback->($name);
}

# Liefert alle FHEM-Devicenamen stabil sortiert fuer Topologiepruefungen.
sub device_names {
	my ($self) = @_;
	my $callback = $self->_callback(device_names => sub { return [ sort keys %main::defs ] });
	return $callback->();
}

# Liest ein Attribut mit dem ueblichen FHEM-Fallbackverhalten.
sub attr_value {
	my ($self, @arguments) = @_;
	my $callback = $self->_callback(attr_value => sub { return &main::AttrVal(@_) });
	return $callback->(@arguments);
}

# Liest ein Reading mit dem ueblichen FHEM-Fallbackverhalten.
sub reading_value {
	my ($self, @arguments) = @_;
	my $callback = $self->_callback(reading_value => sub { return &main::ReadingsVal(@_) });
	return $callback->(@arguments);
}

# Liefert den letzten FHEM-Zeitstempel eines Readings. Damit kann eine direkte
# Antwort auch dann erkannt werden, wenn event-on-change-reading ihr Event unterdrueckt.
sub reading_timestamp {
	my ($self, $device, $reading, $default) = @_;
	my $callback = $self->{callbacks}{reading_timestamp};
	return $callback->($device, $reading, $default) if ref($callback) eq 'CODE';
	my $hash = $self->device($device);
	return $default if !$hash || !exists($hash->{READINGS}{$reading});
	return defined($hash->{READINGS}{$reading}{TIME})
		? $hash->{READINGS}{$reading}{TIME} : $default;
}

# Sendet einen Set-Befehl ueber FHEMs regulaere Kommandoschnittstelle und gibt
# deren Fehlermeldung unveraendert an den aufrufenden Adapter zurueck.
sub set_command {
	my ($self, $device, $command, @arguments) = @_;
	my $callback = $self->_callback(command_set => sub { return main::CommandSet(undef, $_[0]) });
	my $definition = join(' ', grep { defined($_) && $_ ne '' } $device, $command, @arguments);
	return $callback->($definition);
}

# Veroeffentlicht ein MQTT-Kommando ueber das IODev eines verwalteten MQTT2-Devices.
# Ein separates Bridge-Device ist dafuer weder erforderlich noch Teil des Vertrags.
sub mqtt_publish {
	my ($self, $device, $topic, $payload) = @_;
	my $callback = $self->{callbacks}{mqtt_publish};
	return $callback->($device, $topic, $payload) if ref($callback) eq 'CODE';
	my $device_hash = $self->device($device);
	return "MQTT-Device $device existiert nicht" if !$device_hash;
	my $message = defined($payload) && $payload ne '' ? "$topic $payload" : $topic;
	return main::IOWrite($device_hash, 'publish', $message);
}

# Aktualisiert ein Reading; undef wird als leerer sichtbarer Wert normalisiert.
sub update_reading {
	my ($self, $hash, $reading, $value, $trigger) = @_;
	my $callback = $self->_callback(update_reading => sub { return &main::readingsSingleUpdate(@_) });
	return $callback->($hash, $reading, defined($value) ? $value : '', $trigger ? 1 : 0);
}

# Begrenzt Notify auf die tatsaechlich verwalteten Devices und den FHEM-Lifecycle.
sub set_notify_devices {
	my ($self, $hash, $devices) = @_;
	my $callback = $self->_callback(set_notify_devices => sub { return &main::setNotifyDev(@_) });
	return $callback->($hash, $devices);
}

# Liefert die FHEM-Zeitquelle stets skalar, da gettimeofday im Listenkontext
# zusaetzlich die Mikrosekunden als zweiten Wert zurueckgeben wuerde.
sub now {
	my ($self) = @_;
	my $callback = $self->_callback(now => sub {
		return defined(&main::gettimeofday) ? main::gettimeofday() : time;
	});
	return scalar $callback->();
}

# Plant einen kurzen InternalTimer, ohne FHEMs Initialisierung zu blockieren.
sub schedule {
	my ($self, $delay, $hash, $function) = @_;
	my $callback = $self->_callback(schedule => sub {
		return main::InternalTimer(main::gettimeofday() + $_[0], $_[2], $_[1], 0);
	});
	return $callback->($delay, $hash, $function);
}

# Entfernt alle Timer derselben Instanz und Callbackfunktion idempotent.
sub cancel_timer {
	my ($self, $hash, $function) = @_;
	my $callback = $self->{callbacks}{cancel_timer};
	return $callback->($hash, $function) if ref($callback) eq 'CODE';
	return undef if !defined(&main::RemoveInternalTimer);
	return main::RemoveInternalTimer($hash, $function);
}

# Schreibt eine bereits aufbereitete Diagnosemeldung ueber FHEMs Logsystem.
sub log {
	my ($self, $name, $level, $message) = @_;
	my $callback = $self->_callback(log => sub { return &main::Log3(@_) });
	return $callback->($name, $level, $message);
}

1;
