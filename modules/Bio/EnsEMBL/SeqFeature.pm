
#
# BioPerl module for Bio::EnsEMBL::SeqFeature
#
# Cared for by Ewan Birney <birney@sanger.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::SeqFeature - Ensembl specific sequence feature.

=head1 SYNOPSIS

    my $feat = new Bio::EnsEMBL::SeqFeature(-seqname => 'pog',
					    -start   => 100,
					    -end     => 220,
					    -strand  => -1,
					    -frame   => 1,
					    -source  => 'tblastn_vert',
					    -primary => 'similarity',
					    -analysis => $analysis
					    );

    # $analysis is a Bio::EnsEMBL::Analysis::Analysis object
    
    # SeqFeatureI methods can be used
    my $start = $feat->start;
    my $end   = $feat->end;

    # Bio::EnsEMBL::SeqFeature specific methods can be used
    my $analysis = $feat->analysis;

    # Validate all the data in the object
    $feat->validate  || $feat->throw("Invalid data in $feat");

=head1 DESCRIPTION

This is an implementation of the ensembl Bio::EnsEMBL::SeqFeatureI interface.  Extra
methods are to store details of the analysis program/database/version used
to create this data and also a method to validate all data in the object is
present and of the right type.  This is useful before writing into
a relational database for example.

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::SeqFeature;

use vars qw(@ISA);
use strict;

# Object preamble - inheriets from Bio::Root::Object

use Bio::SeqFeatureI;
use Bio::Root::Object;

@ISA = qw(Bio::SeqFeatureI
	  Bio::Root::Object);

# new is inherited from Bio::Root::Object

sub _initialize {
  my($self,@args) = @_;

  my $make = $self->SUPER::_initialize;

  my ($analysis) = $self->_rearrange([qw(ANALYSIS
					 )],@args);

  $self->analysis($analysis);

  return $make; # success - we hope!
}

=head2 analysis

 Title   : analysis
 Usage   : $sf->analysis();
 Function: Store details of the program/database
           and versions used to create this feature.
           
 Example :
 Returns : 
 Args    :


=cut

sub analysis {
   my ($self,$value) = @_;

   if (defined($value)) {
       $self->throw("Analysis is not a Bio::EnsEMBL::Analysis::Analysis object") unless 
	   $value->isa("Bio::EnsEMBL::Analysis::Analysis");
       $self->{_analysis} = $value;
   }
   return $self->{_analysis};

}

=head2 validate

 Title   : validate
 Usage   : $sf->validate;
 Function: Checks whether all the data is present in the
           object.
 Example :
 Returns : 
 Args    :


=cut

sub validate {
   my ($self,$value) = @_;

   $self->_abstractDeath;

}


1;
