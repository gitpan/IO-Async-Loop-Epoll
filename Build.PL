use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'IO::Async::Loop::Epoll',
   requires => {
                 'IO::Async'    => '0.20',
                 'IO::Epoll'    => 0.02,
               },
   build_requires => {
                 'Test::More' => 0,
                 'Test::Exception' => 0,
                 'Test::Refcount' => 0,
                 'Time::HiRes' => 0,
               },
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
  );

$build->create_build_script;
