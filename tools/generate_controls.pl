#!/usr/bin/env perl

use strict;
use warnings;
use File::Find qw(find);
use File::Spec ();
use POSIX qw(strftime);

my $output = 'controls_AudioManager.txt';
my @files = ('FHEM/90_AudioManager.pm');

# Das Controlfile liefert nur produktive Perlmodule aus; Tests, Werkzeuge und
# Dokumentation bleiben Bestandteile des Repositories, aber nicht des FHEM-Updates.
find(
	{
		no_chdir => 1,
		wanted => sub {
			return if !-f $File::Find::name || $File::Find::name !~ /\.pm\z/;
			push @files, File::Spec->abs2rel($File::Find::name, '.');
		},
	},
	'lib/AudioManager',
);

# Ermittelt die Auslieferungslaenge mit LF-Zeilenenden, wie GitHub sie bereitstellt.
sub delivery_size {
	my ($file) = @_;
	open my $input, '<:raw', $file or die "Kann $file nicht lesen: $!\n";
	local $/;
	my $content = <$input>;
	close $input or die "Kann $file nicht schliessen: $!\n";
	$content =~ s/\r\n/\n/g;
	return length($content);
}

my %seen;
@files = sort grep { !$seen{$_}++ } @files;
open my $controls, '>:raw', $output or die "Kann $output nicht schreiben: $!\n";

# Jede Produktionsdatei erscheint genau einmal mit portablem Slash-Pfad.
for my $file (@files) {
	my @stat = stat($file);
	die "Kann $file nicht lesen: $!\n" if !@stat;
	my $path = $file;
	$path =~ s{\\}{/}g;
	my $timestamp = strftime('%Y-%m-%d_%H:%M:%S', localtime($stat[9]));
	print {$controls} "UPD $timestamp " . delivery_size($file) . " $path\n";
}

close $controls or die "Kann $output nicht schliessen: $!\n";
print "$output mit " . scalar(@files) . " Dateien erzeugt.\n";
