package XrefMapper::homo_sapiens;

use  XrefMapper::BasicMapper;

use vars '@ISA';

@ISA = qw{ XrefMapper::BasicMapper };

sub get_set_lists {

  return [["ExonerateGappedBest1", ["homo_sapiens","*"]]];

}

sub gene_description_filter_regexps {

  return ('^BA\S+\s+\(NOVEL PROTEIN\)\.?',
	  '^DJ\S+\s+\(NOVEL PROTEIN\)\.?',
	  '^LOC\d+\s*(PROTEIN)?\.?',
	  '^ORF.*',
	  '^PROTEIN C\d+ORF\d+\.*',
	  '\(CLONE \S+\)\s+',
	  '^BC\d+\_\d+\.?',
	  '^CGI\-\d+ PROTEIN\.?\;?',
	  '[0-9A-Z]{10}RIK PROTEIN[ \.]',
	  'R\d{5}_\d[ \.,].*',
	  'PROTEIN KIAA\d+[ \.].*',
	  'RIKEN CDNA [0-9A-Z]{10}[ \.]',
	  '^\(*HYPOTHETICAL\s+.*',
	  '^UNKNOWN\s+.*',
	  '^DKFZP[A-Z0-9]+\s+PROTEIN[\.;]?.*',
	  '^CHROMOSOME\s+\d+\s+OPEN\s+READING\s+FRAME\s+\d+\.?.*',
	  '^FKSG\d+\.?.*',
	  '^HSPC\d+\s+PROTEIN\.?.*',
	  '^KIAA\d+\s+PROTEIN\.?.*',
	  '^KIAA\d+\s+GENE\s+PRODUCT\.?.*',
	  '^HSPC\d+.*',
	  '^PRO\d+\s+PROTEIN\.?.*',
	  '^PRO\d+\.?.*',
	  '^FLJ\d+\s+PROTEIN.*',
	  '^PRED\d+\s+PROTEIN.*',
	  '^WUGSC:.*\s+PROTEIN\.?.*',
	  '^SIMILAR TO GENE.*',
	  '^SIMILAR TO PUTATIVE[ \.]',
	  '^SIMILAR TO HYPOTHETICAL.*',
	  '^SIMILAR TO (KIAA|LOC).*',
	  '^SIMILAR TO\s+$',
          '^WUGSC:H_.*',
          '^\s*\(?PROTEIN\)?\.?\s*$',
	  '^\s*\(?FRAGMENT\)?\.?\s*$',
          '^\s*\(?GENE\)?\.?\s*$',
	  '^\s*\(\s*\)\s*$',
          '^\s*\(\d*\)\s*[ \.]$');

}

1;
