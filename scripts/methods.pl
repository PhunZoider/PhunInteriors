#!/usr/bin/perl
# Print the methods a class actually declares, with signatures.
#
# The constant pool alone is not enough: it holds every name a class *calls*
# as well as the ones it owns, which is why grepping for a method name gives
# false positives. This walks the real method table.
#
#   perl methods.pl <Foo.class> [name filter]
use strict;
use warnings;

my $path = shift or die "usage: methods.pl <class file> [filter]\n";
my $filter = shift;

open(my $fh, "<:raw", $path) or die "$path: $!";
local $/;
my $d = <$fh>;
close $fh;

my $pos = 0;
sub u1 { my $v = unpack("C", substr($d, $pos, 1)); $pos += 1; return $v }
sub u2 { my $v = unpack("n", substr($d, $pos, 2)); $pos += 2; return $v }
sub u4 { my $v = unpack("N", substr($d, $pos, 4)); $pos += 4; return $v }

die "not a class file\n" unless u4() == 0xCAFEBABE;
u2(); u2();   # minor, major

my $cpCount = u2();
my @cp;
for (my $i = 1; $i < $cpCount; $i++) {
    my $tag = u1();
    if ($tag == 1) {                        # Utf8
        my $len = u2();
        $cp[$i] = substr($d, $pos, $len);
        $pos += $len;
    } elsif ($tag == 7 || $tag == 8 || $tag == 16 || $tag == 19 || $tag == 20) {
        $pos += 2;
    } elsif ($tag == 15) {
        $pos += 3;
    } elsif ($tag == 5 || $tag == 6) {      # Long / Double take two slots
        $pos += 8;
        $i++;
    } else {
        $pos += 4;
    }
}

u2(); u2(); u2();                           # access, this, super
my $ifaces = u2();
$pos += 2 * $ifaces;

sub skipAttributes {
    my $count = u2();
    for (1 .. $count) {
        u2();
        my $len = u4();
        $pos += $len;
    }
}

my $fields = u2();
for (1 .. $fields) { u2(); u2(); u2(); skipAttributes(); }

# Turn a JVM descriptor into something readable
sub pretty {
    my ($desc) = @_;
    my ($args, $ret) = $desc =~ /^\((.*)\)(.+)$/ or return $desc;
    my @out;
    while ($args) {
        my $arr = "";
        while ($args =~ s/^\[//) { $arr .= "[]" }
        if ($args =~ s/^L([^;]+);//) {
            my $cls = $1;
            $cls =~ s{.*/}{};
            push @out, $cls . $arr;
        } elsif ($args =~ s/^(.)//) {
            my %prim = (B=>'byte', C=>'char', D=>'double', F=>'float',
                        I=>'int', J=>'long', S=>'short', Z=>'boolean', V=>'void');
            push @out, ($prim{$1} // $1) . $arr;
        } else {
            last;
        }
    }
    my $r = $ret;
    $r =~ s/^\[+//;
    if ($r =~ /^L([^;]+);$/) { $r = $1; $r =~ s{.*/}{}; }
    else {
        my %prim = (B=>'byte', C=>'char', D=>'double', F=>'float',
                    I=>'int', J=>'long', S=>'short', Z=>'boolean', V=>'void');
        $r = $prim{$r} // $r;
    }
    return "(" . join(", ", @out) . ") -> $r";
}

my $methods = u2();
my @found;
for (1 .. $methods) {
    my $access = u2();
    my $name = $cp[u2()];
    my $desc = $cp[u2()];
    skipAttributes();
    next if defined $filter && $name !~ /\Q$filter\E/i;
    my $vis = ($access & 0x0001) ? "public" : ($access & 0x0002) ? "private"
            : ($access & 0x0004) ? "protected" : "package";
    my $static = ($access & 0x0008) ? " static" : "";
    push @found, sprintf("  %-9s%-7s %s %s", $vis, $static, $name, pretty($desc));
}

print "$path (" . scalar(@found) . " matching)\n";
print "$_\n" for sort @found;
