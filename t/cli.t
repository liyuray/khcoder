#!/usr/bin/perl
# Regression tests for the headless engine, driven through khc.pl.
#
# These pin the numbers the Tk build produces for the kokoro tutorial, so a
# change to the SQL translator, the engine, or a future web front end that
# alters a result shows up here rather than in someone's analysis.
#
#   cd /khcoder/src && perl t/cli.t
#
# The fixture project is built once from tutorial_jp/kokoro.xls and reused;
# pass --rebuild to force it to be created again.

use strict;
use warnings;
use utf8;          # the Japanese literals below are characters, not bytes
use Encode ();

my $PROJECT = 'khc_test';
my $SOURCE  = '../tutorial_jp/kokoro.xls';
my $REBUILD = grep { $_ eq '--rebuild' } @ARGV;

# KH Coder registers one project per source path, so the fixture works from its
# own copy. Otherwise it would collide with -- or force the removal of -- a real
# project the user built from the same tutorial file.
my $TMP    = $ENV{TMPDIR} || '/tmp';
my $TARGET = "$TMP/khc_test_kokoro.xls";

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my ($ran, $failed) = (0, 0);

# Single-quote for the shell, escaping any quote in the argument itself.
sub shq {
    my $s = shift;
    return $s unless $s =~ /[^\w.\/=-]/;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub khc {
    my @args = @_;
    my $cmd = join ' ', 'perl', 'khc.pl', map { shq($_) } @args;
    my $out = `$cmd 2>&1`;
    return Encode::decode('UTF-8', $out);
}

sub json_get {
    # Small extractor: these payloads are flat enough not to need a parser.
    my ($json, $key) = @_;
    return $1 if $json =~ /"\Q$key\E":\s*"((?:[^"\\]|\\.)*)"/;
    return $1 if $json =~ /"\Q$key\E":\s*(-?[0-9.]+)/;
    return undef;
}

sub is {
    my ($got, $want, $name) = @_;
    ++$ran;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    if ("$got" eq "$want") { print "ok $ran - $name\n"; return 1 }
    ++$failed;
    print "not ok $ran - $name\n     got: $got\nexpected: $want\n";
    return 0;
}

sub like {
    my ($got, $re, $name) = @_;
    ++$ran;
    if ( defined $got && $got =~ $re ) { print "ok $ran - $name\n"; return 1 }
    ++$failed;
    print "not ok $ran - $name\n     got: ", (defined $got ? $got : '(undef)'), "\n";
    return 0;
}

#--------------------------------------------------------------------#
#   fixture                                                          #
#--------------------------------------------------------------------#

my $projects = khc('projects', '--json');
my $registered = $projects =~ /"name":"\Q$PROJECT\E"/;

# Registered is not the same as usable: the database file may have been removed
# under it. Only a stats call that returns a sentence count proves the fixture.
my $usable = 0;
if ($registered) {
    my $probe = khc('stats', '--project', $PROJECT, '--json');
    $usable = $probe =~ /"sentences":[1-9]/;
}

if ($REBUILD || !$usable) {
    print "# building the fixture project from $TARGET ...\n";
    die "# fixture source missing: $SOURCE\n" unless -e $SOURCE;
    khc('drop', '--project', $PROJECT) if $registered;   # clear any stale entry
    require File::Copy;
    File::Copy::copy($SOURCE, $TARGET) or die "# could not stage $TARGET: $!\n";
    my $new = khc('new', '--target', $TARGET, '--column', 0, '--name', $PROJECT);
    die "# could not create the project:\n$new" unless $new =~ /dbname/;
    my $prep = khc('prep', '--project', $PROJECT);
    die "# pre-processing failed:\n$prep" unless $prep =~ /sentences/;
}

#--------------------------------------------------------------------#
#   the figures the Tk build shows on its main window                #
#--------------------------------------------------------------------#

my $stats = khc('stats', '--project', $PROJECT, '--json');

is( json_get($stats, 'sentences'),  5064,   'sentence count (文)' );
is( json_get($stats, 'paragraphs'), 1215,   'paragraph count (段落)' );
is( json_get($stats, 'used_words'), 5451,   'words in use (異なり語数・使用)' );
is( json_get($stats, 'words'),      6048,   'distinct word forms' );
is( json_get($stats, 'tokens'),     109549, 'token count' );
like( json_get($stats, 'db'), qr/\.db$/,    'project is a single SQLite file' );

#--------------------------------------------------------------------#
#   word frequency list                                              #
#--------------------------------------------------------------------#

my $words = khc('words', '--project', $PROJECT, '--limit', 5, '--json');
like( $words, qr/"word":"する"/,  'most frequent word is する' );
like( $words, qr/"freq":1710/,     'する occurs 1710 times' );
like( $words, qr/"word":"ない"/,  'ない is in the top five' );

my $one = khc('words', '--project', $PROJECT, '--query', '先生', '--mode', 'c', '--json');
like( $one, qr/"freq":595/,        '先生 occurs 595 times' );
like( $one, qr/"pos":"名詞"/,      '先生 is tagged as a noun' );

#--------------------------------------------------------------------#
#   concordance                                                      #
#--------------------------------------------------------------------#

my $conc = khc('conc', '--project', $PROJECT, '--query', '先生', '--limit', 3, '--json');
like( $conc, qr/"hit":"先生"/,                 'KWIC centres on the query word' );
like( $conc, qr/私はその人を常に/,             'first hit carries the opening line' );

#--------------------------------------------------------------------#
#   document retrieval and the seq column                            #
#--------------------------------------------------------------------#

my $first = khc('sql', '--project', $PROJECT, '--json', 'SELECT MIN(id) FROM bun');
my ($first_id) = $first =~ /\[\[(\d+)\]\]/;
my $doc = khc('doc', '--project', $PROJECT, '--id', $first_id, '--json');
is( json_get($doc, 'seq'), 1, 'first sentence has seq 1' );
like( json_get($doc, 'text'), qr/私はその人を常に先生と呼んでいた/, 'document text reads back' );

# seq must be dense 1..N: it drives next/previous navigation.
my $dense = khc('sql', '--project', $PROJECT, '--json',
    'SELECT COUNT(*), MAX(seq), MIN(seq), COUNT(DISTINCT seq) FROM bun');
like( $dense, qr/\[\[5064,5064,1,5064\]\]/, 'seq is dense 1..N over all sentences' );

#--------------------------------------------------------------------#
#   SQL dialect regressions                                          #
#--------------------------------------------------------------------#

# "||" is concatenation in SQLite, not logical OR; the engine must use OR.
my $or = khc('sql', '--project', $PROJECT, '--json',
    "SELECT COUNT(*) FROM hselection WHERE name = 'TAG' OR name = 'HTMLタグ'");
like( $or, qr/\[\[\d+\]\]/, 'OR in a WHERE clause returns a count' );

# CONVERT(x USING ujis) is translated to the kh_ujis() collation function.
my $sort = khc('sql', '--project', $PROJECT, '--json',
    'SELECT name FROM genkei ORDER BY CONVERT(name USING ujis) LIMIT 1');
like( $sort, qr/^\[\[/, 'CONVERT(... USING ujis) is accepted' );

# MySQL's IF() becomes IIF().
my $iif = khc('sql', '--project', $PROJECT, '--json',
    'SELECT IF(1=1, 42, 0)');
like( $iif, qr/\[\[42\]\]/, 'IF() is translated to IIF()' );

# Index DDL: MySQL ALTER ... ADD INDEX becomes CREATE INDEX.
my $idx = khc('sql', '--project', $PROJECT,
    'ALTER TABLE bun ADD INDEX t_probe (dan_id)');
like( $idx, qr/ok/, 'ALTER TABLE ADD INDEX is translated' );
my $idx_gone = khc('sql', '--project', $PROJECT, '--json',
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='bun_t_probe'");
like( $idx_gone, qr/\[\[1\]\]/, 'the index is created with a table-prefixed name' );
khc('sql', '--project', $PROJECT, 'DROP INDEX IF EXISTS bun_t_probe');

#--------------------------------------------------------------------#

print "\n1..$ran\n";
print $failed ? "# FAILED $failed of $ran\n" : "# all $ran tests passed\n";
exit($failed ? 1 : 0);
