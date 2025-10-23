use Test2::V0;

# These tests are specific to XS implementation
# Skip when the XS implementation will not be loaded
plan skip_all => 'ENSEMBL_NO_XS_INTERVAL_TREE is set, XS version not available'
    if $ENV{ENSEMBL_NO_XS_INTERVAL_TREE};
# Skip when the XS implementation is not installed or version is too old
plan skip_all => 'Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable XS version not available'
  unless eval { require Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable; Bio::EnsEMBL::XS::Utils::Tree::Interval::Mutable->VERSION('1.3.1'); 1; };

subtest 'load modules' => sub {
    is(
        eval {require Bio::EnsEMBL::Utils::Tree::Interval::Mutable; 1;},
        1,
        'Bio::EnsEMBL::Utils::Tree::Interval::Mutable loads'
    );
    is(Bio::EnsEMBL::Utils::Tree::Interval::Mutable::BIO_ENSEMBL_XS(), 1, 'BIO_ENSEMBL_XS is true');

    my $tree = Bio::EnsEMBL::Utils::Tree::Interval::Mutable->new();
    is($tree, object {
        prop isa => 'Bio::EnsEMBL::Utils::Tree::Interval::Mutable';
        call size => 0;
        call [search => 1, 10] => U();
        call root => DNE(); # XS implementation has no root method
    }, 'object instantiated with correct class');
};

subtest 'xs implementation tests' => sub {
    require Bio::EnsEMBL::Utils::Tree::Interval::Mutable;
    my $interval_class = 'Bio::EnsEMBL::Utils::Interval';
    my $tree = Bio::EnsEMBL::Utils::Tree::Interval::Mutable->new();

    $tree->insert($interval_class->new(@$_)) for (
        [5, 20, {name => 'foo'}], [15, 25, {name => 'bar'}], [30, 40, {name => 'baz'}]);

    is($tree, object {
        prop isa => 'Bio::EnsEMBL::Utils::Tree::Interval::Mutable';
        call size => 3;
        call [search => 14, 16] => array {
            item object {
                prop isa => $interval_class;
                call data => hash { field name => 'foo'};
                call start => 5;
                call end => 20;
            };
            item object {
                prop isa => $interval_class;
                call data => hash { field name => 'bar'};
                call start => 15;
                call end => 25;
            };
        };
        call [search => 27, 29] => U();
    }, 'insert and search methods work correctly');

    is($tree->remove($interval_class->new(15, 25)), 1, 'remove method works correctly');
    is($tree, object {
        call size => 2;
    }, 'size is decreased appropriately');

    is($tree->new, object {
        prop isa => 'Bio::EnsEMBL::Utils::Tree::Interval::Mutable';
        call size => 0;
        call root => DNE(); # parent missing this method
    }, 'new method works correctly');
};

done_testing;