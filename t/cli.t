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
#   group 1: tabular analyses                                        #
#--------------------------------------------------------------------#

# Coding needs a rule file; the tutorial's is Shift-JIS, so stage a UTF-8 copy.
my $RULES = "$TMP/khc_test_theme.txt";
if ( -e '../tutorial_jp/theme.txt' ) {
    open(my $in,  '<:encoding(cp932)', '../tutorial_jp/theme.txt') or die;
    open(my $out, '>:encoding(UTF-8)', $RULES) or die;
    print {$out} $_ while <$in>;
    close $in; close $out;
}

SKIP: {
    unless ( -e $RULES ) { print "# no coding rules; skipping coding tests\n"; last SKIP }

    my $freq = khc('cod-freq', '--project', $PROJECT, '--rules', $RULES, '--json');
    like( $freq, qr/"code":"＊人の死"/,  'coding frequency names the codes' );
    like( $freq, qr/"n":129/,             '人の死 codes 129 sentences' );
    like( $freq, qr/"n":137/,             '病気 codes 137 sentences' );
    like( $freq, qr/"n":5064/,            'the total row matches the sentence count' );

    my $jac = khc('cod-jaccard', '--project', $PROJECT, '--rules', $RULES, '--json');
    like( $jac, qr/1\.000/,               'similarity matrix has a unit diagonal' );

    my $tab = khc('cod-crosstab', '--project', $PROJECT, '--rules', $RULES,
                  '--var', '部', '--tani', 'h5', '--json');
    like( $tab, qr/上＿先生と私/,          'crosstab rows are the 部 values' );
    like( $tab, qr/1215/,                 'crosstab totals the 1,215 sections' );
}

my $vars = khc('vars', '--project', $PROJECT, '--json');
like( $vars, qr/"name":"部"/,   'external variables are listed' );

my $as = khc('assoc', '--project', $PROJECT, '--query', '先生',
             '--limit', 5, '--min_doc', 3, '--json');
like( $as, qr/"word":"/,  'word association returns words' );
like( $as, qr/"score":/,  'word association returns a score' );

# The score is a ratio of proportions: it must not be integer-divided to zero.
like( $as, qr/"score":[1-9]/, 'association scores survive real division' );

my $csv = "$TMP/khc_test_wordlist.csv";
my $ex  = khc('export', '--project', $PROJECT, '--out', $csv, '--json');
like( $ex, qr/"rows":[1-9]/, 'word list export reports rows' );
{
    ++$ran;
    if ( -s $csv ) { print "ok $ran - word list export wrote a file\n" }
    else { ++$failed; print "not ok $ran - word list export wrote a file\n" }
}

#--------------------------------------------------------------------#
#   group 2: R plots                                                 #
#--------------------------------------------------------------------#

# Plots on one project share config/R-bridge and cannot run concurrently,
# so these run one at a time.
for my $kind (qw(cls mds corresp network som tf-dist df-dist tf-df doc-cls
                 cod-cls cod-mds cod-corresp cod-netg cod-som)) {
    my $png  = "$TMP/khc_test_$kind.png";
    unlink $png if -e $png;
    my @args = ('plot', '--project', $PROJECT, '--kind', $kind,
                '--out', $png, '--json');
    if ( $kind =~ /^cod-/ ) {
        next unless -e $RULES;
        push @args, ('--rules', $RULES);
    } else {
        push @args, ('--min', 50);
    }
    # Correspondence analysis needs denser units than single sentences.
    push @args, ('--tani', 'h5') if $kind =~ /corresp/;
    my $out = khc(@args);

    like( $out, qr/"written"/, "$kind plot reports a file" );
    ++$ran;
    if ( -s $png > 5000 ) { print "ok $ran - $kind plot wrote a real PNG\n" }
    else { ++$failed; print "not ok $ran - $kind plot wrote a real PNG (", (-s $png || 0), " bytes)\n" }
}

#--------------------------------------------------------------------#
#   group 3: project operations                                      #
#--------------------------------------------------------------------#

my $khc_file = "$TMP/khc_test_archive.khc";
unlink $khc_file if -e $khc_file;
my $arc = khc('archive', '--project', $PROJECT, '--out', $khc_file, '--json');
like( $arc, qr/"bytes":[1-9]/, 'project archive reports a size' );

my $restored_src = "$TMP/khc_test_restored.xls";
unlink $restored_src if -e $restored_src;
my $res = khc('restore', '--archive', $khc_file, '--target', $restored_src, '--json');
my $newdb = json_get($res, 'project');
like( $newdb, qr/^khc\d+$/, 'archive restores into a new project' );

if ( $newdb ) {
    # The restored project must carry the same corpus, not just register.
    my $rs = khc('stats', '--project', $newdb, '--json');
    is( json_get($rs, 'sentences'), 5064, 'restored project has all 5,064 sentences' );
    is( json_get($rs, 'words'),     6048, 'restored project has all word forms' );
    khc('drop', '--project', $newdb);
}

#--------------------------------------------------------------------#
#   preprocessing, dictionary and text extraction                    #
#--------------------------------------------------------------------#

my $cw = khc('check-words', '--project', $PROJECT, '--query', '先生', '--json');
like( $cw, qr/先生/, 'check-words shows how the tagger split the string' );

my $dj = khc('dict', '--project', $PROJECT, '--json');
like( $dj, qr/"pos_in_use":\[/,  'dict lists the parts of speech in use' );
like( $dj, qr/名詞/,              'nouns are among them' );
like( $dj, qr/"pos_off":\[/,     'dict lists the ones switched off' );

khc('phrases-detect', '--project', $PROJECT);
my $ph = khc('phrases', '--project', $PROJECT, '--limit', 5, '--json');
like( $ph, qr/\[/, 'noun phrases come back after detection' );

my $st = khc('settings', '--json');
like( $st, qr/"c_or_j":"mecab"/, 'settings reports the analyser' );

SKIP: {
    unless ( -e $RULES ) { print "# no coding rules; skipping pickup\n"; last SKIP }
    my $pf = "$TMP/khc_test_pick.txt";
    unlink $pf if -e $pf;
    my $pk = khc('pickup', '--project', $PROJECT, '--rules', $RULES,
                 '--out', $pf, '--code', 0, '--json');
    like( $pk, qr/"bytes":[1-9]/, 'pickup extracts the text a code matches' );
}

my $hf = "$TMP/khc_test_head.txt";
unlink $hf if -e $hf;
my $hd = khc('headings', '--project', $PROJECT, '--out', $hf, '--json');
like( $hd, qr/"bytes":[1-9]/, 'headings are exported' );

my $tp = khc('topics', '--project', $PROJECT, '--topics', 3, '--limit', 4,
             '--min', 40, '--json');
like( $tp, qr/"topic":1/,  'topic model returns numbered topics' );
like( $tp, qr/"word":"/,   'each topic lists its strongest words' );

# import-folder: each file in a folder becomes one document.
my $dir = "$TMP/khc_test_docs";
mkdir $dir unless -d $dir;
for my $n (1..3) {
    open(my $o, '>:encoding(UTF-8)', "$dir/doc$n.txt") or next;
    print {$o} "これは文書$n です。先生は東京にいた。\n";
    close $o;
}
my $unified = "$TMP/khc_test_unified.txt";
unlink $unified if -e $unified;
my $imp = khc('import-folder', '--folder', $dir, '--out', $unified, '--json');
like( $imp, qr/"files":3/,   'import-folder unifies every file in the folder' );
like( $imp, qr/"heading":"h5"/, 'each file gets a heading of its own' );
{
    ++$ran;
    my $txt = -e $unified ? do { open(my $i,'<:encoding(UTF-8)',$unified); local $/; <$i> } : '';
    if ( $txt =~ m{<h5>file:doc1\.txt</h5>} ) { print "ok $ran - the unified file carries file headings\n" }
    else { ++$failed; print "not ok $ran - the unified file carries file headings\n" }
}

#--------------------------------------------------------------------#

print "\n1..$ran\n";
print $failed ? "# FAILED $failed of $ran\n" : "# all $ran tests passed\n";
exit($failed ? 1 : 0);
