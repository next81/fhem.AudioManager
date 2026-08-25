use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use AudioManager::Core;

my $now = 1_000;
my @actions;

# Erzeugt fuer jeden Subtest einen Scheduler mit protokollierten Seiteneffekten.
sub build_core {
	@actions = ();
	return AudioManager::Core->new(
		clock => sub { return $now },
		callbacks => {
			on_start => sub { push @actions, "start:$_[0]{type}:$_[0]{id}"; return undef },
			on_suspend => sub { push @actions, "suspend:$_[0]{type}:$_[0]{id}"; return undef },
			on_resume => sub { push @actions, "resume:$_[0]{type}:$_[0]{id}"; return undef },
			on_stop => sub { push @actions, "stop:$_[0]{type}:$_[0]{id}"; return undef },
		},
	);
}

subtest 'verschachtelte Prioritaeten werden rueckwaerts fortgesetzt' => sub {
	$now = 1_000;
	my $core = build_core();
	my $stream = $core->submit(type => 'stream', targets => ['A'], payload => { favorite => 'Radio' });
	my $queue = $core->submit(type => 'queue', targets => ['A']);
	my $play = $core->submit(type => 'play', targets => ['A'], payload => { uri => 'clip.mp3' });
	my $speak = $core->submit(type => 'speak', targets => ['A'], payload => { text => 'Hallo' }, deferred => 1);
	is($stream->{state}, 'suspended', 'Stream wurde unterbrochen');
	is($queue->{state}, 'suspended', 'Media-Queue wurde unterbrochen');
	is($play->{state}, 'active', 'Einzelclip ist vor der fertigen Sprache aktiv');
	is($core->ready($speak->{id}, uri => 'speech.mp3'), undef, 'TTS wird freigegeben');
	is($speak->{state}, 'active', 'Sprache unterbricht den Einzelclip');
	is($core->complete($speak->{id}), undef, 'Sprache endet');
	is($play->{state}, 'active', 'Einzelclip wird zuerst fortgesetzt');
	is($core->complete($play->{id}), undef, 'Einzelclip endet');
	is($queue->{state}, 'active', 'Media-Queue wird danach fortgesetzt');
	is($core->cancel($queue->{id}), undef, 'Media-Queue wird beendet');
	is($stream->{state}, 'active', 'Stream wird zuletzt fortgesetzt');
};

subtest 'gleiche Prioritaet bleibt FIFO und disjunkte Ziele laufen parallel' => sub {
	$now = 2_000;
	my $core = build_core();
	my $first = $core->submit(type => 'play', targets => ['A'], payload => { uri => 'one' });
	my $second = $core->submit(type => 'play', targets => ['A'], payload => { uri => 'two' });
	my $other = $core->submit(type => 'play', targets => ['B'], payload => { uri => 'other' });
	is($first->{state}, 'active', 'erster Clip ist aktiv');
	is($second->{state}, 'queued', 'zweiter Clip wartet FIFO');
	is($other->{state}, 'active', 'disjunkter Player spielt parallel');
	$core->complete($first->{id});
	is($second->{state}, 'active', 'zweiter Clip startet nach dem ersten');
};

subtest 'Sprachduplikate verwenden ein nicht verlaengertes Zeitfenster' => sub {
	$now = 3_000;
	my $core = build_core();
	$core->set_dedupe_window(5);
	my $first = $core->submit(type => 'speak', targets => ['A'], payload => { text => '  Waschmaschine fertig! ' }, deferred => 1);
	$now += 2;
	my $duplicate = $core->submit(type => 'speak', targets => ['A'], payload => { text => 'waschmaschine   fertig.' }, deferred => 1);
	is($duplicate->{state}, 'deduplicated', 'normalisierter Text wird verworfen');
	is($duplicate->{coalesced_into}, $first->{id}, 'Duplikat verweist auf Original');
	$now += 4;
	my $again = $core->submit(type => 'speak', targets => ['A'], payload => { text => 'Waschmaschine fertig' }, deferred => 1);
	is($again->{state}, 'preparing', 'verworfener Trigger verlaengert das Fenster nicht');
	$core->set_dedupe_window(0);
	my $unfiltered = $core->submit(type => 'speak', targets => ['A'], payload => { text => 'Waschmaschine fertig' }, deferred => 1);
	is($unfiltered->{state}, 'preparing', 'Fenster 0 deaktiviert den Filter');
};

subtest 'vorbereitete hoehere Sprache verhindert kurzes Stream-Resume' => sub {
	$now = 4_000;
	my $core = build_core();
	my $stream = $core->submit(type => 'stream', targets => ['A'], payload => { favorite => 'Radio' });
	my $first = $core->submit(type => 'speak', targets => ['A'], payload => { text => 'Eins' }, deferred => 1);
	$core->ready($first->{id}, uri => 'one.mp3');
	my $second = $core->submit(type => 'speak', targets => ['A'], payload => { text => 'Zwei' }, deferred => 1);
	$core->complete($first->{id});
	is($stream->{state}, 'suspended', 'Stream bleibt waehrend der naechsten TTS-Erzeugung pausiert');
	$core->ready($second->{id}, uri => 'two.mp3');
	is($second->{state}, 'active', 'naechste Sprache startet ohne Stream-Zwischenstart');
};

subtest 'neuer Stream ersetzt nur denselben ueberlappenden Sollzustand' => sub {
	$now = 5_000;
	my $core = build_core();
	my $old = $core->submit(type => 'stream', targets => ['A'], payload => { favorite => 'Alt' });
	my $new = $core->submit(type => 'stream', targets => ['A'], payload => { favorite => 'Neu' });
	is($old->{state}, 'replaced', 'alter Stream wird ersetzt');
	is($new->{state}, 'active', 'neuer Stream ist aktiv');
};

subtest 'Abbruch eines pausierten Requests ruft dessen Ressourcen-Cleanup auf' => sub {
	$now = 6_000;
	my $core = build_core();
	my $queue = $core->submit(type => 'queue', targets => ['A']);
	my $play = $core->submit(type => 'play', targets => ['A'], payload => { uri => 'clip.mp3' });
	is($queue->{state}, 'suspended', 'Queue ist durch den hoeher priorisierten Clip pausiert');
	is($play->{state}, 'active', 'Clip bleibt waehrend des Queue-Abbruchs aktiv');
	@actions = ();
	is($core->cancel($queue->{id}), undef, 'pausierte Queue wird beendet');
	is(
		\@actions,
		["stop:queue:$queue->{id}"],
		'Backend erhaelt fuer den pausierten Request genau einen Cleanup-Aufruf',
	);
	is($play->{state}, 'active', 'hoeher priorisierter Clip bleibt schedulerseitig unangetastet');
};

done_testing;
