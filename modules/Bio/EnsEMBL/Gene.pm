
#
# BioPerl module for Gene
#
# Cared for by Ewan Birney <birney@sanger.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Gene - Object for confirmed Genes

=head1 SYNOPSIS

Confirmed genes. Basically has a set of transcripts

=head1 DESCRIPTION

Needs more description.

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::Gene;
use vars qw(@ISA);
use strict;

# Object preamble - inheriets from Bio::SeqFeature::Generic

use Bio::EnsEMBL::Root;
use Bio::EnsEMBL::TranscriptI;
use Bio::DBLinkContainerI;
use Bio::Annotation::DBLink;
use Bio::EnsEMBL::DBEntry;


@ISA = qw(Bio::EnsEMBL::Root Bio::DBLinkContainerI);
# new() is inherited from Bio::Root::Object

# _initialize is where the heavy stuff will happen when new is called

sub new {
  my($class,@args) = @_;

  my $self = bless {}, $class;

  $self->{'_transcript_array'} = [];
#  $self->{'_db_link'} = [];
# set stuff in self from @args
  return $self; # success - we hope!
}



=head2 start

  Arg [1]    : (optional) int $start
  Example    : $start = $gene->start;
  Description: This is a convenience method.  It may be better to calculate
               your own start by looking at the exons yourself.
               Gets/sets the lowest start coordinate of this genes exons.
               No consistancy check is performed and if this is used as a
               setter potentially the start could be set to a value which
               does not correspond to the lowest exon start.  If this
               gene is in RawContig coordinates and its exons span multiple
               contigs the lowest value is still returned and a warning is
               issued.
  Returntype : int
  Exceptions : warning if gene spans multiple contigs
  Caller     : general, contigview

=cut

sub start {
  my($self, $start) = @_;

  my $multi_flag = 0;

  if($start) {
    $self->{start} = $start;   
  } elsif(!defined $self->{start}) {
    my $last_contig;
    foreach my $exon (@{$self->get_all_Exons}) {
      if(!defined($self->{start}) || $exon->start() < $self->{start}) {
        $self->{start} = $exon->start();
      }
      $multi_flag = 1 if($last_contig && $last_contig ne $exon->contig->name);
      $last_contig = $exon->contig->name;
    }
  }

  if($multi_flag) {
    $self->warn("Bio::EnsEMBL::Gene::start - Gene spans multiple contigs." .
		"The return value from start may not be what you want");
  }    
  
  return $self->{start};
}



=head2 end

  Arg [1]    : (optional) int $end
  Example    : $end = $gene->end;
  Description: This is a convenience method.  It may be better to calculate
               your own end by looking at the exons yourself.
               Gets/sets the highest end coordinate of this genes exons.
               No consistancy check is performed and if this is used as a
               setter potentially the end could be set to a value which
               does not correspond to the highest exon end.  If this
               gene is in RawContig coordinates and its exons span multiple
               contigs the highest value is still returned and a warning is
               issued.
  Returntype : int
  Exceptions : warning if gene spans multiple contigs
  Caller     : general, contigview

=cut

sub end {
  my($self, $end) = @_;

  my $multi_flag = 0;

  if($end) {
    $self->{end} = $end;   
  } elsif(!defined $self->{end}) {
    my $last_contig;
    foreach my $exon (@{$self->get_all_Exons()}) {
      if(!defined($self->{end}) || $exon->end() > $self->{end}) {
        $self->{end} = $exon->end();
      }
      $multi_flag = 1 if($last_contig && $last_contig ne $exon->contig->name);
      $last_contig = $exon->contig->name;
    }
  }

  if($multi_flag) {
    $self->warn("Bio::EnsEMBL::Gene::end - Gene spans multiple contigs." .
		"The return value from end may not be what you want");
  }

  return $self->{end};
}



=head2 strand

  Arg [1]    : (optional) int strand 
  Example    : $strand = $gene->strand;
  Description: This is a convenience method. It may be better just to
               get the strand from this genes exons yourself.  
               Gets/Sets the strand of this gene. No consistancy check is
               performed and if used as a setter the strand can be set 
               incorrectly.  If this gene is in RawContig coords and spans 
               multiple contigs it is not possible to calculate the strand
               correctly, and a warning is returned.  
  Returntype : int
  Exceptions : Warning if strand is not defined and Gene is in RawContig coords
               so strand cannot be calculated
  Caller     : general

=cut

sub strand {
  my $self = shift;
  my $arg = shift;

  if( defined $arg ) {
    $self->{'strand'} = $arg;
  } elsif( ! defined $self->{strand} ) {
    my $exons = $self->get_all_Exons();
    if(@$exons) {
      if($exons->[0]->contig && 
	 $exons->[0]->contig->isa("Bio::EnsEMBL::RawContig")) {
	my $last_contig;
	foreach my $exon (@$exons) {
	  if($last_contig && $last_contig ne $exon->contig->name) {
	    $self->warn("Bio::EnsEMBL::Gene::strand - strand can not be " .
			"calculated for a Gene in RawContig coordinates that "
			. "spans multiple contigs");
	    return 0;
	  }
	  $last_contig = $exon->contig->name;
	}
      }
      $self->{'strand'} = $exons->[0]->strand();
    }
  }
  return $self->{'strand'};

}


=head2 chr_name

  Arg [1]    : (optional) string $chr_name
  Example    : $chr_name = $gene->chr_name
  Description: Getter/Setter for the name of the chromosome that this
               Gene is on.  This is really just a shortcut to the slice
               attached this genes exons, but the value can also be set, which 
               is useful for use with the lite database and web code.
               This function will return undef if this gene is not attached
               to a slice and the chr_name attribute has not already been set. 
  Returntype : string
  Exceptions : warning if chr_name is not defined and Gene is in RawContig 
               coordinates
  Caller     : Lite GeneAdaptor, domainview

=cut

sub chr_name {
  my ($self, $chr_name) = @_;

  if(defined $chr_name) { 
    $self->{'_chr_name'} = $chr_name;
  } elsif(!defined $self->{'_chr_name'}) {
    #attempt to get the chr_name from the contig attached to the exons
    my ($exon, $contig);
    ($exon) = @{$self->get_all_Exons()};
    if($exon && ($contig = $exon->contig())) {
      if(ref $contig && $contig->isa('Bio::EnsEMBL::Slice')) {
        $self->{'_chr_name'} = $contig->chr_name();
      } else {
	$self->warn('Gene::chr_name - Gene is in RawContig coords, and must '
                  . 'be in Slice coords to have a valid chr_name');
      }
    }
  } 

  return $self->{'_chr_name'};
}


=head2 source

  Arg [1]    : string $source
  Example    : none
  Description: get/set for attribute source
  Returntype : string
  Exceptions : none
  Caller     : general

=cut


sub source {
  my ($self, $source) = @_;

  if(defined $source) {
    $self->{'_source'} = $source;
  }

  return $self->{'_source'};
}



=head2 is_known

  Args       : none
  Example    : none
  Description: returns true if the Gene or one of its Transcripts have
               DBLinks
  Returntype : 0,1
  Exceptions : none
  Caller     : general

=cut


sub is_known{
  my ($self) = @_;
  my @array;
  @array = $self->get_all_DBLinks();
  if( scalar(@array) > 0 ) {
    return 1;
  }
  foreach my $trans ( @{$self->get_all_Transcripts} ) {
    @array = $trans->get_all_DBLinks();
    if( scalar(@array) > 0 ) {
      return 1;
    }
  }
  
  return 0;
}


=head2 adaptor

  Arg [1]    : Bio::EnsEMBL::DBSQL::GeneAdaptor $adaptor
  Example    : none
  Description: get/set for attribute adaptor
  Returntype : Bio::EnsEMBL::DBSQL::GeneAdaptor
  Exceptions : none
  Caller     : set only used by adaptor on store or retrieve

=cut


sub adaptor {
   my ($self, $arg) = @_;

   if ( defined $arg ) {
      $self->{'_adaptor'} = $arg ;
   }
   return $self->{'_adaptor'};
}




=head2 analysis

  Arg [1]    : Bio::EnsEMBL::Analysis $analysis
  Example    : none
  Description: get/set for attribute analysis
  Returntype : Bio::EnsEMBL::Analysis
  Exceptions : none
  Caller     : general

=cut


sub analysis {
  my ($self,$value) = @_;
  if( defined $value ) {
    $self->{'analysis'} = $value;
  }
  return $self->{'analysis'};
}




=head2 dbID

  Arg [1]    : int $dbID
  Example    : none
  Description: get/set for attribute dbID
  Returntype : int
  Exceptions : none
  Caller     : set only by adaptor on store or retrieve

=cut


sub dbID {
   my ($self, $arg) = @_;

   if ( defined $arg ) {
      $self->{'_dbID'} = $arg ;
   }
   return $self->{'_dbID'};
}



=head2 external_name

  Arg [1]    : string $external_name
  Example    : none
  Description: get/set for attribute external_name. It could be calculated
               from dblinks in a species dependent way. Well introduce 
               that later.
  Returntype : string
  Exceptions : none
  Caller     : Lite::GeneAdaptor knows how to set it correct

=cut

sub external_name {
  my ($self, $arg ) = @_;

  if( defined $arg ) {
    $self->{'_external_name'} = $arg;
  }

  return $self->{'_external_name'};
}



=head2 external_db	

  Arg [1]    : string $external_db
  Example    : none
  Description: get/set for attribute external_db. The db is the one that 
               belongs to the external_name
  Returntype : string
  Exceptions : none
  Caller     : general

=cut


sub external_db {
  my ($self, $arg ) = @_;

  if( defined $arg ) {
    $self->{'_external_db'} = $arg;
  }

  return $self->{'_external_db'};
}




=head2 description

  Arg [1]    : (optional) string $description
  Example    : none
  Description: you can set get this argument. If not set its lazy loaded
               from attached adaptor.
  Returntype : string
  Exceptions : if no GeneAdaptor is set and no description is there
  Caller     : general

=cut


sub description {
    my ($self, $arg) = @_;
    
    if( defined $arg ) {
      $self->{'_description'} = $arg;
      return $arg;
    }

    if( exists $self->{'_description'} ) {
      return $self->{'_description'};
    }
    $self->{'_description'} = $self->adaptor->get_description($self->dbID);
    return $self->{'_description'};
}



=head2 get_all_DBLinks

  Arg [1]    : none
  Example    : @dblinks = @{$gene->get_all_DBLinks()};
  Description: retrieves a listref of DBLinks for this gene
  Returntype : list reference to Bio::EnsEMBL::DBEntry objects
  Exceptions : none
  Caller     : general

=cut

sub get_all_DBLinks {
   my $self = shift;

   if( !defined $self->{'_db_link'} ) {
     $self->{'_db_link'} = [];
     if( defined $self->adaptor ) {
       $self->adaptor->db->get_DBEntryAdaptor->fetch_all_by_Gene($self);
     }
   } 

   return $self->{'_db_link'};
}



=head2 add_DBLink

  Arg [1]    : Bio::Annotation::DBLink $link
               a link is a database entry somewhere else.
               Usually this is a Bio::EnsEMBL::DBEntry.
  Example    : none
  Description: will add  the link to the list of links already in the
               gene object.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut


sub add_DBLink{
  my ($self,$value) = @_;

  unless(defined $value && ref $value 
	 && $value->isa('Bio::Annotation::DBLink') ) {
    $self->throw("This [$value] is not a DBLink");
  }
  
  if( !defined $self->{'_db_link'} ) {
    $self->{'_db_link'} = [];
  }

  push(@{$self->{'_db_link'}},$value);
}




=head2 get_all_Exons

  Args       : none
  Example    : none
  Description: a set off all the exons associated with this gene.
  Returntype : listref Bio::EnsEMBL::Exon
  Exceptions : none
  Caller     : general

=cut


sub get_all_Exons {
   my ($self,@args) = @_;
   my %h;

   my @out = ();

   foreach my $trans ( @{$self->get_all_Transcripts} ) {
       foreach my $exon ( @{$trans->get_all_Exons} ) {
	   $h{"$exon"} = $exon;
       }
   }

   push @out, values %h;

   return \@out;
}



=head2 type

  Arg [1]    : string $type
  Example    : none
  Description: get/set for attribute type
  Returntype : string
  Exceptions : none
  Caller     : general

=cut


sub type {
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'type'} = $value;
    }
    return $obj->{'type'};
}



=head2 add_Transcript

  Arg  1     : Bio::EnsEMBL::Transcript $transcript
  Example    : none
  Description: adds another Transcript to the set of alternativly
               spliced Transcripts off this gene. If it shares exons 
               with another Transcript, these should be object-identical
  Returntype : none
  Exceptions : none
  Caller     : general

=cut


sub add_Transcript{
   my ($self,$trans) = @_;

   if( !ref $trans || ! $trans->isa("Bio::EnsEMBL::TranscriptI") ) {
       $self->throw("$trans is not a Bio::EnsEMBL::TranscriptI!");
   }

   #invalidate the start and end since they may need to be recalculated
   $self->{start} = undef;
   $self->{end} = undef;
   $self->{strand} = undef;

   push(@{$self->{'_transcript_array'}},$trans);
}



=head2 get_all_Transcripts

  Args       : none
  Example    : none
  Description: return the Transcripts in this gene
  Returntype : listref Bio::EnsEMBL::Transcript
  Exceptions : none
  Caller     : general

=cut


sub get_all_Transcripts {
  my ($self) = @_;

  return $self->{'_transcript_array'};
}



=head2 created

  Arg [1]    : string $created
               The time the stable id for this gene was created. Not very well
               maintained data (at release 9)
  Example    : none
  Description: get/set/lazy_load for the created timestamp
  Returntype : string
  Exceptions : none
  Caller     : general

=cut


sub created{
    my ($self,$value) = @_;

    if(defined $value ) {
      $self->{'_created'} = $value;
    }


    if( exists $self->{'_created'} ) {
      return $self->{'_created'};
    }

    $self->_get_stable_entry_info();

    return $self->{'_created'};

}


=head2 modified

  Arg [1]    : string $modified
               The time the gene with this stable_id was last modified.
               Not well maintained data (release 9)
  Example    : none
  Description: get/set/lazy_load of modified timestamp
  Returntype : string
  Exceptions : none
  Caller     : general

=cut


sub modified{
    my ($self,$value) = @_;
    

    if( defined $value ) {
      $self->{'_modified'} = $value;
    }

    if( exists $self->{'_modified'} ) {
      return $self->{'_modified'};
    }

    $self->_get_stable_entry_info();

    return $self->{'_modified'};
}



=head2 version

  Arg [1]    : int $version
               A version number for the stable_id
  Example    : nonen
  Description: get/set/lazy_load for the version number
  Returntype : int
  Exceptions : none
  Caller     : general

=cut


sub version{

    my ($self,$value) = @_;
    

    if( defined $value ) {
      $self->{'_version'} = $value;
    }

    if( exists $self->{'_version'} ) {
      return $self->{'_version'};
    }

    $self->_get_stable_entry_info();

    return $self->{'_version'};

}



=head2 stable_id

  Arg [1]    : string $stable_id
  Example    : ("ENSG0000000001")
  Description: get/set/lazy_loaded stable id for this gene
  Returntype : string
  Exceptions : none
  Caller     : general

=cut

sub stable_id{

    my ($self,$value) = @_;
    

    if( defined $value ) {
      $self->{'_stable_id'} = $value;
      return;
    }

    if( exists $self->{'_stable_id'} ) {
      return $self->{'_stable_id'};
    }

    $self->_get_stable_entry_info();

    return $self->{'_stable_id'};

}



=head2 _get_stable_entry_info

  Args       : none
  Example    : none
  Description: does the lazy loading for all stable id related information
  Returntype : none
  Exceptions : none
  Caller     : internal

=cut


sub _get_stable_entry_info {
   my $self = shift;

   if( !defined $self->adaptor ) {
     return undef;
   }

   $self->adaptor->get_stable_entry_info($self);

}



sub _dump{
   my ($self,$fh) = @_;

   if( ! $fh ) {
       $fh = \*STDOUT;
   }

   print $fh "Gene ", $self->dbID(), "\n";
   foreach my $t ( @{$self->get_all_Transcripts()} ) {
       print $fh "  Trans ", $t->dbID(), " :";
       foreach my $e ( @{$t->get_all_Exons} ) {
	   print $fh " ",$e->dbID(),",";
       }
       print "\n";
   }

}


=head2 transform

  Arg  1     : (optional) Bio::EnsEMBL::Slice $slice
              
  Description: when passed a Slice as argument,
               it will transform this Gene to the Slice coordinate system.
               Without an argument it  transforms the Gene (which should be in a slice) to a RawContig 
               coordinate system.
               The method changes the Gene in place and returns itself.
  Returntype : Bio::EnsEMBL::Gene
  Exceptions : none
  Caller     : object::methodname or just methodname

=cut


sub transform {
  my $self = shift;
  my $slice = shift;

  # hash arrray to store the refs of transformed exons
  my %exon_transforms;

  # transform Exons
  for my $exon ( @{$self->get_all_Exons()} ) {
    my $newExon = $exon->transform( $slice );
    $exon_transforms{ $exon } = $newExon;
  }

  # now need to re-jiggle the transcripts and their
  # translations to account for the re-mapping process

  foreach my $transcript ( @{$self->get_all_Transcripts()} ) {

    # need to grab the translation before starting to 
    # re-jiggle the exons

    $transcript->transform( \%exon_transforms );
    
  }

  #unset the start, end, and strand - they need to be recalculated
  $self->{start} = undef;
  $self->{end} = undef;
  $self->{strand} = undef;
  $self->{_chr_name} = undef;

  return $self;
}



=head2 temporary_id

 Title   : temporary_id
 Usage   : $obj->temporary_id($newval)
 Function: Temporary ids are used for Genscan predictions - which should probably
           be moved over to being stored inside the gene tables anyway. Bio::EnsEMBL::TranscriptFactory use this.
           MC Over my dead body they will.  Unless you can speed up the database by a couple of orders of magnitude.
 Example : 
 Returns : value of temporary_id
 Args    : newvalue (optional)


=cut

sub temporary_id {
   my ($obj,$value) = @_;
   if( defined $value) {
      $obj->{'temporary_id'} = $value;
    }
    return $obj->{'temporary_id'};

}





#############################
#
# DEPRECATED METHODS FOLLOW
#
#############################

=head2 each_Transcript

 Title   : each_Transcript
 Usage   : DEPRECATED foreach $trans ( $gene->each_Transcript)
 Function: DEPRECATED
 Example : DEPRECATED
 Returns : DEPRECATED An array of Transcript objects
 Args    : DEPRECATED


=cut

sub each_Transcript {
   my ($self) = @_;

   $self->warn("Gene->each_Transcript is deprecated.  " .
	     "Use get_all_Transcripts().\n" . $self->stack_trace_dump() ."\n");
   
   

   return $self->get_all_Transcripts();   
}

=head2 id

 Title   : id
 Usage   : DEPRECATED $obj->id($newval)
 Function: DEPRECATED
 Returns : DEPRECATED value of id
 Args    : DEPRECATED newvalue (optional)


=cut

sub id{
  my $self = shift;
  my $value = shift;

   my ($p,$f,$l) = caller;
   $self->warn("$f:$l id deprecated. Please choose from stable_id or dbID");

  if( defined $value ) {
    $self->warn("$f:$l stable ids are loaded separately and dbIDs are generated on writing. Ignoring set value $value");
    return;
  }


   if( defined $self->stable_id ) {
     return $self->stable_id();
   } else {
     return $self->dbID;
   }

}


sub each_unique_Exon{
   my ($self) = @_;

   my ($p,$f,$l) = caller;
   $self->warn("$f:$l each_unique_Exon deprecated. use get_all_Exons instead. Exon objects should be unique memory locations");

   return $self->get_all_Exons;
}


sub all_Exon_objects{

   my ($self) = @_;

   my ($p,$f,$l) = caller;
   $self->warn("$f:$l all_Exon_objects deprecated. use get_all_Exons instead. Exon objects should be unique memory locations");

   return $self->get_all_Exons;
}


=head2 refresh

  Arg [1]    : none
  Example    : none
  Description: DEPRECATED no longer needed, do not call
  Returntype : none
  Exceptions : none
  Caller     : none

=cut

sub refresh {
   my ($self) = @_;

   $self->warn("call to deprecated method refresh.  This method is not needed "
	       . "anymore and should not be called\n" );

#   foreach my $e ($self->get_all_Exons) {
#       $e->start($e->ori_start);
#       $e->end($e->ori_end);
#       $e->strand($e->ori_strand);
#   }
}



=head2 each_DBLink

  Arg [1]    : none
  Example    : none
  Description: DEPRECATED use Bio::EnsEMBL::get_all_DBLinks instead
  Returntype : none
  Exceptions : none
  Caller     : none

=cut

sub each_DBLink {
  my $self = shift;

  $self->warn("each_DBLink has been renamed get_all_DBLinks\n" .
	      caller);

  return $self->get_all_DBLinks();
}


=head2 get_Exon_by_id

  Arg [1]    : none
  Example    : none
  Description: DEPRECATED use get_all_Exons instead
  Returntype : none
  Exceptions : none
  Caller     : none

=cut

sub get_Exon_by_id {
    my ($self, $id) = @_;

    $self->warn("Get Exon by id is deprecated use get_all_Exons and " .
		"sort through them yourself\n");

    # perhaps not ideal
    foreach my $exon ( $self->get_all_Exons ) {
      # should this be stable_id
      if( $exon->dbID eq $id ) {
	return $exon;
      }
    }
}

1;
