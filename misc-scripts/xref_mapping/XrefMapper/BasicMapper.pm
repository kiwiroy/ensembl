package XrefMapper::BasicMapper;

use strict;
use Cwd;
use DBI;
use File::Basename;
use IPC::Open3;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Translation;
use XrefMapper::db;
use vars qw(@ISA @EXPORT_OK);
use strict;
@EXPORT_OK = qw (%stable_id_to_internal_id  %xref_to_source %xref_accessions %source_to_external_db);
use vars qw (%stable_id_to_internal_id %xref_to_source %xref_accessions %source_to_external_db);

=head1 NAME

XrefMapper::BasicMapper

=head1 DESCIPTION

This is the basic mapper routine. It will create the necessary fasta files for
both the xref and ensembl sequences. These will then be matched using exonerate
and the results written to another file. By creating a <species>.pm file and 
inheriting from this base class different matching routines, parameters, data 
sets etc can be set.

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk


=cut

# hold alist of source that have more than 1 priority
# and hence can come from several sources.
my %priority_source_id;     # {1090} = 1
my %priority_source_name;   # {HUGO} = 2
my %priority_source_id_to_name;    # {1091} = HUGO

#be able to get from xref to the accession or source for those needed
my %priority_xref_acc;      # {12} =  "567";
my %priority_xref_source_id;# {12} = 1090;

# hold a hash of the values with the highest priority
my %priority_xref;          # {HUGO:567} = 12
my %priority_xref_extra_bit;# {12} = "\tDIRECT\tExternally assigned relationship between ENST123 and Q12345\n";
my %priority_xref_state;    # {HUGO:567} = "primary" or "dependent" or "direct";
my %priority_xref_priority; # {HUGO:567} = 1; 
my %priority_object_xref;   # {HUGO:567} = {Gene:123456};
my %priority_identity_xref; # {HUGO:567} = as normal print except no object_xref_id at the start
#                                        = "100\t100\t1\t100\t110-210\t100M\t100\t987\n";
my %priority_failed;         # {1090:12} = "gene|123456|78|35|90|90\n";


my %unmapped_primary_xref;   # $unmapped_primary_xref{1234} = " master QZ1234 had no match"
                             # store list of primary unmapped xrefs
                             # to use to write secondary unmapped_object data

my %object_succesfully_mapped;  # $object_succesfully_mapped{1235}  = 1;



# Hashes to hold method-specific thresholds
my %method_query_threshold;
my %method_target_threshold;

# Various useful variables.
my %translation_to_transcript;
my %transcript_to_translation;
my %genes_to_transcripts;
my %internal_id_to_stable_id;
my %xref_descriptions;
my %xrefs_written;
my %priority_seenit;
my %object_xrefs_written;        # Needed in case an xref if matched to one enembl object
                                 # by more than one method. On the display we only want to see it once.
my %failed_xref_mappings;
my %updated_source;
my %XXXxref_id_to_accession;



=head2 find_priority_sources

  Description: Finds those source that hae more than one source
               Stores the results in the global hashes 
               %priority_source_id and %priority_source_name
  Returntype : none
  Exceptions : none
  Caller     : General

=cut

sub find_priority_sources{
  my($self) = @_;



# need to check if this needed for this species.
# NOTE: only store in priority_source_name if same name seen more than once :-)
# i.e. more than one priority source is "USED"

  my $sql = "select distinct(source.source_id), source.name, source.priority from source, xref where xref.source_id = source.source_id ";
  my $sth = $self->xref->dbc->prepare($sql);
  $sth->execute();
  my ($source_id, $name, $priority);
  $sth->bind_columns(\$source_id,\$name, \$priority);
  my %more_than_one;
  while($sth->fetch()){
      if(!defined($more_than_one{$name})){
	  $more_than_one{$name} = $priority;
      }
      else{
	  $priority_source_name{$name} = $priority;
      }
  }
  $sth->finish;







  foreach my $name (keys %priority_source_name){
    $sql = 'SELECT source_id, name, priority from source where name ="'.$name.'"'; 
    print "\t".$name." to be processed using prioritys of the sources\n";
    
    #for each name get all the sources and then store the xref data needed.
    my $sth = $self->xref->dbc->prepare($sql);
    $sth->execute();
    $sth->bind_columns(\$source_id,\$name, \$priority);
    my @source_ids=();
    while($sth->fetch()){
      $priority_source_name{$name} = $priority;
      $priority_source_id{$source_id} = $priority;    
      $priority_source_id_to_name{$source_id} = $name;
      push @source_ids, $source_id;
    }
    $sth->finish;
    foreach my $source (@source_ids){

      my $sql2 = "SELECT xref_id, accession from xref where xref.source_id = $source";
      my $sth2 = $self->xref->dbc->prepare($sql2);
      $sth2->execute();
      my ($xref_id, $acc);
      $sth2->bind_columns(\$xref_id,\$acc);
      print "\tgetting data for source $source\n";	
      my $count =0;
      while($sth2->fetch){
	$priority_xref_acc{$xref_id}       = $acc;
	$priority_xref_source_id{$xref_id} = $source;
	$count++;
      }
      print "\t$count xrefs accessed at priority level ".$priority_source_id{$source}."\n";
      $sth2->finish;
    }
  }

}

=head2 new

  Description: Constructor for BasicMapper.
  Returntype : BasicMapper
  Exceptions : none
  Caller     : general

=cut

sub new{
  my($class, @args) = @_;

  my $self ={};
  bless $self,$class;
  $self->jobcount(0);
  return $self;
}


=head2 dump_seqs

  Arg[1]: xref object which holds info needed for the dump of xref

  Description: Dumps out the files for the mapping. Xref object should hold
              the value of the databases and source to be used.
  Returntype : none
  Exceptions : will die if species not known or an error occurs while
             : trying to write to files. 
  Caller     : general
 
=cut
 


sub dump_seqs{

  my ($self, $location) = @_;

  $self->dump_xref();
  $self->dump_ensembl($location);

}



=head2 build_list_and_map

  Arg[1]: xref object which holds info on method and files.

  Description: runs the mapping of the list of files with species methods
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub build_list_and_map {

  my ($self) = @_;

  my @list=();

  my $i = 0;
  foreach my $method (@{$self->method()}){
    my @dna=();
    my $q_dna_file = $self->xref->dir."/xref_".$i."_dna.fasta";
    if (-e $q_dna_file and -s $q_dna_file) {
      push @dna, $method;
      push @dna, $q_dna_file;
      push @dna, $self->core->dna_file();
      push @list, \@dna;
    }

    my @pep=();
    my $q_pep_file =  $self->xref->dir."/xref_".$i."_peptide.fasta";
    if (-e $q_pep_file and -s $q_pep_file) {
      push @pep, $method;
      push @pep, $self->xref->dir."/xref_".$i."_peptide.fasta";
      push @pep, $self->core->protein_file();
      push @list, \@pep;
    }
    $i++;
  }

  $self->run_mapping(\@list);

}
#
#  $self->remove_all_old_output_files();


=head2 get_species_id_from_species_name

  Arg[1]: species name

  Description: get the species_id from the database for the named database.
  Example    : my $id = get_species_id_from_species_name('homo_sapiens');
  Returntype : int (species_id)
  Exceptions : will die if species does not exist in given xref database.
  Caller     : general

=cut

sub get_species_id_from_species_name{
  my ($self,$species) = @_;


  my $sql = "select species_id from species where name = '".$species."'";
  my $sth = $self->dbc->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  my $species_id;
  if (@row) {
    $species_id = $row[0];
  } else {
    print STDERR "Couldn't get ID for species ".$species."\n";
    print STDERR "It must be one of :-\n";
    $sql = "select name from species";
    $sth = $self->dbc->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){
      print STDERR $row[0]."\n";
    }
    die("Please try again :-)\n");
  }
  $sth->finish();

  return $species_id;
}


=head2 get_set_lists

  Description: specifies the list of databases and source to be used in the
             : generation of one or more data sets.
  Returntype : list of lists
  Example    : my @lists =@{$self->get_set_lists()};
  Exceptions : none
  Caller     : dump_xref

=cut

sub get_set_lists{
  my ($self) = @_;

  return [["ExonerateGappedBest1", ["*","*"]]];

}

=head2 get_source_id_from_source_name

  Arg[1]: source name

  Description: get the source_id from the database for the named source.
  Example    : my $id = get_source_id_from_source_name('RefSeq');
  Returntype : int (source_id)
  Exceptions : will die if source does not exist in given xref database.
  Caller     : general

=cut

sub get_source_id_from_source_name{
  my ($self, $source) = @_;
  my $source_id;
  
  my $sql = "select source_id from source where name = '".$source."'";
  my $sth = $self->dbc->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  if (defined $row[0] and $row[0] ne '') {
    $source_id = $row[0];
  } else {
    print STDERR "Couldn't get ID for source ".$source."\n";
    print STDERR "It must be one of :-\n";
    $sql = "select name from source";
    $sth = $self->dbc->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){
      print STDERR $row[0]."\n";
    }
    die("Please try again :-)\n");
  }
  $sth->finish();

  return $source_id;
} 


=head2 dump_xref

  Arg[1]: xref object which holds info on method and files.

  Description: Dumps the Xref data as fasta file(s)
  Returntype : none
  Exceptions : none
  Caller     : dump_seqs

=cut

sub dump_xref{
  my ($self) = @_;
  
  my $xref =$self->xref();
  if(!defined($xref->dir())){
    if(defined($self->dir)){
      $xref->species($self->dir);
    }
    else{
      $xref->dir(".");
    }
  }
  
  my @method=();
  
  my @lists =@{$self->get_set_lists()};
  
  my $i=0;
  if(defined($self->dumpcheck())){
    my $skip = 1;
    foreach my $list (@lists){
      if(!-e $xref->dir()."/xref_".$i."_dna.fasta"){ 
	$skip = 0;
      }
      if(!-e $xref->dir()."/xref_".$i."_peptide.fasta"){ 
	$skip = 0;
      }
      $i++;
    }
    if($skip){
      my $k = 0;
      foreach my $list (@lists){
	$method[$k++] = shift @$list;
      }
      $self->method(\@method);
      return;
    }
  }

  $i=0;
  foreach my $list (@lists){
    $method[$i] = shift @$list;
    my $j = 0;
    my @source_id=();
    my @species_id=();
    foreach my $element (@$list){
      while(my $species = shift(@$element)){
	if($species ne "*"){
	  $species_id[$j] = get_species_id_from_species_name($xref,$species);
	}
	else{
	  $species_id[$j] = -1;
	}
	my $source = shift(@$element);
	if($source ne "*"){
	  $source_id[$j] = get_source_id_from_source_name($xref,$source);
	}
	else{
	  $source_id[$j] = -1;
	}
	$j++;
      }
    }
    #method data fully defined now
    $self->dump_subset($xref,\@species_id,\@source_id,$i);    
    $i++;
  }
  
  $self->method(\@method);

  return;
  
}

=head2 dump_subset

  Arg[1]: xref object which holds info on files.
  Arg[2]: list of species to use.
  Arg[3]: list of sources to use.
  Arg[4]: index to be used in file creation.
  
  Description: Dumps the Xref data for one set of species/databases
  Returntype : none
  Exceptions : none
  Caller     : dump_xref

=cut


sub dump_subset{

  my ($self,$xref,$rspecies_id,$rsource_id,$index) = @_;

  # generate or condition list for species and sources
  my $final_clause;
  my $use_all = 0;
  my @or_list;
  for (my $j = 0; $j < scalar(@$rspecies_id); $j++){
    my @condition;
    if($$rspecies_id[$j] > 0){
      push @condition, "x.species_id=" . $$rspecies_id[$j];
   }
    if($$rsource_id[$j] > 0){
      push @condition, "x.source_id=" . $$rsource_id[$j];
    }

    # note if both source and species are * (-1) there's no need for a final clause

    if ( !@condition ) {
      $use_all = 1;
      last;
    }

    push @or_list, join (" AND ", @condition);

  }

  $final_clause = " AND ((" . join(") OR (", @or_list) . "))" unless ($use_all) ;

  for my $sequence_type ('dna', 'peptide') {

    my $filename = $xref->dir() . "/xref_" . $index . "_" . $sequence_type . ".fasta";
    open(XREF_DUMP,">$filename") || die "Could not open $filename";

    my $sql = "SELECT p.xref_id, p.sequence, x.species_id , x.source_id ";
    $sql   .= "  FROM primary_xref p, xref x ";
    $sql   .= "  WHERE p.xref_id = x.xref_id AND ";
    $sql   .= "        p.sequence_type ='$sequence_type' ";
    $sql   .= $final_clause;

    if(defined($self->maxdump())){
      $sql .= " LIMIT ".$self->maxdump()." ";
    }

    my $sth = $xref->dbc->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){

      $row[1] =~ s/(.{60})/$1\n/g;
      print XREF_DUMP ">".$row[0]."\n".$row[1]."\n";

    }

    close(XREF_DUMP);
    $sth->finish();

  }

}

=head2 dump_ensembl

  Description: Dumps the ensembl data to a file in fasta format.
  Returntype : none
  Exceptions : none
  Caller     : dump_seqs

=cut

sub dump_ensembl{
  my ($self, $location) = @_;

  $self->fetch_and_dump_seq($location);

}


=head2 fetch_and_dump_seq

  Description: Dumps the ensembl data to a file in fasta format.
  Returntype : none
  Exceptions : wil die if the are errors in db connection or file creation.
  Caller     : dump_ensembl

=cut

sub fetch_and_dump_seq{
  my ($self, $location) = @_;

  my $ensembl = $self->core;
  my $logic_name = $self->logic_name;
  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(-dbconn => $ensembl->dbc);

  #
  # store ensembl dna file name and open it
  #
  if(!defined($ensembl->dir())){
    $ensembl->dir(".");
  }
  $ensembl->dna_file($ensembl->dir."/".$ensembl->species."_dna.fasta");


  #
  # store ensembl protein file name and open it
  #
  $ensembl->protein_file($ensembl->dir."/".$ensembl->species."_protein.fasta");


  if(defined($self->dumpcheck()) and -e $ensembl->protein_file() and -e $ensembl->dna_file()){
    return;
  }
  open(DNA,">".$ensembl->dna_file()) 
    || die("Could not open dna file for writing: ".$ensembl->dna_file."\n");

  open(PEP,">".$ensembl->protein_file()) 
    || die("Could not open protein file for writing: ".$ensembl->protein_file."\n");

  my $gene_adaptor = $db->get_GeneAdaptor();


  # fetch by location, or everything if not defined

  my @genes;
  if ($location) {

    my $slice_adaptor = $db->get_SliceAdaptor();
    my $slice = $slice_adaptor->fetch_by_name($location);
    @genes = @{$gene_adaptor->fetch_all_by_Slice( $slice )};

  } else {

    my $constraint;
    if( $logic_name ){
      $constraint = $gene_adaptor->_logic_name_to_constraint( '',$logic_name );
    }
    @genes = @{$gene_adaptor->fetch_all( $constraint )};

  }

  my $max = undef;
  if(defined($self->maxdump())){
    $max = $self->maxdump();
  }
  my $i =0;
  my $rna = 0;
  foreach my $gene (@genes){
    next if $gene->biotype eq 'J_segment';
    next if $gene->biotype eq 'D_segment';

    foreach my $transcript (@{$gene->get_all_Transcripts()}) {
      $i++;
      my $seq = $transcript->spliced_seq(); 
      $seq =~ s/(.{60})/$1\n/g;
      print DNA ">" . $transcript->dbID() . "\n" .$seq."\n";
      my $trans = $transcript->translation();
      my $translation = $transcript->translate();
      
      if(defined($translation)){
	my $pep_seq = $translation->seq();
	$pep_seq =~ s/(.{60})/$1\n/g;
	print PEP ">".$trans->dbID()."\n".$pep_seq."\n";
      }
    }

     last if(defined($max) and $i > $max);
    
  }
  close DNA;
  close PEP;
  
}



###
# Getter/Setter methods
###





=head2 method
 
  Arg [1]    : (optional) list reference $arg
               reference to a list of method names 
  Example    : my @methods = @{$self->method()};
  Description: Getter / Setter for the methods 
  Returntype : list
  Exceptions : none

=cut


sub method{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_method} = $arg );
  return $self->{_method};
}

=head2 core
 
  Arg [1]    : (optional) 
  Example    : $mapper->core($new_core);
  Description: Getter / Setter for the core. 
               info for the ensembl core database. 
  Returntype : XrefMapper::db
  Exceptions : none

=cut

sub core{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_core} = $arg );
  return $self->{_core};
}


=head2 dumpcheck
 
  Arg [1]    : (optional) 
  Example    : $mapper->dumpcheck("yes");
  Description: Getter / Setter for dumpcheck. 
               If set the mapper will not dump fasta files 
               if they exist already. 
  Returntype : scalar
  Exceptions : none

=cut

sub dumpcheck {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_dumpcheck} = $arg );
  return $self->{_dumpcheck};
}

=head2 external_db_file
 
  Arg [1]    : (optional) 
  Example    : $mapper->external_db_file(cwd()."../../external_db.txt");
  Description: Getter / Setter for external_db_file. 
               Stores the file witj path of where to get the external database file.
  Returntype : scalar
  Exceptions : none

=cut

sub external_db_file {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_external_db_file} = $arg );
  return $self->{_external_db_file};
}

=head2 upload
 
  Arg [1]    : (optional) 
  Example    : $mapper->upload("yes");
  Description: Getter / Setter for dumpcheck. 
               If set the mapper will not upload files.
  Returntype : scalar
  Exceptions : none

=cut

sub upload {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_upload} = $arg );
  return $self->{_upload};
}


=head2 maxdump
 
  Arg [1]    : (optional) 
  Example    : $mapper->maxdump(10);
  Description: Getter / Setter for maxdump. 
               If set the mapper will only dump that number of 
               sequences into the fasta files. (Mainly used for testing).
  Returntype : scalar
  Exceptions : none

=cut

sub maxdump {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_maxdump} = $arg );
  return $self->{_maxdump};
}



=head2 use_existing_mappings

  Arg [1]    : (optional) 
  Example    : $mapper->use_existing_mappings("yes");
  Description: Getter / Setter for use_existing_mappings. 
               If set the mapper will not redo the mapping
               but parse the existing .map files.
  Returntype : scalar
  Exceptions : none

=cut

sub use_existing_mappings {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_use_existing_mappings} = $arg );
  return $self->{_use_existing_mappings};
}


=head2 logic_name

  Arg [1]    : (optional) 
  Example    : $mapper->logic_name('ensembl_genes');
  Description: Getter / Setter for logic_name. 
               Only genes corresponding to this analysis.logic_name
               will be dumped. 
  Returntype : scalar
  Exceptions : none

=cut

sub logic_name {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_logic_name} = $arg );
  return $self->{_logic_name};
}


=head2 xref
 
  Arg [1]    : (optional) 
  Example    : $mapper->core($new_core);
  Description: Getter / Setter for the core. 
               info for the xref database. 
  Returntype : XrefMapper::db
  Exceptions : none

=cut

sub xref{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_xref} = $arg );
  return $self->{_xref};
}

=head2 jobcount
 
  Arg [1]    : (optional) 
  Example    : $mapper->jobcount(1004);
  Description: Getter / Setter for number of jobs submitted. 
  Returntype : scalar
  Exceptions : none

=cut

sub jobcount {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_jobcount} = $arg );
  return $self->{_jobcount};
}


=head2 run_mapping

  Arg[1]     : List of lists of (method, query, target)
  Arg[2]     :
  Example    : none
  Description: Create and submit mapping jobs to LSF, and wait for them to finish.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub run_mapping {

  my ($self, $lists) = @_;

  # delete old output files in target directory if we're going to produce new ones
  if (!defined($self->use_existing_mappings())) {
    print "Deleting out err and map files from output dir\n";
    my $dir = $self->core->dir();
    unlink (<$dir/*.map $dir/*.out $dir/*.err>);
  }
  $self->remove_all_old_output_files();
  #disconnect so that we can then reconnect after the long mapping bit.
  $self->core->dbc->disconnect_if_idle(1);
  $self->xref->dbc->disconnect_if_idle(1);
  $self->core->dbc->disconnect_when_inactive(1);
  $self->xref->dbc->disconnect_when_inactive(1);


  # foreach method, submit the appropriate job & keep track of the job name
  # note we check if use_existing_mappings is set here, not earlier, as we
  # still need to instantiate the method object in order to fill
  # method_query_threshold and method_target_threshold

  my @job_names;
  my @running_methods;
  foreach my $list (@$lists){

    my ($method, $queryfile ,$targetfile)  =  @$list;

    my $obj_name = "XrefMapper::Methods::$method";
    # check that the appropriate object exists
    eval "require $obj_name";
    if($@) {

      warn("Could not find object $obj_name corresponding to mapping method $method, skipping\n$@");

    } else {

      my $obj = $obj_name->new();
      $method_query_threshold{$method} = $obj->query_identity_threshold();
      $method_target_threshold{$method} = $obj->target_identity_threshold();


      if (!defined($self->use_existing_mappings)) {
	my $job_name = $obj->run($queryfile, $targetfile, $self->core->dir());
	push @job_names, $job_name;
        push @running_methods, $obj;
	sleep 1; # make sure unique names really are unique
      }
      $self->jobcount($self->jobcount+$obj->jobcount);
    }

  } # foreach method

  if (!defined($self->use_existing_mappings)) {
    # submit depend job to wait for all mapping jobs
    foreach my $method( @running_methods ){
      # Submit all method-specific depend jobs
      if( $method->can('submit_depend_job') ){
        $method->submit_depend_job;
      }
    }
    # Submit generic depend job. Defaults to LSF
    submit_depend_job($self->core->dir, @job_names);
  }
  $self->check_err($self->core->dir); 
} # run_mapping


=head2 submit_depend_job

  Arg[1]     : List of job names.
  Arg[2]     :
  Example    : none
  Description: Submit an LSF job that waits for other jobs to finish.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub submit_depend_job {

  my ($root_dir, @job_names) = @_;

  # Submit a job that does nothing but wait on the main jobs to
  # finish. This job is submitted interactively so the exec does not
  # return until everything is finished.

  # build up the bsub command; first part
  my @depend_bsub = ('bsub', '-K');

  # build -w 'ended(job1) && ended(job2)' clause
  my $ended_str = "-w ";
  my $i = 0;
  foreach my $job (@job_names) {
    $ended_str .= "ended($job)";
    $ended_str .= " && " if ($i < $#job_names);
    $i++;
  }

  push @depend_bsub, $ended_str;

  # rest of command
  push @depend_bsub, ('-q', 'small', '-o', "$root_dir/depend.out", '-e', "$root_dir/depend.err");

  #print "##depend bsub:\n" . join (" ", @depend_bsub) . "\n";

  my $jobid = 0;

  eval {
    my $pid;
    my $reader;

    local *BSUB;
    local *BSUB_READER;

    if (($reader = open(BSUB_READER, '-|'))) {
      while (<BSUB_READER>) {
        #print "YES:$_";
	if (/^Job <(\d+)> is submitted/) {
	  $jobid = $1;
	  print "LSF job ID for depend job: $jobid\n"
	}
      }
      close(BSUB_READER);
    } else {
      die("Could not fork : $!\n") unless (defined($reader));
      open(STDERR, ">&STDOUT");
      if (($pid = open(BSUB, '|-'))) {
	
	print BSUB "/bin/true\n";
	close BSUB;
	if ($? != 0) {
	  die("bsub exited with non-zero status ($?) - job not submitted\n");
	}
      } else {
	if (defined($pid)) {
	  exec(@depend_bsub);
	  die("Could not exec bsub : $!\n");
	} else {
	  die("Could not fork : $!\n");
	}
      }
      exit(0);
    }
  };

  if ($@) {
    # Something went wrong
    warn("Job submission failed:\n$@\n");
  }

}

=head2 parse_mappings

  Example    : none
  Description: Parse exonerate output files and build files for loading into target db tables.
  Returntype : List of strings
  Exceptions : none
  Caller     : general

=cut

sub parse_mappings {

  my ($self, $notriage) = @_;

  my $ensembl = $self->core;
  my $xref = $self->xref;
  my $dir = $ensembl->dir();

  # incase timed out, force reconnection
  $ensembl->dbc->disconnect_if_idle(0);
  $ensembl->dbc->disconnect_when_inactive(0);
  $ensembl->dbc->connect();

  $xref->dbc->disconnect_if_idle(0);
  $xref->dbc->disconnect_when_inactive(0);
  $xref->dbc->connect();


  # Will need lookup tables for gene/transcript/translation stable ID to internal ID
  $self->build_stable_id_to_internal_id_hash();

  # get current max object_xref_id
  my $row = @{$ensembl->dbc->db_handle->selectall_arrayref("SELECT MAX(object_xref_id) FROM object_xref")}[0];
  my $max_object_xref_id = @{$row}[0];
  if (!defined $max_object_xref_id) {
    print "No existing object_xref_ids, will start from 1\n";
    $max_object_xref_id = 0;
  } else {
    print "Maximum existing object_xref_id = $max_object_xref_id\n";
  }

  $row = @{$ensembl->dbc->db_handle->selectall_arrayref("SELECT MAX(xref_id) FROM xref")}[0];
  my $max_xref_id = @$row[0];
  if (!defined $max_xref_id) {
    print "No existing xref_ids, will start from 1\n";
    $max_xref_id = -1; # so that generated xref_ids will be the same as in xref db
  } else {
    print "Maximum existing xref_id = $max_xref_id\n";
  }

  my $xref_id_offset = $max_xref_id + 1;

  $self->xref_id_offset($xref_id_offset); #store 

  # files to write table data to
  open (OBJECT_XREF,   ">$dir/object_xref.txt");
  open (IDENTITY_XREF, ">$dir/identity_xref.txt");

  my $total_lines = 0;
  my $last_lines = 0;
  my $total_files = 0;

  # keep a (unique) list of xref IDs that need to be written out to file as well
  # this is a hash of hashes, keyed on xref id that relates xrefs to e! objects (may be 1-many)
  my %primary_xref_ids = ();


  # and a list of mappings of ensembl objects to xrefs
  # (primary now, dependent added in dump_core_xrefs)
  # this is required for display_xref generation later
  # format:
  #   key: ensembl object type:ensembl object id
  #   value: list of xref_id (with offset)



  my @dna_check=();
  my @pep_check=();
  my $count_new=0;

  foreach my $file (glob("$dir/*.map")) {

    #print "Parsing results from " . basename($file) .  "\n";
    open(FILE, $file);
    $total_files++;

    # files are named Method_(dna|peptide)_N.map

    my ($method, $type, $part) = get_parts($file);
    
    if($type =~ 'Translation'){
      $pep_check[$part] = $part;
    }
    elsif($type =~ 'Transcript'){
      $dna_check[$part] =  $part;
    }
    else{
      die "unknown type $type\n";
    }
    # get or create the appropriate analysis ID
    # XXX restore when using writeable database
    my $analysis_id = $self->get_analysis_id($type);
    #    my $analysis_id = 999;

    open(PRIORITY_FILE,">>priority_xref.out") || die "Could not open priority_xref.out\n";
    while (<FILE>) {

      $total_lines++;
      chomp();
      my ($label, $query_id, $target_id, $identity, $query_length, $target_length, $query_start, $query_end, $target_start, $target_end, $cigar_line, $score) = split(/:/, $_);
      $cigar_line =~ s/ //g;
      $cigar_line =~ s/([MDI])(\d+)/$2$1/ig;


      # calculate percentage identities
      my $query_identity = int (100 * $identity / $query_length);
      my $target_identity = int (100 * $identity / $target_length);

      # only take mappings where there is a good match on one or both sequences
      if ($query_identity  < $method_query_threshold{$method} &&
	  $target_identity < $method_target_threshold{$method}){ 
	my $reason = $type."|".$target_id."|".$query_identity."|".$target_identity."|";
	$reason .= $method_query_threshold{$method}."|". $method_target_threshold{$method};
	#IANL
	if(!defined($priority_xref_source_id{$query_id})){
	  $failed_xref_mappings{$query_id} = $reason;
	}
	else{
	  $priority_failed{$priority_source_id_to_name{$priority_xref_source_id{$query_id}}
						       .":".$priority_xref_acc{$query_id}} = $reason;
	  print PRIORITY_FILE  $priority_xref_acc{$query_id}."\tFailed cutoff $reason\n";
	}
	next;
      }

      if(defined($priority_xref_source_id{$query_id})){
	my $source_id = $priority_xref_source_id{$query_id};
	if(!defined($priority_source_id_to_name{$source_id}) or length($priority_source_id_to_name{$source_id}) < 2){
	  print STDERR "priority_source_id_to_name has ".scalar(%priority_source_id_to_name)." keys for hash\n";
	  die "no source name for source id $source_id\n";
	}
	my $key = $priority_source_id_to_name{$source_id}.":".$priority_xref_acc{$query_id};
	if(!defined($priority_xref_priority{$key})){
	  print PRIORITY_FILE $priority_xref_acc{$query_id}."\t".$source_id.
	    " being set as undef from parsing mapped data.(PRIMARY) priority = ".$priority_source_id{$source_id}."\n";
	  
	  $priority_xref{$key} = $query_id;
	  $priority_xref_priority{$key} = $priority_source_id{$source_id};
	  $priority_object_xref{$key} = "$type:$target_id\n";
	  $priority_identity_xref{$key} = join("\t", ($query_identity, $target_identity, 
						      $query_start+1, $query_end, 
						      $target_start+1, $target_end, 
						      $cigar_line, $score, "\\N", $analysis_id)) . "\n";
	  $priority_xref_state{$key} = "primary";
	  $priority_xref_extra_bit{$query_id} =  "\tSEQUENCE_MATCH\t" . "Relationship generated from exonerate mapping" . "\n";
	  next;
	}
	if($priority_xref_priority{$key} 
	   > $priority_source_id{$source_id}){
	  print PRIORITY_FILE $priority_xref_acc{$query_id}."\t".$source_id.
	    " being set as better priority found from parsing mapped data.(PRIMARY) priority = ".$priority_source_id{$source_id}."\n";
	  
	  $priority_xref{$key} = $query_id;
	  $priority_xref_priority{$key} = $priority_source_id{$source_id};
	  $priority_object_xref{$key} = "$type:$target_id\n";
	  $priority_identity_xref{$key} = join("\t", ($query_identity, $target_identity, 
						      $query_start+1, $query_end, 
						      $target_start+1, $target_end, 
						      $cigar_line, $score, "\\N", $analysis_id)) . "\n";
	  $priority_xref_state{$key} = "primary";
	  $priority_xref_extra_bit{$query_id} =  "\tSEQUENCE_MATCH\t" . "Relationship generated from exonerate mapping" . "\n";
	}
	else{
	  print PRIORITY_FILE $priority_xref_acc{$query_id}."\t".$source_id." has less priority (PRIMARY) so left as is\n";
	}
	next; # do not store OBJECT, IDENTITY or set primary_xref. do much later
	  
      }
      else{
	$count_new++;
      }
      # note we add on $xref_id_offset to avoid clashes
      $object_succesfully_mapped{query_id} = 1;
      print OBJECT_XREF "$max_object_xref_id\t$target_id\t$type\t" . ($query_id+$xref_id_offset) . "\n";
      print IDENTITY_XREF join("\t", ($max_object_xref_id, $query_identity, $target_identity, $query_start+1, $query_end, $target_start+1, $target_end, $cigar_line, $score, "\\N", $analysis_id)) . "\n";
      $max_object_xref_id++;
      # TODO - evalue?

      # store mapping for later - note NON-OFFSET xref_id is used
      my $key = $type . "|" . $target_id;
      my $xref_id = $query_id;


      # note the NON-OFFSET xref_id is stored here as the values are used in
      # a query against the original xref database
      $primary_xref_ids{$query_id}{$target_id."|".$type} = $target_id."|".$type;

    }

    close(FILE);
    $last_lines = $total_lines;
  }

  close(IDENTITY_XREF);
  close(OBJECT_XREF);
  close(PRIORITY_FILE);

  print "Read $total_lines lines from $total_files exonerate output files\n";
  print "\n number of non priority dependent xrefs is $count_new\n";


  if($self->jobcount() != $total_files){
    print $dna_check[-1]." dna map files\n";
    print $pep_check[-1]." peptide map files\n";
    my $test_failed = 0;
    for(my $i=1; $i < $dna_check[-1]; $i++){
      if($dna_check[$i] != $i){
	print "DNA $i file not found\n"; 
	$test_failed = 1;
      }
    }
    for(my $i=1; $i < $pep_check[-1]; $i++){
      if($pep_check[$i] != $i){
	print "PEPTIDE $i file not found\n"; 
	$test_failed = 1;
      }
    }
    if($test_failed){
      die "Missing Files aborting run\n";
    }
    if(!defined($self->use_existing_mappings())){
      print  "There should be ".$self->jobcount()." files. Please check\n";
      print  "As this is the number of jobs submitted\n";
      die "There should be ".$self->jobcount()." files. Please check\n";
    }  
  }

  # write relevant xrefs to file
  $max_object_xref_id = $self->dump_core_xrefs(\%primary_xref_ids, $max_object_xref_id, $xref_id_offset);

  # dump interpro table as well
  $self->dump_interpro();

  # dump direct xrefs
  $self->dump_direct_xrefs($xref_id_offset, $max_object_xref_id);

  # dump xrefs that don't appear in either the primary_xref or dependent_xref tables
  $self->dump_orphan_xrefs($xref_id_offset);


  # dump triage type data
  if(!$notriage){
    $self->dump_triage_data($xref_id_offset);
  }  
  # if no triage then dump the xrefs at least
  else{
    $self->dump_xref_with_no_triage_data($xref_id_offset);
  }

}


sub process_priority_xrefs{
  my ($self) =@_;


  my $ensembl = $self->core;
  my $xref = $self->xref;
  my $dir = $ensembl->dir();

  my $primary_sql= (<<PSQL);
    SELECT DISTINCT(s.name), px.sequence_type
      FROM source s, primary_xref px, xref x 
	WHERE x.xref_id = px.xref_id
	  AND s.source_id = x.source_id
PSQL

  my $psth = $self->xref->dbc->prepare($primary_sql) || die "prepare failed";
  $psth->execute() || die "execute failed";

  my %source_2_seqtype=();

  my ($prim,$seq_type);
  $psth->bind_columns(\$prim,\$seq_type);
  while($psth->fetch()){
    $source_2_seqtype{$prim} = $seq_type;
  }  





  my $xref_id_offset = $self->xref_id_offset();
  # get current max object_xref_id
  my $row = @{$ensembl->dbc->db_handle->selectall_arrayref("SELECT MAX(object_xref_id) FROM object_xref")}[0];
  my $max_object_xref_id = @{$row}[0];
  if (!defined $max_object_xref_id) {
    print "No existing object_xref_ids, will start from 1\n";
    $max_object_xref_id = 0;
  } else {
    print "Maximum existing object_xref_id = $max_object_xref_id\n";
  }
  my $object_xref_id =  $max_object_xref_id + 1;

  open(XREF_P,">$dir/xref_priority.txt") || die "Could not open xref_priority.txt";
  open(OBJECT_XREF_P,">$dir/object_xref_priority.txt") || die "Could not open object_xref_priority.txt"; 
  open(IDENTITY_XREF_P,">$dir/identity_xref_priority.txt") || die "Could not open identity_xref_priority.txt";


  my @xref_list=();

  # first process the 'primary' ones. As these may generate new ones
  # and hence added to the list as we go along. These would be missed if 
  # all done at once.
  foreach my $key (keys %priority_xref){
    my($source_name,$acc) = split(/:/,$key);
    my $xref_id = $priority_xref{$key};
    my $dep_list;
    if($priority_xref_state{$key} ne  "primary"){
      if(($priority_xref_state{$key} eq "direct" and defined($source_2_seqtype{$source_name}))){
	$priority_xref_state{$key} = "primary";
      }
      else{
	next;
      }
    }
    my ($type,$id) = split(/:/,$priority_object_xref{$key});
    chomp $id;
    $dep_list = $self->dump_all_dependencies($xref_id, $xref_id_offset, $type, $id);
    push @xref_list, $xref_id;
    if(defined($priority_object_xref{$key})){
      $object_succesfully_mapped{$xref_id} = 1;
      print OBJECT_XREF_P $object_xref_id."\t".$id."\t".$type."\t".($xref_id+$xref_id_offset)."\n";
      if(defined($priority_identity_xref{$key})){
        print IDENTITY_XREF_P $object_xref_id."\t".$priority_identity_xref{$key};
      }
      $object_xref_id++;
      foreach my $dependent (@$dep_list){
	$object_succesfully_mapped{$xref_id} = 1;
	print OBJECT_XREF_P $object_xref_id."\t".$id."\t".$type."\t".$dependent."\n";	  
	$object_xref_id++;	  
      }
    } 
  }

  foreach my $key (keys %priority_xref){
    my($source_name,$acc) = split(/:/,$key);
    my $xref_id = $priority_xref{$key};
    my $dep_list;
    if($priority_xref_state{$key} eq "primary"){  #ignore as already done.
	next;
    }
    push @xref_list, $xref_id;
    if(defined($priority_object_xref{$key})){
      my ($type,$id) = split(/:/,$priority_object_xref{$key});
      $object_succesfully_mapped{$xref_id} = 1;
      print OBJECT_XREF_P $object_xref_id."\t".$id."\t".$type."\t".($xref_id+$xref_id_offset)."\n";
      if(defined($priority_identity_xref{$key})){
        print IDENTITY_XREF_P $object_xref_id."\t".$priority_identity_xref{$key};
      }
      $object_xref_id++;
    } 
  }

  if(scalar(@xref_list) < 1){
    print "At end of process prioritys  Maximum existing object_xref_id = $max_object_xref_id\n";
    return;
  }
  my $list = join(", ", @xref_list);
  my $sql = "SELECT xref_id, accession, version, label, description, source_id from xref where xref_id in ($list)";
  my $sth = $self->xref->dbc->prepare($sql);
  $sth->execute();
  my ($xref_id, $acc,$ver, $label, $desc, $source_id);
  $sth->bind_columns(\$xref_id, \$acc, \$ver, \$label, \$desc, \$source_id);
  while($sth->fetch()){
    my $key = $priority_source_id_to_name{$priority_xref_source_id{$xref_id}}.":".$acc;
    print XREF_P ($xref_id+$xref_id_offset)."\t". $source_to_external_db{$source_id}.
      "\t$acc\t$label\t$ver\t$desc";
    if(defined( $priority_xref_extra_bit{$xref_id})){
      print XREF_P $priority_xref_extra_bit{$xref_id}; # no need for "\n" already added;
    }
    else{
      print STDERR "no extra bit for $acc ($xref_id)\n";
      print XREF_P "\n";
    }
    $xrefs_written{$xref_id};
    $priority_seenit{$key} = "SEEN_IT";
  }
  $sth->finish;


  close OBJECT_XREF_P;
  close IDENTITY_XREF_P;

  # Do one big query to get a list of all the synonyms; note each xref may have
  # more than one synonym so they are stored in a hash of lists
  my $syn_count = 0;
  my %synonyms;
  my $syn_sth = $self->xref->dbc->prepare("SELECT xref_id, synonym FROM synonym where xref_id in ($list)");
  $syn_sth->execute();
  
  my ($sxref_id, $synonym);
  $syn_sth->bind_columns(\$sxref_id, \$synonym);
  while ($syn_sth->fetch()) {
    
    if(defined($priority_xref_source_id{$sxref_id})){
      push @{$synonyms{$sxref_id}}, $synonym;
    }
  }

  open (EXTERNAL_SYNONYM, ">$dir/external_synonym_priority.txt");
  # Dump any synonyms for xrefs we've written
  # Now write the synonyms we want to the file
  foreach my $xref_id (keys %synonyms) {
    foreach my $syn (@{$synonyms{$xref_id}}) {
      print EXTERNAL_SYNONYM ($xref_id+$xref_id_offset) . "\t" . $syn . "\n";
      $syn_count++;
    }
  }
  close EXTERNAL_SYNONYM;



  foreach my $table ("xref","object_xref","identity_xref","external_synonym"){
    my $file = $dir."/".$table."_priority.txt";
  
    if(-s $file){
      my $sth = $ensembl->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE $table");
      print "Uploading data in $file to $table\n";
      $sth->execute();
    }
    else{
      print "NO file or zero size file, so not able to load file $file to $table\n";
    }
  }


  print "At end of process prioritys  Maximum existing object_xref_id = $object_xref_id\n";

}


sub get_stable_ids(){
  my ($self, $type, $string, $hashref) = @_;

  my $sql = "SELECT ".$type."_id ,stable_id ";
  $sql .=      "FROM ".$type."_stable_id ";
  $sql .=          "WHERE ".$type."_id IN (".$string.")";

  my $sth = $self->core->dbc->prepare($sql);
  $sth->execute();
  my ($trans, $stable);
  $sth->bind_columns(\$trans,\$stable);
  while($sth->fetch()){
    $hashref->{$trans} = $stable;
  }
  $sth->finish;
}

sub get_failed_id{
  my ($self, $q_cut, $t_cut, $summary_failed)= @_;
  my $description_failed = "Unable to match at the thresholds of $q_cut\% for the query or $t_cut\% for the target";

  my $sth = $self->core->dbc->prepare("select unmapped_reason_id from unmapped_reason where full_description like '".$description_failed."'");
  $sth->execute();
  my $xref_failed_id=undef;
  $sth->bind_columns(\$xref_failed_id);
  $sth->fetch;
  if(!defined($xref_failed_id)){
    print STDERR "Could not find the description:\n";
    print STDERR $description_failed."\n";
    print STDERR "In the directory ensembl/misc-scripts/unmapped_reason you ";
    print STDERR "can add the new reason to the unmapped_reason.txt file ";
    print STDERR "and run the update_unmapped_reasons.pl script to update ";
    print STDERR "your core database\n";
    print STDERR "Alterntively do not add the triage data and add -notriage to the command line.\n";
    die();
  }
  return $xref_failed_id;
}

sub dump_triage_data() {
  my ($self, $xref_id_offset) = @_;

  print "Dumping triage data\n";
  my $translation="";
  my $translation_count=0;
  my $transcript="";
  my $transcript_count=0;
  my $batch_size=200;
  my %translation_2_stable=();
  my %transcript_2_stable=();
  foreach my $temp (values %failed_xref_mappings){
    my ($type,$id,@junk) = split(/\|/,$temp);
    if($type =~ /Translation/){
      $translation_count++;
      if($translation_count > $batch_size){
	my $ex = $self->get_stable_ids("translation",$translation.$id,\%translation_2_stable);
	$translation_count = 0;
	$translation = "";
      }
      else{
	$translation .= "$id,";
      }
    }
    elsif($type =~ /Transcript/){
      $transcript_count++;
      if($transcript_count > $batch_size){
	$self->get_stable_ids("transcript",$transcript.$id,\%transcript_2_stable);
	$transcript_count=0;
	$transcript="";
      }
      else{
	$transcript .= "$id,";
      }
    }
    else{
      die "Unknown type *".$type."*\n".$temp."\n";
    }
  }
  if($transcript_count){
    chop $transcript; # remove last , from list
    $self->get_stable_ids("transcript",$transcript,\%transcript_2_stable);
  }
  if($translation_count){
    chop $translation;
    $self->get_stable_ids("translation",$translation,\%translation_2_stable);
  }


  my $primary_sql= (<<PSQL);
    SELECT DISTINCT(s.source_id), px.sequence_type
      FROM source s, primary_xref px, xref x 
	WHERE x.xref_id = px.xref_id
	  AND s.source_id = x.source_id
PSQL

  my $psth = $self->xref->dbc->prepare($primary_sql) || die "prepare failed";
  $psth->execute() || die "execute failed";

  my @primary_sources =();
  my %source_2_seqtype=();

  my ($prim,$seq_type);
  $psth->bind_columns(\$prim,\$seq_type);
  while($psth->fetch()){
    push @primary_sources, $prim;
    $source_2_seqtype{$prim} = $seq_type;
  }

  open (XREF, ">>" . $self->core->dir() . "/xref.txt");

  open (UNMAPPED_OBJECT, ">" . $self->core->dir() . "/unmapped_object.txt");

  # get the Unmapped Object Reasons for the core database and 
  # add new ones if the standard xref descriptions are not there
  my %cutoff_2_failed_id=();

  my $summary_failed = "Failed to match at thresholds";
  my $summary_missed = "Failed to match";
  my $description_missed = "Unable to match to any ensembl entity at all";
  
  my $sth = $self->core->dbc->prepare("select MAX(unmapped_object_id) ".
				      "from unmapped_object");
  $sth->execute();
  my $max_unmapped_object_id;
  $sth->bind_columns(\$max_unmapped_object_id);
  $sth->fetch;
  if(!defined($max_unmapped_object_id)){
    $max_unmapped_object_id = 1;
  }
  $sth->finish;

  my ($xref_DNA_analysis, $xref_PROT_analysis);

  $sth = $self->core->dbc->prepare("select unmapped_reason_id from unmapped_reason where full_description like '".$description_missed."'");  
  $sth->execute();
  my $xref_missed_id;
  $sth->bind_columns(\$xref_missed_id);
  $sth->fetch;
  if(!defined($xref_missed_id)){
    print STDERR "Could not find the description:\n";
    print STDERR $description_missed,"\n";
    print STDERR "In the directory ensembl/misc-scripts/unmapped_reason you ";
    print STDERR "can add the new reason to the unmapped_reason.txt file ";
    print STDERR "and run the update_unmapped_reasons.pl script to update ";
    print STDERR "your core database\n";
    print STDERR "Alterntively do not add the triage data and add -notriage to the command line.\n";
    die();
  }
  $sth->finish;
 

  foreach my $source (@primary_sources){

    my %triage_dumped=(); # dump only once for each accession

    if(defined($priority_source_id{$source})){ # These are done seperately at the end.
      next;
    }

    my $sql = "select x.xref_id, x.accession, x.version, x.label, x.description, x.source_id, ".
              "x.species_id from xref x where x.source_id = $source";
    my $sth = $self->xref->dbc->prepare($sql);
    $sth->execute();
    
    my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id);
    $sth->bind_columns(\$xref_id, \$accession, \$version, \$label, 
		       \$description, \$source_id, \$species_id);
    while($sth->fetch()){
      if (!$xrefs_written{$xref_id}) {
	my $external_db_id = $source_to_external_db{$source_id};
	if(!defined($updated_source{$external_db_id})){
	  $self->cleanup_sources_file($external_db_id);
	}
	print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . 
	  "\t" . $label . "\t" . $version . "\t" . $description . "\tMISC\tNo match\n";
	
	#dump out dependencies aswell
	
        $self->dump_all_dependencies($xref_id, $xref_id_offset);

	if(defined($failed_xref_mappings{$xref_id})){

	  my ($ensembl_type,$ensembl_id,$q_perc,$t_perc,$q_cut,$t_cut) =  
	    split(/\|/,$failed_xref_mappings{$xref_id});

	  if(!defined($cutoff_2_failed_id{$q_cut."_".$t_cut})){
	    $cutoff_2_failed_id{$q_cut."_".$t_cut} = $self->get_failed_id($q_cut, $t_cut, $summary_failed);
	  }
	  $max_unmapped_object_id++;
	  
	  print  UNMAPPED_OBJECT $max_unmapped_object_id."\txref\t";

	  if($ensembl_type  =~ /Translation/){
            if (not defined $xref_PROT_analysis) {
              $xref_PROT_analysis = $self->get_analysis_id($ensembl_type);
            }
	    print UNMAPPED_OBJECT $xref_PROT_analysis."\t";
	  }
	  elsif($ensembl_type  =~ /Transcript/){
            if (not defined $xref_DNA_analysis) {
              $xref_DNA_analysis = $self->get_analysis_id($ensembl_type);
            }
	    print UNMAPPED_OBJECT $xref_DNA_analysis."\t";
	  }
	  else{
	    die "type=*".$ensembl_type."*\n".$failed_xref_mappings{$xref_id}."\n";
	  }
	  print UNMAPPED_OBJECT $external_db_id."\t".$accession."\t".$cutoff_2_failed_id{$q_cut."_".$t_cut}."\t";
	  print UNMAPPED_OBJECT $q_perc."\t".$t_perc."\t";
	  print UNMAPPED_OBJECT $ensembl_id."\t".$ensembl_type."\n";

	}
	else{
	  $max_unmapped_object_id++;
	  print  UNMAPPED_OBJECT $max_unmapped_object_id."\txref\t";
	  if($source_2_seqtype{$source} =~ /peptide/){
            if (not defined $xref_PROT_analysis) {
              $xref_PROT_analysis = $self->get_analysis_id("translation");
            }
	    print UNMAPPED_OBJECT $xref_PROT_analysis."\t";
	  }
	  elsif($source_2_seqtype{$source} =~ /dna/){
            if (not defined $xref_DNA_analysis) {
              $xref_DNA_analysis = $self->get_analysis_id("transcript");
            }
	    print UNMAPPED_OBJECT $xref_DNA_analysis."\t";
	  }
	  print UNMAPPED_OBJECT $external_db_id."\t".$accession."\t";
	  print UNMAPPED_OBJECT $xref_missed_id."\t0\t0\t0\tNULL\n";
	}
      }
    }
    $sth->finish;
  }
  close(XREF);
  close(UNMAPPED_OBJECT);
#  close(UNMAPPED_REASON);
}

# dump xrefs that don't appear in either the primary_xref or dependent_xref tables
# also ignore direct_xref
# e.g. Interpro xrefs

sub dump_orphan_xrefs() {

  my ($self, $xref_id_offset) = @_;

  my $count = 0;

  open (XREF, ">>" . $self->core->dir() . "/xref.txt");

  # need a triple left-join

  my $sql = q[
    SELECT x.xref_id, x.accession, x.version, x.label, x.description, 
           x.source_id, x.species_id 
      FROM xref x 
      LEFT JOIN primary_xref px   ON px.xref_id=x.xref_id 
      LEFT JOIN dependent_xref dx ON dx.dependent_xref_id=x.xref_id 
      LEFT JOIN direct_xref dirx  ON dirx.general_xref_id=x.xref_id 
     WHERE px.xref_id           IS NULL 
       AND dx.dependent_xref_id IS NULL 
       AND dirx.general_xref_id is NULL ];

  my $sth = $self->xref->dbc->prepare($sql);
  $sth->execute();

  my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id);
  $sth->bind_columns(\$xref_id, \$accession, \$version, \$label, \$description, \$source_id, \$species_id);

  while ($sth->fetch()) {

    if(defined($priority_source_id{$source_id})){
      next;
    }

    my $external_db_id = $source_to_external_db{$source_id};
    if ($external_db_id) { # skip "unknown" sources
      if (!$xrefs_written{$xref_id}) {
	if(!defined($updated_source{$external_db_id})){
	  $self->cleanup_sources_file($external_db_id);
	}
	if(!defined($priority_xref_source_id{$xref_id})){
	  print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\tMISC\tNo match\n";
	  $xrefs_written{$xref_id} = 1;
	  $count++;
	}
      }
    }

  }
  $sth->finish();

  close(XREF);

  print "Wrote $count xrefs that are neither primary nor dependent\n";

}


# Dump direct xrefs. Need to do stable ID -> internal ID mapping.

sub dump_direct_xrefs {

  my ($self, $xref_id_offset, $max_object_xref_id) = @_;
  my $object_xref_id = $max_object_xref_id + 1;

  print "Writing direct xrefs\n";

  my $count = 0;

  open (XREF, ">>" . $self->core->dir() . "/xref.txt");
  open (OBJECT_XREF, ">>" . $self->core->dir() . "/object_xref.txt");
  open (GO_XREF, ">>" .$self->core->dir(). "/go_xref.txt");


  my $go_source_id;
  my $worm_pep_source_id = undef;
  my $worm_locus_source_id = undef;
  my $worm_gene_source_id = undef;
  my $worm_transcript_source_id = undef;
  
  # Will need to look up translation stable ID from transcript stable ID, build hash table
  print "  Building transcript stable ID -> translation stable ID lookup table\n";
  my %transcript_stable_id_to_translation_stable_id;
  my $trans_sth = $self->core->dbc->prepare("SELECT tss.stable_id as transcript, tls.stable_id AS translation FROM translation tl, translation_stable_id tls, transcript_stable_id tss WHERE tss.transcript_id=tl.transcript_id AND tl.translation_id=tls.translation_id");
  $trans_sth->execute();
  my ($transcript_stable_id, $translation_stable_id);
  $trans_sth->bind_columns(\$transcript_stable_id, \$translation_stable_id);
  while ($trans_sth->fetch()) {
    $transcript_stable_id_to_translation_stable_id{$transcript_stable_id} = $translation_stable_id;
  }
  $trans_sth->finish();

#  # Will need lookup tables for gene/transcript/translation stable ID to internal ID
#  $self->build_stable_id_to_internal_id_hash();


  # SQL / statement handle for getting all direct xrefs
  my $xref_sql = "SELECT dx.general_xref_id, dx.ensembl_stable_id, dx.type, dx.linkage_xref, x.accession, x.version, x.label, x.description, x.source_id, x.species_id FROM direct_xref dx, xref x WHERE dx.general_xref_id=x.xref_id";
  my $xref_sth = $self->xref->dbc->prepare($xref_sql);

  my $rv = $xref_sth->execute();
  print "  Found $rv direct xrefs in xref DB\n";

  my ($xref_id, $ensembl_stable_id, $type, $linkage_xref, $accession, $version, $label, $description, $source_id, $species_id);
  $xref_sth->bind_columns(\$xref_id, \$ensembl_stable_id, \$type, \$linkage_xref,\ $accession, \$version, \$label, \$description, \$source_id, \$species_id);


  my %error_count;
  my %error_example;

  open(PRIORITY_FILE,">>priority_xref.out") || die "Could not open priority_xref.out\n";
  my $ccds_source = get_source_id_from_source_name($self->xref(), "CCDS");
  while ($xref_sth->fetch()) {
    my $external_db_id = $source_to_external_db{$source_id};

    unless( $external_db_id ){
      if( ! defined( $external_db_id ) ){
        warn("  No external_db_id for source $source_id. Skip source!\n" );  
        $source_to_external_db{$source_id} = 0;
      }
      next;
    }

    # In the case of CCDS xrefs, direct_xref is to transcript but we want
    # the mapping in the core db to be to the *translation*
    if ($source_id == $ccds_source) {
      $type = 'translation';
      my $tmp_esid = $ensembl_stable_id;
      $ensembl_stable_id = $transcript_stable_id_to_translation_stable_id{$tmp_esid};
      if(defined($error_count{$source_id}) and !$ensembl_stable_id){
	$error_count{$source_id}++;
	if($error_count{$source_id} < 6){
	  $error_example{$source_id} .= ", $tmp_esid - $accession";
	}
      }
      elsif(!$ensembl_stable_id){
	$error_count{$source_id} = 1;
	$error_example{$source_id} = "$tmp_esid - $accession";
      }
#      warn "Can't find translation for transcript $tmp_esid" if (!$ensembl_stable_id);
      #print "CCDS: transcript $tmp_esid -> translation $ensembl_stable_id\n";
    }
    
    my $ensembl_internal_id;
    if(defined($stable_id_to_internal_id{$type}->{$ensembl_stable_id})){
      $ensembl_internal_id = $stable_id_to_internal_id{$type}->{$ensembl_stable_id};
    }
    else{ # ncRNA store internal id not stable check and switch if needed
      if(defined($internal_id_to_stable_id{$type}{$ensembl_stable_id})){
        my $tmp = $internal_id_to_stable_id{$type}{$ensembl_stable_id};
        $ensembl_internal_id = $ensembl_stable_id;
        $ensembl_stable_id = $tmp;
      }
    }
    if ($ensembl_internal_id) {
      
      if (!$xrefs_written{$xref_id}) {
        if(!defined($updated_source{$external_db_id})){
          $self->cleanup_sources_file($external_db_id);
        }

	if(defined($priority_xref_source_id{$xref_id})){
	  if(!defined($priority_source_id_to_name{$source_id}) or length($priority_source_id_to_name{$source_id}) < 2){
	    print STDERR "priority_source_id_to_name has ".scalar(%priority_source_id_to_name)." keys for has\n";
	    die "no source name for source id $source_id\n";
	  }
	  my $key = $priority_source_id_to_name{$source_id}.":".$priority_xref_acc{$xref_id};
	  if(!defined($priority_xref_priority{$key})){
	    print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id.
	      " being set as undef (DIRECT) xref= $xref_id key = $key  priority = ".$priority_source_id{$source_id}."\n";
	    $priority_xref_extra_bit{$xref_id} = "\tDIRECT" . "\t" . 
                              "Externally assigned relationship between $ensembl_stable_id and $accession" . "\n";
	    $priority_xref{$key} = $xref_id;
	    $priority_xref_priority{$key} = $priority_source_id{$source_id};
	    $priority_object_xref{$key} = ucfirst($type).":".$ensembl_internal_id;
	    $priority_identity_xref{$key} = undef;

	    $priority_xref_state{$key} = "direct";
	    next; # do not store XREF or OBJECT. do much later
	  }
	  if($priority_xref_priority{$key}        # old one
	     > $priority_source_id{$source_id}){  # new one

	    print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id.
	      " being set as better priority found (DIRECT) priority = ".$priority_source_id{$source_id}."\n";

	    $priority_xref_extra_bit{$xref_id} = "\tDIRECT" . "\t" . 
                              "Externally assigned relationship between $ensembl_stable_id and $accession" . "\n";
	    $priority_xref{$key} = $xref_id;
	    $priority_xref_priority{$key} = $priority_source_id{$source_id};
	    $priority_object_xref{$key} = ucfirst($type).":".$ensembl_internal_id;
	    $priority_identity_xref{$key} = undef;

	    $priority_xref_state{$key} = "direct";
          }
	  else{
	    print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id." has less (DIRECT) priority so left as is. \n";
	  }
          next; # do not store XREF or OBJECT. do much later
	}
        print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description ."\t". "DIRECT" . "\t" . "Externally assigned relationship between $ensembl_stable_id and $accession" . "\n";

        $xrefs_written{$xref_id} = 1;
      }
      $object_succesfully_mapped{$xref_id} = 1;
      print OBJECT_XREF "$object_xref_id\t$ensembl_internal_id\t" . ucfirst($type) . "\t" . ($xref_id+$xref_id_offset) . "\n";
      $object_xref_id++;
      $count++;
      
    } else { ##ahh
      if(!defined($worm_pep_source_id)){
        $worm_pep_source_id = get_source_id_from_source_name($self->xref(), "wormpep_id");
        $worm_locus_source_id = get_source_id_from_source_name($self->xref(), "wormbase_locus");
        $worm_gene_source_id = get_source_id_from_source_name($self->xref(), "wormbase_gene");
        $worm_transcript_source_id = get_source_id_from_source_name($self->xref(), "wormbase_transcript");
        $go_source_id = get_source_id_from_source_name($self->xref(), "GO" );
      }
      # deal with UTR transcripts in Elegans and potentially others
      # Need to link xrefs that are listed as linking to e.g. ZK829.4
      # to each of ZK829.4.1, ZK829.4.2, ZK829.4.3
      my $old_object_xref_id = $object_xref_id;
      if ($source_id == $worm_pep_source_id || $source_id == $go_source_id 
          || $source_id == $worm_locus_source_id || $source_id == $worm_gene_source_id
          || $source_id == $worm_transcript_source_id) {
        
        # search for matching stable IDs
        my $pat = $ensembl_stable_id .  '\..+';
        foreach my $stable_id (keys %{$stable_id_to_internal_id{$type}}) {
          
          if ($stable_id =~ /$pat/) {
            
            if (!$xrefs_written{$xref_id}) {
              if(!defined($updated_source{$external_db_id})){
                $self->cleanup_sources_file($external_db_id);
              }
              print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description ."\t". "DIRECT" . "\t" . "Externally assigned relationship between $ensembl_stable_id and $accession" ."\n";
              $xrefs_written{$xref_id} = 1;
            }
            $ensembl_internal_id = $stable_id_to_internal_id{$type}->{$stable_id};
	    $object_succesfully_mapped{$xref_id} = 1;
            print OBJECT_XREF "$object_xref_id\t$ensembl_internal_id\t" . ucfirst($type) . "\t" . ($xref_id+$xref_id_offset) . "\n";
            if( $source_id == $go_source_id){
              print GO_XREF $object_xref_id . "\t" . $linkage_xref . "\n";
            }
            $object_xref_id++;
            
          }
          
        } # foreach stable_id
        
      } # if source_id
      # if we haven't changed $object_xref_id, nothing was written
 #     print STDERR "Can't find $type corresponding to stable ID $ensembl_stable_id in ${type}_stable_id, not writing record for xref $accession\n" if ($object_xref_id == $old_object_xref_id);
      if(defined($error_count{$source_id})){
    #IANL add priority_failed HERE.
	$error_count{$source_id}++;
	if($error_count{$source_id} < 6){
	  $error_example{$source_id} .= ", $ensembl_stable_id - $accession";
	}
      }
      else{
	$error_count{$source_id} = 1;
    #IANL add priority_failed HERE.
	$error_example{$source_id} = "$ensembl_stable_id - $accession";
      }
      
            
    }
  }

  foreach my $key (keys %error_count){
    print STDERR "Problems with ".$error_count{$key}." Direct Xrefs for source $key\n";
    print STDERR "\te.g.   ".$error_example{$key}."\n";
  }

  close(OBJECT_XREF);
  close(XREF);
  close(GO_XREF);
  close(PRIORITY_FILE);
  $xref_sth->finish();

  print "  Wrote $count direct xrefs\n";

}


# Dump the interpro table from the xref database
sub dump_interpro {

  my $self = shift;

  open (INTERPRO, ">" .  $self->core->dir() . "/interpro.txt");

  my $sth = $self->xref->dbc->prepare("SELECT * FROM interpro");
  $sth->execute();

  my ($interpro, $pfam);
  $sth->bind_columns(\$interpro, \$pfam);
  while ($sth->fetch()) {
    print INTERPRO $interpro . "\t" . $pfam . "\n";
  }
  $sth->finish();

  close (INTERPRO);

}

sub build_stable_id_to_internal_id_hash {

  my ($self) = @_;

#  my %stable_id_to_internal_id;
#  my %internal_id_to_stable_id;
  foreach my $type ('gene', 'transcript', 'translation') { # Add exon here if required

    print "Caching stable ID -> internal ID links for ${type}s\n";

    my $core_sql = "SELECT ${type}_id, stable_id FROM ${type}_stable_id" ;
    my $sth = $self->core->dbc->prepare($core_sql);
    $sth->execute();
    my ($internal_id, $stable_id);
    $sth->bind_columns(\$internal_id, \$stable_id);

    while ($sth->fetch) {

      $stable_id_to_internal_id{$type}{$stable_id} = $internal_id;
      $internal_id_to_stable_id{$type}{$internal_id} = $stable_id;
    }

  }

  return 1;

}

sub get_ensembl_object_type {

  my $filename = shift;
  my $type;

  $filename = basename($filename);

  if ($filename =~ /_dna_/i) {

    $type = "Transcript";

  } elsif ($filename =~ /_peptide_/i) {

    $type = "Translation";

  } else {

    print STDERR "Cannot deduce Ensembl object type from filename $filename\n";
  }

  return $type;

}

sub get_parts {

  my $filename = shift;

  $filename = basename($filename);

  my ($method,$type,$part) = $filename =~ /^(.*)_(dna|peptide)_(\d+)\.map/;
  if ($type eq "dna" ) {

    $type = "Transcript";

  } elsif ($type eq "peptide") {

    $type = "Translation";

  } else {

    print STDERR "Cannot deduce Ensembl object type from filename $filename\n";
  }

  return ($method, $type, $part);

}

sub get_method {

  my $filename = shift;

  $filename = basename($filename);

  my ($method) = $filename =~ /^(.*)_(dna|peptide)_\d+\.map/;

  return $method;

}

sub get_analysis_id {

  my ($self, $ensembl_type) = @_;

  my %typeToLogicName = ( 'transcript' => 'XrefExonerateDNA',
			  'translation' => 'XrefExonerateProtein' );

  my $logic_name = $typeToLogicName{lc($ensembl_type)};

  my $sth = $self->core->dbc->prepare("SELECT analysis_id FROM analysis WHERE logic_name='" . $logic_name ."'");
  $sth->execute();

  my $analysis_id;

  if (my @row = $sth->fetchrow_array()) {

    $analysis_id = $row[0];
#    print "Found exising analysis ID ($analysis_id) for $logic_name\n";

  } else {

    print "No analysis with logic_name $logic_name found, creating ...\n";
    $sth = $self->core->dbc->prepare("INSERT INTO analysis (logic_name, created) VALUES ('" . $logic_name. "', NOW())");
    # TODO - other fields in analysis table
    $sth->execute();
    $analysis_id = $sth->{'mysql_insertid'};
    print "Done (analysis ID=" . $analysis_id. ")\n";

  }
  $sth->finish();

  return $analysis_id;

}

sub remove_all_old_output_files{
  my ($self) =@_;

  my $dir = $self->core->dir();

  unlink(<$dir/*.txt $dir/*.sql>);

}

sub dump_core_xrefs {

  my ($self, $xref_ids_hashref, $start_object_xref_id, $xref_id_offset, $object_xref_id_offset) = @_;

  my @xref_ids = keys %$xref_ids_hashref;
  my %xref_to_objects = %$xref_ids_hashref;


  my $dir = $self->core->dir();

  open (XREF, ">$dir/xref.txt");
  open (OBJECT_XREF, ">>$dir/object_xref.txt");
  open (EXTERNAL_SYNONYM, ">$dir/external_synonym.txt");
  open (GO_XREF, ">>$dir/go_xref.txt");

  # Cache synonyms for later use
  # Do one big query to get a list of all the synonyms; note each xref may have
  # more than one synonym so they are stored in a hash of lists
  my $syn_count = 0;
  my %synonyms;
  my $syn_sth = $self->xref->dbc->prepare("SELECT xref_id, synonym FROM synonym");
  $syn_sth->execute();

  my ($sxref_id, $synonym);
  $syn_sth->bind_columns(\$sxref_id, \$synonym);
  while ($syn_sth->fetch()) {

    if(!defined($priority_xref_source_id{$sxref_id})){
      push @{$synonyms{$sxref_id}}, $synonym;
    }
  }

  # keep a unique list of source IDs to build the external_db table later
  my %source_ids;

  my $object_xref_id = $start_object_xref_id;

  # build cache of source id -> external_db id; note %source_to_external_db is global
  %source_to_external_db = $self->map_source_to_external_db();

  # execute several queries with a max of 200 entries in each IN clause - more efficient
  my $batch_size = 200;

  # keep track of what xref_id & object_xref_ids have been written to prevent
  # duplicates; e.g. several dependent xrefs may be dependent on the same master xref.
  # Note %xrefs_written and %object_xrefs_written are global

  while(@xref_ids) {

    my @ids;
    if($#xref_ids > $batch_size) {
      @ids = splice(@xref_ids, 0, $batch_size);
    } else {
      @ids = splice(@xref_ids, 0);
    }

    my $id_str;
    if(@ids > 1)  {
      $id_str = "IN (" . join(',', @ids). ")";
    } else {
      $id_str = "= " . $ids[0];
    }


    my $sql = "SELECT * FROM xref WHERE xref_id $id_str";
    my $xref_sth = $self->xref->dbc->prepare($sql);
    $xref_sth->execute();

    my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id, $master_xref_id, $linkage_annotation);
    $xref_sth->bind_columns(\$xref_id, \$accession, \$version, \$label, \$description, \$source_id, \$species_id);

    # note the xref_id we write to the file is NOT the one we've just read
    # from the internal xref database as the ID may already exist in the
    # core database so we add on $xref_id_offset
    while ($xref_sth->fetch()) {

      $XXXxref_id_to_accession{$xref_id} = $accession;

      # make sure label is set to /something/ so that the website displays something
      $label = $accession if (!$label);

      if (!$xrefs_written{$xref_id}) {
	my $external_db_id = $source_to_external_db{$source_id};
	if ($external_db_id) { # skip "unknown" sources
	  if(!defined($updated_source{$external_db_id})){
	    $self->cleanup_sources_file($external_db_id);
	  }
	  print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\t" . "SEQUENCE_MATCH\t" . "Relationship generated from exonerate mapping" . "\n";
	  $xrefs_written{$xref_id} = 1;
	  $source_ids{$source_id} = $source_id;
	}
      }
    }

    # Now get the dependent xrefs for each of these xrefs and write them as well
    # Store the go_linkage_annotations as we go along (need for dumping go_xref)
    my $go_source_id = get_source_id_from_source_name($self->xref, "GO");

    $sql = "SELECT DISTINCT(x.xref_id), dx.master_xref_id, x.accession, x.label, x.description, x.source_id, x.version, dx.linkage_annotation FROM dependent_xref dx, xref x WHERE x.xref_id=dx.dependent_xref_id AND master_xref_id $id_str";

    my $dep_sth = $self->xref->dbc->prepare($sql);
    $dep_sth->execute();

    $dep_sth->bind_columns(\$xref_id, \$master_xref_id, \$accession, \$label, \$description, \$source_id, \$version, \$linkage_annotation);

    open(PRIORITY_FILE,">>priority_xref.out") || die "Could not open priority_xref.out\n";


    while ($dep_sth->fetch()) {  # dependent xrefs

      my $external_db_id = $source_to_external_db{$source_id};
      next if (!$external_db_id);


      $label = $accession if (!$label);

      my $master_accession = $XXXxref_id_to_accession{$master_xref_id};

      if (!$xrefs_written{$xref_id}) {
	if(!defined($updated_source{$external_db_id})){
	  $self->cleanup_sources_file($external_db_id);
	}
	
	if(!defined($priority_xref_source_id{$xref_id})){
	  print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\t" . "DEPENDENT" . "\t" . "Generated via $master_accession" . "\n";
	}
	$xrefs_written{$xref_id} = 1;
	$source_ids{$source_id} = $source_id;
      }

      # create an object_xref linking this (dependent) xref with any objects it maps to
      # write to file and add to object_xref_mappings
      if (defined $xref_to_objects{$master_xref_id}) {
	my @ensembl_object_ids = keys( %{$xref_to_objects{$master_xref_id}} );
	foreach my $object_id_key (@ensembl_object_ids) {
	  my ($object_id, $type) = split /\|/, $object_id_key;
	  my $full_key = $type."|".$object_id."|".$xref_id;
	  if(defined($priority_xref_source_id{$xref_id})){
	    my $key = $priority_source_id_to_name{$source_id}.":".$priority_xref_acc{$xref_id};	  
	    if(!defined($priority_xref_priority{$key})){
	      print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id.
		" being set as undef  (DEPENDENT) priority = ".$priority_source_id{$source_id}."\n";
	      
	      $priority_xref_extra_bit{$xref_id} = "\t" . "DEPENDENT" . "\t" . "Generated via $master_accession" . "\n";
	      $priority_xref{$key} = $xref_id;
	      $priority_xref_priority{$key} = $priority_source_id{$source_id};
	      $priority_object_xref{$key} = "$type:$object_id";
	      $priority_identity_xref{$key} = undef;
	      $priority_xref_state{$key} = "dependent";
	      next;
	    }
	    if($priority_xref_priority{$key} 
	       > $priority_source_id{$source_id}){
	      
	      print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id.
		" being set as better priority found  (DEPENDENT) priority = ".$priority_source_id{$source_id}."\n";

	      $priority_xref_extra_bit{$xref_id} = "\t" . "DEPENDENT" . "\t" . "Generated via $master_accession" . "\n";
	      $priority_xref{$key} = $xref_id;
	      $priority_xref_priority{$key} = $priority_source_id{$source_id};
	      $priority_object_xref{$key} = "$type:$object_id";
	      $priority_identity_xref{$key} = undef;
	      $priority_xref_state{$key} = "dependent";
	      next;
	    }
	    else{
	      print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id." has less priority (DEPENDENT) so left as is\n";
	    }
	    next;
	  }
	  if (!$object_xrefs_written{$full_key}) {
	       	    
	    $object_succesfully_mapped{$xref_id} = 1;
	    print OBJECT_XREF "$object_xref_id\t$object_id\t$type\t" . ($xref_id+$xref_id_offset) . "\n";
	    # Add this mapping to the list - note NON-OFFSET xref_id is used
	    my $key = $type . "|" . $object_id;
	    $object_xrefs_written{$full_key} = 1;

	    # write a go_xref with the appropriate linkage type
	    print GO_XREF $object_xref_id . "\t" . $linkage_annotation . "\n"  if ($source_id == $go_source_id);
	    my $master_accession = $XXXxref_id_to_accession{$master_xref_id};
#	    print "Wrote object ID $object_xref_id linkage $linkage_annotation for accession $accession master xref id $master_xref_id master accession $master_accession\n" if ($source_id == $go_source_id);
	
	    # Also store *parent's* query/target identity for dependent xrefs
	    print GO_XREF $object_xref_id . "\t" . $linkage_annotation . "\n"  if ($source_id == $go_source_id);

	    $object_xref_id++;

	  }
	}
      }
    }# end of dependents

    #print "source_ids: " . join(" ", keys(%source_ids)) . "\n";

  } # while @xref_ids

  # Dump any synonyms for xrefs we've written
  # Now write the synonyms we want to the file
  foreach my $xref_id (keys %synonyms) {
    foreach my $syn (@{$synonyms{$xref_id}}) {
      print EXTERNAL_SYNONYM ($xref_id+$xref_id_offset) . "\t" . $syn . "\n";
      $syn_count++;
    }
  }

  print "Wrote $syn_count synonyms\n";

  close(XREF);
  close(OBJECT_XREF);
  close(EXTERNAL_SYNONYM);
  close(GO_XREF);
  close (PRIORITY_FILE);

  return $object_xref_id;

}


sub build_transcript_and_gene_display_xrefs {
  my ($self) = @_;
  my $dir = $self->core->dir();

  # only load the xrefs which are used in the setting of descriptions
  # see transcript_display_xref_sources;

  # get the priority for the xrefs  (this is the display xref priority)
  # for each transcript {
  #    get the objects_xref for this
  #    get the object_xref for its translation
  #    get the one with the best priority
  #    set the transcript or set to null if none found (maybe report if changed)
  #    set hash of transcript_to_xref{gene} = xref_id sort of thing
  #    set hash object_to_gene{transcript|translation:id} = gene
  #    set hash for score and priority aswell/
  # }

  # for each gene{
  #   for each transcript{
  #     get the highest presedence then score if equal
  #   }
  #   set gene display_xref_id

  if(!scalar(keys %translation_to_transcript)){
    print "Building translation to transcript mappings\n";
    my $sth = $self->core->dbc->prepare("SELECT translation_id, transcript_id FROM translation");
    $sth->execute();
    
    my ($translation_id, $transcript_id);
    $sth->bind_columns(\$translation_id, \$transcript_id);
    
    while ($sth->fetch()) {
      $translation_to_transcript{$translation_id} = $transcript_id;
      $transcript_to_translation{$transcript_id} = $translation_id if ($translation_id);
    }
  }

  my %external_name_to_id;  
  my %ex_db_id_to_status;
  my $sql1 = "SELECT external_db_id, db_name, status from external_db";
  
  my $sth1 = $self->core->dbc->prepare($sql1) || die "prepare failed for $sql1\n";
  $sth1->execute() || die "execute failed";
  my ($db_id, $name, $status);
  $sth1->bind_columns(\$db_id, \$name, \$status);
  while($sth1->fetch()){
    $external_name_to_id{$name}  = $db_id;
    $ex_db_id_to_status{$db_id} = $status;
  }
  $sth1->finish;

  my @presedence = $self->transcript_display_xref_sources();

  my $sql = (<<ESQL);
  SELECT ox.ensembl_id, ox.ensembl_object_type, ox.xref_id, ix.query_identity, ix.target_identity
    FROM (object_xref ox, xref x) 
      LEFT JOIN identity_xref ix ON (ox.object_xref_id = ix.object_xref_id) 
	WHERE x.xref_id = ox.xref_id and x.external_db_id =?
ESQL

  my $psth = $self->core->dbc->prepare($sql) || die "prepare failed for $sql\n";
 
  my $level = 0;
  my ($ensembl_id, $ens_type, $xref_id, $qid, $tid);
  my %gene_best_hit;
  my %gene_level;
  my %trans_best_hit;
  my %trans_level;

  my $format_problem=0;
  foreach my $ord (reverse(@presedence)){ # if we do this in reverse then it is okay to overwrite values

    #reset each loop so can be used to see if it has been set for this loop
    # know when to test the ids
    my %gene_score;
    my %trans_score;
    $level++;

    if(defined($external_name_to_id{$ord})){
      $psth->execute($external_name_to_id{$ord}) || die "execute failed";
      $psth->bind_columns(\$ensembl_id, \$ens_type, \$xref_id, \$qid, \$tid);
      while($psth->fetch()){
	if($ens_type eq "Gene"){
	  # gene cannot have identitys, so just take the first one.
	  if(!defined($gene_score{$ensembl_id})){
	    $gene_best_hit{$ensembl_id} = $xref_id;
	    $gene_score{$ensembl_id} = 1;
	    $gene_level{$ensembl_id} = $level; 
	  }
	}
	elsif($ens_type eq "Transcript" || $ens_type eq "Translation"){
	  if($ens_type eq "Translation"){
	    $ensembl_id = $translation_to_transcript{$ensembl_id};
	    # so everything is stored on the transcript. 
	  }
	  if(!defined($trans_score{$ensembl_id})){
	    $trans_best_hit{$ensembl_id} = $xref_id;
	    $trans_level{$ensembl_id} = $level; 
	    if(defined($qid)){
	      $trans_score{$ensembl_id}  = $tid."\t".$qid;
	    }
	    else{
	      $trans_score{$ensembl_id}  = "100\t100";
	    }
	  }
	  else{
	    if(defined($trans_score{$ensembl_id} and defined($qid))){
	      my ($old_t, $old_q) = split (/\s+/,$trans_score{$ensembl_id});
	      if(($qid > $old_q) || ($qid == $old_q and $tid > $old_t)){
		$trans_best_hit{$ensembl_id} = $xref_id;
		$trans_level{$ensembl_id} = $level; 
		$trans_score{$ensembl_id}  = $tid."\t".$qid;		
	      }
	    }
	  }
	}
	else{
	  $format_problem++;
	}
      }

    }
    else{
      print $ord." Could not find external db id for this\n";
    }
	 
  }
  open (TRANSCRIPT_DX, ">$dir/transcript_display_xref.sql");
  open (TRANSCRIPT_DX_TXT, ">$dir/transcript_display_xref.txt");

  foreach my $transcript (keys %trans_best_hit){
    # print the display_xref_id for these
    print TRANSCRIPT_DX "UPDATE transcript SET display_xref_id=" .$trans_best_hit{$transcript}. 
      " WHERE transcript_id=" . $transcript . ";\n";
    print TRANSCRIPT_DX_TXT  $trans_best_hit{$transcript}. "\t" . $transcript . "\n";
    
  }
  
  close TRANSCRIPT_DX;
  close TRANSCRIPT_DX_TXT;

  #now do the gene display xrefs;
  open (GENE_DX, ">$dir/gene_display_xref.sql");
  open (GENE_DX_TXT, ">$dir/gene_display_xref.txt");

  if(!scalar(keys %genes_to_transcripts)){
    $self->build_genes_to_transcripts();
  }

  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(-dbconn => $self->core->dbc);

  my $ta = $db->get_TranscriptAdaptor();

  foreach my $gene_id (keys %genes_to_transcripts) {

    my @transcripts = @{$genes_to_transcripts{$gene_id}};

    my $best_xref = undef;
    my $best_level = 0;
    my $best_object = undef;
    my $best_length =0;
    if(defined($gene_best_hit{$gene_id})){
      $best_xref = $gene_best_hit{$gene_id};
      $best_level = $gene_level{$gene_id};
    }

    foreach my $transcript_id (@transcripts) {
      if(defined($trans_best_hit{$transcript_id})){
	if($trans_level{$transcript_id} >  $best_level){
	  $best_xref = $trans_best_hit{$transcript_id};
	  $best_level = $trans_level{$transcript_id};
	  $best_object = $transcript_id;
	}
	elsif($trans_level{$transcript_id} == $best_level){ # now use the longest
	  my $transcript = $ta->fetch_by_dbID($transcript_id);
	  my $new_length = $transcript->length();
	  if(!$best_length){
	    $transcript = $ta->fetch_by_dbID($best_object);
	    $best_length = $transcript->length();
	  }
	  if($best_length < $new_length){
	    $best_xref = $trans_best_hit{$transcript_id};
	    $best_level = $trans_level{$transcript_id};
	    $best_object = $transcript_id;
	    $best_length = $new_length;
	  }
	}
      }
    }
    if(defined($best_xref)) {
      print GENE_DX "UPDATE gene g SET g.display_xref_id=" . $best_xref . 
	" WHERE g.gene_id=" . $gene_id . ";\n";
      print GENE_DX_TXT $best_xref . "\t" . $gene_id ."\n";
      
    }
  }
  close GENE_DX;
  close GENE_DX_TXT;

  return;

}



# Display xref sources to be used for transcripts *in order of priority*
# Source names used must be identical to those in the source table.

sub transcript_display_xref_sources {

  return ('RFAM',
	  'miRBase',
	  'HUGO',
	  'MarkerSymbol',
	  'flybase_symbol',
	  'Anopheles_symbol',
	  'Genoscope_annotated_gene',
	  'Uniprot/SWISSPROT',
	  'Uniprot/Varsplic',
	  'RefSeq_peptide',
	  'RefSeq_dna',
	  'Uniprot/SPTREMBL',
	  'EntrezGene');

}

# Get transcripts associated with each gene

sub build_genes_to_transcripts {

  my ($self) = @_;

  print "Getting transcripts for all genes\n";

  my $sql = "SELECT gene_id, transcript_id FROM transcript";
  my $sth = $self->core->dbc->prepare($sql);
  $sth->execute();

  my ($gene_id, $transcript_id);
  $sth->bind_columns(\$gene_id, \$transcript_id);

  # Note %genes_to_transcripts is global
  while ($sth->fetch()) {
    push @{$genes_to_transcripts{$gene_id}}, $transcript_id;
  }

  print "Got " . scalar keys(%genes_to_transcripts) . " genes\n";

}

# Find the index of an item in a list(ref), or -1 if it's not in the list.
# Only look for exact matches (case insensitive)

sub find_in_list {

  my ($item, @list) = @_;

  for (my $i = 0; $i < scalar(@list); $i++) {
    if (lc($list[$i]) eq lc($item)) {
      return $i;
    }
  }

  return -1;

}

# Take a string and a list of regular expressions
# Find the index of the highest matching regular expression
# Return the index, or -1 if not found.

sub find_match {

 my ($str, @list) = @_;

 my $str2 = $str;
 my $highest_index = -1;

  for (my $i = 0; $i < scalar(@list); $i++) {
    my $re = $list[$i];
    if ($str2 =~ /$re/i) {
      $highest_index = $i;
    }
  }

  return $highest_index;

}

# Build a map of source id (in xref database) to external_db (in core database)

sub map_source_to_external_db {

  my $self = shift;

  my %source_to_external_db;

  # get all sources
  my $sth = $self->xref->dbc->prepare("select s.source_id, s.name, count(*) from xref x, source s where x.source_id = s.source_id group by source_id");
  $sth->execute();
  my ($source_id, $source_name, $count);
  $sth->bind_columns(\$source_id, \$source_name, \$count);

  while($sth->fetchrow_array()) {

    # find appropriate external_db_id for each one
    my $sql = "SELECT external_db_id FROM external_db WHERE db_name=?";
    my $core_sth = $self->core->dbc->prepare($sql);
    $core_sth->execute($source_name);

    my @row = $core_sth->fetchrow_array();

    if (@row) {

      $source_to_external_db{$source_id} = $row[0];
      #print "Source name $source_name id $source_id corresponds to core external_db_id " . $row[0] . "\n";

    } else {
      print STDERR "Can't find external_db entry for source name $source_name; xrefs for this source will not be written. Consider adding $source_name to external_db and \n"
      . " Make sure that you used TABS not spaces as delimiters in external_db.txt\n" ; 
    }

  } # while source

  return %source_to_external_db;
}


sub cleanup_sources_file{
  my ($self,$id) = @_;

  $updated_source{$id} =1;

  my $dir = $self->core->dir();
  open (DEL, ">>$dir/cleanup.sql") || die "Could not open $dir/cleanup.sql\n";

  if ($id =~ m/\w/){

    print DEL "DELETE external_synonym ";
    print DEL     "FROM external_synonym, xref ";
    print DEL       "WHERE external_synonym.xref_id = xref.xref_id ";
    print DEL         "AND xref.external_db_id = $id\n";

    print DEL "DELETE gx ";
    print DEL     "FROM xref x, object_xref ox LEFT JOIN go_xref gx ";
    print DEL       "ON ox.object_xref_id = gx.object_xref_id ";
    print DEL       "WHERE x.xref_id = ox.xref_id ";
    print DEL          "AND x.external_db_id = $id ";
    print DEL          "AND gx.linkage_type is not null\n"; 

    print DEL "DELETE identity_xref ";
    print DEL     "FROM identity_xref, object_xref, xref ";
    print DEL       "WHERE identity_xref.object_xref_id = object_xref.object_xref_id ";
    print DEL         "AND object_xref.xref_id = xref.xref_id ";
    print DEL         "AND xref.external_db_id = $id \n";


    print DEL "DELETE object_xref ";
    print DEL     "FROM object_xref, xref ";
    print DEL       "WHERE object_xref.xref_id = xref.xref_id ";
    print DEL         "AND xref.external_db_id = $id\n";


    print DEL "DELETE FROM xref WHERE xref.external_db_id = $id \n";

    print DEL "DELETE FROM unmapped_object WHERE type='xref' and external_db_id = $id \n";

  } else { 
    warn("\nFound an empty id\n");
  }
  close DEL;

}

# Upload .txt files and execute .sql files.

sub do_upload {

  my ($self) = @_;

  my $ensembl = $self->core;
  my $core_db = $ensembl->dbc;
  # xref.txt etc
  my $file = $ensembl->dir() . "/cleanup.sql";

  print "Deleting existing data - using file $file\n";
  open(CLEAN,"<$file") || die "could not open $file for reading \n";
  while (<CLEAN>){
    chomp;
    my $sth = $core_db->prepare($_); 
    $sth->execute() or die "Couldn't execute statement: " . $sth->errstr;
  }     
  close CLEAN;
  


  foreach my $table ("go_xref", "interpro") {
    my $file = $ensembl->dir() . "/" . $table . ".txt";
    
    if(-s $file){ 
      my $sth = $core_db->prepare("DELETE FROM $table");
      print "Deleting existing data in $table\n";
      $sth->execute();
    }
  }
  
  print "Uploading new data\n";
  foreach my $table ("xref", "object_xref", "identity_xref", "external_synonym", 
		     "go_xref", "interpro", "unmapped_object") {

    my $file = $ensembl->dir() . "/" . $table . ".txt";

    if(-s $file){
      my $sth = $core_db->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE $table");
      print "Uploading data in $file to $table\n";
      $sth->execute();
    }
    else{
      print "NO file or zero size file, so not able to load file $file to $table\n";
    }
  }

}

sub genes_and_transcripts_attributes_set{
  my ($self) = @_;

  my $ensembl = $self->core;
  my $core_db = $ensembl->dbc;
  #use the core data that is already there.

  $self->build_transcript_and_gene_display_xrefs();
  $self->new_build_gene_descriptions();

  if(!defined($self->upload)){
    print "Not clearing genes and transcript attrubutes and loading new ones as upload NOT set\n";
    return;
  }

  # gene & transcript display_xrefs
  my $sth = $core_db->prepare(<<GADES);
  UPDATE gene g 
    SET g.display_xref_id=NULL 
GADES
  print "Setting all existing display_xref_id in gene to null\n";
  $sth->execute();
  

  my $sth = $core_db->prepare(<<TRAN);
  UPDATE transcript t 
    SET t.display_xref_id=NULL
TRAN
  print "Setting all existing display_xref_id in transcript to null\n";
  $sth->execute();

  # gene descriptions
  my $sth = $core_db->prepare(<<GENE);
  UPDATE gene g
    SET g.description=NULL 
GENE
  print "Setting all existing descriptions in gene table to null\n";
  $sth->execute();

  # gene_display_xref.sql etc
  foreach my $table ("gene", "transcript") {

    my $file = $ensembl->dir() . "/" . $table . "_display_xref.sql";

    print "Setting $table display_xrefs from $file\n";
    my $mysql_command = $self->get_mysql_command($core_db);
    system( "$mysql_command < $file" ) == 0 
        or print( "ERROR: parsing $file in mysql\n" );
  }

  # gene descriptions
  my $file = $ensembl->dir() . "/gene_description.sql";
  print "Setting gene descriptions from $file\n";
  my $mysql_command = $self->get_mysql_command($core_db);
  system( "$mysql_command < $file" ) == 0 
      or print( "ERROR: parsing $file in mysql\n" );

  # update meta table with timestamp saying when xrefs were last updated
  $file =  $ensembl->dir() . "/meta_timestamp.sql";
  open (FILE, ">$file");
  print FILE "DELETE FROM meta WHERE meta_key='xref.timestamp';\n";
  print FILE "INSERT INTO meta (meta_key,meta_value) VALUES ('xref.timestamp', NOW())\n";
  close(FILE);

  my $mysql_command = $self->get_mysql_command($core_db);
  system( "$mysql_command < $file" ) == 0 
      or print( "ERROR: parsing $file in mysql\n" );

  # set gene and transcript statuses to KNOWN or NOVEL based on external_db status
  print "Setting gene and transcript status from external_db KNOWN/NOVEL\n";
  $file =  $ensembl->dir() . "/gene_transcript_status.sql";
  open (FILE, ">$file");
  print FILE "UPDATE transcript SET status=\'NOVEL\';\n";
  print FILE "UPDATE gene SET status=\'NOVEL\';\n";

  print FILE "UPDATE gene g, xref x, external_db e SET g.status = \'KNOWN\' ";
  print FILE    "WHERE g.display_xref_id = x.xref_id ";
  print FILE     "AND x.external_db_id = e.external_db_id AND e.status=\'KNOWN\';\n";

  print FILE "UPDATE gene g, xref x, external_db e SET g.status = \'KNOWN\' ";
  print FILE    "WHERE g.display_xref_id = x.xref_id ";
  print FILE     "AND x.external_db_id = e.external_db_id AND e.status=\'KNOWNXREF\';\n";

  print FILE "UPDATE transcript t, xref x, external_db e SET t.status = \'KNOWN\' ";
  print FILE    "WHERE t.display_xref_id = x.xref_id ";
  print FILE    "AND x.external_db_id = e.external_db_id AND e.status=\'KNOWN\';\n";

  print FILE "UPDATE transcript t, xref x, external_db e SET t.status = \'KNOWN\' ";
  print FILE    "WHERE t.display_xref_id = x.xref_id ";
  print FILE    "AND x.external_db_id = e.external_db_id AND e.status=\'KNOWNXREF\';\n";
  close(FILE);

  my $mysql_command = $self->get_mysql_command($core_db);
  system( "$mysql_command < $file" ) == 0 
      or print( "ERROR: parsing $file in mysql\n" );
}





sub new_build_gene_descriptions{
  my ($self) = @_;

  #  1) get xrefs descriptions and accessions for those in the list
  #        use $self->gene_description_sources  to get sources.
  #        only store xrefs if valid description
  #  2) process these descriptions with $self->filter_by_regexp
  #  3) get transcripts and gene xrefs for these (similar to earlier)
  #     but do different output

  my @regexps = $self->gene_description_filter_regexps();

  if(scalar(@regexps) == 0){
    warn "no reg exps\n";
  }
  my @sources = $self->gene_description_sources();

  if(!scalar(keys %translation_to_transcript)){
    print "Building translation to transcript mappings\n";
    my $sth = $self->core->dbc->prepare("SELECT translation_id, transcript_id FROM translation");
    $sth->execute();
    
    my ($translation_id, $transcript_id);
    $sth->bind_columns(\$translation_id, \$transcript_id);
    
    while ($sth->fetch()) {
      $translation_to_transcript{$translation_id} = $transcript_id;
      $transcript_to_translation{$transcript_id} = $translation_id if ($translation_id);
    }
  }

  my %external_name_to_id;  
  my %ex_db_id_to_status;
  my $sql1 = "SELECT external_db_id, db_name, status from external_db";
  
  my $sth1 = $self->core->dbc->prepare($sql1) || die "prepare failed for $sql1\n";
  $sth1->execute() || die "execute failed";
  my ($db_id, $name, $status);
  $sth1->bind_columns(\$db_id, \$name, \$status);
  while($sth1->fetch()){
    $external_name_to_id{$name}  = $db_id;
    $ex_db_id_to_status{$db_id} = $status;
  }
  $sth1->finish;

  my $sql = (<<ESQL);
  SELECT x.xref_id, x.dbprimary_acc, x.description
    FROM xref x
      WHERE x.external_db_id = ?
ESQL

  my $sth = $self->core->dbc->prepare($sql) || die "prepare failed for $sql\n";

  my ($xref_id, $acc, $description);
  
  my $level = 0;
  my $removed = 0;
  my $added = 0;
  my $checked = 0;
  foreach my $source (@sources){
    $level++;
    if(defined($external_name_to_id{$source})){
      $sth->execute($external_name_to_id{$source}) || die "execute failed";
      $sth->bind_columns(\$xref_id, \$acc, \$description);
      while($sth->fetch()){
	$checked++;
	if ($description) {
	  my $filtered_description = $self->filter_by_regexp($description, \@regexps);
	  if ($filtered_description ne "") {
	    $xref_descriptions{$xref_id} = $description;
	    $xref_accessions{$xref_id} = $acc;
	    $added++;
	  } else {
	    $removed++;
	  }
	}	
      }
    }
    else{
      print "Could not find $source in table external_db\n";
    }
  }
  $sth->finish;
  print "Regexp filtering (" . scalar(@regexps) . 
    " regexps) removed $removed descriptions, left with " . scalar(keys %xref_descriptions) . "\n";

  $sql = (<<ETSQL);
  SELECT ox.ensembl_id, ox.ensembl_object_type, ox.xref_id, ix.query_identity, ix.target_identity
    FROM (object_xref ox, xref x) 
      LEFT JOIN identity_xref ix on (ox.object_xref_id = ix.object_xref_id) 
	WHERE x.xref_id = ox.xref_id and x.external_db_id =?
ETSQL

  my $psth = $self->core->dbc->prepare($sql) || die "prepare failed for $sql\n";
 
  my $level = 0;
  my ($ensembl_id, $ens_type, $xref_id, $qid, $tid);
  my %gene_best_hit;
  my %gene_level;
  my %gene_source;
  my %trans_best_hit;
  my %trans_level;
  my %trans_source;
  my %trans_score;

  my $format_problem=0;


  my @words = qw(unknown hypothetical putative novel probable [0-9]{3} kDa fragment cdna protein);
  my $trembl_id = $external_name_to_id{"Uniprot/SPTREMBL"};
  
  foreach my $ord (@sources){
    my %gene_score;
    my %trans_seen;
    $level++;
    
    if(defined($external_name_to_id{$ord})){
      $psth->execute($external_name_to_id{$ord}) || die "execute failed";
      $psth->bind_columns(\$ensembl_id, \$ens_type, \$xref_id, \$qid, \$tid);
      while($psth->fetch()){
	if(defined($xref_descriptions{$xref_id})){ # if no description then ignore
	  if($ens_type eq "Gene"){
	    $gene_best_hit{$ensembl_id} = $xref_id;
	    $gene_score{$ensembl_id} = 1;
	    $gene_level{$ensembl_id} = $level; 
	    $gene_source{$ensembl_id} = $ord;
	  }
	  elsif($ens_type eq "Transcript" || $ens_type eq "Translation"){
	    if($ens_type eq "Translation"){
	      $ensembl_id = $translation_to_transcript{$ensembl_id};
	      # so everything is stored on the transcript. 
	    }
	    if(!defined($trans_seen{$ensembl_id})){
	      $trans_seen{$ensembl_id} = 1;
	      $trans_best_hit{$ensembl_id} = $xref_id;
	      $trans_level{$ensembl_id} = $level; 
	      $trans_source{$ensembl_id} = $ord;
	      if($external_name_to_id{$ord} == $trembl_id){
		$trans_score{$ensembl_id} = find_match($xref_descriptions{$xref_id}, @words);
	      }
	      else{
		if(defined($qid)){
		  $trans_score{$ensembl_id}  = $tid."\t".$qid;
		}
		else{
		  $trans_score{$ensembl_id}  = "100\t100";
		}
	      }
	    }
	    else{ # need to check if this is better than the one already stored.
	      if($external_name_to_id{$ord} == $trembl_id){
		my $new_score = find_match($xref_descriptions{$xref_id}, @words);
		if($new_score > $trans_score{$ensembl_id}){
		  $trans_best_hit{$ensembl_id} = $xref_id;
		  $trans_level{$ensembl_id} = $level; 
		  $trans_score{$ensembl_id} = $new_score;
		  $trans_source{$ensembl_id} = $ord;
		}
	      }
	      else{
		if(defined($qid)){
		  my ($old_t, $old_q) = split (/\s+/,$trans_score{$ensembl_id});
		  if(($qid > $old_q) || ($qid == $old_q and $tid > $old_t)){
		    $trans_best_hit{$ensembl_id} = $xref_id;
		    $trans_level{$ensembl_id} = $level; 
		    $trans_score{$ensembl_id}  = $tid."\t".$qid;		
		    $trans_source{$ensembl_id} = $ord;
		  }
		}	      
	      }
	    }
	  }
	}
      }
    }
    else{
      print "Ignoring $ord as this does not appear in the table external_db\n"; 
    }	  
  }

  print  "number of best transcripts id ".scalar( keys %trans_best_hit)."\n";
  
  # So i now have the best descriptions!
  if(!scalar(keys %genes_to_transcripts)){
    $self->build_genes_to_transcripts();
  }

  my $dir = $self->core->dir();
  open(GENE_DESCRIPTIONS,">$dir/gene_description.sql") || die "Could not open $dir/gene_description.sql";

  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(-dbconn => $self->core->dbc);

  my $ta = $db->get_TranscriptAdaptor();

  foreach my $gene_id (keys %genes_to_transcripts) {

    my @transcripts = @{$genes_to_transcripts{$gene_id}};

    my $best_xref = undef;
    my $best_level = 0;
    my $best_object = undef;
    my $best_source = "";
    my $best_length =0;
    my $best_score=0;
    if(defined($gene_best_hit{$gene_id})){
      $best_xref = $gene_best_hit{$gene_id};
      $best_level = $gene_level{$gene_id};
      $best_source = $gene_source{$gene_id};
    }

    foreach my $transcript_id (@transcripts) {
      if(defined($trans_best_hit{$transcript_id})){
	if($trans_level{$transcript_id} >  $best_level){
	  $best_xref = $trans_best_hit{$transcript_id};
	  $best_level = $trans_level{$transcript_id};
	  $best_object = $transcript_id;
	  $best_source = $trans_source{$transcript_id};
	  $best_score = $trans_score{$transcript_id};
	}
	elsif($trans_level{$transcript_id} == $best_level){ # now use the longest
	  #use the scores;
	  my ($told, $qold) = split (/\s+/,$best_score);
	  my ($tnew, $qnew) = split (/\s+/,$trans_score{$transcript_id});
	  my $same = 1;
	  if(defined($qold)){ #q and t values
	    if(($qnew > $qold) || 
	       ($qnew == $qold and $tnew > $told)){
	      $same = 0;
	      $best_xref = $trans_best_hit{$transcript_id};
	      $best_level = $trans_level{$transcript_id};
	      $best_object = $transcript_id;
	      $best_source = $trans_source{$transcript_id};
	      $best_score = $trans_score{$transcript_id};	      	      
	    }
	  }
	  else{ # trembl and only has one score.
	    if($told < $tnew){
	      $same = 0;
	      $best_xref = $trans_best_hit{$transcript_id};
	      $best_level = $trans_level{$transcript_id};
	      $best_object = $transcript_id;
	      $best_source = $trans_source{$transcript_id};
	      $best_score = $trans_score{$transcript_id};	      
	    }
	    elsif($told != $tnew){
	      $same = 0;
	    }
	  }

	  if($same){
	    my $transcript = $ta->fetch_by_dbID($transcript_id);
	    my $new_length = $transcript->length();
	    if(!$best_length){
	      $transcript = $ta->fetch_by_dbID($best_object);
	      $best_length = $transcript->length();
	    }
	    if($best_length < $new_length){
	      $best_xref = $trans_best_hit{$transcript_id};
	      $best_level = $trans_level{$transcript_id};
	      $best_source = $trans_source{$transcript_id};
	      $best_object = $transcript_id;
	      $best_length = $new_length;
	    }
	  }
	}
      }
    }
    
    if(defined($best_xref)) {
      my $description = $xref_descriptions{$best_xref};
      my $acc = $xref_accessions{$best_xref};
      
      $description =~ s/\"//ig; # remove " as they will cause problems in .sql files
      
      my $desc = $description . " [Source:$best_source;Acc:$acc]";
  
      print GENE_DESCRIPTIONS "UPDATE gene g SET g.description=\"$desc\" ".
	"WHERE g.gene_id=$gene_id;\n" if ($description);
      
    }

  }
  close GENE_DESCRIPTIONS;




}



# Check if any .err files exist that have non-zero size;
# this indicates that something has gone wrong with the exonerate run

sub check_err {

  my ($self, $dir) = @_;

  foreach my $err (glob("$dir/*.err")) {

    print "\n\n*** Warning: $err has non-zero size; may indicate".
      " problems with exonerate run\n\n\n" if (-s $err);

  }
}

sub get_best {
  my ($self,$refxref) = @_;
  return $$refxref[-1];
}

sub strip{
  my ($self,$refarray) = @_;
  my @ret;

  foreach my $arr (@$refarray){
    if(defined($xref_accessions{$arr})){
      push @ret, $arr;
    }
  }
  return \@ret;
}

# remove a list of patterns from a string
sub filter_by_regexp {

  my ($self, $str, $regexps) = @_;

  foreach my $regexp (@$regexps) {
    $str =~ s/$regexp//ig;
  }

  return $str;

}

# Regexp used for filter out useless text from gene descriptions
# Method can be overridden in species-specific modules
sub gene_description_filter_regexps {

  return ();

}



# move translation hits on to their transcripts if the same external_db_id
# has hits to both translation and transcript


sub cleanup_database {
  my ($self) = @_;
  my $ensembl_dbc = $self->core->dbc;

  # 1 make sure external_db do not lie on both translations and transcripts

  my $sql_check  = (<<ESQL);
  SELECT x.external_db_id, ox.ensembl_object_type, COUNT(*), e.db_name
    FROM xref x, object_xref ox, external_db e 
     WHERE x.xref_id = ox.xref_id AND e.external_db_id = x.external_db_id
       GROUP BY x.external_db_id, ox.ensembl_object_type
ESQL

  my $sth = $ensembl_dbc->prepare($sql_check);
  $sth->execute();
  my $previous_id = -1;
  my $previous_type ="";
  while(my @row = $sth->fetchrow_array()){
    my $external_db_id = $row[0];
    if($external_db_id == $previous_id){
      $self->fix_mart_prob($row[3],$external_db_id,$row[1],$previous_type);  
    }
    $previous_id = $external_db_id;
    $previous_type = $row[1];
  }

  # now recheck just incase :-)
  $sth->execute();
  $previous_id = -1;
  $previous_type ="";
  my $error =0;
  while(my @row = $sth->fetchrow_array()){
    my $external_db_id = $row[0];
    if($external_db_id == $previous_id){
      print "Problem: Still have multiple associations with ".$row[3]."\n";
      $error++;
    }
    $previous_id = $external_db_id;
    $previous_type = $row[1];
  }
  $sth->finish();
  if(!$error){
    print "External databases only associate to one ensembl type (PASS)\n";
  }
  else{
    print "External databases only associate to one ensembl type (FAIL)\n";
  }
}


sub fix_mart_prob{
  my ($self,$db_name,$db_id,$type1,$type2) = @_;
  my $ensembl_dbc = $self->core->dbc;

  print "$db_name is associated with both $type1 and $type2 object types\n";

  my $to;
  if($type1 eq "Gene" or $type2 eq "Gene"){
    $to = "Gene";
  }
  else{
    $to = "Transcript";
  }
    
  print "Therefore moving all associations to the ".$to."s\n";


  $ensembl_dbc->do("CREATE TABLE object_xref2 like object_xref");

  $ensembl_dbc->do("ALTER TABLE object_xref DROP INDEX ensembl_object_type");

# Move translations onto the transcripts
  my $sql =(<<EOF);
  UPDATE object_xref, translation, xref
     SET object_xref.ensembl_object_type = 'Transcript',
         object_xref.ensembl_id = translation.transcript_id 
     WHERE object_xref.ensembl_object_type = 'Translation' AND
           object_xref.ensembl_id = translation.translation_id AND
           xref.xref_id = object_xref.xref_id AND
           xref.external_db_id = $db_id;
EOF
  $ensembl_dbc->do($sql);
  
  if($to eq "Gene"){ #move transcripts to the gene
    my $sql =(<<GENE);
  UPDATE object_xref, transcript, xref
     SET object_xref.ensembl_object_type = 'Gene',
         object_xref.ensembl_id = transcript.gene_id 
     WHERE object_xref.ensembl_object_type = 'Transcript' AND
           object_xref.ensembl_id = transcript.transcript_id AND
           xref.xref_id = object_xref.xref_id AND
           xref.external_db_id = $db_id;
GENE
    $ensembl_dbc->do($sql);
    
  }
  
  
  $ensembl_dbc->do("INSERT IGNORE INTO object_xref2 SELECT * FROM object_xref");
  
  $ensembl_dbc->do("DROP TABLE object_xref");

  $ensembl_dbc->do("ALTER TABLE object_xref2 RENAME object_xref");


}



# list of sources to be used when building gene descriptions
# sorted into increasing order of priority

sub gene_description_sources {

  return ("Uniprot/SPTREMBL",
	  "Uniprot/Varsplic",
	  "RefSeq_dna",
	  "RefSeq_peptide",
	  "Uniprot/SWISSPROT",
	  "miRBase",
	  "RFAM");

}

# load external_db (if it's empty) from ../external_db/external_dbs.txt

sub upload_external_db {
  my ($self,$force_upload) = @_;
 
  my $core_db = $self->core->dbc;
  my $dbname = $core_db->dbname ; ;
  $core_db->connect();
  my $row = @{$core_db->db_handle->selectall_arrayref("SELECT COUNT(*) FROM external_db")}[0];
  my $count = @{$row}[0];
  
  my $upload_external_db = 0 ;

  if ($count > 0 ) {
    print "external_db table already has $count rows\n" ; 
    print " you may use -delete_external_db to delete all entries from external_db table and upload new data\n"  unless $force_upload ; 
  }
  if ($force_upload) { 
    print "WARNING: to delete all data from external_db table in $dbname enter \"yes\" to confirm\n";
    print "WARNING: any other key to continue without changing the table\n" ; 
    print "WARNING: Do you really want to delete all entries from external_db ? [ENTER = no | yes = delete ] " ;  

    $| = 1; # flush stdout
    my $p = <STDIN>;
    chomp $p;
    if ($p eq "yes") {
      my $edb_sth = $core_db->prepare("DELETE FROM external_db ") ;
      $edb_sth->execute();
      print "$count entries deleted from external_db table, now uploading new data\nusing file ./ensembl/misc_scripts/external_db/external_dbs.txt into $dbname \n" ;
      $upload_external_db = 1 ;
    } else {
      print "\n$dbname.external_db will NOT be changed\n";
    }
  }

  if ($count == 0 || $upload_external_db ) {
    my $edb = $self->external_db_file;
    print "external_db table is empty, uploading from $edb\n";
    my $edb_sth = $core_db->prepare("LOAD DATA LOCAL INFILE \'$edb\' INTO TABLE external_db");
    $edb_sth->execute();
  }

}


sub get_xref_descriptions{
  return \%xref_descriptions;
}

sub get_xref_accessions{
 return \%xref_accessions;
}

sub xref_id_offset{
 my  $self  = shift;

  $self->{'xref_id_offset'} = shift if( @_ );
  if( exists $self->{'xref_id_offset'} ) {
    return $self->{'xref_id_offset'};
  }
 return undef;
}

sub add_missing_pairs{
  my ($self) = @_;
  my $xref_id_offset = $self->xref_id_offset();
  #
  # add the pairs
  #
  # get current max object_xref_id
  my $row = @{$self->core->dbc->db_handle->selectall_arrayref("SELECT MAX(object_xref_id) FROM object_xref")}[0];
  my $max_object_xref_id = @{$row}[0];

  my $row2 = @{$self->core->dbc->db_handle->selectall_arrayref("SELECT count(object_xref_id) FROM object_xref")}[0];
  my $entries_obj_xref = @{$row2}[0]; 

  if (!defined $max_object_xref_id && $entries_obj_xref == 0 ) {
    die ("No existing object_xref_ids, something very wrong\n");
  }
  if (!defined $max_object_xref_id) {
    print "No existing object_xref_ids, will start from 1\n";
    $max_object_xref_id = 0;
  } else {
    print "Maximum existing object_xref_id = $max_object_xref_id\n";
  }

  my $xref_sql = (<<EOS);
  SELECT x1.xref_id, x2.xref_id, x1.accession, x2.accession, x1.source_id, x2.source_id   
    FROM pairs p, xref x1, xref x2
      WHERE p.accession1 = x1.accession
	AND p.accession2 = x2.accession
	 AND p.source_id = x1.source_id
EOS
  my $xref_sth = $self->xref->dbc->prepare($xref_sql);
  $xref_sth->execute(); 
  my ($xref_id1,$xref_id2, $x1_acc, $x2_acc, $x1_source_id, $x2_source_id);
  $xref_sth->bind_columns(\$xref_id1, \$xref_id2, \$x1_acc, \$x2_acc, \$x1_source_id, \$x2_source_id);

  my %good2missed=();
  my %good2missed_acc=();
  my $okay =0;
  my $both = 0;
  my $poss = 0;

  my @xref_list;

  while ($xref_sth->fetch()) {
   # If either of these are a priority source then make sure they are the chosen one.
    if(defined($priority_xref_source_id{$xref_id1})){
      my $key = $priority_source_id_to_name{$priority_xref_source_id{$xref_id1}}.":".$x1_acc;
      if(!defined($xrefs_written{$xref_id1})){
	if(!defined($priority_seenit{$key})){
	  push @xref_list, $xref_id1;
	  $priority_seenit{$key} = $x2_acc;
	}
	else{
	  next;
	}
      }
      else{
	next;
      }
    }

    if(defined($priority_xref_source_id{$xref_id2})){
      if(!defined($xrefs_written{$xref_id2})){
	my $key = $priority_source_id_to_name{$priority_xref_source_id{$xref_id2}}.":".$x2_acc;
	if(!defined($priority_seenit{$key})){
	  push @xref_list, $xref_id2;
	  $priority_seenit{$key} = $x1_acc;
	}
	else{
	  next;
	}
      }
      else{
	next;
      }
    }
    

    if(!defined($xrefs_written{$xref_id1}) or !defined($xrefs_written{$xref_id2})){
      if (!defined($xrefs_written{$xref_id1}) and !defined($xrefs_written{$xref_id2})){
	$okay++;
      }
      elsif(!defined($xrefs_written{$xref_id2})){
	$poss++;
	$good2missed{$xref_id1+$xref_id_offset} = $xref_id2+$xref_id_offset;
	$good2missed_acc{$xref_id1+$xref_id_offset} = $x2_acc;
      }
      else{
	$poss++;
	$good2missed{$xref_id2+$xref_id_offset} = $xref_id1+$xref_id_offset;
	$good2missed_acc{$xref_id2+$xref_id_offset} = $x1_acc;
      }
    }
    else{
      $both++;
    }
  }


  #sql needed to get the dependent xrefs for those missed.
  my $dep_sql = "SELECT dx.dependent_xref_id FROM dependent_xref dx, xref x WHERE x.xref_id=dx.dependent_xref_id AND master_xref_id = ?";
  my $dep_sth = $self->xref->dbc->prepare($dep_sql);
  

  if(scalar(@xref_list) > 1){
    open(XREF2, ">".$self->core->dir()."/pairs_xref.txt") 
      || die "Could not open pairs_xref.txt";


    my $list = join(", ", @xref_list);
    my $sql = "SELECT xref_id, accession, version, label, description, source_id from xref where xref_id in ($list)";
    my $sth = $self->xref->dbc->prepare($sql);
    $sth->execute();
    my ($xref_id, $acc,$ver, $label, $desc, $source_id);
    $sth->bind_columns(\$xref_id, \$acc, \$ver, \$label, \$desc, \$source_id);
    my $count =0;
    while($sth->fetch()){
      $count++;
      print XREF2 ($xref_id+$xref_id_offset)."\t". $source_to_external_db{$source_id}.
	"\t$acc\t$label\t$ver\t$desc";
      my $key = $priority_source_id_to_name{$priority_xref_source_id{$source_id}}.":".$acc;
      print XREF2 "\tINFERRED_PAIR\tGenerated via its Pair ".$priority_seenit{$key}."\n";
      $xrefs_written{$xref_id}
	
    }
    $sth->finish;

    close XREF2;
    my $file = $self->core->dir()."/pairs_xref.txt";
    
    # don't seem to be able to use prepared statements here
    if(-s $file){
      my $sth = $self->core->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE xref");
      print "Uploading data in $file to object_xref\n";
      $sth->execute();
      
      print "$count xrefs added based on the Pairs\n";
    }

  }



# create a hash to interchange between transcripts and translations
  my $tran_sth = $self->core->dbc->prepare("SELECT translation_id, transcript_id from translation");
  my $transcript;
  my $translation;
  $tran_sth->execute();
  $tran_sth->bind_columns(\$translation,\$transcript);
  my %transcript_2_translation;
  my %translation_2_transcript;
  while($tran_sth->fetch()){
    $transcript_2_translation{$transcript} = $translation;
    $translation_2_transcript{$translation} = $transcript;
  }
  $tran_sth->finish();

  open(OBJECT_XREF2, ">".$self->core->dir()."/pairs_object_xref.txt") 
    || die "Could not open pairs_object_xref.txt";

  my $triage_file = $self->core->dir()."/triage_update.sql";
  open(TRIAGE_UPDATE,">".$triage_file)
    || die "Could not open $triage_file\n";

  my $i=0;
  my $index;
  my $added = 0;
  my $sql = "SELECT o.xref_id, o.ensembl_id, o.ensembl_object_type, ";
  $sql   .=        "x.dbprimary_acc, x.external_db_id ";
  $sql   .=    "FROM object_xref o, xref x ";
  $sql   .=      "WHERE x.xref_id = o.xref_id AND x.xref_id IN (";
  my ($goodxref, $ens_int_id, $type, $acc, $ex_db_id);
  my @list =();
  foreach my $key (keys %good2missed){
    if($i > 200){
      my $sth_ob = $self->core->dbc->prepare($sql.(join(',',@list)).")") || die @_;
      $sth_ob->execute();
      $sth_ob->bind_columns(\$goodxref,\$ens_int_id,\$type, \$acc, \$ex_db_id);
      while($sth_ob->fetch()){
	if(($type =~ /Transcript/) and defined($transcript_2_translation{$ens_int_id})){
	  $max_object_xref_id++;
	  $added++;
          $object_succesfully_mapped{($good2missed{$goodxref}-$xref_id_offset)} = 1;
 	  print OBJECT_XREF2 "$max_object_xref_id\t";
	  print OBJECT_XREF2 $transcript_2_translation{$ens_int_id}."\tTranslation\t" ;
	  print OBJECT_XREF2 $good2missed{$goodxref};
	  print OBJECT_XREF2 "\n";	


	  $dep_sth->execute($good2missed{$goodxref}-$xref_id_offset);
	  my $dep_xref;
	  $dep_sth->bind_columns(\$dep_xref);
	  while($dep_sth->fetch){
	    $max_object_xref_id++;
	    $object_succesfully_mapped{$dep_xref} = 1;
 	    print OBJECT_XREF2 "$max_object_xref_id\t";
	    print OBJECT_XREF2 $transcript_2_translation{$ens_int_id}."\tTranslation\t" ;
	    print OBJECT_XREF2 $dep_xref+$xref_id_offset;
	    print OBJECT_XREF2 "\n";	
	  }
	  print TRIAGE_UPDATE "DELETE unmapped_object FROM unmapped_object ";
	  print TRIAGE_UPDATE   "WHERE identifier = '".$good2missed_acc{$goodxref}."' ";
	  print TRIAGE_UPDATE   "AND external_db_id = $ex_db_id ;\n";
	}
	elsif(($type =~ /Translation/) and defined($translation_2_transcript{$ens_int_id})){
	  $max_object_xref_id++;
	  $added++;
          $object_succesfully_mapped{($good2missed{$goodxref}-$xref_id_offset)} = 1;
 	  print OBJECT_XREF2 "$max_object_xref_id\t";
	  print OBJECT_XREF2 $translation_2_transcript{$ens_int_id}."\tTranscript\t" ;
	  print OBJECT_XREF2 $good2missed{$goodxref};
	  print OBJECT_XREF2 "\n";	

	  $dep_sth->execute($good2missed{$goodxref}-$xref_id_offset);
	  my $dep_xref;
	  $dep_sth->bind_columns(\$dep_xref);
	  while($dep_sth->fetch){
	    $max_object_xref_id++;
	    $object_succesfully_mapped{$dep_xref} = 1;
 	    print OBJECT_XREF2 "$max_object_xref_id\t";
	    print OBJECT_XREF2 $translation_2_transcript{$ens_int_id}."\tTranscript\t" ;
	    print OBJECT_XREF2 $dep_xref+$xref_id_offset;
	    print OBJECT_XREF2 "\n";	
	  }

	  print TRIAGE_UPDATE "DELETE unmapped_object FROM unmapped_object ";
	  print TRIAGE_UPDATE   "WHERE identifier = '".$good2missed_acc{$goodxref}."' ";
	  print TRIAGE_UPDATE   "AND external_db_id = $ex_db_id ;\n";
	}
      }
      $sth_ob->finish();
      @list =();
      $i=0;
    }
    else{
      push @list, $key;
      $i++;
    }
  }
  if($i){
    my $sth_ob = $self->core->dbc->prepare($sql.(join(',',@list)).")") || die @_;
    $sth_ob->execute();
    $sth_ob->bind_columns(\$goodxref,\$ens_int_id,\$type, \$acc, \$ex_db_id);
    while($sth_ob->fetch()){
      if(($type =~ /Transcript/) and defined($transcript_2_translation{$ens_int_id})){
	$max_object_xref_id++;
	$added++;
	$object_succesfully_mapped{($good2missed{$goodxref}-$xref_id_offset)} = 1;
 	print OBJECT_XREF2 "$max_object_xref_id\t";
	print OBJECT_XREF2 $transcript_2_translation{$ens_int_id}."\tTranslation\t" ;
	print OBJECT_XREF2 $good2missed{$goodxref};
	print OBJECT_XREF2 "\n";	
	$dep_sth->execute($good2missed{$goodxref}-$xref_id_offset);
	my $dep_xref;
	$dep_sth->bind_columns(\$dep_xref);
	while($dep_sth->fetch){
	  $max_object_xref_id++;
          $object_succesfully_mapped{$dep_xref} = 1;
 	  print OBJECT_XREF2 "$max_object_xref_id\t";
	  print OBJECT_XREF2 $transcript_2_translation{$ens_int_id}."\tTranslation\t" ;
	  print OBJECT_XREF2 $dep_xref+$xref_id_offset;
	  print OBJECT_XREF2 "\n";	
	}
	print TRIAGE_UPDATE "DELETE unmapped_object FROM unmapped_object ";
	print TRIAGE_UPDATE   "WHERE identifier like '".$good2missed_acc{$goodxref}."' ";
	print TRIAGE_UPDATE   "AND external_db_id = $ex_db_id ;\n";
      }
      elsif(($type =~ /Translation/) and defined($translation_2_transcript{$ens_int_id})){
	$max_object_xref_id++;
	$added++;
	$object_succesfully_mapped{($good2missed{$goodxref}-$xref_id_offset)} = 1;
 	print OBJECT_XREF2 "$max_object_xref_id\t";
	print OBJECT_XREF2 $translation_2_transcript{$ens_int_id}."\tTranscript\t" ;
	print OBJECT_XREF2 $good2missed{$goodxref};
	print OBJECT_XREF2 "\n";	
	$dep_sth->execute($good2missed{$goodxref}-$xref_id_offset);
	my $dep_xref;
	$dep_sth->bind_columns(\$dep_xref);
	while($dep_sth->fetch){
	  $max_object_xref_id++;
          $object_succesfully_mapped{$dep_xref} = 1;
 	  print OBJECT_XREF2 "$max_object_xref_id\t";
	  print OBJECT_XREF2 $translation_2_transcript{$ens_int_id}."\tTranscript\t" ;
	  print OBJECT_XREF2 $dep_xref+$xref_id_offset;
	  print OBJECT_XREF2 "\n";	
	}
	print TRIAGE_UPDATE "DELETE unmapped_object FROM unmapped_object ";
	print TRIAGE_UPDATE   "WHERE identifier like '".$good2missed_acc{$goodxref}."' ";
	print TRIAGE_UPDATE   "AND external_db_id = $ex_db_id ;\n";
      }
      
    }
   $sth_ob->finish();
  }

  close OBJECT_XREF2;

  #
  # Now load the data into the database.
  #
 
  my $file = $self->core->dir()."/pairs_object_xref.txt";
  
  # don't seem to be able to use prepared statements here
   if(-s $file){
       my $sth = $self->core->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE object_xref");
       print "Uploading data in $file to object_xref\n";
       $sth->execute();
  
       print "$added new object xrefs added based on the Pairs\n";
   }


  print "At end of pairs Maximum existing object_xref_id = $max_object_xref_id\n";


  my $core_db = $self->core->dbc;

  my $mysql_command = $self->get_mysql_command($core_db);
  system( "$mysql_command < $triage_file" ) == 0 
      or print( "ERROR: parsing $file in mysql\n" );

  print "updated triage data accordingly\n";
}

sub dump_all_dependencies{
  my ($self, $master_id, $xref_id_offset, $type, $object_id) = @_;
  my @return;

  # Now get the dependent xrefs for this xref and write them
  
  my $sql = "SELECT DISTINCT(x.xref_id), dx.master_xref_id, x.accession, x.label, x.description, x.source_id, x.version, dx.linkage_annotation FROM dependent_xref dx, xref x WHERE x.xref_id=dx.dependent_xref_id AND master_xref_id = $master_id";
  
  my $dep_sth = $self->xref->dbc->prepare($sql);
  $dep_sth->execute();

   my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id, $master_xref_id, $linkage_annotation);
  
  $dep_sth->bind_columns(\$xref_id, \$master_xref_id, \$accession, \$label, \$description, \$source_id, \$version, \$linkage_annotation);
  while ($dep_sth->fetch()) {
    
    
    my $external_db_id = $source_to_external_db{$source_id};
     next if (!$external_db_id);
    
    
    $label = $accession if (!$label);
    
    if (!$xrefs_written{$xref_id}) {
	if(!defined($updated_source{$external_db_id})){
	    $self->cleanup_sources_file($external_db_id);
	}
	
	
	my $master_accession = $XXXxref_id_to_accession{$master_xref_id};
	
	if(!defined($priority_xref_source_id{$xref_id})){
	    print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description .  "\t" . "DEPENDENT" . "\t" . "Generated via $master_accession" . "\n";
	    push @return, ($xref_id+$xref_id_offset);
	    $xrefs_written{$xref_id} = 1;
	}
	elsif(defined($type)){
	    my $key = $priority_source_id_to_name{$source_id}.":".$priority_xref_acc{$xref_id};	  
	    if(!defined($priority_xref_priority{$key})){
		print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id.
		    " being set as undef  (DEPENDENT) priority = ".$priority_source_id{$source_id}."\n";
		
		$priority_xref_extra_bit{$xref_id} = "\t" . "DEPENDENT" . "\t" . "Generated via $master_accession" . "\n";
		$priority_xref{$key} = $xref_id;
		$priority_xref_priority{$key} = $priority_source_id{$source_id};
		$priority_object_xref{$key} = "$type:$object_id";
		$priority_identity_xref{$key} = undef;
		$priority_xref_state{$key} = "dependent";
		next;
	    }
	    if($priority_xref_priority{$key} 
	       > $priority_source_id{$source_id}){
		
		print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id.
		    " being set as better priority found  (DEPENDENT) priority = ".$priority_source_id{$source_id}."\n";
		
		$priority_xref_extra_bit{$xref_id} = "\t" . "DEPENDENT" . "\t" . "Generated via $master_accession" . "\n";
		$priority_xref{$key} = $xref_id;
		$priority_xref_priority{$key} = $priority_source_id{$source_id};
		$priority_object_xref{$key} = "$type:$object_id";
		$priority_identity_xref{$key} = undef;
		$priority_xref_state{$key} = "dependent";
		next;
	    }
	    else{
		print PRIORITY_FILE $priority_xref_acc{$xref_id}."\t".$source_id." has less priority (DEPENDENT) so left as is\n";
	    }
	}
    }

  }   
  return \@return;
}
    

sub get_mysql_command{
  my $self = shift;
  my $dbc  = shift;
  
  UNIVERSAL::isa( $dbc, 'Bio::EnsEMBL::DBSQL::DBConnection' )
      || die( "Need a Bio::EnsEMBL::DBSQL::DBConnection not a " . ref($dbc) );

  my $host   = $dbc->host;
  my $port   = $dbc->port;
  my $dbname = $dbc->dbname;
  my $user   = $dbc->username;
  my $pass   = $dbc->password;
  my $str = join( ' ',
                  'mysql',
                  ( $host ? ( '-h', $host ) : () ),
                  ( $port ? ( '-P', $port ) : () ),
                  ( $user ? ( '-u', $user ) : () ),
                  ( $pass ? ( "-p'".$pass."'" ) : () ),
                  $dbname );
  return $str;
}

sub dump_xref_with_no_triage_data() {
  my ($self, $xref_id_offset) = @_;

  print "Dumping xrefs\n";
 my $batch_size=200;

  my $primary_sql= (<<PSQL);
    SELECT DISTINCT(s.source_id), px.sequence_type
      FROM source s, primary_xref px, xref x 
	WHERE x.xref_id = px.xref_id
	  AND s.source_id = x.source_id
PSQL

  my $psth = $self->xref->dbc->prepare($primary_sql) || die "prepare failed";
  $psth->execute() || die "execute failed";

  my @primary_sources =();
  my %source_2_seqtype=();

  my ($prim,$seq_type);
  $psth->bind_columns(\$prim,\$seq_type);
  while($psth->fetch()){
    push @primary_sources, $prim;
    $source_2_seqtype{$prim} = $seq_type;
  }

  open (XREF, ">>" . $self->core->dir() . "/xref.txt");

  foreach my $source (@primary_sources){


    if(defined($priority_source_name{$source})){
      next;
    }
    my $sql = "select x.xref_id, x.accession, x.version, x.label, x.description, x.source_id, ".
              "x.species_id from xref x where x.source_id = $source";
    my $sth = $self->xref->dbc->prepare($sql);
    $sth->execute();
    
    my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id);
    $sth->bind_columns(\$xref_id, \$accession, \$version, \$label, 
		       \$description, \$source_id, \$species_id);
    while($sth->fetch()){
      if (!$xrefs_written{$xref_id}) {
	my $external_db_id = $source_to_external_db{$source_id};
	if(!defined($updated_source{$external_db_id})){
	  $self->cleanup_sources_file($external_db_id);
	}
	if(!defined($priority_xref_source_id{$xref_id})){
	  print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . 
	             "\t" . $label . "\t" . $version . "\t" . $description . "\tMISC\tNo match\n";

#dump out dependencies aswell
	
	  $self->dump_all_dependencies($xref_id, $xref_id_offset);
	}

      }
    }
    $sth->finish;
  }
  close(XREF);
}
    


sub unmapped_data_for_prioritys{

  my $self= shift;
  my $xref_id_offset = $self->xref_id_offset();
  my $ensembl = $self->core;
  my $xref = $self->xref;
  my $dir = $ensembl->dir();
  my %cutoff_2_failed_id=();

  my $summary_failed = "Failed to match at thresholds";
  my $summary_missed = "Failed to match";
  my $description_missed = "Unable to match to any ensembl entity at all";


  #IANL
  #unmapped objects. Need to write these for the priority_xrefs.
  # use priority_seenit and priority_failed

  open(UNMAPPED_OBJECT,">$dir/unmapped_object_priority.txt") 
    || die "Could not open unmapped_object_priority.txt";
  
  open(XREF_P,">$dir/unmapped_xref_priority.txt") 
    || die "Could not open unmapped_xref_priority.txt";
  
  #for each priority source that is primary :-
    # get all xref,acc for this
      # if seentit ignore
        # else if priotrity_failed 
           #write unmapped object.

  my $description_missed = "Unable to match to any ensembl entity at all";
  
  my $sth = $self->core->dbc->prepare("select unmapped_reason_id from unmapped_reason where full_description like '".$description_missed."'");  
  $sth->execute();
  my $xref_missed_id;
  $sth->bind_columns(\$xref_missed_id);
  $sth->fetch;
  if(!defined($xref_missed_id)){
    print STDERR "Could not find the description:\n";
    print STDERR $description_missed,"\n";
    print STDERR "In the directory ensembl/misc-scripts/unmapped_reason you ";
    print STDERR "can add the new reason to the unmapped_reason.txt file ";
    print STDERR "and run the update_unmapped_reasons.pl script to update ";
    print STDERR "your core database\n";
    print STDERR "Alterntively do not add the triage data and add -notriage to the command line.\n";
    die();
  }
  $sth->finish;
 

  $sth = $self->core->dbc->prepare("select MAX(unmapped_object_id) ".
				      "from unmapped_object");
  $sth->execute();
  my $max_unmapped_object_id;
  $sth->bind_columns(\$max_unmapped_object_id);
  $sth->fetch;
  if(!defined($max_unmapped_object_id)){
    $max_unmapped_object_id = 1;
  }
  $sth->finish;

  my $primary_sql= (<<PSQL);
    SELECT DISTINCT(s.source_id), px.sequence_type
      FROM source s, primary_xref px, xref x 
	WHERE x.xref_id = px.xref_id
	  AND s.source_id = x.source_id
PSQL

  my $psth = $self->xref->dbc->prepare($primary_sql) || die "prepare failed";
  $psth->execute() || die "execute failed";

  my @primary_sources =();
  my %source_2_seqtype=();

  my ($prim, $seq_type);
  $psth->bind_columns(\$prim,\$seq_type);
  while($psth->fetch()){
   if(defined($priority_source_id_to_name{$prim})){
    push @primary_sources, $prim;
    $source_2_seqtype{$prim} = $seq_type;
   }
  }

  my $xref_PROT_analysis = $self->get_analysis_id("translation");
  my $xref_DNA_analysis  = $self->get_analysis_id("transcript");

  foreach my $source_id (@primary_sources){  #priority primary sources
    my $old_source_name = $priority_source_id_to_name{$source_id};
    my $external_db_id = $source_to_external_db{$source_id};
    my $xref_sql = "SELECT xref_id, accession, version, label, description from xref where xref.source_id = $source_id";
    my $sth = $self->xref->dbc->prepare($xref_sql) || die "prepare failed";
    $sth->execute() || die "execute failed";
    my ($xref_id, $acc, $ver, $lab, $desc);
    $sth->bind_columns(\$xref_id, \$acc, \$ver, \$lab, \$desc);
    while($sth->fetch()){
      my $key = $old_source_name.":".$acc;
      if(defined($priority_seenit{$key})){
	next;
      }
      $priority_seenit{$key} = 1; 
      if(defined($priority_failed{$key})){
	my ($ensembl_type,$ensembl_id,$q_perc,$t_perc,$q_cut,$t_cut) =  
	  split(/\|/,$priority_failed{$key});
	
	if(!defined($cutoff_2_failed_id{$q_cut."_".$t_cut})){
	  $cutoff_2_failed_id{$q_cut."_".$t_cut} = $self->get_failed_id($q_cut, $t_cut, $summary_failed);
	}
	$max_unmapped_object_id++;
	
	print  UNMAPPED_OBJECT $max_unmapped_object_id."\txref\t";
	
	if($ensembl_type  =~ /Translation/){
	  print UNMAPPED_OBJECT $xref_PROT_analysis."\t";
	}
	elsif($ensembl_type  =~ /Transcript/){
	  print UNMAPPED_OBJECT $xref_DNA_analysis."\t";
	}
	else{
	  die "type=*".$ensembl_type."*\n".$failed_xref_mappings{$xref_id}."\n";
	}
	print UNMAPPED_OBJECT $external_db_id."\t".$acc."\t".$cutoff_2_failed_id{$q_cut."_".$t_cut}."\t";
	print UNMAPPED_OBJECT $q_perc."\t".$t_perc."\t";
	print UNMAPPED_OBJECT $ensembl_id."\t".$ensembl_type."\n";
	print XREF_P ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $acc . 
	  "\t" . $lab . "\t" . $ver . "\t" . $desc . "\tMISC\tNo match over threshold\n";
      }
      else{
	$max_unmapped_object_id++;
	print  UNMAPPED_OBJECT $max_unmapped_object_id."\txref\t";
	if($source_2_seqtype{$source_id} =~ /peptide/){
	  print UNMAPPED_OBJECT $xref_PROT_analysis."\t";
	}
	elsif($source_2_seqtype{$source_id} =~ /dna/){
	  print UNMAPPED_OBJECT $xref_DNA_analysis."\t";
	}
	print UNMAPPED_OBJECT $external_db_id."\t".$acc."\t";
	print UNMAPPED_OBJECT $xref_missed_id."\t0\t0\t0\tNULL\n";
	print XREF_P ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $acc . 
	  "\t" . $lab . "\t" . $ver . "\t" . $desc . "\tMISC\tNo match\n";
      }
    }
  }
  close UNMAPPED_OBJECT;
  close XREF_P;

  my $file = $dir."/unmapped_xref_priority.txt";
  
  if(-s $file){
    my $sth = $ensembl->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE xref");
    print "Uploading data in $file to xref\n";
    $sth->execute();
  }
  $file = $dir."/unmapped_object_priority.txt";
  
  if(-s $file){
    my $sth = $ensembl->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE unmapped_object");
    print "Uploading data in $file to unmapped_object\n";
    $sth->execute();
  }


}




=head2 write_dependent_unmapped_objects

  Description: wrote and load the unmapped object for the dependent xrefs
  Exceptions : none
  Returntype : none

=cut

sub write_dependent_unmapped_objects{
  my $self = shift;
  my $xref_id_offset = $self->xref_id_offset();
  my $ensembl = $self->core;
  my $dir = $ensembl->dir();

  open(UNMAPPED_OBJECT,">$dir/unmapped_object_dependents.txt")
    || die "Could not open unmapped_object_dependents.txt";

  open(XREF,">$dir/dependent_xref.txt")
    || die "Could not open dependent_xref.txt";


  my $description_missed = "Unable to match as parent xref was not mapped";

  my $sth = $self->core->dbc->prepare("select unmapped_reason_id from unmapped_reason where full_description like '".$description_missed."'");
  $sth->execute();
  my $xref_missed_id;
  $sth->bind_columns(\$xref_missed_id);
  $sth->fetch;
  if(!defined($xref_missed_id)){
    print STDERR "Could not find the description:\n";
    print STDERR $description_missed,"\n";
    print STDERR "In the directory ensembl/misc-scripts/unmapped_reason you ";
    print STDERR "can add the new reason to the unmapped_reason.txt file ";
    print STDERR "and run the update_unmapped_reasons.pl script to update ";
    print STDERR "your core database\n";
    print STDERR "Alterntively do not add the triage data and add -notriage to the command line.\n";
    die();
  }
  $sth->finish;

  my $max_unmapped_object_id;
  $sth = $self->core->dbc->prepare("select MAX(unmapped_object_id) ".
                                      "from unmapped_object");
  $sth->execute();
  my $max_unmapped_object_id;
  $sth->bind_columns(\$max_unmapped_object_id);
  $sth->fetch;
  if(!defined($max_unmapped_object_id)){
    $max_unmapped_object_id = 1;
  }
  $sth->finish;

  my $primary_sql= (<<PSQL);
    SELECT DISTINCT(s.source_id), px.sequence_type
      FROM source s, primary_xref px, xref x
        WHERE x.xref_id = px.xref_id
          AND s.source_id = x.source_id
PSQL

  my $psth = $self->xref->dbc->prepare($primary_sql) || die "prepare failed";
  $psth->execute() || die "execute failed";


  my %source_2_seqtype=();

  my ($prim, $seq_type);
  $psth->bind_columns(\$prim,\$seq_type);
  while($psth->fetch()){
    $source_2_seqtype{$prim} = $seq_type;
  }

  my $xref_PROT_analysis = $self->get_analysis_id("translation");
  my $xref_DNA_analysis  = $self->get_analysis_id("transcript");

  #  $unmapped_primary_xref{$xref_id} = "QZ1234";

  my $sql = "SELECT DISTINCT(x.xref_id), x2.source_id, dx.master_xref_id, x.accession, x.label, x.description, x.source_id,x.version, dx.linkage_annotation FROM dependent_xref dx, xref x, xref x2 WHERE x2.xref_id = dx.master_xref_id and x.xref_id=dx.dependent_xref_id AND master_xref_id = ?";

  my $dep_sth = $self->xref->dbc->prepare($sql);


  foreach my $key (keys %unmapped_primary_xref){
    $dep_sth->execute($key);
    my ($xref_id, $master_source, $accession, $version, $label, $description, $source_id, $species_id, $master_xref_id, $linkage_annotation);

    $dep_sth->bind_columns(\$xref_id, \$master_source, \$master_xref_id, \$accession, \$label, \$description, \$source_id, \$version, \$linkage_annotation);

    while ($dep_sth->fetch()) {


      if(defined($priority_xref_source_id{$xref_id})){ #priority ones already done
        next;
      }

      my $external_db_id = $source_to_external_db{$source_id};
      next if (!$external_db_id);


      if (!$xrefs_written{$xref_id}) {
        print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" .
          $label . "\t" . $version . "\t" . $description .  "\t" . "DEPENDENT" . "\t" .
            "No mapping ".$unmapped_primary_xref{$xref_id}. "\n";
        $xrefs_written{$xref_id} = 1;
      }
      if(!defined($object_succesfully_mapped{$xref_id})){
        $max_unmapped_object_id++;
        print  UNMAPPED_OBJECT $max_unmapped_object_id."\txref\t";
        if($source_2_seqtype{$master_source} =~ /peptide/){
          if (not defined $xref_PROT_analysis) {
            $xref_PROT_analysis = $self->get_analysis_id("translation");
          }
          print UNMAPPED_OBJECT $xref_PROT_analysis."\t";
        }
        elsif($source_2_seqtype{$master_source} =~ /dna/){
          if (not defined $xref_DNA_analysis) {
            $xref_DNA_analysis = $self->get_analysis_id("transcript");
          }
          print UNMAPPED_OBJECT $xref_DNA_analysis."\t";
        }
        else{
          die "COULD NOT get an analysis for source id = $master_source ".$unmapped_primary_xref{$master_xref_id}."\n";
        }
        print UNMAPPED_OBJECT $external_db_id."\t".$accession."\t";
        print UNMAPPED_OBJECT $xref_missed_id."\t0\t0\t0\tNULL\t".
          $unmapped_primary_xref{$master_xref_id}. "\n";
      }
    }
  }
  close UNMAPPED_OBJECT;
  close XREF;

  my $file = $dir."/dependent_xref.txt";

  if(-s $file){
    my $sth = $ensembl->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE xref");
    print "Uploading data in $file to xref\n";
    $sth->execute();
  }
  $file = $dir."/unmapped_object_dependents.txt";

  if(-s $file){
    my $sth = $ensembl->dbc->prepare("LOAD DATA LOCAL INFILE \'$file\' IGNORE INTO TABLE unmapped_object");
    print "Uploading data in $file to unmapped_object\n";
    $sth->execute();
  }

}




1;

