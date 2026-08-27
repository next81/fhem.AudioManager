# Copyright (c) 2026 Andreas Planer

##############################################
# Priorisiertes, backendneutrales Audiomanagement fuer FHEM
package main;

use strict;
use warnings;
use lib './lib';
use AudioManager::Module::FHEM ();
use vars qw(%defs %attr $readingFnAttributes);

our $AUDIOMANAGER_VERSION = '0.6.4';
our $AUDIOMANAGER_WORKER_DELAY = 0.25;


# Vorwaertsdeklaration haelt den prototypisierten Timer-Callback zur Compilezeit sichtbar.
sub AudioManager_schedule_worker($);

# Registriert die FHEM-Callbacks ueber die zentrale FHEM-Schnittstelle.
sub AudioManager_Initialize($) {
	my ($hash) = @_;
	return AudioManager::Module::FHEM::initialize($hash, $readingFnAttributes);
}

# Definiert einen Manager ueber die zentrale FHEM-Schnittstelle.
sub AudioManager_Define($$) {
	my ($hash, $definition) = @_;
	return AudioManager::Module::FHEM::define(
		$hash, $definition, $AUDIOMANAGER_VERSION, 'AudioManager_Worker', \&AudioManager_schedule_worker,
	);
}

# Entfernt einen Manager ueber die zentrale FHEM-Schnittstelle.
sub AudioManager_Undef($$) {
	my ($hash, undef) = @_;
	return AudioManager::Module::FHEM::undefine($hash, 'AudioManager_Worker');
}

# Validiert und uebernimmt Attribute ueber die zentrale FHEM-Schnittstelle.
sub AudioManager_Attr(@) {
	my ($operation, $name, $attribute, @values) = @_;
	return AudioManager::Module::FHEM::attr(
		\%defs, $operation, $name, $attribute, \@values, \&AudioManager_schedule_worker,
	);
}

# Plant den FHEM-Timer ueber die ausgelagerte Runtime-Schicht.
sub AudioManager_schedule_worker($) {
	my ($hash) = @_;
	return AudioManager::Module::FHEM::schedule_worker(
		$hash, $AUDIOMANAGER_WORKER_DELAY, 'AudioManager_Worker',
	);
}

# Bleibt als stabiler FHEM-Timer-Callback erhalten und delegiert die Arbeit.
sub AudioManager_Worker($) {
	my ($hash) = @_;
	return AudioManager::Module::FHEM::worker(
		$hash, \%defs, \&AudioManager_schedule_worker,
	);
}

# Delegiert FHEM-Set-Kommandos an die zentrale FHEM-Schnittstelle.
sub AudioManager_Set($@) {
	my ($hash, @arguments) = @_;
	return AudioManager::Module::FHEM::set(
		$hash, \@arguments, \&AudioManager_schedule_worker,
	);
}

# Delegiert FHEM-Get-Kommandos an die zentrale FHEM-Schnittstelle.
sub AudioManager_Get($@) {
	my ($hash, @arguments) = @_;
	return AudioManager::Module::FHEM::get($hash, \@arguments);
}

# Delegiert FHEM-Notify-Ereignisse an die zentrale FHEM-Schnittstelle.
sub AudioManager_Notify($$) {
	my ($hash, $device) = @_;
	return AudioManager::Module::FHEM::notify(
		$hash, $device, \&AudioManager_schedule_worker, \&AudioManager::Module::FHEM::set_notify_devices,
	);
}

# Bietet FHEM-Perlcode eine sichere direkte API ohne fragile neu gequotete fhem()-Texte.
sub AudioManager_Submit($$$) {
	my ($manager, $type, $options) = @_;
	return AudioManager::Module::FHEM::submit_api(
		\%defs, $manager, $type, $options, \&AudioManager_schedule_worker,
	);
}

# Ersetzt bestehende say-Helfer durch einen duennen, zentral verwalteten Kompatibilitaetsaufruf.
sub AudioManager_Say($$;$) {
	my ($manager, $text, $target) = @_;
	return AudioManager::Module::FHEM::say_api(
		\%defs, $manager, $text, $target, \&AudioManager_schedule_worker,
	);
}

1;

=pod

=head1 NAME

AudioManager - priorisiertes, backendneutrales Audiomanagement fuer FHEM

=head1 SYNOPSIS

	define Audio AudioManager sonos2mqtt=Sonos.FlurEG,Sonos.Kueche
	attr Audio ttsDevice SonosTTS
	set Audio speak Die Waschmaschine ist fertig.

=head1 SECURITY

Das Modul fuehrt kein C<save> aus. Es steuert nur die im Define explizit genannten Player.

=item device
=item summary Prioritized audio sessions with pluggable backends
=item summary_DE Priorisierte Audiositzungen mit austauschbaren Backends

=begin html

<a id="AudioManager"></a>
<h3>AudioManager</h3>
<p>Coordinates prioritized streams, queues, clips, speech and alarms through
versioned backend adapters. The initial backend supports sonos2mqtt speakers.</p>

<a id="AudioManager-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; AudioManager sonos2mqtt=&lt;speaker&gt;[,&lt;speaker&gt;...]</code></p>
<p>Missing FHEM devices in a mixed speaker list are ignored and reported at
error log level. At least one existing speaker is required. Existing devices
still have to satisfy the backend's speaker validation.</p>

<a id="AudioManager-set"></a>
<h4>Set</h4>
<p>Playback commands accept the leading options <code>target=...</code>,
<code>volume=0..100</code> and <code>fadein=0..86400</code>. Without
<code>target</code>, all managed players are addressed in their existing groups.
Targets may be <code>all</code>, <code>backend:&lt;id&gt;</code>,
<code>group:&lt;player&gt;</code>, <code>player:&lt;player&gt;</code>,
<code>players:&lt;player,...&gt;</code> or <code>zone:&lt;name&gt;</code>.</p>
<ul>
<a id="AudioManager-set-alarm"></a>
<li><code>alarm [target=...] [volume=...] [fadein=seconds] [text=|uri=]&lt;content&gt;</code><br>
Creates a finite, highest-priority alarm. Content with <code>scheme://</code> is
detected as a URI; other content is rendered through <code>ttsDevice</code>.
The optional prefix overrides this detection.</li>
<a id="AudioManager-set-group"></a>
<li><code>group create &lt;coordinator&gt; &lt;member&gt;[,&lt;member&gt;...]</code><br>
<code>group add &lt;player&gt; &lt;coordinator&gt;</code><br>
<code>group remove &lt;player&gt;</code><br>
<code>group dissolve &lt;coordinator&gt;</code><br>
Creates or changes a native group. Every player must be managed by the same
backend.</li>
<a id="AudioManager-set-speak"></a>
<li><code>speak [target=...] [volume=...] [fadein=seconds] &lt;text&gt;</code><br>
Renders the text through <code>ttsDevice</code> and queues it as a finite speech
request. Equal texts may be filtered by <code>speakDedupeWindow</code>.</li>
<a id="AudioManager-set-play"></a>
<li><code>play [target=...] [volume=...] [fadein=seconds] &lt;uri&gt;</code><br>
Plays one finite media URI and resumes the interrupted lower-priority source
after completion.</li>
<a id="AudioManager-set-stream"></a>
<li><code>stream [target=...] [volume=...] [fadein=seconds] &lt;favorite|uri&gt;</code><br>
Starts a persistent stream. Content with <code>scheme://</code> is used as a URI;
all other content is treated as a Sonos favorite name.</li>
<a id="AudioManager-set-queue"></a>
<li><code>queue [target=...] [volume=...] [fadein=seconds]</code><br>
Starts the media queue already present on the selected coordinator. Managed URI
lists are available through the Perl API.</li>
<a id="AudioManager-set-stop"></a>
<li><code>stop [all|target=...|&lt;request-id&gt;|alarm|speak|play|queue|stream]</code><br>
Cancels all requests, one exact request, one audio type or all requests that
overlap the selected target. A target stop also reaches the backend when no
nonterminal request remains.</li>
<a id="AudioManager-set-transport"></a>
<li><code>transport [target=...] &lt;play|pause|previous|next&gt;</code><br>
Sends a direct transport command to the selected managed players without
creating a scheduler request.</li>
<a id="AudioManager-set-mute"></a>
<li><code>mute [target=...] &lt;on|off&gt; [force]</code><br>
<code>on</code> remembers each player's previous mute state. <code>off</code>
restores that snapshot; <code>off force</code> unmutes every selected player.</li>
<a id="AudioManager-set-volume"></a>
<li><code>volume [target=...] &lt;0..100&gt;</code><br>
Sets the volume directly on all selected managed players.</li>
<a id="AudioManager-set-volumeStep"></a>
<li><code>volumeStep [target=...] &lt;up|down&gt;</code><br>
Changes the volume by the backend-specific step without creating a scheduler
request.</li>
</ul>
<p>Alarm content that looks like a URL with <code>scheme://</code> is used as a URI;
all other content is rendered as text. The optional <code>text=</code> and
<code>uri=</code> prefixes override this automatic detection.</p>
<p>Stream content with <code>scheme://</code> is played as a persistent URI;
all other stream content is treated as a Sonos favorite name.</p>
<p><code>mute on</code> stores each target player's previous mute state once.
A normal <code>mute off</code> restores only stored targets, while
<code>mute off force</code> unmutes all selected targets regardless of that state. Mute
snapshots are volatile and are discarded on redefine or restart.</p>
<p>The normalized readings <code>source</code>, <code>title</code>, <code>artist</code>,
<code>album</code>, <code>albumArtUri</code>, <code>transportState</code>,
<code>volume</code> and <code>mute</code> describe the highest-priority active
request and can be used directly by FTUI.</p>
<p>Existing <code>all</code>, backend and <code>group:</code> targets remain playable
when an unmanaged speaker joins through the Sonos app. Such a speaker participates
only as part of its native group and cannot be selected directly. The
<code>topologyWarning</code> reading reports the deviation until it leaves.</p>

<a id="AudioManager-get"></a>
<h4>Get</h4>
<ul>
<a id="AudioManager-get-topology"></a>
<li><code>topology</code><br>
Returns the current player and group topology as canonical JSON, separated by
backend instance.</li>
<a id="AudioManager-get-requests"></a>
<li><code>requests</code><br>
Returns all tracked scheduler requests as canonical JSON, including ID, type,
state, priority, targets, timestamps and terminal reason.</li>
<a id="AudioManager-get-priorities"></a>
<li><code>priorities</code><br>
Returns the effective priorities after merging configured partial overrides
with the defaults.</li>
<a id="AudioManager-get-health"></a>
<li><code>health</code><br>
Returns the detailed supervisor report for all backend instances as canonical
JSON.</li>
</ul>

<a id="AudioManager-attr"></a>
<h4>Attributes</h4>
<ul>
<a id="AudioManager-attr-priorities"></a>
<li><code>priorities &lt;type:value,...&gt;</code><br>
Overrides priorities from 0 to 10000 for selected audio types. Missing types
keep the defaults <code>alarm:400,speak:300,play:200,queue:100,stream:50</code>;
higher values win and equal values use FIFO.</li>
<a id="AudioManager-attr-defaultVolumes"></a>
<li><code>defaultVolumes &lt;type:0..100,...&gt;</code><br>
Overrides the request volume for selected audio types. Missing types keep
<code>alarm:60,speak:25,play:20,queue:15,stream:12</code>.</li>
<a id="AudioManager-attr-volumePolicies"></a>
<li><code>volumePolicies &lt;type:fixed|minimum|keep,...&gt;</code><br>
Selects whether the configured volume is set exactly, used only as a minimum,
or left unchanged. The defaults are <code>alarm:minimum</code> and
<code>fixed</code> for every other type.</li>
<a id="AudioManager-attr-volumeLimits"></a>
<li><code>volumeLimits &lt;type:min-max,...&gt;</code> or
<code>&lt;type:start-end:min-max,...&gt;</code><br>
Defines independent all-day or local-time safety limits. Following time windows
for the same type may omit the type, for example
<code>alarm:8-20:30-80,20-8:30-50</code>.</li>
<a id="AudioManager-attr-quietHours"></a>
<li><code>quietHours &lt;type=start-end[,start-end...],...&gt;</code><br>
Blocks new requests of the named types during local-time windows. Windows may
cross midnight; their start is inclusive and their end is exclusive.</li>
<a id="AudioManager-attr-speakDedupeWindow"></a>
<li><code>speakDedupeWindow &lt;seconds&gt;</code><br>
Filters equal normalized speech texts within this nonnegative interval. The
default is 5 seconds; 0 disables filtering.</li>
<a id="AudioManager-attr-ttsDevice"></a>
<li><code>ttsDevice &lt;device&gt;</code><br>
Names the FHEM Text2Speech provider used by <code>speak</code> and text-based
<code>alarm</code> requests.</li>
<a id="AudioManager-attr-zones"></a>
<li><code>zones &lt;name=player,player;other=player&gt;</code><br>
Defines logical <code>zone:</code> targets. Every player must be listed in the
AudioManager define; one logical zone may span multiple backends.</li>
<a id="AudioManager-attr-backendAvailability"></a>
<li><code>backendAvailability &lt;prefix=device[:reading],...&gt;</code><br>
Maps an MQTT prefix to an optional bridge availability reading. The reading
defaults to <code>connected</code>; without this attribute the adapter attempts
automatic discovery.</li>
<a id="AudioManager-attr-startTimeout"></a>
<li><code>startTimeout &lt;seconds&gt;</code><br>
Sets the positive timeout for TTS generation and playback-start confirmation.
The default is 15 seconds.</li>
<a id="AudioManager-attr-stopGrace"></a>
<li><code>stopGrace &lt;seconds&gt;</code><br>
Sets the positive grace period after the last confirmed playback before a
finite request completes. The default is 2 seconds.</li>
<a id="AudioManager-attr-groupTimeout"></a>
<li><code>groupTimeout &lt;seconds&gt;</code><br>
Limits how long the backend waits for native grouping phases. The default is
30 seconds.</li>
<a id="AudioManager-attr-healthDebounce"></a>
<li><code>healthDebounce &lt;seconds&gt;</code><br>
Debounces health checks after relevant backend events. The default is 3
seconds; 0 disables the delay.</li>
<a id="AudioManager-attr-healthVerifyTimeout"></a>
<li><code>healthVerifyTimeout &lt;seconds&gt;</code><br>
Sets the positive timeout for a player to confirm an active health probe. The
default is 15 seconds.</li>
<a id="AudioManager-attr-healthRecoveryCooldown"></a>
<li><code>healthRecoveryCooldown &lt;seconds&gt;</code><br>
Sets the minimum interval between subscription recovery attempts. The default
is 60 seconds; 0 disables the cooldown.</li>
<a id="AudioManager-attr-healthProbeInterval"></a>
<li><code>healthProbeInterval &lt;seconds&gt;</code><br>
Sets the positive interval between periodic player health probes. The default
is 900 seconds.</li>
<a id="AudioManager-attr-autoLeave"></a>
<li><code>autoLeave &lt;0|1&gt;</code><br>
Allows a request to split an existing native group temporarily and restore it
afterwards. The safe default is 0; explicit <code>group</code> commands are not
affected.</li>
<a id="AudioManager-attr-disable"></a>
<li><code>disable &lt;0|1&gt;</code><br>
With 1, cancels active requests, rejects new playback requests and sets the
manager state to <code>disabled</code>. The default is 0.</li>
</ul>
<p><code>volumeLimits</code> defines independent safety bounds per audio type.
A plain range such as <code>stream:10-40</code> applies all day. Timed rules use
<code>type:start-end:min-max</code>; following windows for the same type may omit
the type. Rules are selected from local time when a request is accepted and
their end is exclusive. The bounds also clamp explicit volume values,
<code>minimum</code>, <code>keep</code>, and volumes restored during resume.</p>
<p>The adapter actively checks every managed sonos2mqtt speaker with the
read-only <code>GetZoneInfo</code> command. Only a fresh player response confirms the
probe. If a response is missing, the adapter publishes exactly one
<code>&lt;prefix&gt;/cmd/check-subscriptions</code> and retries the affected player.</p>
<p>After the retry also fails, <code>backendHealthError</code> names the offline
player and one level 2 log entry is written. A confirmed recovery clears the
reading and creates one level 3 log entry. Repeated unchanged states are not logged.</p>
<p>A bridge device remains optional. The adapter automatically detects an exact
<code>&lt;prefix&gt;/connected</code> mapping in an existing MQTT2_DEVICE on the same
IODev, independent of MQTT2_Discovery. <code>backendAvailability</code> can provide
the mapping explicitly. Use <code>get &lt;name&gt; health</code> for the detailed report.</p>

=end html

=begin html_DE

<a id="AudioManager"></a>
<h3>AudioManager</h3>
<p>Koordiniert Streams, Media-Queues, Einzelclips, Sprache und Alarme ueber
versionierte Backendadapter. Der erste Adapter unterstuetzt sonos2mqtt-Speaker.</p>

<a id="AudioManager-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; AudioManager sonos2mqtt=&lt;speaker&gt;[,&lt;speaker&gt;...]</code></p>
<p>Ein Bridge-Device ist nicht erforderlich. Nur explizit genannte
<code>sonos2mqtt_speaker</code> werden verwaltet.</p>
<p>Nicht vorhandene FHEM-Devices in einer gemischten Playerliste werden ignoriert
und mit Fehler-Loglevel gemeldet. Mindestens ein vorhandener Player ist
erforderlich. Vorhandene Devices muessen die Playerpruefung des Backends weiterhin
erfuellen.</p>

<a id="AudioManager-set"></a>
<h4>Set</h4>
<p>Wiedergabebefehle akzeptieren am Anfang die Optionen
<code>target=...</code>, <code>volume=0..100</code> und
<code>fadein=0..86400</code>. Ohne <code>target</code> werden alle verwalteten
Player in ihren vorhandenen Gruppen angesprochen. Ziele sind <code>all</code>,
<code>backend:&lt;ID&gt;</code>, <code>group:&lt;Player&gt;</code>,
<code>player:&lt;Player&gt;</code>, <code>players:&lt;Player,...&gt;</code> oder
<code>zone:&lt;Name&gt;</code>.</p>
<ul>
<a id="AudioManager-set-alarm"></a>
<li><code>alarm [target=...] [volume=...] [fadein=Sekunden] [text=|uri=]&lt;Inhalt&gt;</code><br>
Erzeugt einen endlichen Alarm mit hoechster Prioritaet. Inhalt mit
<code>Schema://</code> wird als URI erkannt, anderer Inhalt ueber
<code>ttsDevice</code> gerendert. Das optionale Praefix uebersteuert die Erkennung.</li>
<a id="AudioManager-set-group"></a>
<li><code>group create &lt;Coordinator&gt; &lt;Mitglied&gt;[,&lt;Mitglied&gt;...]</code><br>
<code>group add &lt;Player&gt; &lt;Coordinator&gt;</code><br>
<code>group remove &lt;Player&gt;</code><br>
<code>group dissolve &lt;Coordinator&gt;</code><br>
Erstellt oder aendert eine native Gruppe. Alle Player muessen vom selben
Backend verwaltet werden.</li>
<a id="AudioManager-set-speak"></a>
<li><code>speak [target=...] [volume=...] [fadein=Sekunden] &lt;Text&gt;</code><br>
Rendert den Text ueber <code>ttsDevice</code> und reiht ihn als endliche Ansage
ein. Gleiche Texte koennen durch <code>speakDedupeWindow</code> gefiltert werden.</li>
<a id="AudioManager-set-play"></a>
<li><code>play [target=...] [volume=...] [fadein=Sekunden] &lt;URI&gt;</code><br>
Spielt eine einzelne endliche Medien-URI und setzt die unterbrochene Quelle mit
niedrigerer Prioritaet anschliessend fort.</li>
<a id="AudioManager-set-stream"></a>
<li><code>stream [target=...] [volume=...] [fadein=Sekunden] &lt;Favorit|URI&gt;</code><br>
Startet einen dauerhaften Stream. Inhalt mit <code>Schema://</code> gilt als URI,
jeder andere Inhalt als Sonos-Favoritenname.</li>
<a id="AudioManager-set-queue"></a>
<li><code>queue [target=...] [volume=...] [fadein=Sekunden]</code><br>
Startet die bereits auf dem ausgewaehlten Coordinator vorhandene Media-Queue.
Verwaltete URI-Listen sind ueber die Perl-API verfuegbar.</li>
<a id="AudioManager-set-stop"></a>
<li><code>stop [all|target=...|&lt;Request-ID&gt;|alarm|speak|play|queue|stream]</code><br>
Bricht alle Auftraege, einen bestimmten Auftrag, eine Audioart oder alle mit dem
Ziel ueberlappenden Auftraege ab. Ein Zielstopp erreicht das Backend auch ohne
verbleibenden nichtterminalen Auftrag.</li>
<a id="AudioManager-set-transport"></a>
<li><code>transport [target=...] &lt;play|pause|previous|next&gt;</code><br>
Sendet einen direkten Transportbefehl an die ausgewaehlten verwalteten Player,
ohne einen Schedulerauftrag anzulegen.</li>
<a id="AudioManager-set-mute"></a>
<li><code>mute [target=...] &lt;on|off&gt; [force]</code><br>
<code>on</code> merkt sich den vorherigen Mute-Zustand jedes Players.
<code>off</code> restauriert diesen Snapshot; <code>off force</code> entmutet alle
ausgewaehlten Player.</li>
<a id="AudioManager-set-volume"></a>
<li><code>volume [target=...] &lt;0..100&gt;</code><br>
Setzt die Lautstaerke direkt auf allen ausgewaehlten verwalteten Playern.</li>
<a id="AudioManager-set-volumeStep"></a>
<li><code>volumeStep [target=...] &lt;up|down&gt;</code><br>
Aendert die Lautstaerke um den backendspezifischen Schritt, ohne einen
Schedulerauftrag anzulegen.</li>
</ul>
<p>Alarm-Inhalt mit <code>Schema://</code> wird automatisch als URI verwendet;
jeder andere Inhalt wird als Text gerendert. Die optionalen Praefixe
<code>text=</code> und <code>uri=</code> uebersteuern diese Erkennung.</p>
<p>Stream-Inhalt mit <code>Schema://</code> wird als dauerhafte URI abgespielt;
jeder andere Stream-Inhalt gilt als Sonos-Favoritenname.</p>
<p><code>mute on</code> sichert pro Zielplayer einmalig den vorherigen Zustand.
Ein normales <code>mute off</code> restauriert nur gesicherte Ziele;
<code>mute off force</code> entmutet alle ausgewaehlten Ziele unabhaengig davon. Die
Mute-Snapshots sind fluechtig und entfallen bei Defmod oder Neustart.</p>
<p><code>fadein</code> ist optional, dauert 0 bis 86400 Sekunden und pausiert
zusammen mit einer prioritaetsbedingten Unterbrechung. Eine direkte
<code>AudioManager_Submit</code>-Queue kann zusaetzlich eine URI-Liste
<code>uris =&gt; [...]</code> uebergeben; der Adapter verwaltet dann Aufbau,
Wiederholung, Start und Stop der nativen Sonos-Queue.</p>
<p>Vorhandene <code>all</code>-, Backend- und <code>group:</code>-Ziele bleiben
abspielbar, wenn ueber die Sonos-App ein nicht verwalteter Player beitritt. Er
nimmt nur als Mitglied seiner nativen Gruppe teil und kann nicht direkt als Ziel
gewaehlt werden. Das Reading <code>topologyWarning</code> meldet die Abweichung bis
zu seinem Austritt.</p>

<a id="AudioManager-get"></a>
<h4>Get</h4>
<ul>
<a id="AudioManager-get-topology"></a>
<li><code>topology</code><br>
Liefert die aktuelle Player- und Gruppentopologie als kanonisches JSON,
getrennt nach Backendinstanz.</li>
<a id="AudioManager-get-requests"></a>
<li><code>requests</code><br>
Liefert alle bekannten Schedulerauftraege als kanonisches JSON mit ID, Art,
Status, Prioritaet, Zielen, Zeitpunkten und terminalem Grund.</li>
<a id="AudioManager-get-priorities"></a>
<li><code>priorities</code><br>
Liefert die wirksamen Prioritaeten nach dem Zusammenfuehren partieller
Attributwerte mit den Defaults.</li>
<a id="AudioManager-get-health"></a>
<li><code>health</code><br>
Liefert den detaillierten Supervisorbericht fuer alle Backendinstanzen als
kanonisches JSON.</li>
</ul>

<a id="AudioManager-attr"></a>
<h4>Attribute</h4>
<ul>
<a id="AudioManager-attr-priorities"></a>
<li><code>priorities &lt;Audioart:Wert,...&gt;</code><br>
Ueberschreibt Prioritaeten von 0 bis 10000 fuer einzelne Audioarten. Fehlende
Arten behalten <code>alarm:400,speak:300,play:200,queue:100,stream:50</code>;
hoehere Werte gewinnen, gleiche Werte werden FIFO verarbeitet.</li>
<a id="AudioManager-attr-defaultVolumes"></a>
<li><code>defaultVolumes &lt;Audioart:0..100,...&gt;</code><br>
Ueberschreibt die Auftragslautstaerke fuer einzelne Audioarten. Fehlende Arten
behalten <code>alarm:60,speak:25,play:20,queue:15,stream:12</code>.</li>
<a id="AudioManager-attr-volumePolicies"></a>
<li><code>volumePolicies &lt;Audioart:fixed|minimum|keep,...&gt;</code><br>
Waehlt, ob die Lautstaerke exakt gesetzt, nur als Minimum verwendet oder nicht
geaendert wird. Defaults sind <code>alarm:minimum</code> und <code>fixed</code> fuer
alle anderen Arten.</li>
<a id="AudioManager-attr-volumeLimits"></a>
<li><code>volumeLimits &lt;Audioart:Minimum-Maximum,...&gt;</code> oder
<code>&lt;Audioart:Start-Ende:Minimum-Maximum,...&gt;</code><br>
Definiert unabhaengige ganztaegige oder lokale zeitabhaengige
Sicherheitsgrenzen. Folgefenster derselben Art duerfen den Namen auslassen, zum
Beispiel <code>alarm:8-20:30-80,20-8:30-50</code>.</li>
<a id="AudioManager-attr-quietHours"></a>
<li><code>quietHours &lt;Audioart=Start-Ende[,Start-Ende...],...&gt;</code><br>
Blockiert neue Auftraege der genannten Arten in lokalen Zeitfenstern. Fenster
duerfen Mitternacht ueberschreiten; der Start ist inklusiv, das Ende exklusiv.</li>
<a id="AudioManager-attr-speakDedupeWindow"></a>
<li><code>speakDedupeWindow &lt;Sekunden&gt;</code><br>
Filtert gleiche normalisierte Sprachtexte innerhalb dieses nichtnegativen
Intervalls. Default sind 5 Sekunden; 0 deaktiviert den Filter.</li>
<a id="AudioManager-attr-ttsDevice"></a>
<li><code>ttsDevice &lt;Device&gt;</code><br>
Nennt den FHEM-Text2Speech-Provider fuer <code>speak</code> und textbasierte
<code>alarm</code>-Auftraege.</li>
<a id="AudioManager-attr-zones"></a>
<li><code>zones &lt;Name=Player,Player;Anderer=Player&gt;</code><br>
Definiert logische <code>zone:</code>-Ziele. Jeder Player muss im
AudioManager-Define stehen; eine logische Zone darf mehrere Backends umfassen.</li>
<a id="AudioManager-attr-backendAvailability"></a>
<li><code>backendAvailability &lt;Praefix=Device[:Reading],...&gt;</code><br>
Ordnet einem MQTT-Praefix optional ein Bridge-Availability-Reading zu. Ohne
Reading gilt <code>connected</code>; ohne dieses Attribut versucht der Adapter
die Zuordnung automatisch zu erkennen.</li>
<a id="AudioManager-attr-startTimeout"></a>
<li><code>startTimeout &lt;Sekunden&gt;</code><br>
Setzt die positive Frist fuer TTS-Erzeugung und Bestaetigung des
Wiedergabestarts. Default sind 15 Sekunden.</li>
<a id="AudioManager-attr-stopGrace"></a>
<li><code>stopGrace &lt;Sekunden&gt;</code><br>
Setzt die positive Nachlaufzeit nach der letzten bestaetigten Wiedergabe, bevor
ein endlicher Auftrag abgeschlossen wird. Default sind 2 Sekunden.</li>
<a id="AudioManager-attr-groupTimeout"></a>
<li><code>groupTimeout &lt;Sekunden&gt;</code><br>
Begrenzt die Wartezeit des Backends auf native Gruppenphasen. Default sind 30
Sekunden.</li>
<a id="AudioManager-attr-healthDebounce"></a>
<li><code>healthDebounce &lt;Sekunden&gt;</code><br>
Entprellt Healthpruefungen nach relevanten Backendereignissen. Default sind 3
Sekunden; 0 deaktiviert die Verzoegerung.</li>
<a id="AudioManager-attr-healthVerifyTimeout"></a>
<li><code>healthVerifyTimeout &lt;Sekunden&gt;</code><br>
Setzt die positive Frist, in der ein Player einen aktiven Healthprobe
bestaetigen muss. Default sind 15 Sekunden.</li>
<a id="AudioManager-attr-healthRecoveryCooldown"></a>
<li><code>healthRecoveryCooldown &lt;Sekunden&gt;</code><br>
Setzt den Mindestabstand zwischen Versuchen zur Wiederherstellung der
Subscriptions. Default sind 60 Sekunden; 0 deaktiviert den Abstand.</li>
<a id="AudioManager-attr-healthProbeInterval"></a>
<li><code>healthProbeInterval &lt;Sekunden&gt;</code><br>
Setzt das positive Intervall zwischen regelmaessigen Player-Healthprobes.
Default sind 900 Sekunden.</li>
<a id="AudioManager-attr-autoLeave"></a>
<li><code>autoLeave &lt;0|1&gt;</code><br>
Erlaubt einem Auftrag, eine bestehende native Gruppe temporaer aufzutrennen und
anschliessend wiederherzustellen. Sicherer Default ist 0; explizite
<code>group</code>-Befehle sind davon nicht betroffen.</li>
<a id="AudioManager-attr-disable"></a>
<li><code>disable &lt;0|1&gt;</code><br>
Mit 1 werden aktive Auftraege abgebrochen, neue Wiedergabeauftraege abgelehnt
und der Managerstatus auf <code>disabled</code> gesetzt. Default ist 0.</li>
</ul>
<p><code>volumeLimits</code> definiert unabhaengige Sicherheitsgrenzen je
Audioart. Eine reine Spanne wie <code>stream:10-40</code> gilt ganztags.
Zeitregeln verwenden <code>Audioart:Start-Ende:Minimum-Maximum</code>; weitere
Fenster derselben Audioart duerfen den Namen auslassen. Die lokale Uhrzeit beim
Annehmen des Requests waehlt die Regel, deren Ende jeweils exklusiv ist. Die
Grenzen klemmen auch explizite Lautstaerken, <code>minimum</code>,
<code>keep</code> und beim Resume restaurierte Pegel.</p>
<p>Der Adapter prueft jeden verwalteten sonos2mqtt-Speaker aktiv mit dem
nicht steuernden Kommando <code>GetZoneInfo</code>. Erst eine frische Playerantwort
bestaetigt den Probe. Fehlt sie, veroeffentlicht der Adapter genau einmal
<code>&lt;Praefix&gt;/cmd/check-subscriptions</code> und prueft den betroffenen Player erneut.</p>
<p>Bleibt auch der Wiederholungsprobe erfolglos, nennt
<code>backendHealthError</code> den offline erkannten Player und es entsteht genau
ein Logeintrag mit Level 2. Die bestaetigte Wiederkehr loescht das Reading und
erzeugt genau einen Logeintrag mit Level 3. Unveraenderte Zustaende werden nicht
erneut geloggt.</p>
<p>Ein Bridge-Device bleibt optional. Der Adapter erkennt unabhaengig von
MQTT2_Discovery automatisch eine exakte Zuordnung fuer
<code>&lt;Praefix&gt;/connected</code> in einem vorhandenen MQTT2_DEVICE am selben IODev.
<code>backendAvailability</code> kann die Zuordnung explizit vorgeben.
<code>get &lt;name&gt; health</code> liefert den Detailbericht.</p>

=end html_DE

=cut
