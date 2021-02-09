# -*- mode; perl -*-
use strict;
use warnings;
use Cwd ();
use ExtUtils::MakeMaker;
use File::Basename ();
use File::Spec     ();

my $project_dir   = File::Basename::dirname( Cwd::realpath(__FILE__) );
my $project_name  = File::Basename::basename($project_dir);
my $modules_dir   = 'modules';
my $module        = 'Bio::EnsEMBL::ApiVersion';
my $module_loaded = eval {
  local @INC = ( $modules_dir, @INC );
  require Bio::EnsEMBL::ApiVersion;
  1;
};
die "Failed to load module from $modules_dir: $@" if $@;
my $version = $module->software_version;

eval { require ExtUtils::MakeMaker::CPANfile; 1; } or
  die "Please install ExtUtils::MakeMaker::CPANfile using cpanm\n";

ExtUtils::MakeMaker::CPANfile->import;

WriteMakefile(
    NAME               => $project_name,
    ABSTRACT           => "Perl API ($project_name)",
    VERSION            => $version,
    PMLIBDIRS          => [$modules_dir],
    PMLIBPARENTDIRS    => [$modules_dir],
    TEST_REQUIRES      => { 'Bio::EnsEMBL::Test::TestUtils' => 0 },
    CONFIGURE_REQUIRES => { 'ExtUtils::MakeMaker::CPANfile' => '0.09' },
    test => { TESTS => File::Spec->catfile( $modules_dir, 't', '*.t' ) }
);
