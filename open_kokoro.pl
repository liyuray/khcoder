# Launch KH Coder and open the kokoro tutorial project (tutorial_jp/kokoro.xls).
# Mirrors kh_coder.pl's startup, then drives gui_window::project_new the same way
# auto_test/lib/kh_at/project_new.pm does.
$| = 1;
use strict;
use vars qw($config_obj $project_obj $main_gui $kh_version);

BEGIN {
	use Jcode;
	push @INC, '.';
	require kh_lib::Jcode_kh if $] > 5.008 && eval 'require Encode::EUCJPMS';
	eval { require Encode::Locale; };
	unless ( Encode::find_encoding('console_out') ) {
		$Encode::Locale::ENCODING_CONSOLE_OUT = $Encode::Locale::ENCODING_LOCALE;
		$Encode::Locale::ENCODING_CONSOLE_IN  = $Encode::Locale::ENCODING_LOCALE;
		eval{ Encode::Locale::_flush_aliases(); };
	}
	unless ( Encode::find_encoding('locale_fs') ) {
		$Encode::Locale::ENCODING_LOCALE_FS = $Encode::Locale::ENCODING_LOCALE;
		eval{ Encode::Locale::_flush_aliases(); };
	}
	eval { binmode STDOUT, ":encoding(console_out)"; };

	use Cwd;
	unshift @INC, cwd.'/kh_lib';
	use Tk;
	require kh_sysconfig;
	$config_obj = kh_sysconfig->readin('./config/coder.ini',&cwd);
}

use Tk;
use mysql_ready;
use mysql_words;
use mysql_conc;
use kh_about;
use kh_project;
use kh_projects;
use kh_morpho;
use gui_window;

$kh_version = kh_about->version;
print "This is KH Coder $kh_version on $^O.\n";

# R
use Statistics::R;
no  warnings 'redefine';
*Statistics::R::output_chk = sub {return 1};
use warnings 'redefine';

mkdir $::config_obj->{cwd}.'/config/R-bridge'
	unless -d $::config_obj->{cwd}.'/config/R-bridge';

$::config_obj->{R} = Statistics::R->new(
	r_bin   => $::config_obj->os_path( $::config_obj->r_path ),
	log_dir => $::config_obj->{cwd}.'/config/R-bridge',
	tmp_dir => $::config_obj->{cwd}.'/config/R-bridge',
);
if ($::config_obj->{R}){
	$ENV{LANGUAGE} = 'EN';
	$::config_obj->{R}->startR;
	$::config_obj->{R}->send('Sys.setlocale(category="LC_ALL",locale="ja_JP.UTF-8")');
	$::config_obj->{R}->send('dummy_d <- matrix(1:9, nrow=3, ncol=3)');
	$::config_obj->{R}->send('dummy_r <- cmdscale(dist(dummy_d), k=1)');
	$::config_obj->{R}->read();
	$::config_obj->{R}->output_chk(1);
	$::config_obj->ram;
}
chdir ($::config_obj->{cwd});
$::config_obj->R_version;

use my_threads;
my_threads->init;

$main_gui = gui_window::main->open;

# Kick off project creation once the main loop is running.
$main_gui->{win_obj}->after(1500, \&open_kokoro);

MainLoop;

#--------------------------------------------------#

sub open_kokoro {
	my $target = '/khcoder/tutorial_jp/kokoro.xls';
	unless (-e $target) { print "FATAL: $target not found\n"; return }

	# Already registered from an earlier run? Just open it.
	my $projects = kh_projects->read;
	my $n = -1;
	for my $i ( 0 .. $#{$projects->list} ) {
		my $c = $projects->list->[$i];
		if ( $c->{comment} && $c->{comment} =~ /kokoro tutorial/ ) { $n = $i; last }
	}
	if ($n >= 0) {
		print "### existing kokoro project found (index $n), opening...\n";
		kh_project->temp(
			target  => $projects->list->[$n]{target},
			dbname  => $projects->list->[$n]{dbname},
		)->open;
		$::main_gui->close_all;
		$::main_gui->menu->refresh;
		$::main_gui->inner->refresh;
		print "### project opened.\n";
		return;
	}

	print "### creating new project from $target\n";
	gui_window::project_new->open;
	my $w = $::main_gui->get('w_new_pro');

	$w->{e1}->delete(0,'end');
	$w->{e1}->insert(0, gui_window->gui_jchar($target));
	$w->check_path($target);              # builds {column_list} for the .xls

	$w->{e2}->delete(0,'end');
	$w->{e2}->insert(0, gui_window->gui_jchar('kokoro tutorial'));

	$w->{lang_menu}->set_value('jp');
	$w->refresh_method;
	$w->{lang}   = 'jp';
	$w->{method} = 'mecab';
	$w->{column} = 0;                     # column 0 = テキスト

	print "### columns: ", join(' | ', @{$w->{column_list}}), "\n";
	$w->_make_new or do { print "FATAL: _make_new failed\n"; return };
	print "### project registered, running morphological analysis...\n";

	$::main_gui->menu->mc_morpho_exec
		or do { print "FATAL: morphological analysis failed\n"; return };

	$::main_gui->close_all;
	$::main_gui->menu->refresh;
	$::main_gui->inner->refresh;
	print "### DONE: kokoro tutorial project is open.\n";
}
