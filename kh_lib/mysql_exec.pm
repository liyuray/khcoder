package mysql_exec;
use DBI;
use strict;
use File::Path qw(mkpath);
use File::Basename qw(dirname);
use Encode ();
use kh_project;

# SQLite back end.
#
# The module name and its API are unchanged so that the ~950 call sites
# elsewhere keep working; only the storage engine underneath is different.
# One project == one SQLite file at <private_dir>/<dbname>/<dbname>.db, so a
# project is self-contained and portable, and there is no server to run.
#
# Usage (unchanged):
# 	mysql_exec->[do/select]("sql","[1/0]")
# 		sql: SQL
#		[1/0]: Critical(1) or not(0)

my $sqlite_version = -1;
my $dbh_common;

# Connections opened by this process, so PRAGMAs are applied exactly once.
my %opened;

#------------#
#   DB       #
#------------#

sub _db_dir {
	my $dbname = shift;
	my $dir = $::config_obj->os_path( $::config_obj->private_dir );
	$dir .= '/'.$dbname;
	return $dir;
}

sub db_path {
	my $class  = shift;
	my $dbname = shift;
	return _db_dir($dbname).'/'.$dbname.'.db';
}

sub dsn_gen{
	my $db = shift;
	return "dbi:SQLite:dbname=".&db_path(undef, $db);
}

sub _tune {
	my $dbh = shift;
	# WAL lets the two worker threads read while the main thread writes;
	# busy_timeout absorbs the writer contention that WAL still allows.
	$dbh->do("PRAGMA journal_mode = WAL");
	$dbh->do("PRAGMA busy_timeout = 60000");
	$dbh->do("PRAGMA synchronous  = NORMAL");
	$dbh->do("PRAGMA temp_store   = MEMORY");
	$dbh->do("PRAGMA cache_size   = -200000");   # ~200MB page cache
	$dbh->do("PRAGMA foreign_keys = OFF");

	# KH Coder sorts Japanese words by their EUC-JP byte order (MySQL's
	# "CONVERT(x USING ujis)") so the ordering matches KH Coder 2.x. SQLite has
	# no CONVERT, so the same key is produced here and sorted with the default
	# BINARY collation, which compares bytes.
	# MySQL's TRUNCATE(x, n): cut to n decimals toward zero, not round.
	$dbh->sqlite_create_function('truncate', 2, sub {
		my ($x, $n) = @_;
		return undef unless defined $x;
		my $f = 10 ** ( $n || 0 );
		return int( $x * $f ) / $f;
	});

	$dbh->sqlite_create_function('kh_ujis', 1, sub {
		my $t = shift;
		return $t unless defined $t;
		my $b = eval { Encode::encode('euc-jp', $t, Encode::FB_DEFAULT()) };
		return defined($b) ? $b : $t;
	});

	return $dbh;
}

# The shared handle used before any project is open.
sub connect_common{
	my $path = &db_path(undef, 'khc_master');
	mkpath( dirname($path) ) unless -d dirname($path);
	$dbh_common = DBI->connect(
		"dbi:SQLite:dbname=$path", '', '',
		{ sqlite_unicode => 1, AutoCommit => 1, PrintError => 0 }
	) or gui_errormsg->open(type => 'mysql', sql => 'Connect');
	&_tune($dbh_common);
}

sub connect_db{
	my $dbname     = $_[1];
	my $no_verbose = $_[2];

	my $path = &db_path(undef, $dbname);
	mkpath( dirname($path) ) unless -d dirname($path);

	my $dbh = DBI->connect(
		"dbi:SQLite:dbname=$path", '', '',
		{ sqlite_unicode => 1, AutoCommit => 1, PrintError => 0 }
	) or gui_errormsg->open(type => 'mysql', sql => 'Connect');

	&_tune($dbh);

	unless ($sqlite_version ne '-1') {
		my $t = $dbh->prepare("select sqlite_version()");
		$t->execute;
		my $r = $t->fetch;
		$sqlite_version = $r->[0] if $r;
	}
	print "Connected to SQLite $sqlite_version, $dbname.\n" unless $no_verbose;

	return $dbh;
}

# There is no server, so nothing can cross-talk.
sub integrity_test{ return 1 }

sub connection_test{ return 1 }

# Allocate the next khcN. The number is derived from what is already on disk,
# which replaces the khc_master table MySQL needed for LAST_INSERT_ID().
sub create_new_db{
	my $class = shift;
	my $file  = shift;

	my $root = $::config_obj->os_path( $::config_obj->private_dir );
	mkpath($root) unless -d $root;

	my $max = 0;
	if ( opendir(my $dh, $root) ) {
		foreach my $e ( readdir($dh) ) {
			if ( $e =~ /^khc([0-9]+)$/ ) {
				$max = $1 if $1 > $max;
			}
		}
		closedir($dh);
	}

	my $n = $max + 1;
	my $new_db_name = "khc$n";

	# Never hand back a name whose file already exists.
	while ( -e &db_path(undef, $new_db_name) ) {
		++$n;
		$new_db_name = "khc$n";
	}

	mkpath( _db_dir($new_db_name) );
	return $new_db_name;
}

sub drop_db{
	my $drop = $_[1];

	my $path = &db_path(undef, $drop);
	foreach my $f ($path, "$path-wal", "$path-shm") {
		unlink($f) if -e $f;
	}
	rmdir( _db_dir($drop) );   # only succeeds when nothing else is left

	return 1;
}

# Nothing to shut down.
sub shutdown_db_server{ return 1 }

#------------------#
#   Tables         #
#------------------#

sub drop_table{
	my $class = shift;
	my $table = shift;

	$::project_obj->dbh->do("DROP TABLE IF EXISTS $table");
}

sub table_exists{
	my $class = shift;
	my $table = shift;

	my $dbh = $::project_obj->dbh;
	local $dbh->{PrintError} = 0;
	local $dbh->{RaiseError} = 0;

	my $t = $dbh->prepare("SELECT * FROM $table LIMIT 1") or return 0;
	$t->execute or return 0;
	$t->finish;

	return 1;
}

sub clear_tmp_tables{
	my $class = shift;
	foreach my $i ( &table_list ){
		if ( index($i,'ct_') == 0){
			$::project_obj->dbh->do("drop table $i");
		}
	}
}

sub table_list{
	my $class = shift;

	my @r;
	my $dbh = $::project_obj->dbh;
	my $t = $dbh->prepare(
		"SELECT name FROM sqlite_master WHERE type='table'
		 UNION ALL
		 SELECT name FROM sqlite_temp_master WHERE type='table'"
	);
	$t->execute;
	while ( my $i = $t->fetch ) {
		next if $i->[0] =~ /^sqlite_/;
		push @r, $i->[0];
	}
	return @r;
}

#----------------#
#   Do           #
#----------------#

# MySQL -> SQLite dialect translation. Applied to every statement so that the
# call sites do not have to change.

# MySQL accepts "#" as a comment-to-end-of-line; SQLite only knows "--".
# Quote state is tracked so a "#" inside a literal is left alone.
sub _strip_hash_comments {
	my $sql = shift;
	return $sql if index($sql, '#') < 0;

	my $out = '';
	my $q   = '';
	my @c   = split //, $sql;
	for (my $i = 0; $i <= $#c; $i++) {
		my $ch = $c[$i];
		if ($q ne '') {
			$out .= $ch;
			if ($ch eq "\\" && $i < $#c) { $out .= $c[++$i]; next }
			$q = '' if $ch eq $q;
			next;
		}
		if ($ch eq "'" || $ch eq '"' || $ch eq '`') { $q = $ch; $out .= $ch; next }
		if ($ch eq '#') {
			++$i while ($i <= $#c && $c[$i] ne "\n");
			$out .= "\n";
			next;
		}
		$out .= $ch;
	}
	return $out;
}


# MySQL's "/" is real division; SQLite truncates when both operands are
# integers, which silently turns ratios into 0 and empties result sets. The
# code base was written against MySQL, so every unquoted division is made real.
sub _real_division {
	my $sql = shift;
	return $sql if index($sql, '/') < 0;

	my $out = '';
	my $q   = '';
	my @c   = split //, $sql;
	for (my $i = 0; $i <= $#c; $i++) {
		my $ch = $c[$i];
		if ($q ne '') {
			$out .= $ch;
			if ($ch eq "\\" && $i < $#c) { $out .= $c[++$i]; next }
			$q = '' if $ch eq $q;
			next;
		}
		if ($ch eq "'" || $ch eq '"' || $ch eq '`') { $q = $ch; $out .= $ch; next }
		# leave /* ... */ comments alone
		if ($ch eq '/' && $i < $#c && $c[$i+1] eq '*') {
			$out .= '/*'; $i += 2;
			$out .= $c[$i++] while $i <= $#c && !($c[$i] eq '*' && $c[$i+1] eq '/');
			$out .= '*/'; ++$i;
			next;
		}
		if ($ch eq '/') { $out .= '* 1.0 /'; next }
		$out .= $ch;
	}
	return $out;
}

sub _translate {
	my $sql = shift;

	$sql = _strip_hash_comments($sql);
	$sql = _real_division($sql);

	# Storage-engine and table-option clauses have no meaning here.
	$sql =~ s/\bMAX_ROWS\s*=\s*[0-9]+//ig;
	$sql =~ s/\b(?:TYPE|ENGINE)\s*=\s*[A-Za-z]+//ig;

	# Collation. MySQL's default (utf8mb4_general_ci) compares text
	# case-INsensitively; SQLite's default BINARY does not. Left alone, an
	# English corpus would list "The" and "the" as two different words, because
	# reform() groups by genkei and hinshi.
	#
	# So a declared text column gets COLLATE NOCASE to match MySQL, except
	# where MySQL said "varchar(N) binary" -- a deliberately byte-exact column
	# (hyoso, the surface form) -- which is marked BINARY first so the pass
	# below leaves it alone.
	#
	# NOCASE folds ASCII only, which is what general_ci did for the Latin
	# range; Japanese is unaffected either way.
	if ( $sql =~ /\bCREATE\s+(?:TEMPORARY\s+)?TABLE\b/i ) {
		$sql =~ s/\b((?:var)?char\s*\(\s*[0-9]+\s*\))\s+binary\b/$1 COLLATE BINARY/ig;
		$sql =~ s/\b((?:var)?char(?:\s*\(\s*[0-9]+\s*\))?)(?!\s*COLLATE)(?=\s|,|\))/$1 COLLATE NOCASE/ig;
	} else {
		$sql =~ s/\b((?:var)?char\s*\(\s*[0-9]+\s*\))\s+binary\b/$1/ig;
	}

	# RENAME TABLE a TO b  ->  ALTER TABLE a RENAME TO b
	$sql =~ s/\bRENAME\s+TABLE\s+(\S+)\s+TO\s+(\S+)/ALTER TABLE $1 RENAME TO $2/ig;
	# ALTER TABLE a RENAME b  ->  ALTER TABLE a RENAME TO b
	$sql =~ s/\bALTER\s+TABLE\s+(\S+)\s+RENAME\s+(?!TO\b)(\S+)/ALTER TABLE $1 RENAME TO $2/ig;

	# ALTER TABLE t ADD [UNIQUE] INDEX name (cols) -> CREATE INDEX
	# Index names are per-table in MySQL but global in SQLite, so they are
	# prefixed with the table name to keep "index1" on two tables apart.
	# ALTER TABLE t ADD [UNIQUE] INDEX n (cols) [, ADD INDEX ...] -> CREATE INDEX.
	# MySQL allows several ADD clauses in one ALTER; SQLite needs one statement
	# each, so this can return several joined by ";" (see _split_statements).
	# Index names are per-table in MySQL but global in SQLite, hence the prefix.
	if ( $sql =~ /^\s*ALTER\s+TABLE\s+(\w+)\s+(ADD\s+(?:UNIQUE\s+)?INDEX\s+.*)$/is ) {
		my ($tbl, $rest) = ($1, $2);
		my @out;
		while ( $rest =~ /ADD\s+(UNIQUE\s+)?INDEX\s+(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)/ig ) {
			my ($uniq, $idx, $cols) = ($1, $2, $3);
			$cols =~ s/\(\s*[0-9]+\s*\)//g;      # drop prefix lengths: name(20)
			push @out, 'CREATE '.($uniq ? 'UNIQUE ' : '')
				."INDEX IF NOT EXISTS ${tbl}_${idx} ON $tbl ($cols)";
		}
		return join('; ', @out) if @out;
	}

	# CREATE TABLE a LIKE b -- copy the column layout, no rows.
	$sql =~ s/\bCREATE\s+TABLE\s+(\w+)\s+LIKE\s+(\w+)/CREATE TABLE $1 AS SELECT * FROM $2 WHERE 0/ig;

	# Dropping AUTO_INCREMENT from a populated column is a no-op for SQLite.
	$sql =~ s/\bALTER\s+TABLE\s+\w+\s+CHANGE\s+COLUMN\s+.*$/SELECT 1/is
		if $sql =~ /\bCHANGE\s+COLUMN\b/i;

	# AUTO_INCREMENT columns become SQLite rowid aliases. The modifiers appear in
	# several orders in the code base, so they are matched as an unordered blob.
	$sql =~ s{
		\b(\w+)\s+int(?:eger)?\b
		((?:\s+(?:primary\s+key|not\s+null|unique|auto_increment))+)
	}{
		my ($col, $mods) = ($1, $2);
		$mods =~ /auto_increment/i
			? "$col INTEGER PRIMARY KEY AUTOINCREMENT"
			: "$col int$mods";
	}igex;

	$sql =~ s/\bINSERT\s+IGNORE\s+INTO\b/INSERT OR IGNORE INTO/ig;

	# Scalar functions that differ in name only.
	# IF(c,a,b) is IIF(c,a,b) here; the lookbehind keeps IFNULL() intact.
	$sql =~ s/(?<![A-Za-z0-9_])IF\s*\(/IIF(/ig;
	# SQLite's length() already counts characters for text values.
	$sql =~ s/(?<![A-Za-z0-9_])CHAR_LENGTH\s*\(/LENGTH(/ig;
	# "col = binary 'x'" forces a byte-exact compare in MySQL; SQLite's default
	# BINARY collation already does that, so the keyword just goes.
	$sql =~ s/(?<![A-Za-z0-9_])binary\s+(?=['"])//ig;
	# CONVERT(x USING ujis) -> the kh_ujis() function registered in _tune.
	$sql =~ s/(?<![A-Za-z0-9_])CONVERT\s*\((.+?)\s+USING\s+\w+\s*\)/kh_ujis($1)/ig;

	return $sql;
}

# MySQL's LOAD DATA LOCAL INFILE, reimplemented as a batched insert.
# Fields fill the table's columns left to right, exactly as MySQL does, so a
# trailing AUTO_INCREMENT id column is left to fill itself.
sub _load_file {
	my $self  = shift;
	my $file  = shift;
	my $table = shift;
	my $cs    = shift;

	my %enc = (
		utf8 => 'UTF-8', utf8mb4 => 'UTF-8', ujis => 'EUC-JP',
		eucjpms => 'EUC-JP', sjis => 'CP932', cp932 => 'CP932',
		binary => 'UTF-8', latin1 => 'ISO-8859-1',
	);
	my $layer = $enc{ lc($cs // 'utf8') } || 'UTF-8';

	my $dbh = $::project_obj ? $::project_obj->dbh : $dbh_common;

	# Column list, in declaration order.
	my @cols;
	my $ti = $dbh->prepare("PRAGMA table_info($table)");
	$ti->execute;
	while ( my $r = $ti->fetch ) { push @cols, $r->[1] }
	unless (@cols) {
		$self->{err} = "LOAD DATA: unknown table $table";
		return $self->print_error;
	}

	# Pass 1: how many fields does the widest line hold?
	my $width = 0;
	open (my $IN, "<:encoding($layer)", $file) or do {
		$self->{err} = "LOAD DATA: cannot read $file";
		return $self->print_error;
	};
	while (my $l = <$IN>) {
		chomp $l;
		$l =~ s/\r$//;
		next unless length $l;
		my $n = scalar( my @f = split /\t/, $l, -1 );
		$width = $n if $n > $width;
	}
	close $IN;
	$width = 1 unless $width;
	$width = scalar(@cols) if $width > scalar(@cols);

	my @target = @cols[0 .. $width - 1];
	my $sth = $dbh->prepare(
		"INSERT INTO $table (".join(',', @target).") VALUES ("
		.join(',', ('?') x $width).")"
	) or return $self->print_error;

	# Pass 2: insert. One transaction keeps this fast.
	open ($IN, "<:encoding($layer)", $file) or do {
		$self->{err} = "LOAD DATA: cannot read $file";
		return $self->print_error;
	};
	$dbh->begin_work;
	my $n = 0;
	while (my $l = <$IN>) {
		chomp $l;
		$l =~ s/\r$//;
		next unless length $l;
		my @f = split /\t/, $l, -1;
		push @f, '' while scalar(@f) < $width;   # MySQL pads short rows
		splice(@f, $width) if scalar(@f) > $width;
		$sth->execute(@f);
		++$n;
	}
	$dbh->commit;
	close $IN;

	print "LOAD: $n rows into $table\n";
	return $self;
}


# Split on top-level ";" so a translated multi-index ALTER (and any statement
# that simply ends in a semicolon) can be executed a piece at a time.
sub _split_statements {
	my $sql = shift;
	return ($sql) if index($sql, ';') < 0;

	my @out;
	my $cur = '';
	my $q   = '';
	my @c   = split //, $sql;
	for (my $i = 0; $i <= $#c; $i++) {
		my $ch = $c[$i];
		if ($q ne '') {
			$cur .= $ch;
			if ($ch eq "\\" && $i < $#c) { $cur .= $c[++$i]; next }
			$q = '' if $ch eq $q;
			next;
		}
		if ($ch eq "'" || $ch eq '"' || $ch eq '`') { $q = $ch; $cur .= $ch; next }
		if ($ch eq ';') { push @out, $cur; $cur = ''; next }
		$cur .= $ch;
	}
	push @out, $cur;
	return grep { /\S/ } @out;
}

sub do{
	my $class = shift;
	my $self;
	$self->{sql} = shift;
	$self->{critical} = shift;
	bless $self, $class;

	($self->{caller_pac}, $self->{caller_file}, $self->{caller_line}) = caller;

	# Bulk load is handled in Perl rather than by the engine.
	if ( $self->{sql} =~ /\bLOAD\s+DATA\s+(?:LOCAL\s+)?INFILE\s+['"]?(.+?)['"]?\s+INTO\s+TABLE\s+(\w+)(?:\s+CHARACTER\s+SET\s+(\w+))?/is ) {
		$self->log;
		return $self->_load_file($1, $2, $3);
	}

	$self->{sql} = _translate($self->{sql});
	$self->log;

	my $dbh;
	if ($::project_obj) {
		$dbh = $::project_obj->dbh;
	} else {
		&connect_common unless $dbh_common;
		$dbh = $dbh_common;
	}

	for my $one ( _split_statements($self->sql) ) {
		$dbh->do($one) or do { $self->{sql} = $one; $self->print_error };
	}
	return $self;
}

sub select{
	my $class = shift;
	my $self;
	$self->{sql} = shift;
	$self->{critical} = shift;
	bless $self, $class;

	($self->{caller_pac}, $self->{caller_file}, $self->{caller_line}) = caller;

	$self->{sql} = _translate($self->{sql});
	$self->log;

	my $dbh;
	if ($::project_obj) {
		$dbh = $::project_obj->dbh;
	} else {
		&connect_common unless $dbh_common;
		$dbh = $dbh_common;
	}

	# DBD::SQLite reports syntax errors at prepare time, where DBD::mysql only
	# reported them on execute. Bail out here so the SQL is what gets reported.
	my $t = $dbh->prepare($self->sql);
	unless ($t) { $self->print_error; return $self }
	$t->execute or $self->print_error;
	$self->{hundle} = mysql_exec::sth->new($t);
	return $self;
}

sub selected_rows{
	my $self = shift;
	return $self->{hundle}->rows;
}

sub print_error{
	my $self = shift;

	my $dbh;
	if    ($::project_obj) { $dbh = $::project_obj->dbh }
	elsif ($dbh_common)    { $dbh = $dbh_common }

	if ($dbh) {
		$self->{err} =
			"SQL Input:\n".$self->sql."\nError:\n"
			.($dbh->errstr // $self->{err} // '')."\n\n"
			."SQL Caller: $self->{caller_file} line $self->{caller_line}"
		;
	}

	unless ($self->critical){
		warn($self->{err});
		return 0;
	}

	# With KHC_SQL_AUDIT set, a failing statement is reported and execution
	# carries on, so one run surfaces every problem instead of stopping at the
	# first. Diagnostics only -- results after an error are not trustworthy.
	if ($ENV{KHC_SQL_AUDIT}) {
		print "\n[SQL-AUDIT] $self->{err}\n";
		return 0;
	}

	print "\n\n$self->{err}\n";
	gui_errormsg->open(type => 'mysql',sql => $self->err);
}

sub quote{
	my $class = shift;
	my $input = shift;

	return $::project_obj->dbh->quote($input);
}

# There is no server-side cache to flush; a WAL checkpoint is the analogue.
sub flush{
	my $class = shift;

	my $dbh;
	if ($::project_obj) {
		$dbh = $::project_obj->dbh;
	} else {
		&connect_common unless $dbh_common;
		$dbh = $dbh_common;
	}

	$dbh->do("PRAGMA wal_checkpoint(TRUNCATE)");
	print "SQLite: checkpoint\n";
	return 1;
}

sub version_number{
	return $sqlite_version;
}

#-------------------------------#
sub log{
	return 1 unless $::config_obj->sqllog;

	use POSIX 'strftime';
	my $self = shift;
	my $logfile = $::config_obj->sqllog_file;
	open (LOG,">>:utf8", $logfile) or
		gui_errormsg->open(
			type    => 'file',
			thefile => "$logfile"
		);
	my $d = strftime('%Y %m/%d %H:%M:%S',localtime);
	print LOG "$d\n";
	print LOG $self->sql."\n\n";
	close LOG;
	return 1;
}
#--------------#
sub sql{
	my $self = shift;
	return $self->{sql};
}
sub critical{
	my $self = shift;
	return $self->{critical};
}
sub err{
	my $self = shift;
	return $self->{err};
}
sub hundle{
	my $self = shift;
	return $self->{hundle};
}

1;

#-----------------------------------------------------------------#
#   Buffered statement handle                                     #
#-----------------------------------------------------------------#
# DBD::mysql buffers a whole result set client-side, so $sth->rows returns the
# real row count after a SELECT. DBD::SQLite streams and returns -1 instead,
# which silently breaks every "if ($h->rows > 0)" in the code base. Buffering
# here restores the semantics the call sites were written against, and matches
# what DBD::mysql was doing for memory anyway.
package mysql_exec::sth;
use strict;

sub new {
	my ($class, $sth) = @_;
	my $self = { i => 0, rows => [], names => [] };
	bless $self, $class;
	return $self unless $sth;

	$self->{names} = $sth->{NAME} || [];
	if ( $sth->{NUM_OF_FIELDS} ) {           # a row-returning statement
		while ( my $r = $sth->fetchrow_arrayref ) {
			push @{ $self->{rows} }, [ @$r ];
		}
	}
	$self->{err}    = $sth->err;
	$self->{errstr} = $sth->errstr;
	$sth->finish;
	return $self;
}

sub rows { return scalar @{ $_[0]->{rows} } }

sub fetch {
	my $self = shift;
	return undef if $self->{i} > $#{ $self->{rows} };
	return $self->{rows}[ $self->{i}++ ];
}
*fetchrow_arrayref = \&fetch;

sub fetchrow_array {
	my $r = shift->fetch;
	return $r ? @$r : ();
}

sub fetchrow_hashref {
	my $self = shift;
	my $r = $self->fetch or return undef;
	my %h;
	@h{ @{ $self->{names} } } = @$r;
	return \%h;
}

sub fetchall_arrayref {
	my $self = shift;
	my @out = @{ $self->{rows} }[ $self->{i} .. $#{ $self->{rows} } ];
	$self->{i} = scalar @{ $self->{rows} };
	return \@out;
}

sub finish { return 1 }
sub err    { return $_[0]->{err} }
sub errstr { return $_[0]->{errstr} }

1;
