use strict;
use warnings;
use Test2::V0;
use lib 'lib';
no warnings qw(once);

ok(eval { require AudioManager::Core; 1 }, 'Scheduler laedt') or diag $@;
ok(eval { require AudioManager::Config; 1 }, 'Konfigurationsparser laden') or diag $@;
ok(eval { require AudioManager::Backend; 1 }, 'Backendvertrag laedt') or diag $@;
ok(eval { require AudioManager::Backend::Sonos2mqtt; 1 }, 'Sonos2mqtt-Adapter laedt') or diag $@;
ok(eval { require AudioManager::Backend::Sonos2mqtt::Health; 1 }, 'Sonos2mqtt-Health laedt') or diag $@;
ok(eval { require AudioManager::Backend::Sonos2mqtt::Topology; 1 }, 'Sonos2mqtt-Topologie laedt') or diag $@;
ok(eval { require AudioManager::Backend::Sonos2mqtt::Snapshot; 1 }, 'Sonos2mqtt-Snapshot laedt') or diag $@;
ok(eval { require AudioManager::Backend::Sonos2mqtt::Controls; 1 }, 'Sonos2mqtt-Controls laedt') or diag $@;
ok(eval { require AudioManager::FHEMGateway; 1 }, 'FHEM-Gateway laedt') or diag $@;
ok(eval { require AudioManager::Module::Status; 1 }, 'Statusmodul laedt') or diag $@;
ok(eval { require AudioManager::Module::FHEM; 1 }, 'FHEM-Schnittstelle laedt') or diag $@;
ok(eval { require AudioManager::Module::TTS; 1 }, 'TTS-Modul laedt') or diag $@;
ok(eval { require AudioManager::Module::Runtime; 1 }, 'Runtime-Modul laedt') or diag $@;
ok(eval { require AudioManager::Supervisor; 1 }, 'Backend-Supervisor laedt') or diag $@;
is($AudioManager::Backend::INTERFACE_VERSION, 3, 'Backendvertrag ist versioniert');
open my $module_file, '<:raw', 'FHEM/90_AudioManager.pm'
	or die "Kann FHEM/90_AudioManager.pm nicht lesen: $!";
local $/;
my $module_source = <$module_file>;
close $module_file or die "Kann FHEM/90_AudioManager.pm nicht schliessen: $!";

my ($module_version) = $module_source =~ /\bour\s+\$AUDIOMANAGER_VERSION\s*=\s*'([^']+)'/;
is($module_version, '0.6.4', 'Modulversion ist zentral sichtbar');
is($AudioManager::Core::VERSION, undef, 'Core hat keine eigene Version');
is($AudioManager::Supervisor::VERSION, undef, 'Supervisor hat keine eigene Version');
ok(!$INC{'Test/More.pm'}, 'Produktionsmodule laden Test::More nicht');

done_testing;
