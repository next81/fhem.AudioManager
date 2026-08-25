package AudioManager::Backend;

use strict;
use warnings;
use Carp qw(croak);

our $INTERFACE_VERSION = 3;
our %FACTORIES;

# Registriert einen Backend-Treiber unter einem stabilen Namen. Weitere
# Integrationen koennen sich dadurch einklinken, ohne den AudioManager-Core zu aendern.
sub register {
	my ($class, $name, $factory) = @_;
	croak 'Backend-Name fehlt' if !defined($name) || $name !~ /^[a-z][a-z0-9_]*$/;
	croak "Factory fuer $name ist kein Callback" if ref($factory) ne 'CODE';
	$FACTORIES{$name} = $factory;
	return 1;
}

# Erzeugt einen registrierten Backend-Adapter und prueft dessen Schnittstellenversion.
sub create {
	my ($class, $name, %arguments) = @_;
	my $factory = $FACTORIES{$name};
	croak "Unbekanntes AudioManager-Backend: $name" if ref($factory) ne 'CODE';
	my $backend = $factory->(%arguments);
	croak "Backend $name lieferte kein Objekt" if ref($backend) eq '';
	my $version = $backend->interface_version;
	croak "Backend $name verwendet Schnittstelle $version statt $INTERFACE_VERSION"
		if !defined($version) || $version != $INTERFACE_VERSION;
	return $backend;
}

# Liefert die versionierte Vertragsebene, gegen die der Manager einen Adapter prueft.
sub interface_version {
	return $INTERFACE_VERSION;
}

# Abstrakte Methoden schlagen sichtbar fehl, damit unvollstaendige Fremdadapter
# nicht erst waehrend einer laufenden Alarmansage unbemerkt ausfallen.
sub _abstract {
	my ($self, $method) = @_;
	croak ref($self) . " implementiert $method() nicht";
}

# Liefert die eindeutige Instanzkennung des Backends innerhalb eines Managers.
sub id { return $_[0]->_abstract('id'); }

# Prueft die Konfiguration und alle explizit verwalteten Player.
sub validate { return $_[0]->_abstract('validate'); }

# Uebernimmt optionale Laufzeitparameter; Backends ohne eigene Parameter duerfen sie ignorieren.
sub configure { return undef; }

# Beschreibt die vom Adapter angebotenen Health- und Recovery-Faehigkeiten.
sub health_capabilities { return $_[0]->_abstract('health_capabilities'); }

# Uebersetzt backendtypische Device-Ereignisse in neutrale Supervisor-Signale.
sub health_event { return $_[0]->_abstract('health_event'); }

# Startet eine backendtypische, nicht steuernde Erreichbarkeitspruefung.
sub health_probe { return $_[0]->_abstract('health_probe'); }

# Prueft nach der Entprellung, ob eine automatische Recovery erforderlich ist.
sub health_check { return $_[0]->_abstract('health_check'); }

# Fuehrt genau eine backendtypische Recoveryaktion aus.
sub health_recover { return $_[0]->_abstract('health_recover'); }

# Bestaetigt die Recovery ausschliesslich anhand frischer Backenddaten.
sub health_verify { return $_[0]->_abstract('health_verify'); }

# Liefert zusaetzliche, backendtypische Healthdetails fuer Diagnoseausgaben.
sub health_details { return {}; }

# Meldet tolerierte Abweichungen zwischen nativer Topologie und Verwaltungsgrenze.
sub topology_warnings { return []; }

# Liefert Devices, deren Ereignisse eine backendtypische Topologieaenderung anzeigen.
sub topology_devices { return []; }

# Liefert FHEM-Devices, deren Ereignisse der Healthadapter zusaetzlich benoetigt.
sub health_devices { return []; }

# Prueft einen konkreten Start vor der Snapshot-Erfassung ohne Seiteneffekte.
# Backends ohne besondere Gruppengrenzen duerfen jeden validierten Start zulassen.
sub preflight_start { return undef; }

# Liefert die explizite Verwaltungsgrenze als sortierte Devicenamen.
sub managed_players { return $_[0]->_abstract('managed_players'); }

# Loest einen backendlokalen Zielausdruck in konkrete Player auf.
sub resolve_target { return $_[0]->_abstract('resolve_target'); }

# Erstellt einen fluechtigen Snapshot fuer Unterbrechung und Wiederherstellung.
sub snapshot { return $_[0]->_abstract('snapshot'); }

# Startet einen vorbereiteten Audioauftrag asynchron.
sub start { return $_[0]->_abstract('start'); }

# Fuehrt noch ausstehende Gruppierungs- oder Startschritte ohne Blockieren fort.
sub progress { return $_[0]->_abstract('progress'); }

# Pausiert einen aktiven Auftrag und sichert den tatsaechlichen Playerzustand.
sub suspend { return $_[0]->_abstract('suspend'); }

# Setzt einen zuvor pausierten Auftrag anhand seines Laufzeitsnapshots fort.
sub resume { return $_[0]->_abstract('resume'); }

# Beendet die aktuelle Ausgabe eines Auftrags auf seinen physischen Zielen.
sub stop { return $_[0]->_abstract('stop'); }

# Stellt einen Snapshot nach dem Ende der gesamten Manager-Sitzung wieder her.
sub restore { return $_[0]->_abstract('restore'); }

# Ermittelt, ob ein endlicher Auftrag auf mindestens einem Ziel hoerbar laeuft.
sub is_playing { return $_[0]->_abstract('is_playing'); }

# Liefert die aktuell aus den Player-Readings abgeleitete Gruppentopologie.
sub topology { return $_[0]->_abstract('topology'); }

# Fuehrt eine explizite, kontrollierte Gruppenoperation aus.
sub group_command { return $_[0]->_abstract('group_command'); }

# Setzt Mute fuer eine bereits aufgeloeste Playerliste.
sub set_mute { return $_[0]->_abstract('set_mute'); }

# Setzt die Lautstaerke fuer eine bereits aufgeloeste Playerliste.
sub set_volume { return $_[0]->_abstract('set_volume'); }

# Liefert normalisierte Metadaten des primaeren Players fuer eine aktive Ausgabe.
# Backends ohne Medienreadings lassen die optionale Statusoberflaeche leer.
sub media_status { return {}; }

# Steuert die native Wiedergabe bereits aufgeloester Ziele.
sub transport_command { return ref($_[0]) . ' unterstuetzt keine Transportsteuerung'; }

# Aendert die Lautstaerke bereits aufgeloester Ziele um einen nativen Schritt.
sub change_volume { return ref($_[0]) . ' unterstuetzt keine Lautstaerkeschritte'; }

1;
