package kh_headless;

# Minimal stand-ins for the GUI packages the analysis engine calls at runtime,
# so the engine can be driven without Perl/Tk.
#
# The engine modules never "use gui_window" or "use Tk" -- they only call
# gui_errormsg->open and a handful of gui_window string helpers, relying on
# those packages being loaded by the application. Loading this module instead
# supplies them, and Tk is never pulled in.
#
# Surface actually used by non-GUI modules:
#   gui_errormsg->open      245 call sites
#   gui_window->gui_jchar    19
#   gui_window->gui_bmp       4
#   gui_window->kchar_patchim 3
#   gui_window->gui_jg        1
#
# Load this INSTEAD of gui_window, never alongside it.

use strict;
use Encode ();
use Jcode;

our $VERSION = '1.0';

# Errors are thrown rather than shown in a dialog. Callers that pass a
# non-critical flag already handle a false return; the rest propagate to the
# CLI or API layer, which decides how to report them.
our $DIE_ON_ERROR = 1;

sub import {
	# Announce the packages as loaded so a stray "require" is a no-op.
	$INC{'gui_window.pm'}   ||= __FILE__;
	$INC{'gui_errormsg.pm'} ||= __FILE__;
	$INC{'gui_wait.pm'}     ||= __FILE__;
	return 1;
}

#--------------------------------------------------#
package gui_errormsg;
use strict;

sub open {
	shift;
	my %a = @_;
	my $msg;
	if    ( $a{type} eq 'file'  ) { $msg = "cannot open file: ".($a{thefile} // $a{file} // '?') }
	elsif ( $a{type} eq 'mysql' ) { $msg = "SQL error: ".($a{sql} // '?') }
	else                          { $msg = $a{msg} // 'error' }

	my ($pkg, $file, $line) = caller;
	my $where = " at $file line $line";

	die "KH Coder: $msg$where\n" if $kh_headless::DIE_ON_ERROR;
	warn "KH Coder: $msg$where\n";
	return 0;
}

#--------------------------------------------------#
package gui_wait;
use strict;

# Progress indicator; nothing to draw without a GUI.
sub start { my $s = {}; return bless $s, shift }
sub end   { return 1 }
sub update{ return 1 }

#--------------------------------------------------#
package gui_window;
use strict;
use Encode ();
use Jcode;

my %char_code = ( euc => 'eucJP-ms', sjis => 'cp932' );

# Decode a byte string coming out of the engine into character data.
sub gui_jchar {
	my $char = $_[1];
	my $code = $_[2];
	return $char unless defined $char;
	return $char if utf8::is_utf8($char);

	$code = Jcode->new($char)->icode unless $code;
	$code = $char_code{euc}  if $code eq 'euc';
	$code = $char_code{sjis} if $code eq 'sjis';
	$code = $char_code{sjis} if $code eq 'shiftjis';
	$code = $char_code{euc}  unless length($code);
	return Encode::decode($code, $char);
}

# Drop characters outside the Basic Multilingual Plane, as the Tk build does,
# so stored strings match between the two front ends.
sub gui_bmp {
	my $t = $_[1];
	return $t unless defined $t;
	$t = gui_window->gui_jchar($t) unless utf8::is_utf8($t);
	$t = Encode::encode('UCS-2LE', $t, Encode::FB_DEFAULT);
	$t = Encode::decode('UCS-2LE', $t);
	$t =~ s/\x{fffd}/?/g;
	return $t;
}

# Normalise a string coming from the user.
sub gui_jg {
	my $char       = $_[1];
	my $reserve_rn = $_[2];
	return $char unless defined $char;
	if ( utf8::is_utf8($char) ) {
		$char =~ s/\x0D|\x0A//go unless $reserve_rn;
	}
	return $char;
}

sub gui_jm { return $_[1] }

# Korean jamo composition, copied from gui_window.pm so results match.
my %patchim_n = (
	"\x{11A8}" => 1,  "\x{11A9}" => 2,  "\x{11AA}" => 3,  "\x{11AB}" => 4,
	"\x{11AC}" => 5,  "\x{11AD}" => 6,  "\x{11AE}" => 7,  "\x{11AF}" => 8,
	"\x{11B0}" => 9,  "\x{11B1}" => 10, "\x{11B2}" => 11, "\x{11B3}" => 12,
	"\x{11B4}" => 13, "\x{11B5}" => 14, "\x{11B6}" => 15, "\x{11B7}" => 16,
	"\x{11B8}" => 17, "\x{11B9}" => 18, "\x{11BA}" => 19, "\x{11BB}" => 20,
	"\x{11BC}" => 21, "\x{11BD}" => 22, "\x{11BE}" => 23, "\x{11BF}" => 24,
	"\x{11C0}" => 25, "\x{11C1}" => 26, "\x{11C2}" => 27,
);

sub kchar_patchim {
	my $t = $_[1];
	return $t unless defined $t;
	while ( $t =~ /([^_])([\x{11A8}-\x{11C2}])/ ) {
		my $num  = int( unpack('U', $1) ) + $patchim_n{$2};
		my $conv = pack('U', $num);
		$t =~ s/$1$2/$conv/;
	}
	return $t;
}

1;
