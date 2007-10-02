use strict;

# Submits the display name and GO term projections as farm jobs
# Remember to check/set the various config optons

# ------------------------------ config -------------------------------
my $release = 47;

my $base_dir = "/lustre/work1/ensembl/gp1/projections/";

my $conf = "release_47.ini"; # registry config file

# -------------------------- end of config ----------------------------

# check that base directory exists
die ("Cannot find base directory $base_dir") if (! -e $base_dir);

# create release subdir if necessary
my $dir = $base_dir. $release;
if (! -e $dir) {
  mkdir $dir;
  print "Created $dir\n";
} else {
  print "Cleaning and re-using $dir\n";
  unlink <$dir/*.out>, <$dir/*.err>;
}

# common options
my $opts = "-conf $conf -release $release -quiet";

my ($o, $e, $n);

# ----------------------------------------
# Display names

# human to chimp,opossum,dog,cow,macaque,chicken,xenopus,pig,armadillo,small_hedgehog,european_hedgehog,cat,elephant,macaque,bat,platypus,rabbit,galago,european_shrew,squirrel,ground_shrew
foreach my $to ("chimp", "opossum", "dog", "cow", "macaque", "chicken", "xenopus", "guinea_pig", "armadillo", "small_hedgehog", "european_hedgehog", "cat", "elephant", "bat", "platypus", "rabbit", "galago", "european_shrew", "squirrel", "ground_shrew") {
  $o = "$dir/names_human_$to.out";
  $e = "$dir/names_human_$to.err";
  $n = substr("n_hum_$to", 0, 10); # job name display limited to 10 chars
  system "bsub -o $o -e $e -J $n perl project_display_xrefs.pl $opts -from human -to $to -names -delete_names -no_database";
}

# mouse to rat
foreach my $to ("rat") { # don't need the loop but may add more species later
  $o = "$dir/names_mouse_$to.out";
  $e = "$dir/names_mouse_$to.err";
  $n = substr("n_mou_$to", 0, 10);
  system "bsub -o $o -e $e -J $n perl project_display_xrefs.pl $opts -from mouse -to $to -names -delete_names -no_database";
}

# human to fish - note use of -one_to_many option for 1-many projections
foreach my $to ("zebrafish", "medaka", "tetraodon", "fugu", "stickleback") {
  $o = "$dir/names_human_$to.out";
  $e = "$dir/names_human_$to.err";
  $n = substr("n_hum_$to", 0, 10);
  system "bsub -o $o -e $e -J $n perl project_display_xrefs.pl $opts -from human -to $to -names -delete_names -no_database -one_to_many";
}

# ----------------------------------------
# GO terms

$opts .= " -nobackup";

# human to mouse, rat, dog, chicken, cow, chimp, macaque, guinea_pig
foreach my $to ("mouse", "rat", "dog", "chicken", "cow", "chimp", "macaque", "guinea_pig") {
  $o = "$dir/go_human_$to.out";
  $e = "$dir/go_human_$to.err";
  $n = substr("g_hum_$to", 0, 10);
  system "bsub -o $o -e $e -J $n perl project_display_xrefs.pl $opts -from human -to $to -go_terms -delete_go_terms";
}

# drosophila to anopheles, aedes
foreach my $to ("anopheles", "aedes") {
  $o = "$dir/go_drosophila_$to.out";
  $e = "$dir/go_drosophila_$to.err";
  $n = substr("g_dros_$to", 0, 10);
  system "bsub -o $o -e $e -J $n perl project_display_xrefs.pl $opts -from drosophila -to $to -go_terms -delete_go_terms";
}

# ----------------------------------------

# GO terms - mouse to human, rat, dog, chicken, cow
# Have to use job dependencies since these jobs need to run after the corresponding human-X projections have
# Note need to not use -delete the second time around
foreach my $to ("human", "rat", "dog", "chicken", "cow") {
  $o = "$dir/go_mouse_$to.out";
  $e = "$dir/go_mouse_$to.err";
  $n = substr("g_mou_$to", 0, 10);
  my $d;
  if ($to eq 'human') { # no "human-human" to depend upon
    $d = '';
  } else {
    my $depend_job_name = substr("g_hum_$to", 0, 10);
    $d = "-w 'ended($depend_job_name)'";
  }
  system "bsub -o $o -e $e -J $n $d perl project_display_xrefs.pl $opts -from mouse -to $to -go_terms";
}
