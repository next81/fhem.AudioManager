use strict;
use warnings;
use Test2::V0;
use File::Find qw(find);
use File::Spec ();

my $controls_file = 'controls_AudioManager.txt';
my @expected = ('FHEM/90_AudioManager.pm');

# Ermittelt dieselbe LF-normalisierte Auslieferungslaenge wie der Generator.
sub delivery_size {
	my ($file) = @_;
	open my $input, '<:raw', $file or die "Kann $file nicht lesen: $!";
	local $/;
	my $content = <$input>;
	close $input or die "Kann $file nicht schliessen: $!";
	$content =~ s/\r\n/\n/g;
	return length($content);
}

# Alle produktiven Bibliotheken muessen unabhaengig von neuen Unterverzeichnissen enthalten sein.
find(
	{
		no_chdir => 1,
		wanted => sub {
			return if !-f $File::Find::name || $File::Find::name !~ /\.pm\z/;
			my $path = File::Spec->abs2rel($File::Find::name, '.');
			$path =~ s{\\}{/}g;
			push @expected, $path;
		},
	},
	'lib/AudioManager',
);

open my $controls, '<:raw', $controls_file or die "Kann $controls_file nicht lesen: $!";
my @lines = <$controls>;
close $controls or die "Kann $controls_file nicht schliessen: $!";
my (%entries, @errors);

# Syntax, Eindeutigkeit und Bytelaenge werden fuer jede Controlzeile geprueft.
for my $line (@lines) {
	chomp $line;

	if ($line !~ /^UPD (\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2}) (\d+) (\S+)$/) {
		push @errors, "Ungueltige Control-Zeile: $line";
		next;
	}

	my ($size, $path) = ($2, $3);
	push @errors, "Doppelter Control-Eintrag: $path" if exists $entries{$path};
	$entries{$path} = 0 + $size;
}

is(\@errors, [], 'Controlfile enthaelt nur eindeutige gueltige UPD-Zeilen');
is([ sort keys %entries ], [ sort @expected ], 'Controlfile enthaelt exakt alle Produktionsmodule');

# Jede referenzierte Datei muss existieren und exakt zur veroeffentlichten Laenge passen.
for my $path (sort keys %entries) {
	ok(-f $path, "$path existiert");
	is($entries{$path}, delivery_size($path), "$path hat die angegebene Auslieferungslaenge");
}

done_testing;
