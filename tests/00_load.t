use strict;
use warnings;
use Test2::V0;
use lib 'lib';
no warnings qw(once);

ok(eval { require AudioManager::Core; 1 }, 'Scheduler laedt') or diag $@;
ok(eval { require AudioManager::Backend; 1 }, 'Backendvertrag laedt') or diag $@;
ok(eval { require AudioManager::Backend::Sonos2mqtt; 1 }, 'Sonos2mqtt-Adapter laedt') or diag $@;
ok(eval { require AudioManager::FHEMGateway; 1 }, 'FHEM-Gateway laedt') or diag $@;
ok(eval { require AudioManager::Supervisor; 1 }, 'Backend-Supervisor laedt') or diag $@;
is($AudioManager::Backend::INTERFACE_VERSION, 3, 'Backendvertrag ist versioniert');
is($AudioManager::Core::VERSION, '0.5.0', 'Coreversion ist sichtbar');
is($AudioManager::Supervisor::VERSION, '0.6.0', 'Supervisorversion ist sichtbar');
ok(!$INC{'Test/More.pm'}, 'Produktionsmodule laden Test::More nicht');

done_testing;

