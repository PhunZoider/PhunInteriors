#!/usr/bin/perl
# Disassemble one method body from a .class file.
#
# Companion to methods.pl. That one answers "does this class declare X";
# this one answers "and what does X actually do", which is the question you
# reach as soon as a declared method does not behave the way its name reads.
#
# No JDK required -- the game ships a JRE, so javap is not available.
#
#   perl body.pl <Foo.class> <methodName> [descriptor]
use strict;
use warnings;

my $path = shift or die "usage: body.pl <class file> <method> [descriptor]\n";
my $want = shift or die "usage: body.pl <class file> <method> [descriptor]\n";
my $wantDesc = shift;

open(my $fh, "<:raw", $path) or die "$path: $!";
local $/;
my $d = <$fh>;
close $fh;

my $pos = 0;
sub u1 { my $v = unpack("C", substr($d, $pos, 1)); $pos += 1; return $v }
sub u2 { my $v = unpack("n", substr($d, $pos, 2)); $pos += 2; return $v }
sub u4 { my $v = unpack("N", substr($d, $pos, 4)); $pos += 4; return $v }
sub s2 { my $v = unpack("n", substr($d, $pos, 2)); $pos += 2; return $v > 32767 ? $v - 65536 : $v }

die "not a class file\n" unless u4() == 0xCAFEBABE;
u2(); u2();

my $cpCount = u2();
my (@cp, @tag);
for (my $i = 1; $i < $cpCount; $i++) {
    my $t = u1();
    $tag[$i] = $t;
    if ($t == 1) { my $len = u2(); $cp[$i] = substr($d, $pos, $len); $pos += $len }
    elsif ($t == 7 || $t == 8 || $t == 16 || $t == 19 || $t == 20) { $cp[$i] = [u2()] }
    elsif ($t == 15) { u1(); $cp[$i] = [u2()] }
    elsif ($t == 5 || $t == 6) { $pos += 8; $i++ }
    else { $cp[$i] = [u2(), u2()] }
}

# Class / Fieldref / Methodref / NameAndType resolution
sub cls  { my $i = shift; my $n = $cp[$cp[$i][0]]; $n =~ s{.*/}{}; return $n }
sub ref_ {
    my $i = shift;
    return "?" unless $cp[$i] && @{$cp[$i]} == 2;
    my ($ci, $nti) = @{$cp[$i]};
    my ($ni, $di) = @{$cp[$nti]};
    return cls($ci) . "." . $cp[$ni] . " " . $cp[$di];
}

u2(); u2(); u2();
my $ifaces = u2(); $pos += 2 * $ifaces;

sub skipAttrs { my $c = u2(); for (1 .. $c) { u2(); my $l = u4(); $pos += $l } }
my $fields = u2();
for (1 .. $fields) { u2(); u2(); u2(); skipAttrs() }

# operand byte counts; switches and wide handled inline
my %len = (
    0x10=>1, 0x11=>2, 0x12=>1, 0x13=>2, 0x14=>2, 0x84=>2, 0xa9=>1,
    0xb9=>4, 0xba=>4, 0xbc=>1, 0xc5=>3, 0xc8=>4, 0xc9=>4,
);
$len{$_} = 1 for (0x15..0x19, 0x36..0x3a);
$len{$_} = 2 for (0x99..0xa8, 0xb2..0xb8, 0xbb, 0xbd, 0xc0, 0xc1, 0xc6, 0xc7);

my %name = (
    0xb2=>'getstatic', 0xb3=>'putstatic', 0xb4=>'getfield', 0xb5=>'putfield',
    0xb6=>'invokevirtual', 0xb7=>'invokespecial', 0xb8=>'invokestatic',
    0xb9=>'invokeinterface', 0xbb=>'new', 0xc0=>'checkcast', 0xc1=>'instanceof',
    0x99=>'ifeq', 0x9a=>'ifne', 0x9b=>'iflt', 0x9c=>'ifge', 0x9d=>'ifgt', 0x9e=>'ifle',
    0x9f=>'if_icmpeq', 0xa0=>'if_icmpne', 0xa1=>'if_icmplt', 0xa2=>'if_icmpge',
    0xa3=>'if_icmpgt', 0xa4=>'if_icmple', 0xa5=>'if_acmpeq', 0xa6=>'if_acmpne',
    0xa7=>'goto', 0xc6=>'ifnull', 0xc7=>'ifnonnull',
    0x2a=>'aload_0', 0x2b=>'aload_1', 0x2c=>'aload_2', 0x2d=>'aload_3',
    0x03=>'iconst_0', 0x04=>'iconst_1', 0x01=>'aconst_null',
    0xac=>'ireturn', 0xb0=>'areturn', 0xb1=>'return', 0x57=>'pop', 0x59=>'dup',
);

my $methods = u2();
for (1 .. $methods) {
    u2();
    my $mname = $cp[u2()];
    my $mdesc = $cp[u2()];
    my $ac = u2();
    my $hit = ($mname eq $want) && (!defined $wantDesc || $mdesc eq $wantDesc);
    for (1 .. $ac) {
        my $an = $cp[u2()];
        my $al = u4();
        my $end = $pos + $al;
        if ($hit && $an eq 'Code') {
            print "$mname $mdesc\n";
            u2(); u2();                      # max_stack, max_locals
            my $clen = u4();
            my $cend = $pos + $clen;
            my $base = $pos;
            while ($pos < $cend) {
                my $off = $pos - $base;
                my $op = u1();
                my $n = $name{$op} // sprintf("op_%02x", $op);
                if ($op == 0xaa || $op == 0xab) {        # switches
                    $pos += (4 - (($pos - $base) % 4)) % 4;
                    my $def = u4();
                    if ($op == 0xaa) { my $lo = u4(); my $hi = u4(); $pos += 4 * ($hi - $lo + 1) }
                    else { my $np = u4(); $pos += 8 * $np }
                    printf("  %4d: %s\n", $off, $op == 0xaa ? 'tableswitch' : 'lookupswitch');
                    next;
                }
                if ($op == 0xc4) { my $o2 = u1(); $pos += ($o2 == 0x84) ? 4 : 2; printf("  %4d: wide\n", $off); next }
                my $nb = $len{$op} // 0;
                if ($op == 0x12 || $op == 0x13) {
                    my $idx = ($op == 0x12) ? u1() : u2();
                    my $v = $tag[$idx] == 8 ? "\"" . $cp[$cp[$idx][0]] . "\"" : ($tag[$idx] == 7 ? cls($idx) : (defined $cp[$idx] && !ref $cp[$idx] ? $cp[$idx] : "#$idx"));
                    printf("  %4d: %-16s %s
", $off, "ldc", $v);
                    next;
                }
                if ($nb == 2 && $op >= 0xb2 && $op <= 0xc1) {
                    my $idx = u2();
                    my $t = $op == 0xbb || $op == 0xc0 || $op == 0xc1 ? cls($idx) : ref_($idx);
                    printf("  %4d: %-16s %s\n", $off, $n, $t);
                } elsif ($nb == 2 && $op >= 0x99 && $op <= 0xa8) {
                    my $b = s2(); printf("  %4d: %-16s %d\n", $off, $n, $off + $b);
                } elsif ($nb == 4 && ($op == 0xb9 || $op == 0xba)) {
                    my $idx = u2(); u2();
                    printf("  %4d: %-16s %s\n", $off, $n, ref_($idx));
                } else {
                    $pos += $nb;
                    printf("  %4d: %s\n", $off, $n);
                }
            }
            exit 0;
        }
        $pos = $end;
    }
}
print "no method '$want'" . (defined $wantDesc ? " $wantDesc" : "") . " in $path\n";
