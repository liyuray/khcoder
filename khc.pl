#!/usr/bin/perl
# khc -- a command line front end for KH Coder.
#
# Drives the same analysis engine as the Tk application, without a GUI, over
# the same SQLite projects. Every command can emit JSON (--json), so this
# doubles as the operation set a web front end would expose.
#
#   ./khc.pl projects
#   ./khc.pl new --target tutorial_jp/kokoro.xls --column 0 --name kokoro
#   ./khc.pl prep --project khc1
#   ./khc.pl stats --project khc1
#   ./khc.pl words --project khc1 --limit 20
#   ./khc.pl conc --project khc1 --query 先生
#   ./khc.pl doc  --project khc1 --id 2
#   ./khc.pl sql  --project khc1 "SELECT COUNT(*) FROM bun"

$| = 1;
use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use Cwd;

use vars qw($config_obj $project_obj);

BEGIN {
	use Jcode;
	push @INC, '.';
	eval { require Encode::Locale; };
	unshift @INC, cwd . '/kh_lib';

	require kh_headless;          # supplies gui_errormsg / gui_window / gui_wait
	kh_headless->import;

	require kh_sysconfig;
	# Config loading chatters on stdout, which would corrupt --json output.
	open(my $saved, '>&', \*STDOUT) or die;
	open(STDOUT, '>&', \*STDERR)    or die;
	$config_obj = kh_sysconfig->readin('./config/coder.ini', &cwd);
	open(STDOUT, '>&', $saved)      or die;

	$config_obj->web_if(1);       # the engine's own headless flag
	$config_obj->multi_threads(0);# no worker threads for a one-shot command
}

use kh_project;
use kh_projects;
use mysql_exec;
use mysql_words;
use mysql_conc;
use mysql_getdoc;
use mysql_ready;
use mysql_outvar;
use mysql_outvar::read;   # external-variable readers used when a project is built
use kh_cod;
use kh_cod::func;
use kh_cod::asso;
use mysql_crossout;
use mysql_crossout::r_com;
use kh_r_plot;
use mysql_getheader;
use kh_datacheck;
use mysql_morpho_check;
use mysql_nounphrases;
use mysql_hukugo;
use kh_dictio;
use kh_cod::pickup;
use mysql_getheader;
use plotR::network;
use plotR::som;
require kh_project_io;
use kh_morpho;
use my_threads;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# Arguments arrive as bytes. The engine compares against character data read
# from SQLite, so a Japanese query has to be decoded or it silently matches
# nothing.
use Encode ();
@ARGV = map { Encode::is_utf8($_) ? $_ : Encode::decode('UTF-8', $_) } @ARGV;

# R is started only when a command needs it (see need_r below).
$::config_obj->{R} = 0;
my_threads->init;

my %OPT = (json => 0, limit => 50, length => 20, column => 0,
           lang => 'jp', method => 'mecab', tani => 'bun');

#--------------------------------------------------#
#   helpers                                        #
#--------------------------------------------------#

sub emit {
	my $data = shift;
	if ($OPT{json}) {
		print _json($data), "\n";
	} else {
		_plain($data);
	}
}

# A small JSON writer, so the CLI adds no dependency.
sub _json {
	my $d = shift;
	if ( !defined $d )            { return 'null' }
	if ( ref $d eq 'ARRAY' )      { return '[' . join(',', map { _json($_) } @$d) . ']' }
	if ( ref $d eq 'HASH' )       {
		return '{' . join(',', map { _jstr($_) . ':' . _json($d->{$_}) } sort keys %$d) . '}'
	}
	if ( $d =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/ ) { return $d }
	return _jstr($d);
}
sub _jstr {
	my $s = shift;
	$s =~ s/(["\\])/\\$1/g;
	$s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; $s =~ s/\t/\\t/g;
	$s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord $1)/ge;
	return '"' . $s . '"';
}

# Render one cell, flattening a nested list or record rather than printing a
# reference.
sub _flat {
	my $v = shift;
	return '' unless defined $v;
	if ( ref $v eq 'ARRAY' ) { return join(' ', map { _flat($_) } @$v) }
	if ( ref $v eq 'HASH'  ) { return join(':', map { _flat($v->{$_}) } sort keys %$v) }
	return $v;
}

sub _plain {
	my $d = shift;
	if ( ref $d eq 'ARRAY' ) {
		foreach my $r (@$d) {
			print ref $r eq 'ARRAY' ? join("\t", map { _flat($_) } @$r) . "\n"
			    : ref $r eq 'HASH'  ? join("\t", map { "$_=" . _flat($r->{$_}) } sort keys %$r) . "\n"
			    :                     "$r\n";
		}
	} elsif ( ref $d eq 'HASH' ) {
		for my $k ( sort keys %$d ) {
			my $v = $d->{$k};
			if ( ref $v eq 'ARRAY' ) {
				# Render a nested list inline rather than as a reference.
				printf "%-24s %s\n", "$k:",
					join(', ', map { ref $_ eq 'ARRAY' ? join('/', map { $_ // '' } @$_)
					                                   : ( defined $_ ? $_ : '' ) } @$v);
			} else {
				printf "%-24s %s\n", "$k:", (defined $v ? $v : '');
			}
		}
	} else {
		print defined $d ? "$d\n" : "\n";
	}
}

sub die_usage {
	my $m = shift;
	print STDERR "khc: $m\n" if $m;
	print STDERR <<'USAGE';
usage: khc.pl <command> [options]

  projects                      list registered projects
  new --target FILE [--column N] [--name TEXT] [--lang jp] [--method mecab]
  prep   --project NAME         run pre-processing (morphological analysis)
  drop   --project NAME         remove a project, its database and working files
  check  --project NAME         check the target text (Pre-Processing menu)
  check-words --project NAME --query TEXT   how the tagger split a string
  phrases  --project NAME [--query T]       noun phrases (TermExtract)
  phrases-detect  --project NAME            run noun-phrase detection
  compounds --project NAME [--query T]      compound words (ChaSen)
  compounds-detect --project NAME           run compound detection
  dict   --project NAME [--pos-on P|--pos-off P]   words selected for analysis
  pickup --project NAME --rules FILE --out FILE [--code N]
                                            extract the text a rule matches
  headings --project NAME --out FILE [--tani h5]   headings for a unit
  settings                                  current configuration
  topics --project NAME [--topics K] [--limit N]   fit an LDA topic model
  archive --project NAME --out FILE.khc          export the whole project
  restore --archive FILE.khc --target FILE       import one back
  stats  --project NAME         the figures shown on the main window
  words  --project NAME [--limit N] [--query TEXT] [--mode p|c|k|z]
  conc   --project NAME --query WORD [--length N]
  doc    --project NAME --id N
  sql    --project NAME "SELECT ..."

  vars        --project NAME               list external variables and headings
  assoc       --project NAME --query WORD   word association
                [--mode and|or|code] [--sort fr|sa|hi]
  cod-freq    --project NAME --rules FILE   coding frequency
  cod-jaccard --project NAME --rules FILE   code similarity matrix
  cod-crosstab --project NAME --rules FILE --var NAME
  export      --project NAME --out FILE [--type def|1c|150] [--ftype csv|xls]

  plot   --project NAME --kind KIND --out FILE.png
                [--min N] [--max N] [--clusters N] [--dist binary|Dice|Simpson|pearson|euclid]

  --tani bun|dan|h1..h5         unit of aggregation (default bun)

  --json                        machine-readable output
USAGE
	exit($m ? 2 : 0);
}

# Open a registered project by dbname, or by position if a number is given.
sub open_project {
	my $want = shift;
	die_usage('--project is required') unless defined $want && length $want;
	my $list = kh_projects->read->list;
	die "khc: no projects are registered\n" unless @$list;
	my ($p) = grep { $_->{dbname} eq $want } @$list;
	($p) = grep { ($_->{comment} // '') eq $want } @$list unless $p;
	die "khc: no such project: $want\n" unless $p;
	kh_project->temp( target => $p->{target}, dbname => $p->{dbname} )->open;
	return $p;
}

# Coding rules come from a plain text file; the engine reads and parses it.
sub coding_rules {
	my $class = shift;
	die_usage('--rules FILE is required') unless $OPT{rules};
	die "khc: no such coding rule file: $OPT{rules}\n" unless -e $OPT{rules};
	my $obj = $class->read_file( $OPT{rules} )
		or die "khc: could not read the coding rules: $OPT{rules}\n";
	return $obj;
}

# Every part of speech the project is set to use. Both the word list and word
# association refuse to run with an empty selection, so this is the default the
# GUI offers.
# Start the R bridge. Only the plot commands need it, so it is not paid for
# by the tabular ones.
sub need_r {
	return $::config_obj->{R} if $::config_obj->{R};
	require Statistics::R;      # CPAN 0.34: a private R process per object
	my $dir = $::config_obj->{cwd} . '/config/R-bridge';
	mkdir $dir unless -d $dir;  # still where plot images and temp .r files go

	# No log_dir/tmp_dir: CPAN Statistics::R talks to R over IPC::Run rather
	# than through files in a shared directory, so there is nothing to collide
	# on and no lock.pid to go stale.
	$::config_obj->{R} = Statistics::R->new(
		r_bin => $::config_obj->os_path( $::config_obj->r_path ),
	) or die "khc: could not start R\n";
	$::config_obj->{R}->startR;
	$::config_obj->{R}->send('Sys.setlocale(category="LC_ALL",locale="ja_JP.UTF-8")');
	$::config_obj->{R}->read();
	$::config_obj->{R}->output_chk(1);
	# Statistics::R moves the process into its tmp_dir; the engine builds paths
	# relative to the project root, so go back, as kh_coder.pl does.
	chdir( $::config_obj->{cwd} );
	return $::config_obj->{R};
}

# The document-word matrix, as the R command that loads it.
sub data_matrix {
	my %a = @_;
	my $pos = used_pos();
	return mysql_crossout::r_com->new(
		tani     => $OPT{tani}, tani2 => $OPT{tani},
		hinshi   => [ sort { $a <=> $b } keys %$pos ],
		max      => ( $OPT{max}    // 0 ),
		min      => ( $OPT{min}    // 0 ),
		max_df   => ( $OPT{max_df} // 0 ),
		min_df   => ( $OPT{min_df} // 0 ),
		rownames => 0,
		sampling => 0,
		%a,
	)->run;
}

# A code-by-document matrix, as the R command that loads it, for the coding
# plots. kh_cod::func->out2r_selected writes the coded results in the same
# shape mysql_crossout::r_com produces for words.
sub code_matrix {
	my $cod = coding_rules('kh_cod::func');
	$cod->code( $OPT{tani} ) or die "khc: coding produced no result\n";
	my $codes = $cod->valid_codes;
	die "khc: need at least three codes for this plot\n" unless @$codes > 2;
	# out2r_selected selects by code NAME, not by index.
	my @sel = map { $_->name } @$codes;

	my $r = $cod->out2r_selected( $OPT{tani}, \@sel )
		or die "khc: could not build the code matrix\n";

	# Label the rows with the code names, as cod_cls does, dropping the
	# leading marker the coding file uses. The names are the ones captured
	# above: out2r_selected re-runs code(), which appends to valid_codes and
	# would otherwise leave twice as many names as the matrix has rows.
	$r .= "\nd <- t(d)\nrow.names(d) <- c(";
	$r .= join(',', map {
		my $n = $_;
		substr($n, 0, 1) = '' if index($n, '＊') == 0 || index($n, '*') == 0;
		kh_r_plot->quote($n);
	} @sel);
	$r .= ")\n";

	# cod_cls leaves the codes as rows; cod_corresp transposes back so they
	# are columns. The caller says which it wants.
	if ( ($_[0] // '') eq 'cols' ) {
		$r .= "d <- t(d)\n";
		return $r;
	}
	$r .= "d <- subset(d, rowSums(d) > 0)\n";
	$r .= "# END: DATA\n";
	return $r;
}

# The frequency-distribution plots build a small matrix themselves and hand it
# straight to kh_r_plot, with no window module in between.
# Emit an R matrix literal named "hoge" from selected columns of a result set,
# the shape the frequency-distribution windows use.
sub matrix_r {
	my ($rows, $cols) = @_;
	die "khc: no data for this plot\n" unless $rows && @$rows;
	my $n = scalar @$rows;
	my $t = 'hoge <- matrix( c(';
	$t .= join(',', map { my $r = $_; join(',', map { $r->[$_] // 0 } @$cols) } @$rows);
	$t .= "), nrow=$n, ncol=" . scalar(@$cols) . ", byrow=TRUE)\n";
	$t .= "# dpi: short based\n";
	return $t;
}

sub simple_plot {
	my (%a) = @_;
	my $plot = kh_r_plot->new(
		name      => $a{name},
		command_f => $a{command},
		( $a{width}  ? (width  => $a{width})  : () ),
		( $a{height} ? (height => $a{height}) : () ),
		font_size => ( $OPT{font_size} // 1 ),
	) or die "khc: the plot could not be produced\n";
	$plot->save( $OPT{out} );
	die "khc: nothing was written to $OPT{out}\n" unless -s $OPT{out};
	return $plot;
}

sub word_count {
	my $pos = used_pos();
	my $n = mysql_crossout::r_com->new(
		tani   => $OPT{tani}, tani2 => $OPT{tani},
		hinshi => [ sort { $a <=> $b } keys %$pos ],
		max    => ( $OPT{max}    // 0 ), min    => ( $OPT{min}    // 0 ),
		max_df => ( $OPT{max_df} // 0 ), min_df => ( $OPT{min_df} // 0 ),
	)->wnum;
	$n =~ s/,//g;
	return $n + 0;
}

sub used_pos {
	my %pos;
	my $h = mysql_exec->select("SELECT khhinshi_id FROM hselection WHERE ifuse = 1", 1)->hundle;
	while ( my $r = $h->fetch ) { $pos{ $r->[0] } = 1 }
	return \%pos;
}

sub _num { my $v = shift; return (defined $v && $v =~ /[0-9]/) ? $v + 0 : 0 }

sub one_value {
	my $sql = shift;
	my $h = mysql_exec->select($sql, 1)->hundle or return undef;
	my $r = $h->fetch or return undef;
	return $r->[0];
}

#--------------------------------------------------#
#   commands                                       #
#--------------------------------------------------#

my %CMD;

$CMD{projects} = sub {
	my $list = kh_projects->read->list;
	emit([ map { { dbname => $_->{dbname},
	               name   => $_->{comment} // '',
	               target => $_->{target} } } @$list ]);
};

$CMD{new} = sub {
	die_usage('--target is required') unless $OPT{target};
	die "khc: no such file: $OPT{target}\n" unless -e $OPT{target};

	require kh_spreadsheet;
	my $cols = ( $OPT{target} =~ /\.(xls|xlsx|csv|tsv)$/i )
	         ? kh_spreadsheet->new($OPT{target})->columns() : [];

	my $new = kh_project->new(
		target  => $OPT{target},
		comment => ( $OPT{name} // 'khc project' ),
	) or die "khc: could not create the project\n";

	$new->prepare_db;
	$::project_obj->morpho_analyzer( $OPT{method} );
	$::project_obj->morpho_analyzer_lang( $OPT{lang} );
	$::project_obj->read_hinshi_setting;
	$::project_obj->copy_and_convert_target_file(
		original    => $OPT{target},
		column      => $OPT{column},
		column_list => $cols,
		lang        => $OPT{lang},
	) or die "khc: could not read the target file\n";

	$new->{target} = $::config_obj->uni_path( $new->{target} );
	$new->{target} .= " [$cols->[ $OPT{column} ]]"
		if @$cols && length( $cols->[ $OPT{column} ] // '' );

	kh_projects->read->add_new($new, 'skip_db')
		or die "khc: could not register the project\n";
	$::project_obj->check_copied_and_converted;

	emit({ dbname  => $new->dbname,
	       name    => $new->comment,
	       columns => scalar(@$cols),
	       column  => $OPT{column},
	       db      => mysql_exec->db_path( $new->dbname ) });
};

$CMD{drop} = sub {
	my $want = $OPT{project};
	die_usage('--project is required') unless defined $want && length $want;
	my $projects = kh_projects->read;
	my $list = $projects->list;
	my ($i) = grep { $list->[$_]{dbname} eq $want
	              || ($list->[$_]{comment} // '') eq $want } 0 .. $#$list;
	die "khc: no such project: $want\n" unless defined $i;
	my $dbname = $list->[$i]{dbname};
	# Deliberately not opened: a project whose database is missing is exactly
	# the one that needs removing, and delete() only needs the registry row to
	# find the files.
	$projects->delete($i);
	emit({ dropped => $dbname });
};

$CMD{prep} = sub {
	open_project( $OPT{project} );

	# Pre-processing issues several hundred statements. With AutoCommit each
	# pays its own WAL commit; one transaction around the lot removes that.
	# --no-batch turns it off, which is what to use when diagnosing a failure,
	# since a rollback would otherwise discard the whole run.
	my $dbh = $::project_obj->dbh;
	my $batched = !$OPT{'no-batch'};
	$dbh->begin_work if $batched;

	my $ok = eval { mysql_ready->first };
	my $err = $@;
	if ($batched) { $ok && !$err ? $dbh->commit : $dbh->rollback }
	die "khc: pre-processing failed\n" . ($err // '') unless $ok && !$err;
	$::project_obj->status_morpho(1);
	$CMD{stats}->('reopened');
};

$CMD{stats} = sub {
	my $reopened = shift;
	my $p = $reopened ? undef : open_project( $OPT{project} );
	emit({
		project    => $::project_obj->dbname,
		name       => ( $p ? ($p->{comment} // '') : ($::project_obj->comment // '') ),
		tokens     => one_value("SELECT COUNT(*) FROM hyosobun") // 0,
		words      => one_value("SELECT COUNT(*) FROM genkei") // 0,
		used_words => one_value(
			"SELECT COUNT(*) FROM genkei, hselection
			 WHERE genkei.khhinshi_id = hselection.khhinshi_id
			   AND hselection.ifuse = 1 AND genkei.nouse = 0") // 0,
		sentences  => one_value("SELECT COUNT(*) FROM bun") // 0,
		paragraphs => one_value("SELECT COUNT(*) FROM dan") // 0,
		db         => mysql_exec->db_path( $::project_obj->dbname ),
	});
};

$CMD{words} = sub {
	open_project( $OPT{project} );

	my $pos = used_pos();
	mysql_words->search(
		# mode: p = contains, c = exact, k = ends with, z = starts with.
		query => ( $OPT{query} // '' ), method => 0, kihon => 0,
		katuyo => 0, mode => ( $OPT{mode} // 'p' ),
		filter => { hinshi => $pos }, hinshi => {},
	);

	my $rows = mysql_exec->select("
		SELECT genkei_name, hselection_name, genkei_num
		FROM word_search_temp ORDER BY id LIMIT $OPT{limit}
	", 1)->hundle->fetchall_arrayref;

	emit([ map { { word => $_->[0], pos => $_->[1], freq => $_->[2] + 0 } } @$rows ]);
};

$CMD{conc} = sub {
	die_usage('--query is required') unless defined $OPT{query} && length $OPT{query};
	open_project( $OPT{project} );

	my $c = mysql_conc->a_word(
		query => $OPT{query}, katuyo => '', hinshi => '', tuika => {},
		# sort1..3 name the column to order by ('id' means document order,
		# 'l1'/'r1' the neighbouring word); anything else builds a join.
		length => $OPT{length}, sort1 => 'id', sort2 => 'id', sort3 => 'id',
		tani => 'bun',
	);
	die "khc: no concordance results\n" unless ref $c;

	# _format($start) yields the KWIC rows: [ left, hit, right ].
	my @rows;
	my $start = 0;
	while ( @rows < $OPT{limit} ) {
		my $page = $c->_format($start) or last;
		last unless @$page;
		push @rows, @$page;
		$start += scalar @$page;
	}
	splice(@rows, $OPT{limit}) if @rows > $OPT{limit};

	emit([ map { { left  => ( $_->[0] // '' ),
	               hit   => ( $_->[1] // '' ),
	               right => ( $_->[2] // '' ) } } grep { ref } @rows ]);
};

$CMD{doc} = sub {
	die_usage('--id is required') unless defined $OPT{id};
	open_project( $OPT{project} );
	my $d = mysql_getdoc->get( doc_id => $OPT{id}, tani => 'bun' );
	emit({
		id   => $OPT{id},
		seq  => $d->doc_seq,
		next => $d->id_next,
		text => join('', map { $_->[0] } @{ $d->body || [] }),
	});
};

$CMD{vars} = sub {
	open_project( $OPT{project} );
	my $rows = mysql_outvar->get_list;
	emit([ map { { tani => $_->[0], name => $_->[1], id => $_->[2] + 0 } } @{ $rows || [] } ]);
};

$CMD{'cod-freq'} = sub {
	open_project( $OPT{project} );
	my $r = coding_rules('kh_cod::func')->count( $OPT{tani} )
		or die "khc: coding produced no result\n";
	# [ name, count, percent ] per code, with a total row appended by the engine.
	# The engine appends a document-count row whose percent cell is blank.
	emit([ map { { code    => $_->[0],
	               n       => _num($_->[1]),
	               percent => _num($_->[2]) } } @{$r} ]);
};

$CMD{'cod-jaccard'} = sub {
	open_project( $OPT{project} );
	my $r = coding_rules('kh_cod::func')->jaccard( $OPT{tani} )
		or die "khc: need at least two codes for a similarity matrix\n";
	emit($r);   # first row is the header
};

$CMD{'cod-crosstab'} = sub {
	open_project( $OPT{project} );
	die_usage('--var is required (see: khc.pl vars)') unless defined $OPT{var};

	# Resolve the variable name to its id.
	my $id = $OPT{var};
	unless ( $id =~ /^[0-9]+$/ ) {
		my ($m) = grep { $_->[1] eq $OPT{var} } @{ mysql_outvar->get_list || [] };
		die "khc: no such variable: $OPT{var}\n" unless $m;
		$id = $m->[2];
	}
	my $r = coding_rules('kh_cod::func')->outtab( $OPT{tani}, $id, 0 )
		or die "khc: crosstab produced no result\n";
	# outtab returns { display, plot, t_rsd }; display is the table the GUI shows.
	emit( ref $r eq 'HASH' ? ( $r->{display} // $r ) : $r );
};

$CMD{assoc} = sub {
	die_usage('--query is required') unless defined $OPT{query} && length $OPT{query};
	open_project( $OPT{project} );

	# The query goes in as a "direct" code, which lands at index 0; asso() is
	# then told to use that one code.
	my $cod = kh_cod::asso->new;
	$cod->add_direct( mode => ( $OPT{mode} // 'or' ), raw => $OPT{query} );
	my $ok = $cod->asso(
		selected => [0],
		tani     => $OPT{tani},
		method   => ( $OPT{method} // 'or' ),
	) or die "khc: word association produced no result\n";

	# order: fr = frequency, sa = difference in proportion, hi = ratio (lift)
	my $r = $ok->fetch_results(
		order  => ( $OPT{sort} // 'hi' ),
		filter => { limit     => $OPT{limit},
		            min_doc   => ( $OPT{min_doc} // 1 ),
		            show_lowc => 0,
		            hinshi    => used_pos() },
	);
	emit([ map { { word     => $_->[0],
	               pos      => $_->[1],
	               docs     => _num($_->[2]),
	               global_p => _num($_->[3]),
	               hits     => _num($_->[4]),
	               cond_p   => _num($_->[5]),
	               score    => _num($_->[6]) } } @{ $r || [] } ]);
};

$CMD{export} = sub {
	open_project( $OPT{project} );
	die_usage('--out FILE is required') unless $OPT{out};
	# word_list_custom dispatches to "_out_file_<ftype>_<type>", and this
	# snapshot only defines _out_file_xls_150, _out_file_xls and _out_file_csv.
	# The writer is therefore chosen here rather than by that name.
	my $type  = $OPT{type}  // 'def';       # def | 1c | 150
	my $ftype = $OPT{ftype} // 'csv';       # csv | xls

	my $self = bless { type => $type, ftype => $ftype, tani => $OPT{tani},
	                   num => ( $OPT{num} // 'tf' ) }, 'mysql_words';
	my $make = "_make_wl_$type";
	die "khc: unknown --type $type (def, 1c or 150)\n"
		unless mysql_words->can($make);
	my $table = $self->$make;

	my $writer = ( $ftype eq 'xls' && $type eq '150' ) ? '_out_file_xls_150'
	           : ( $ftype eq 'xls' )                   ? '_out_file_xls'
	           :                                         '_out_file_csv';
	my $tmp = $self->$writer($table);
	die "khc: the writer produced nothing\n" unless $tmp && -e $tmp;

	require File::Copy;
	File::Copy::copy($tmp, $OPT{out})
		or die "khc: could not write $OPT{out}: $!\n";
	emit({ written => $OPT{out}, rows => scalar(@{ $table || [] }) });
};

# Plot kinds. A spec either names a window module whose package-level
# make_plot builds the plot, or an engine-side plot class (plotR::*).
#
# Two kinds are deliberately absent because they do not terminate here:
#   som      - plotR::som never returns after the data matrix is built, even
#              with the training rounds cut to 20/40.
#   cod-netg - plotR::network on a code matrix hangs the same way, at any
#              edge count. The word-level "network" kind works.
# Both need investigation before they can be offered.
#
# Note: plots on one project cannot run concurrently. kh_r_plot names its
# working files by project in config/R-bridge/, so two at once collide and
# both stall.
my %PLOT = (
	cls => {
		module => 'gui_window::word_cls',
		build  => sub {
			my $r = data_matrix();
			$r .= "d <- t(d)\n# END: DATA\n";
			return ( r_command => $r, plotwin_name => 'word_cls',
			         cluster_number => ( $OPT{clusters} // 'auto' ),
			         cluster_color  => 1,
			         # Jaccard=binary, Dice, Simpson, Cosine=pearson, Euclid=euclid
			         method_dist    => ( $OPT{dist}   // 'binary' ),
			         method_mthd    => ( $OPT{clust}  // 'ward' ) );
		},
	},
	corresp => {
		module => 'gui_window::word_corresp',
		size   => 800,
		build  => sub {
			my $r = data_matrix();
			$r .= "d <- t(d)\n";
			$r .= "d <- subset(d, rowSums(d) > 0)\n";
			$r .= "d <- t(d)\n";
			# corresp.matrix rejects an all-zero row or column, so drop both.
			$r .= "d <- d[rowSums(d) > 0, , drop=FALSE]\n";
			$r .= "d <- d[, colSums(d) > 0, drop=FALSE]\n";
			# word_corresp's own prep declares this before the plot code; it
			# counts the external-variable groups drawn alongside the words,
			# and none are included here.
			$r .= "v_count <- 0\n";
			$r .= "# END: DATA\n";
			return ( r_command => $r, plotwin_name => 'word_corresp',
			         d_x => ( $OPT{x} // 1 ), d_y => ( $OPT{y} // 2 ),
			         show_origin => 1, scaling => 0, zoom => 1,
			         biplot => 0, flt => 0, flw => 0,
			         bubble => 0, bubble_size => 1, resize_vars => 0,
			         breaks => 0, use_alpha => 1,
			         margin_top => 0, margin_bottom => 0,
			         margin_left => 0, margin_right => 0,
			         width  => ( $OPT{size} // 800 ),
			         height => ( $OPT{size} // 800 ) );
		},
	},
	network => {
		module => 'plotR::network',
		class  => 'plotR::network',
		size   => 800,
		build  => sub {
			my $r = data_matrix();
			$r .= "d <- t(d)\n# END: DATA\n";
			return ( r_command => $r, plotwin_name => 'word_netgraph',
			         # n = draw the strongest N edges, j = threshold on the coefficient
			         n_or_j       => ( $OPT{edge_mode} // 'n' ),
			         edges_num    => ( $OPT{edges} // 60 ),
			         edges_jac    => ( $OPT{edge_min} // 0.2 ),
			         method_coef  => ( $OPT{coef} // 'binary' ),
			         line_width   => 100, line_width_n => 100,
			         margin_top   => 0, margin_bottom => 0,
			         margin_left  => 0, margin_right  => 0,
			         use_freq_as_size => 1, bubble_size => 1,
			         smaller_nodes => 0, use_weight_as_width => 1,
			         min_sp_tree => 0, min_sp_tree_only => 0,
			         use_alpha => 1, gray_scale => 0, fix_lab => 0,
			         view_coef => 0, cor_var => 0, cor_var_darker => 0,
			         cor_var_min => -1, cor_var_max => 1,
			         standardize_coef => 0, additional_plots => 0, breaks => 0 );
		},
	},
	# The coding plots reuse the word_* builders, with a code-by-document
	# matrix in place of the word-by-document one.
	'cod-cls' => {
		module => 'gui_window::word_cls',
		count  => sub { scalar @{ coding_rules('kh_cod::func')->codes } },
		build  => sub {
			my $r = code_matrix();
			return ( r_command => $r, plotwin_name => 'word_cls',
			         cluster_number => ( $OPT{clusters} // 'auto' ),
			         cluster_color  => 1,
			         method_dist    => ( $OPT{dist}  // 'binary' ),
			         method_mthd    => ( $OPT{clust} // 'ward' ) );
		},
	},
	'cod-mds' => {
		module => 'gui_window::word_mds',
		size   => 800,
		count  => sub { scalar @{ coding_rules('kh_cod::func')->codes } },
		build  => sub {
			my $r = code_matrix();
			return ( r_command => $r, plotwin_name => 'word_mds',
			         method => ( $OPT{mds} // 'K' ),
			         method_dist => ( $OPT{dist} // 'binary' ),
			         dim_number => ( $OPT{dim} // 2 ),
			         bubble => 0, bubble_size => 1, n_cls => 0, cls_raw => '',
			         fix_asp => 1, use_alpha => 1, random_starts => 0,
			         breaks => 0, bubble_var => '', std_radius => 0,
			         margin_top => 0, margin_bottom => 0,
			         margin_left => 0, margin_right => 0,
			         width => ( $OPT{size} // 800 ), height => ( $OPT{size} // 800 ) );
		},
	},
	'cod-corresp' => {
		module => 'gui_window::word_corresp',
		size   => 800,
		count  => sub { scalar @{ coding_rules('kh_cod::func')->codes } },
		build  => sub {
			# cod_corresp trims empty rows on both axes, as here.
			my $r = code_matrix('cols');
			$r .= "d <- subset(d, rowSums(d) > 0)\n";
			$r .= "d <- t(d)\n";
			$r .= "d <- subset(d, rowSums(d) > 0)\n";
			$r .= "d <- t(d)\n";
			$r .= "v_count <- 0\n";
			return ( r_command => $r, plotwin_name => 'word_corresp',
			         d_x => ( $OPT{x} // 1 ), d_y => ( $OPT{y} // 2 ),
			         show_origin => 1, scaling => 0, zoom => 1,
			         biplot => 0, flt => 0, flw => 0,
			         bubble => 0, bubble_size => 1, resize_vars => 0,
			         breaks => 0, use_alpha => 1,
			         margin_top => 0, margin_bottom => 0,
			         margin_left => 0, margin_right => 0,
			         width => ( $OPT{size} // 800 ), height => ( $OPT{size} // 800 ) );
		},
	},
	som => {
		module => 'plotR::som',
		class  => 'plotR::som',
		size   => 800,
		build  => sub {
			my $r = data_matrix();
			$r .= "d <- t(d)\n# END: DATA\n";
			return ( r_command => $r, plotwin_name => 'word_som',
			         # n_nodes is the side of a square grid, so the map has
			         # n_nodes^2 cells. The GUI defaults to 20 (400 cells);
			         # anything much larger takes hours.
			         n_nodes => ( $OPT{nodes} // 20 ),
			         if_cls  => 1,
			         n_cls   => ( $OPT{clusters} && $OPT{clusters} ne 'auto'
			                      ? $OPT{clusters} : 5 ),
			         p_topo  => 'hx',          # 'hx' or anything else = rectangular
			         rlen1   => ( $OPT{rlen1} // 100 ),
			         rlen2   => ( $OPT{rlen2} // 200 ),
			         reuse   => 0 );
		},
	},
	'cod-netg' => {
		module => 'plotR::network',
		class  => 'plotR::network',
		size   => 800,
		count  => sub { scalar @{ coding_rules('kh_cod::func')->codes } },
		build  => sub {
			# Codes must be the ROWS: they are the network's nodes. Leaving
			# the documents as rows asks for a graph over every document.
			my $r = code_matrix();
			return ( r_command => $r, plotwin_name => 'cod_netg',
			         n_or_j       => ( $OPT{edge_mode} // 'n' ),
			         edges_num    => ( $OPT{edges} // 60 ),
			         edges_jac    => ( $OPT{edge_min} // 0.2 ),
			         method_coef  => ( $OPT{coef} // 'binary' ),
			         line_width   => 100, line_width_n => 100,
			         margin_top   => 0, margin_bottom => 0,
			         margin_left  => 0, margin_right  => 0,
			         use_freq_as_size => 1, bubble_size => 1,
			         smaller_nodes => 0, use_weight_as_width => 1,
			         min_sp_tree => 0, min_sp_tree_only => 0,
			         use_alpha => 1, gray_scale => 0, fix_lab => 0,
			         view_coef => 0, cor_var => 0, cor_var_darker => 0,
			         cor_var_min => -1, cor_var_max => 1,
			         standardize_coef => 0, additional_plots => 0, breaks => 0 );
		},
	},
	'cod-som' => {
		module => 'plotR::som',
		class  => 'plotR::som',
		size   => 800,
		count  => sub { scalar @{ coding_rules('kh_cod::func')->codes } },
		build  => sub {
			my $r = code_matrix();
			return ( r_command => $r, plotwin_name => 'cod_som',
			         n_nodes => ( $OPT{nodes} // 20 ),
			         if_cls  => 1,
			         n_cls   => ( $OPT{clusters} && $OPT{clusters} ne 'auto'
			                      ? $OPT{clusters} : 3 ),
			         p_topo  => 'hx',
			         rlen1   => ( $OPT{rlen1} // 100 ),
			         rlen2   => ( $OPT{rlen2} // 200 ),
			         reuse   => 0 );
		},
	},
	# --- frequency distributions: built and drawn here, no window module ---
	'tf-dist' => {
		direct => sub {
			my ($r1, $r2) = mysql_words->freq_of_f;
			my $m = matrix_r( $r2, [0,3,1] );
			simple_plot( name => 'words_TF_freq1', command => $m
				. 'plot(hoge[,1],hoge[,3],type="b",bty="l",lty=1,pch=1,'
				. 'ylab="frequency", xlab="term frequency")' );
			return scalar @{ $r2 || [] };
		},
	},
	'df-dist' => {
		direct => sub {
			my ($r1, $r2) = mysql_words->freq_of_df( $OPT{tani} );
			my $m = matrix_r( $r2, [0,3,1] );
			simple_plot( name => 'words_DF_freq1', command => $m
				. 'plot(hoge[,1],hoge[,3],type="b",bty="l",lty=1,pch=1,'
				. 'ylab="frequency", xlab="document frequency")' );
			return scalar @{ $r2 || [] };
		},
	},
	'tf-df' => {
		direct => sub {
			my $h = mysql_exec->select("
				select num, f, genkei.name
				from genkei, hselection, df_$OPT{tani}
				where genkei.khhinshi_id = hselection.khhinshi_id
				  and genkei.id = df_$OPT{tani}.genkei_id
				  and genkei.nouse = 0
				  and hselection.ifuse = 1
			",1)->hundle;
			my @rows;
			while ( my $i = $h->fetch ) { push @rows, [ $i->[0], $i->[1] ] }
			my $m = matrix_r( \@rows, [0,1] );
			simple_plot( name => 'words_TF_DF1', command => $m
				. 'plot(hoge[,1],hoge[,2],bty="l",'
				. 'ylab="document frequency", xlab="term frequency")' );
			return scalar @rows;
		},
	},
	'topic-n' => {
		module => 'gui_window::topic_perplexity',
		size   => 800,
		build  => sub {
			my $r = data_matrix();
			$r .= "# END: DATA\n";
			return ( r_command => $r, plotwin_name => 'topic_n_perplexity',
			         method     => ( $OPT{topic_method} // 'perplexity' ),
			         fold       => ( $OPT{folds} // 5 ),
			         candidates => ( $OPT{candidates} // 10 ) );
		},
	},
	mds => {
		module => 'gui_window::word_mds',
		size   => 800,
		build  => sub {
			my $r = data_matrix();
			$r .= "d <- t(d)\n# END: DATA\n";
			return ( r_command => $r, plotwin_name => 'word_mds',
			         # K = Kruskal, C = Classical (SMACOF is not installed)
			         method        => ( $OPT{mds}  // 'K' ),
			         method_dist   => ( $OPT{dist} // 'binary' ),
			         dim_number    => ( $OPT{dim}  // 2 ),
			         bubble        => 0, bubble_size => 1,
			         n_cls         => ( $OPT{clusters} && $OPT{clusters} ne 'auto'
			                            ? $OPT{clusters} : 0 ),
			         cls_raw       => '',
			         fix_asp       => 1,
			         use_alpha     => 1,
			         random_starts => 0,
			         # make_plot also reads these; the GUI supplies them from
			         # its margin and bubble widgets.
			         breaks        => 0, bubble_var => '', std_radius => 0,
			         margin_top    => 0, margin_bottom => 0,
			         margin_left   => 0, margin_right  => 0,
			         width         => ( $OPT{size} // 800 ),
			         height        => ( $OPT{size} // 800 ) );
		},
	},
);

$CMD{check} = sub {
	open_project( $OPT{project} );
	# kh_datacheck reports its verdict -- including "nothing wrong" -- through
	# the message dialog, so that must not be fatal here.
	local $kh_headless::DIE_ON_ERROR = 0;
	my $r = kh_datacheck->run or die "khc: the data check produced no report\n";
	emit({ summary => ( $r->{repo_sum}  // '' ),
	       report  => ( $r->{repo_full} // '' ),
	       clean   => ( $r->{auto_ok} ? 1 : 0 ) });
};

$CMD{archive} = sub {
	open_project( $OPT{project} );
	die_usage('--out FILE is required (a .khc archive)') unless $OPT{out};
	kh_project_io::export( $OPT{out} ) or die "khc: export failed\n";
	die "khc: nothing was written to $OPT{out}\n" unless -s $OPT{out};
	emit({ written => $OPT{out}, bytes => -s $OPT{out} });
};

$CMD{restore} = sub {
	die_usage('--archive FILE is required') unless $OPT{archive};
	die "khc: no such archive: $OPT{archive}\n" unless -e $OPT{archive};
	die_usage('--target FILE is required (where the source text is restored to)')
		unless $OPT{target};
	# import() ends with "undef $::project_obj", so its return value says
	# nothing; the registry is what confirms the project arrived.
	kh_project_io::import( $OPT{archive}, $OPT{target} );

	my ($new) = grep { $_->{target} =~ /\Q$OPT{target}\E/ }
	                 @{ kh_projects->read->list };
	die "khc: the archive did not restore\n" unless $new;
	emit({ project => $new->{dbname}, target => $OPT{target},
	       db => mysql_exec->db_path( $new->{dbname} ) });
};

$CMD{'check-words'} = sub {
	die_usage('--query is required') unless defined $OPT{query} && length $OPT{query};
	open_project( $OPT{project} );
	# How a given string was actually split by the tagger.
	my $r = mysql_morpho_check->search( query => $OPT{query} )
		or die "khc: no result for that query\n";
	emit($r);
};

$CMD{phrases} = sub {
	open_project( $OPT{project} );
	# Noun phrases (TermExtract). With no --query the engine returns the
	# highest scoring ones.
	die "khc: nothing detected yet -- run 'phrases-detect --project ...' first\n"
		unless mysql_exec->table_exists('noun_phrases');
	my $r = mysql_nounphrases->search( query => ( $OPT{query} // '' ) )
		or die "khc: no results\n";
	$r = [ @$r[ 0 .. $OPT{limit} - 1 ] ] if @$r > $OPT{limit};
	emit($r);
};

$CMD{'phrases-detect'} = sub {
	open_project( $OPT{project} );
	mysql_nounphrases->detect;
	emit({ ok => 1 });
};

$CMD{compounds} = sub {
	open_project( $OPT{project} );
	# Compound words found by ChaSen.
	die "khc: nothing detected yet -- run 'compounds-detect --project ...' first\n"
		unless mysql_exec->table_exists('hukugo');
	my $r = mysql_hukugo->search( query => ( $OPT{query} // '' ) )
		or die "khc: no results\n";
	$r = [ @$r[ 0 .. $OPT{limit} - 1 ] ] if @$r > $OPT{limit};
	emit($r);
};

$CMD{'compounds-detect'} = sub {
	open_project( $OPT{project} );
	mysql_hukugo->run_from_morpho;
	emit({ ok => 1 });
};

$CMD{dict} = sub {
	open_project( $OPT{project} );
	my $d = kh_dictio->readin or die "khc: could not read the dictionary\n";

	# Toggling a part of speech: --pos-on 名詞 / --pos-off 動詞
	if ( defined $OPT{'pos-on'} or defined $OPT{'pos-off'} ) {
		my ($name, $val) = defined $OPT{'pos-on'}
			? ( $OPT{'pos-on'}, 1 ) : ( $OPT{'pos-off'}, 0 );
		die "khc: no such part of speech: $name\n"
			unless exists $d->{usethis}{$name};
		$d->{usethis}{$name} = $val;
		$d->save;
		$d = kh_dictio->readin;
	}

	emit({
		pos_in_use => [ grep {  $d->{usethis}{$_} } @{ $d->{hinshilist} || [] } ],
		pos_off    => [ grep { !$d->{usethis}{$_} } @{ $d->{hinshilist} || [] } ],
		force_pick => ( $d->words_mk || [] ),
		stop_words => ( $d->words_st || [] ),
	});
};

$CMD{pickup} = sub {
	die_usage('--rules FILE is required') unless $OPT{rules};
	die_usage('--out FILE is required') unless $OPT{out};
	open_project( $OPT{project} );

	# Write out the parts of the text that one coding rule matches.
	my $cod = coding_rules('kh_cod::pickup');
	my $codes = $cod->codes or die "khc: the rule file defines no codes\n";
	my $n = $OPT{code} // 0;
	die "khc: --code $n is out of range (0.." . $#$codes . ")\n"
		if $n < 0 || $n > $#$codes;

	$cod->pick(
		selected => $n,
		tani     => $OPT{tani},
		file     => $OPT{out},
		pick_hi  => ( $OPT{with_headings} ? 1 : 0 ),
	) or die "khc: nothing matched\n";
	die "khc: nothing was written to $OPT{out}\n" unless -s $OPT{out};
	emit({ written => $OPT{out}, code => $codes->[$n]->name,
	       bytes => -s $OPT{out} });
};

$CMD{headings} = sub {
	open_project( $OPT{project} );
	# The headings that delimit the chosen unit -- what "Texts in Arbitrary
	# Units" exports alongside the text.
	die_usage('--out FILE is required') unless $OPT{out};
	# pic_head picks which heading levels to emit; default to all five.
	my %levels = map { $_ => 1 } ( $OPT{levels} ? split(/,/, $OPT{levels}) : qw(h1 h2 h3 h4 h5) );
	mysql_getheader->get_all( file => $OPT{out}, pic_head => \%levels );
	die "khc: nothing was written to $OPT{out}\n" unless -s $OPT{out};
	emit({ written => $OPT{out}, bytes => -s $OPT{out} });
};

$CMD{settings} = sub {
	# The Project > Settings screen, read-only.
	my @keys = qw(c_or_j last_lang last_method mecabrc_path mecab_unicode
	              msg_lang use_hukugo multi_threads r_path private_dir
	              font_plot font_plot_cn font_plot_kr sqllog);
	my %out;
	for my $k (@keys) {
		next unless $::config_obj->can($k);
		my $v = eval { $::config_obj->$k };
		$out{$k} = defined $v ? "$v" : '';
	}
	$out{sqlite_version} = mysql_exec->version_number // '';
	emit(\%out);
};

$CMD{topics} = sub {
	open_project( $OPT{project} );
	need_r();
	$::config_obj->web_if(0);

	my $k = $OPT{topics} // 5;
	my $pos = used_pos();

	# not_word_but_id keeps the matrix columns addressable by word id, which is
	# how topic_fitting maps terms back to names.
	my $data = mysql_crossout::r_com->new(
		tani     => $OPT{tani}, tani2 => $OPT{tani},
		hinshi   => [ sort { $a <=> $b } keys %$pos ],
		max      => ( $OPT{max}    // 0 ), min    => ( $OPT{min}    // 0 ),
		max_df   => ( $OPT{max_df} // 0 ), min_df => ( $OPT{min_df} // 0 ),
		rownames => 0, sampling => 0,
		not_word_but_id => 1,
	);
	my $r = $data->run;
	my %names = %{ $data->{wName} || {} };

	my $terms = $::config_obj->{cwd} . '/config/R-bridge/'
	          . $::project_obj->dbname . '_topicTM';
	unlink $terms if -e $terms;

	$r .= "\n# END: DATA\n";
	$r .= "\ndtm <- d\nrownames(dtm) <- 1:nrow(dtm)\n";
	$r .= "dtm <- dtm[rowSums(dtm) > 0,]\n";
	$r .= "library(topicmodels)\n";
	$r .= "result_lda <- topicmodels::LDA(dtm, k = $k, method = \"Gibbs\","
	    . " control = list(seed = 1234567, burnin = 1000))\n";
	$r .= 'write.table(posterior(result_lda)$terms, file = "'
	    . $::config_obj->uni_path($terms)
	    . '", fileEncoding="UTF-8", sep="\t", quote=F, col.names=NA )' . "\n";

	$::config_obj->{R}->send($r);
	my $msg = $::config_obj->{R}->read;
	die "khc: fitting the topic model failed\n$msg\n" unless -s $terms;

	# posterior()$terms is topics x terms; report the strongest words per topic.
	open(my $fh, '<:encoding(UTF-8)', $terms) or die "khc: cannot read $terms\n";
	my $head = <$fh>;
	chomp $head;
	my @ids = split /\t/, $head;
	shift @ids;                       # leading empty corner cell
	my @out;
	while ( my $line = <$fh> ) {
		chomp $line;
		my @f = split /\t/, $line;
		my $topic = shift @f;
		my @rank = sort { $f[$b] <=> $f[$a] } 0 .. $#f;
		splice(@rank, $OPT{limit} > 20 ? 20 : $OPT{limit});
		push @out, {
			topic => $topic + 0,
			words => [ map { { word => ( $names{ $ids[$_] } // $ids[$_] ),
			                   p    => sprintf('%.5f', $f[$_]) } } @rank ],
		};
	}
	close $fh;
	emit(\@out);
};

$CMD{plot} = sub {
	die_usage('--out FILE is required') unless $OPT{out};
	my $kind = $OPT{kind} // 'cls';
	my $spec = $PLOT{$kind}
		or die "khc: unknown --kind $kind (have: " . join(', ', sort keys %PLOT) . ")\n";

	open_project( $OPT{project} );
	need_r();

	if ( $spec->{direct} ) {
		$::config_obj->web_if(0);
		my $n = $spec->{direct}->();
		emit({ written => $OPT{out}, kind => $kind, words => $n,
		       bytes => -s $OPT{out} });
		return;
	}

	eval "require $spec->{module}; 1" or die "khc: $@";

	# web_if suppresses interactive canvas work, but in plotR::network and
	# plotR::som it also skips building the plots themselves. Nothing here
	# creates a Tk window -- the display step is stubbed below -- so it is
	# turned off for the duration of the plot.
	$::config_obj->web_if(0);

	# The number of things being plotted: words for the word_* plots, codes
	# for the coding ones. It drives the automatic cluster count.
	my $n = $spec->{count} ? $spec->{count}->() : word_count();
	die "khc: only $n items pass the filters; need at least 3\n" if $n < 3;

	my %build = $spec->{build}->();
	my $win   = $build{plotwin_name};

	# make_plot ends by opening the Tk window that displays the result. The
	# image itself is already on disk by then, so the display step is stubbed
	# out and the file picked up afterwards.
	{
		no strict 'refs';
		no warnings 'redefine';
		*{"gui_window::r_plot::${win}::open"} = sub { return 1 };
	}

	my @common = (
		font_size   => ( $OPT{font_size} // 1 ),
		font_bold   => 0,
		plot_size   => ( $OPT{size} // $spec->{size} // 'auto' ),
		data_number => $n,
	);

	if ( $spec->{class} ) {
		# Engine-side builders (plotR::*) hand back the plot objects, and
		# kh_r_plot::save re-renders one to a path of our choosing.
		my $built = $spec->{class}->new( %build, @common )
			or die "khc: the plot could not be produced\n";
		my $plot = $built->{result_plots}
			? $built->{result_plots}[ $OPT{plot_index} // 0 ]
			: undef;
		die "khc: the builder returned no plot\n" unless $plot;
		$plot->save( $OPT{out} );
		die "khc: nothing was written to $OPT{out}\n" unless -s $OPT{out};
		emit({ written => $OPT{out}, kind => $kind, words => $n,
		       bytes => -s $OPT{out} });
		return;
	} else {
		no strict 'refs';
		my $make = $spec->{module} . '::make_plot';
		&$make( %build, @common )
			or die "khc: the plot could not be produced\n";
	}

	my $src = $::config_obj->{cwd} . '/config/R-bridge/'
	        . $::project_obj->dbname . '_' . $win . '_1.png';
	die "khc: R produced no image at $src\n" unless -s $src;

	require File::Copy;
	File::Copy::copy($src, $OPT{out}) or die "khc: could not write $OPT{out}: $!\n";
	emit({ written => $OPT{out}, kind => $kind, words => $n,
	       bytes => -s $OPT{out} });
};

$CMD{sql} = sub {
	my $sql = shift;
	die_usage('a SQL statement is required') unless defined $sql && length $sql;
	open_project( $OPT{project} );
	if ( $sql =~ /^\s*select\b/i ) {
		emit( mysql_exec->select($sql, 1)->hundle->fetchall_arrayref );
	} else {
		mysql_exec->do($sql, 1);
		emit({ ok => 1 });
	}
};

#--------------------------------------------------#
#   dispatch                                       #
#--------------------------------------------------#

my @argv = @ARGV;
my $cmd  = shift @argv;
die_usage() unless defined $cmd;
die_usage("unknown command: $cmd") unless $CMD{$cmd};

GetOptionsFromArray(\@argv, \%OPT,
	'project=s', 'target=s', 'name=s', 'query=s',
	'limit=i', 'length=i', 'column=i', 'id=i',
	'lang=s', 'method=s', 'mode=s', 'json',
	'rules=s', 'tani=s', 'var=s', 'out=s', 'type=s', 'ftype=s', 'sort=s', 'min_doc=i', 'num=s',
	'kind=s', 'clusters=s', 'dist=s', 'clust=s', 'size=s', 'font_size=f',
	'mds=s', 'dim=i', 'x=i', 'y=i', 'archive=s', 'edges=i', 'edge_mode=s', 'edge_min=f', 'coef=s', 'plot_index=i', 'nodes=i', 'rlen1=i', 'rlen2=i',
	'topic_method=s', 'folds=i', 'candidates=i', 'topics=i',
	'pos-on=s', 'pos-off=s', 'levels=s', 'code=i', 'with_headings', 'no-batch',
	'max=i', 'min=i', 'max_df=i', 'min_df=i',
) or die_usage('bad options');

eval { $CMD{$cmd}->(@argv); 1 } or do {
	my $e = $@ || 'failed';
	print STDERR $e =~ /\n$/ ? $e : "$e\n";
	exit 1;
};
exit 0;
