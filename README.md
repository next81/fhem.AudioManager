# AudioManager

`AudioManager` ist ein priorisiertes Audiomanagement fuer FHEM. Das Modul nimmt
alle Audioauftraege zentral an, entscheidet ueber Unterbrechung und
Wiederaufnahme und steuert angebundene Player.

Derzeit wird nur `sonos2mqtt` unterstützt. Der Core kennt keine
Sonos-Kommandos und ist ueber eine versionierte Schnittstelle fuer spaetere
Adapter wie beispielsweise HEOS vorbereitet.

## Funktionen

- Prioritaeten fuer `alarm`, `speak`, `play`, `queue` und `stream`
- verschachtelte Unterbrechung und Wiederaufnahme in umgekehrter Reihenfolge
- FIFO bei gleicher Prioritaet
- parallele Auftraege auf disjunkten physischen Zielen
- sofort beginnende TTS-Erzeugung ohne kuenstliches Sammelfenster
- zeitbasierter Filter fuer identische Sprachtexte
- getrennte Einzel-MP3s fuer getrennte `speak`-Aufrufe
- Standardlautstaerke und Lautstaerkepolitik je Audioart
- optionaler, unterbrechbarer Fade-in je Audioauftrag
- temporaeres Unmute mit Wiederherstellung des vorherigen Zustands
- optionale Ziele, logische Zonen und `all` als Default
- dynamische native Sonos-Gruppen
- fluechtige Sitzungs-Snapshots fuer Quelle, Transport, Lautstaerke und Mute
- Request-IDs und sichtbare Lebenszyklusreadings
- aktive Backend-Ueberwachung mit read-only Probes und bestaetigter Recovery

## Architektur

```text
FHEM set / Perl API
        |
        v
90_AudioManager.pm
        |
        +-- AudioManager::Core
        |      Prioritaet, FIFO, Deduplizierung, Suspend/Resume
        |
        +-- AudioManager::Supervisor
        |      Health-Events, Debounce, Recovery, Bestaetigung, Cooldown
        |
        +-- AudioManager::Backend (Interface Version 3)
               |
               +-- AudioManager::Backend::Sonos2mqtt
               +-- spaeter: HEOS, weitere Backends
```

Die Sonos-Media-Queue und die interne Request-Queue sind verschiedene Dinge:

- Die Sonos-Media-Queue enthaelt die abzuspielenden Titel.
- Die Request-Queue enthaelt wartende Audioauftraege wie `play` oder `speak`.

Eine ohne URI-Liste gestartete Sonos-Media-Queue wird nicht nochmals
abgebildet. Sie bleibt eine unterbrechbare Wiedergabesitzung. Uebergibt eine
Automation dagegen explizit `uris`, besitzt der Auftrag diesen Queue-Inhalt:
Der Sonos-Adapter ersetzt die native Queue, setzt `REPEAT_ALL`, waehlt Titel 1
und startet sie. So bleibt der Aufrufer frei von Sonos-Kommandos und Timern.
Da manche FHEM-Templates `Input` nur aus Track- und teils veralteten
Radiometadaten ableiten, bestaetigt alternativ der beobachtete Wechsel auf eine
URI genau dieses Queue-Requests den erfolgreichen Queue-Eingang.

## Projektstruktur

- `FHEM/90_AudioManager.pm` – FHEM-Lebenszyklus, Sets, Attribute, Readings und TTS-Pipeline
- `lib/AudioManager/Core.pm` – backendneutraler Scheduler
- `lib/AudioManager/Backend.pm` – versionierter Backendvertrag und Registry
- `lib/AudioManager/Backend/Sonos2mqtt.pm` – sonos2mqtt-Adapter
- `lib/AudioManager/FHEMGateway.pm` – testbare Grenze zu globalen FHEM-Funktionen
- `lib/AudioManager/Supervisor.pm` – backendneutraler Health- und Recovery-Zustandsautomat
- `tests/` – Unit- und Modultests mit `Test2::V0`

## Installation

```text
update all https://raw.githubusercontent.com/next81/fhem.AudioManager/main/controls_AudioManager.txt
shutdown restart
```

## Definition

```text
define Audio AudioManager sonos2mqtt=Sonos.FlurEG,Sonos.Kueche,Sonos.Wintergarten
```

Die Playerliste ist die harte Verwaltungsgrenze. Ein `Sonos.Bridge`-Device wird
nicht benoetigt und als Player abgelehnt. Der Adapter verwendet direkt die
vorhandenen `sonos2mqtt_speaker`-Devices. Dieselben Devices liefern auch die
Ereignisse fuer die Subscription-Ueberwachung; ein zusaetzliches
Ueberwachungsdevice wird nicht definiert.

Nicht vorhandene FHEM-Devices in einer gemischten Playerliste werden beim Define
ignoriert und mit Fehler-Loglevel protokolliert. Mindestens ein vorhandener
Player muss je Backendinstanz uebrig bleiben. Vorhandene Devices werden weiterhin
streng als passende Player des jeweiligen Backends validiert.

Auch reduzierte `sonos2mqtt_speaker`-Devices, deren `setList` nur
`x_raw_payload` anbietet, koennen verwaltet werden. Der Adapter verwendet fuer
Gruppenbeitritt, Mute, Lautstaerke und Transport die offiziellen
sonos2mqtt-JSON-Kommandos. Ein Favoritenname kann ueber dieses Rohprotokoll nicht
gestartet werden. Deshalb waehlt der AudioManager fuer einen Favoriten
automatisch einen Zielplayer mit direktem `playFav` als Coordinator; reduzierte
TV-Devices treten dessen temporaerer Gruppe bei. Besteht das Ziel nur aus einem
solchen Device, wird der Favoritenauftrag mit einer klaren Fehlermeldung abgelehnt.
Die Syntax ist fuer mehrere Backendinstanzen vorbereitet:

```text
define Audio AudioManager sonos2mqtt@Haus=Sonos.FlurEG,Sonos.Kueche
```

Wenn spaeter andere Adapter registriert sind, kann dieselbe Definition um einen
weiteren Descriptor ergaenzt werden. Native Gruppen bleiben immer innerhalb
eines Backends. Ein backenduebergreifender Auftrag ist nur best effort und keine
samplegenaue gemeinsame Gruppe.

## TTS

Ein vorhandenes FHEM-`Text2Speech`-Device wird als Renderer verwendet:

```text
attr Audio ttsDevice SonosTTS
```

Der AudioManager sendet beim ersten `speak` sofort:

```text
set SonosTTS tts <Text>
```

Er beobachtet `playing`, `lastFilename` und `httpName`. Abschluss- und
Ausgabeereignisse werden direkt im FHEM-Notify verarbeitet; der 250-ms-Worker
bleibt nur als Sicherheitsnetz. Dadurch startet auch eine bereits gecachte,
unveraenderte URI ohne das fruehere feste Bereitschaftsfenster. Sobald die
fertige URI vorliegt, wird sie ueber den Backendadapter abgespielt. Weitere Texte bleiben
einzelne Auftraege und werden nicht sprachlich interpretiert oder binaer zu
einer MP3 zusammengeschnitten. Der Renderer kann den naechsten Text bereits
vorbereiten, waehrend der vorherige Clip spielt.

Die vom Renderer gelieferte `duration` dient bei sehr kurzen Clips als
Fallback: Ist die Ansage kuerzer als die sonos2mqtt-Readingverzoegerung, wird
sie nach ihrer MP3-Dauer plus Stop-Toleranz kontrolliert abgeschlossen und
nicht faelschlich als unbestaetigter Start verworfen.

Der Aufrufer muss eine fachlich zusammengehoerige Ansage selbst als einen Text
uebergeben:

```text
set Audio speak Die Waschmaschine ist fertig. Bitte ausraeumen.
```

## Filter fuer gleiche Sprachtexte

```text
attr Audio speakDedupeWindow 5
```

Innerhalb von fuenf Sekunden wird derselbe normalisierte Text nur einmal
erzeugt und abgespielt. Fuer den Vergleich werden aeussere und mehrfache
Leerzeichen, Gross-/Kleinschreibung sowie abschliessende Satzzeichen ignoriert.
Der Originaltext bleibt fuer die TTS-Erzeugung unveraendert.

Das Fenster beginnt mit dem angenommenen Originalauftrag. Ein verworfenes
Duplikat verlaengert es nicht. Mit `0` wird der Filter deaktiviert.

Verworfene Auftraege bleiben als Request mit `state=deduplicated` und
`coalescedInto=<original-id>` nachvollziehbar.

## Ruhezeiten pro Audioart

Das optionale Attribut `quietHours` blockiert neue Auftraege nur fuer die
explizit genannten Audioarten:

```text
attr Audio quietHours speak=20-7,12-14
```

Damit sind normale Sprachausgaben von 20:00 bis 07:00 Uhr und von 12:00 bis
14:00 Uhr gesperrt. Nicht genannte Arten wie `alarm`, `stream`, `queue` und
`play` bleiben jederzeit erlaubt. Ein Komma trennt sowohl mehrere Zeitfenster
als auch Audioarten. Ein Eintrag mit Gleichheitszeichen beginnt eine neue
Audioart:

```text
attr Audio quietHours speak=20-7,12-14,queue=10-12
```

Stunden koennen ein- oder zweistellig, Minuten optional zweistellig angegeben
werden, beispielsweise `20:30-6:45`. Der Start gehoert zum Ruhefenster, das
Ende nicht. Ein Start nach dem Ende beschreibt automatisch ein Fenster ueber
Mitternacht. Gleiche Start- und Endzeiten werden als versehentliche leere
Angabe abgelehnt. Ohne `quietHours` gibt es keine zeitliche Sperre.
## Prioritaeten

Default:

```text
alarm:400,speak:300,play:200,queue:100,stream:50
```

Partielle Overrides werden mit den Defaults zusammengefuehrt:

```text
attr Audio priorities alarm:500,speak:350
```

Hoehere Werte gewinnen. Gleiche Prioritaet wird FIFO verarbeitet. Eine
Attributaenderung betrifft nur neue Auftraege; bereits angenommene Requests
behalten ihre beim Eingang festgeschriebene Prioritaet.

Beispielhierarchie:

```text
alarm
  -> speak
       -> play
            -> queue
                 -> stream
```

Nach dem Ende wird in umgekehrter Unterbrechungsreihenfolge fortgesetzt.

Beim Fortsetzen verwendet AudioManager die Quelle des pausierten Auftrags:
Streams werden erneut ueber ihren Favoriten oder ihre URI gestartet, Queues ueber den
Queue-Eingang und endliche Clips ueber ihre URI. Nur beim abschliessenden
Zuruecksetzen auf eine externe Quelle werden die beim ersten Eingriff
gesicherten Sonos-Readings verwendet. Veraltete Track-Readings koennen damit
keine zuvor beendete Wiedergabe wieder einschalten.

## Lautstaerke

```text
attr Audio defaultVolumes alarm:60,speak:25,play:20,queue:15,stream:12
attr Audio volumePolicies alarm:minimum,speak:fixed,play:fixed,queue:fixed,stream:fixed
attr Audio volumeLimits stream:10-40,alarm:8-20:30-80,20-8:30-50
```

Unterstuetzte Politiken:

- `fixed` – Zielwert wird gesetzt
- `minimum` – bereits hoehere Lautstaerke bleibt erhalten
- `keep` – Lautstaerke wird nicht geaendert

`alarm:minimum` sorgt dafuer, dass ein Alarm deutlich hoerbar wird, ohne einen
bereits lauteren Player leiser zu stellen. Vor jeder Unterbrechung liest der
Adapter die aktuellen Playerwerte erneut. Manuelle Lautstaerkeaenderungen einer
laufenden Sitzung werden dadurch bei deren Wiederaufnahme beruecksichtigt.

`volumeLimits` setzt davon unabhaengige Sicherheitsgrenzen je Audioart. Eine
reine Spanne wie `stream:10-40` gilt ganztags. Zeitabhaengige Regeln beginnen
mit einem Zeitfenster; weitere Fenster derselben Audioart duerfen den Namen
auslassen. Das Beispiel erlaubt Alarme von 08:00 bis 20:00 mit 30 bis 80 und
von 20:00 bis 08:00 mit 30 bis 50. Das Fensterende ist jeweils exklusiv.
Die lokale Uhrzeit beim Annehmen eines Requests waehlt die passende Regel.
Explizite `volume=`-Werte, `minimum` und `keep` werden ebenso geklemmt wie ein
beim Fortsetzen gesicherter Pegel. Damit kann auch ein verzoegertes oder zuvor
manuell erhoehtes Sonos-Reading die konfigurierte Obergrenze nicht ueberschreiten.

Jeder Audioauftrag kann optional linear eingeblendet werden:

```text
set Audio play target=player:Sonos.Kueche volume=30 fadein=10 http://fhem/gong.mp3
set Audio queue target=group:Sonos.FlurEG fadein=300
```

`fadein` ist die Dauer in Sekunden zwischen 0 und 86400. Der Startpegel liegt
bei zehn Prozent des Zielwerts. Bei einer hoeher priorisierten Unterbrechung
werden Wiedergabe und Fade-Uhr gemeinsam pausiert; nach der Wiederaufnahme
laeuft der verbleibende Fade weiter. `fadein` ist nicht mit
`volume_policy=keep` kombinierbar.

## Sets

### Sprache

```text
set Audio speak Die Haustuer ist noch offen.
set Audio speak target=zone:EG volume=30 Die Haustuer ist noch offen.
```

### Einzelne MP3 oder URI

```text
set Audio play http://fhem/gong.mp3
set Audio play target=player:Sonos.Kueche volume=40 http://fhem/gong.mp3
set Audio play target=player:Sonos.Kueche volume=40 fadein=5 http://fhem/gong.mp3
```

### Alarm

```text
set Audio alarm uri=http://fhem/alarm.mp3
set Audio alarm target=all text=Achtung. Wasser erkannt.
set Audio alarm target=group:Sonos.FlurEG volume=30 Dies ist ein AudioManager-Test.
```

Ohne ausdrueckliche Inhaltsart erkennt der AudioManager URL-foermige Inhalte
automatisch als URI und behandelt alle anderen Inhalte als Text. Mit `text=`
kann auch eine URL vorgelesen werden; `uri=` erzwingt umgekehrt eine nicht
URL-foermige Audioquelle. Textalarme verwenden denselben TTS-Renderer, behalten
aber die hoehere Alarmprioritaet und werden nicht allein anhand ihres Textes
dedupliziert.

### Sonos-Favorit oder URL als Stream

```text
set Audio stream Antenne Muenster
set Audio stream target=zone:EG WDR 2
set Audio stream target=zone:EG https://radio.example/live
```

Inhalt mit einem eindeutigen `Schema://` wird als dauerhafte URI ueber `playUri`
gestartet; jeder andere Inhalt gilt als Favoritenname und verwendet `playFav`
direkt am aktuellen beziehungsweise temporaeren Coordinator. Der Favoritenname
muss Sonos bereits bekannt sein. Ein Bridge-Favoritenkatalog ist nur Komfort und
keine Abspielvoraussetzung. Beide Quellen bleiben aktiv, bis der Stream gestoppt
oder durch einen neueren, ueberlappenden Stream ersetzt wird.

### Vorhandene Sonos-Media-Queue

```text
set Audio queue
set Audio queue target=group:Sonos.FlurEG
set Audio queue target=group:Sonos.FlurEG fadein=300
```

Die Set-Variante startet die bereits in Sonos vorhandene Media-Queue. Eine
vollstaendig vom AudioManager verwaltete URI-Liste wird ueber die direkte
Perl-API uebergeben.

### Transport, Stop, Mute und Lautstaerke

```text
set Audio transport target=group:Sonos.FlurEG previous
set Audio transport target=group:Sonos.FlurEG play
set Audio transport target=group:Sonos.FlurEG pause
set Audio transport target=group:Sonos.FlurEG next
set Audio stop all
set Audio stop speak
set Audio stop audio-1800000000-000001
set Audio stop target=player:Sonos.Kueche
set Audio stop target=group:Sonos.FlurEG
set Audio mute target=zone:EG on
set Audio mute target=zone:EG off
set Audio mute target=zone:EG off force
set Audio volume target=player:Sonos.Kueche 25
set Audio volumeStep target=player:Sonos.Kueche up
set Audio volumeStep target=player:Sonos.Kueche down
```

`mute on` sichert pro Zielplayer einmalig dessen vorherigen Mute-Zustand. Ein
normales `mute off` stellt nur die gesicherten Zielplayer wieder her; ein schon
vorher gemuteter Speaker bleibt daher gemutet. Ohne passenden Snapshot ist
`mute off` absichtlich ein No-op. `mute off force` umgeht diese Sicherung, entmutet alle
gewaehlten Ziele und verwirft deren Snapshoteintraege. Der Snapshot ist fluechtig
und wird bei `defmod`, Modulneustart oder FHEM-Neustart verworfen.

## Ziele und Zonen

Ohne `target` wird auf allen im Define verwalteten Playern gespielt. Der Sonos-Adapter
verteilt `all` auf die bereits vorhandenen Gruppen und sendet je Gruppe genau 
einen Quellenbefehl an deren Coordinator. Standalone-Player werden
separat angesteuert; die aktuelle Gruppierung bleibt dabei unveraendert und
`autoLeave` ist nicht erforderlich.

Explizite `player:`, `players:`, `zone:` und `group:`-Ziele beschreiben dagegen
eine gemeinsame exakte Zielgruppe. Verwaltete URI-Queues benoetigen ebenfalls
genau eine Sonos-Zielgruppe, weil ihr Inhalt in der nativen Queue des jeweiligen
Coordinators aufgebaut wird.

Unterstuetzte Zielausdruecke:

```text
all
player:Sonos.Kueche
players:Sonos.Kueche,Sonos.FlurEG
group:Sonos.FlurEG
zone:EG
backend:Haus
```

Zonen werden als Attribut definiert:

```text
attr Audio zones EG=Sonos.FlurEG,Sonos.Kueche;OG=Sonos.Schlafen
```

Eine Zone darf mehrere Backends enthalten. Der Manager erzeugt daraus einen
gemeinsamen Elternrequest mit je einem Teilauftrag pro Backend.

## Sonos-Gruppen

```text
set Audio group create Sonos.FlurEG Sonos.Kueche,Sonos.Wintergarten
set Audio group add Sonos.Kueche Sonos.FlurEG
set Audio group remove Sonos.Kueche
set Audio group dissolve Sonos.FlurEG
```

Die Argumente bleiben FHEM-Devicenamen. Fuer `joinGroup` uebersetzt der
sonos2mqtt-Adapter den angegebenen Coordinator intern in dessen sichtbaren
Sonos-Namen aus dem Reading `name` (beispielsweise `Sonos.FlurEG` in `Flur EG`).

Die Topologie wird aus den Speaker-Readings `uuid` und `coordinatorUuid`
abgeleitet. `groupName`, ein berechnetes `Master`-Reading und die Bridge sind
nicht autoritativ. Bei einer bestehenden gemeinsamen Gruppe startet der ueber
`coordinatorUuid` ermittelte wirkliche Coordinator die Quelle. Ein als
`group:` angegebener Child-Player dient dabei nur als Gruppenanker.

Exakt passende Gruppen werden ohne Umbau verwendet. Standalone-Player duerfen
fuer ein gemeinsames Ziel temporaer gruppiert werden. Eine bereits bestehende
Sonos-Gruppe wird dagegen standardmaessig nicht automatisch aufgetrennt:

```text
attr Audio autoLeave 0
```

Benoetigt ein Auftrag dennoch `leaveGroup`, wird er vor Snapshot und erstem
Sonos-Kommando mit einem Hinweis auf `autoLeave=0` abgelehnt. Insbesondere kann
ein bestehender Coordinator dadurch nicht versehentlich fuer ein Einzelziel
von allen Gruppenmitgliedern getrennt werden.

Die automatische Trennung mit anschliessender Wiederherstellung muss explizit
freigegeben werden:

```text
attr Audio autoLeave 1
```

Leave und Join laufen als nichtblockierende Phasen ueber FHEM-`InternalTimer`;
es wird kein `sleep` und kein dynamisches `at` verwendet. Nach dem letzten
Auftrag wird die vorherige Topologie bestmoeglich wiederhergestellt. Explizite
`set Audio group ...`-Kommandos sind von `autoLeave` nicht betroffen.
Eine bereits zum Snapshot passende Gruppe wird beim Restore nicht getrennt.
Fuer tatsaechlich notwendige Gruppenwechsel wartet der Adapter standardmaessig
bis zu 30 Sekunden; `groupTimeout` kann diesen Wert ueberschreiben.

Befindet sich in einer vorhandenen `all`-, Backend- oder `group:`-Zielgruppe ein
nicht im Define verwalteter Speaker, bleibt die Gruppe als native Einheit
abspielbar. Der fremde Player kann nicht direkt als `player:`-Ziel verwendet
und vom Manager nicht umgruppiert werden. Die Abweichung bleibt im Reading
`topologyWarning` sichtbar, bis die Gruppe wieder nur verwaltete Player enthaelt.
Explizite Player- und Zonen-Ziele werden weiterhin abgelehnt, wenn ihre exakte
Bildung einen nicht verwalteten Player veraendern wuerde.

## Aktive Backend-Ueberwachung

Der `AudioManager::Supervisor` verwaltet fuer jede Backendinstanz einen eigenen
Healthzustand. Der Supervisor kennt keine Sonos-Readings oder MQTT-Topics. Diese
Details stellt jeder Adapter bereit:

1. Ein verwaltetes Device-Ereignis wird durch `health_event` in neutrale Signale
   uebersetzt.
2. `health_probe` startet in einem langen Intervall eine nicht steuernde
   Erreichbarkeitspruefung.
3. `health_verify` verlangt eine echte Antwort. Ein erfolgreich gesendeter
   Befehl allein gilt nicht als Erfolg.
4. Erst ein unbeantworteter Probe darf ueber `health_recover` genau eine
   backendtypische Reparatur und einen Wiederholungsprobe ausloesen.

Der Sonos-Adapter sendet standardmaessig alle 900 Sekunden an jeden verwalteten
Speaker den vom offiziellen FHEM-Template verwendeten Rohbefehl:

```json
{"command":"adv-command","input":{"cmd":"GetZoneInfo","reply":"ZoneInfo"}}
```

`GetZoneInfo` aendert weder Quelle, Transport, Lautstaerke noch Gruppe. Die
Antwort laeuft ueber das bereits vorhandene Topic `<Praefix>/<UUID>/ZoneInfo`
und aktualisiert unter anderem das Reading `IPAddress`. Ein entsprechendes
Event oder ein neuer FHEM-Readingzeitstempel bestaetigt genau diesen Player.
Damit bleibt die Pruefung auch bei `event-on-change-reading` belastbar.

Fehlt eine Antwort, veroeffentlicht der Adapter einmalig
`<Praefix>/cmd/check-subscriptions` direkt ueber das IODev eines verwalteten
Speakers und wiederholt `GetZoneInfo` fuer die fehlenden Player. Erst wenn auch
dieser Retry unbeantwortet bleibt, wird der Player als `unavailable` gemeldet.
Ein spaeter wieder antwortender Player loest ebenfalls einmalig den
Subscription-Refresh aus.

### Optionale Bridge-Availability

Ein Bridge-Device bleibt optional. Der Adapter sucht fuer
`<Praefix>/connected` automatisch eine bereits vorhandene exakte Zuordnung in
der `readingList` eines `MQTT2_DEVICE` am selben IODev. Ein
`sonos2mqtt_bridge`-Device wird dabei bevorzugt. Das funktioniert mit und ohne
`MQTT2_Discovery`; der AudioManager legt kein Bridge-Device und kein Reading an.

Die Werte bedeuten entsprechend sonos2mqtt:

- `2`: MQTT verbunden und mindestens ein Player erkannt
- `1`: MQTT verbunden, aber kein Player erkannt
- `0` oder fehlend: Bridge nicht verbunden

Wird keine passende Zuordnung gefunden, bleibt der Bridgezustand `unknown` und
blockiert die direkten Playerprobes nicht. Eine manuelle Zuordnung ist je
MQTT-Praefix moeglich:

```text
attr Audio backendAvailability sonos=sonos.bridge:connected
attr Audio backendAvailability sonos=sonos.bridge:connected,music=Music.Bridge:serviceState
```

Ohne `:Reading` gilt `connected` als Default. Mehrere gleichzeitig verwaltete
sonos2mqtt-Instanzen koennen unterschiedliche Praefixe und Bridge-Devices
verwenden.

Zwischen den Healthterminen laeuft kein Worker. Es bleibt pro Manager nur
der naechste Langzeittimer beziehungsweise waehrend einer Antwortphase deren
Sicherheitsfrist geplant:

```text
attr Audio healthProbeInterval 900
attr Audio healthDebounce 3
attr Audio healthVerifyTimeout 15
attr Audio healthRecoveryCooldown 60
```

`healthDebounce` und `healthRecoveryCooldown` duerfen `0` sein;
`healthProbeInterval` und `healthVerifyTimeout` muessen positiv bleiben. Die
Werte sind Sekunden und koennen Dezimalstellen enthalten.

## Readings

- `state` – `ready` oder `disabled`
- `version`
- `backendCount`, `playerCount`
- `activeRequests`, `pendingRequests`, `suspendedRequests`
- `ttsQueueLength`
- `currentRequest`, `currentType`, `currentTargets`
- `mediaRequest`, `mediaType`, `mediaPlayer` – höchstpriorisierter aktiver Auftrag
- `source`, `title`, `artist`, `album`, `albumArtUri` – normalisierte Medienanzeige
- `transportState`, `volume`, `mute` – Zustand des angezeigten Coordinators
- `lastRequest`, `lastRequestType`, `lastRequestState`
- `lastError`
- `deduplicatedRequests`
- `backendHealth` – kompakter Zustand je Backendinstanz
- `backendHealthDetails` – vollstaendiger Healthbericht als JSON
- `backendHealthError` – aktueller Fehler, beispielsweise `sonos2mqtt: Player offline: Sonos.Wohnen`
- `backendRecoveryCount`, `lastBackendRecovery`, `lastBackendHealthError`
- `topologyWarning` - tolerierte fremde Player in vorhandenen nativen Gruppen

Weitere Diagnose ist ueber Get verfuegbar:

```text
get Audio topology
get Audio requests
get Audio priorities
get Audio health
```

## Direkte Perl-API und Migration vorhandener Makros

Fuer vorhandene FHEM-Perlfunktionen steht eine direkte API bereit:

```perl
my ($request_id, $error) = AudioManager_Submit('Audio', 'speak', {
	text => 'Die Waschmaschine ist fertig.',
	target => 'all',
});
```

Eine Automation muss nur ihre Dateien ermitteln. Queue-Aufbau, Quellenwechsel,
Wiederholung, Start, Fade und priorisierte Suspend/Resume-Steuerung gehoeren
dem AudioManager:

```perl
my ($request_id, $error) = AudioManager_Submit('Audio', 'queue', {
	target => 'group:Sonos.FlurEG',
	uris => \@mp3_uris,
	fadein => 300,
});
```

Die URI-Reihenfolge bleibt erhalten. Diese Form ersetzt den Inhalt der nativen
Sonos-Queue und leert die selbst verwaltete Queue beim Stop. Der Auftrag bleibt
aktiv, bis er mit seiner Request-ID oder als Audioart `queue` gestoppt oder von
einer neueren Queue ersetzt wird. Das gilt auch waehrend einer prioritaetsbedingt
laufenden Ansage: Nur der pausierte Queue-Inhalt wird bereinigt, die Ansage
erhaelt keinen Stop-Befehl.

Spezielle Queue-Automationen mit eigener Lautstaerke- oder Mute-Steuerung
koennen beide Werte request-lokal unangetastet lassen, solange kein Fade
angefordert ist:

```perl
my ($request_id, $error) = AudioManager_Submit('Audio', 'queue', {
	target => 'group:Sonos.FlurEG',
	volume_policy => 'keep',
	mute_policy => 'keep',
});
```

Diese Optionen stehen bewusst nur der direkten API zur Verfuegung. Normale
`set Audio ...`-Befehle verwenden weiterhin die konfigurierten Defaults.

Direkte Bedienung ueber die Sonos-App, Hardwaretasten, native Sonos-Alarme oder
TV/HDMI kann weiterhin ausserhalb des Managers stattfinden. Solche Quellen
werden als externer Baseline-Zustand gelesen und nur mit den von sonos2mqtt
tatsaechlich angebotenen Befehlen bestmoeglich wiederhergestellt. Es werden
keine eigenen TV-, HDMI- oder AirPlay-Subtypen erfunden.

## Adapterschnittstelle

Ein Adapter registriert eine Factory und implementiert:

```text
id
validate
health_capabilities
health_event
health_probe
health_check
health_recover
health_verify
health_details
health_devices
managed_players
resolve_target
preflight_start
snapshot
start
progress
suspend
resume
stop
restore
is_playing
topology
group_command
set_mute
set_volume
media_status (optional)
transport_command (optional)
change_volume (optional)
```

Die drei optionalen Methoden besitzen kompatible Defaultimplementierungen und
heben die Interface-Version deshalb nicht an. `media_status` normalisiert die
Anzeige aktiver Auftraege; die beiden Steuerhooks kapseln Transport und native
Lautstaerkeschritte.

Backendzustand wird nicht dauerhaft in FHEM dupliziert. Der Adapter liest die
Geraete-Readings als Wahrheitsquelle. Nur fuer aktive Sitzungen werden
fluechtige Snapshots gehalten, weil der vorherige Wert nach einem Quellenwechsel
nicht mehr aus dem Geraet ablesbar ist. Auch Health-Adapter muessen Eventnamen,
Pruefung, Recovery und Erfolgsbeleg selbst kapseln. Dadurch kann ein spaeterer
HEOS-Adapter beispielsweise andere Signale oder Reparaturaktionen verwenden, ohne 
den Supervisor oder das FHEM-Modul zu aendern.

Beim Start eines endlichen Clips akzeptiert der Sonos-Adapter neben der exakten
URI auch einen gegenueber dem Snapshot belegten Quellen- oder
STOPPED-zu-PLAYING-Wechsel. Das verhindert Fehlalarme, wenn Sonos eine HTTP-URI
intern umschreibt. Eine unveraendert weiterlaufende Fremdquelle bestaetigt den
Managerauftrag dagegen nicht.

Native Gruppen duerfen keine unterschiedlichen Backends mischen. Ein kuenftiger
HEOS-Adapter kann dieselben logischen Requests bearbeiten, verspricht zusammen
mit Sonos aber keine samplegenaue Synchronisation.
