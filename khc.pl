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
use kh_morpho;
use my_threads;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# Arguments arrive as bytes. The engine compares against character data read
# from SQLite, so a Japanese query has to be decoded or it silently matches
# nothing.
use Encode ();
@ARGV = map { Encode::is_utf8($_) ? $_ : Encode::decode('UTF-8', $_) } @ARGV;

# R is only needed for plots; the CLI does not draw any.
$::config_obj->{R} = 0;
my_threads->init;

my %OPT = (json => 0, limit => 50, length => 20, column => 0,
           lang => 'jp', method => 'mecab');

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

sub _plain {
	my $d = shift;
	if ( ref $d eq 'ARRAY' ) {
		foreach my $r (@$d) {
			print ref $r eq 'ARRAY' ? join("\t", map { defined $_ ? $_ : '' } @$r) . "\n"
			    : ref $r eq 'HASH'  ? join("\t", map { "$_=" . (defined $r->{$_} ? $r->{$_} : '') } sort keys %$r) . "\n"
			    :                     "$r\n";
		}
	} elsif ( ref $d eq 'HASH' ) {
		printf "%-24s %s\n", "$_:", (defined $d->{$_} ? $d->{$_} : '') for sort keys %$d;
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
  stats  --project NAME         the figures shown on the main window
  words  --project NAME [--limit N] [--query TEXT] [--mode p|c|k|z]
  conc   --project NAME --query WORD [--length N]
  doc    --project NAME --id N
  sql    --project NAME "SELECT ..."

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
	mysql_ready->first or die "khc: pre-processing failed\n";
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

	# Every part of speech the project is set to use, which is what the
	# Frequency List window offers by default.
	my %pos;
	my $h = mysql_exec->select("SELECT khhinshi_id FROM hselection WHERE ifuse = 1", 1)->hundle;
	while ( my $r = $h->fetch ) { $pos{ $r->[0] } = 1 }

	mysql_words->search(
		# mode: p = contains, c = exact, k = ends with, z = starts with.
		query => ( $OPT{query} // '' ), method => 0, kihon => 0,
		katuyo => 0, mode => ( $OPT{mode} // 'p' ),
		filter => { hinshi => \%pos }, hinshi => {},
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
) or die_usage('bad options');

eval { $CMD{$cmd}->(@argv); 1 } or do {
	my $e = $@ || 'failed';
	print STDERR $e =~ /\n$/ ? $e : "$e\n";
	exit 1;
};
exit 0;
