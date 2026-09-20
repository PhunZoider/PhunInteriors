#!/usr/bin/perl
# Dump the room defs of one cell: name, level, and each rect in world coords.
use strict; use warnings;
my $hdr = shift or die "usage: rooms.pl <cell.lotheader> [namefilter]\n";
my $filter = shift;
my ($cx, $cy) = $hdr =~ /(\d+)_(\d+)\.lotheader$/ or die "bad name\n";
my ($ox, $oy) = ($cx * 256, $cy * 256);
local $/; open(my $fh, "<:raw", $hdr) or die "$hdr: $!"; my $h = <$fh>;
my $tileCount = unpack("V", substr($h, 8, 4));
my $hp = 12;
for (1 .. $tileCount) { $hp = index($h, "\n", $hp) + 1 }
my $rp = $hp + 16;
my $roomCount = unpack("V", substr($h, $rp, 4)); $rp += 4;
printf("%s: %d room defs, cell origin %d,%d\n", $hdr, $roomCount, $ox, $oy);
for my $i (1 .. $roomCount) {
    my $e = index($h, "\n", $rp);
    my $name = substr($h, $rp, $e - $rp);
    $rp = $e + 1;
    my $level = unpack("V", substr($h, $rp, 4)); $rp += 4;
    my $rects = unpack("V", substr($h, $rp, 4)); $rp += 4;
    my @r;
    for (1 .. $rects) {
        my ($x, $y, $w, $hh) = unpack("V4", substr($h, $rp, 16)); $rp += 16;
        push @r, sprintf("[%d,%d %dx%d]", $ox + $x, $oy + $y, $w, $hh);
    }
    my $objs = unpack("V", substr($h, $rp, 4)); $rp += 4 + $objs * 12;
    next if defined $filter and $name !~ /$filter/;
    printf("  %-4d %-28s z=%d rects=%d %s\n", $i - 1, $name, $level, $rects, join(" ", @r));
}
