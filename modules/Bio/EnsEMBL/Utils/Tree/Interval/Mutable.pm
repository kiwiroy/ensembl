=head1 LICENSE

See the NOTICE file distributed with this work for additional information
regarding copyright ownership.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut


=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=cut

=head1 NAME

Bio::EnsEMBL::Utils::Tree::Interval::Mutable

=head1 SYNOPSIS

  # start with an empty tree
  my $tree = Bio::EnsEMBL::Utils::Tree::Interval::Mutable->new();

  # add a few intervals (i.e. Bio::EnsEMBL::Utils::Interval)
  $tree->insert($i1);
  $tree->insert($i2);
  $tree->insert($i3);

  # query the tree
  my $result = $tree->search(85, 100);
  if (scalar @{$result}) {
    print "Found overlapping interval: [", $result->[0]->start, ', ', $result->[0]->end, "\n";
  }

=head1 DESCRIPTION

Class representing a dynamic, i.e. mutable, interval tree implemented as an augmented AVL balanced binary tree.

This module is a wrapper around two possible implementations: one using the Perl extension (XS) mechanisms, and
a pure Perl (PP) one. 

For better performance the optional module L<Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable> will be used
automatically if possible. This can also be disabled with the C<ENSEMBL_NO_XS_INTERVAL_TREE> environment
variable to fall back to the PP implementation.
 
=head1 METHODS

=cut

package Bio::EnsEMBL::Utils::Tree::Interval::Mutable;

use strict;

use Bio::EnsEMBL::Utils::Scalar qw(assert_ref);
use Bio::EnsEMBL::Utils::Exception qw(throw warning info);
use Bio::EnsEMBL::Utils::Tree::Interval::Mutable::PP ();
use Sub::Util ();

# if XS is used, version at least 1.3.1 is required (provides the interval tree library)
use constant BIO_ENSEMBL_XS => $ENV{ENSEMBL_NO_XS_INTERVAL_TREE}
  ? 0 # ----- can not use variables in the eval below -----
  : !!eval { require Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable; Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable->VERSION('1.3.1'); 1; };

# the modules providing the underlying implementation,
# either XS or pure perl fallback
my $XS = 'Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable';
my $PP = 'Bio::EnsEMBL::Utils::Tree::Interval::Mutable::PP';

my @public_methods = qw/ insert search remove size /;

for my $func(@public_methods) {
  my $sub = BIO_ENSEMBL_XS ? $XS->can($func) : $PP->can($func);
  no strict 'refs'; ## no critic
  *$func = Sub::Util::set_subname __PACKAGE__ . "::$func", $sub;
}

# so internal methods are called in the right package after reblessing
push our @ISA, BIO_ENSEMBL_XS ? $XS : $PP;

=head2 new

  Arg []      : none
  Example     : my $tree = Bio::EnsEMBL::Utils::Tree::Mutable->new();
  Description : Constructor. Creates a new mutable tree instance
  Returntype  : Bio::EnsEMBL::Utils::Tree::Interval::Mutable
  Exceptions  : none
  Caller      : general

=cut

sub new {
  my $self = shift;
  return bless($self->SUPER::new(@_), ref($self) || $self);
}

1;