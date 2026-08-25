use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use AudioManager::FHEMGateway;

# Die Zeitquelle muss auch fuer Hash-Konstruktionen genau einen Wert liefern.
my $gateway = AudioManager::FHEMGateway->new(
	now => sub { return wantarray ? (123, 456) : 123.456 },
);
my @values = $gateway->now;
is(\@values, [123.456], 'now erzwingt fuer kontextsensitive Zeitquellen den Skalarkontext');

done_testing;
