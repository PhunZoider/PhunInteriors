#!/usr/bin/perl
# What a map cell actually contains, read straight out of the lotpack.
#
#   perl Docs/tiles.pl <world_X_Y.lotpack>              # tally every tile
#   perl Docs/tiles.pl <world_X_Y.lotpack> <tile_name>  # and where they are
#
# The lotheader beside it is found automatically, and the cell origin comes
# from the filename, so world coordinates come out directly.
#
# Written when a test map rendered a generator on every square of open ground.
# The mod's log showed it had placed exactly one, so the question was whether
# the other 35,000 were in the map file -- and counting them settled it in one
# command. It then earned its keep twice more: confirming the fix, and finding
# where the real generators were so `set.power` could point at them instead of
# at the offset the borrowed room set had used.
#
# FORMAT, worked out from the bytes and validated by the square count landing
# on 256*256 and by a known light switch landing on a known room origin:
#
#   "LOTP", int version, int chunkCount (1024 = 32 x 32)
#   chunkCount * int64 file offsets
#   per chunk, a stream of entries:
#     -1, N          N empty entries, skipped
#     count, v...    count ints: v[0] is the room id (-1 for none),
#                    the rest are indices into the lotheader's tile names
#
#   Entries run 64 per level: entry e is level int(e/64), and within a level
#   square int(e/8) across by e%8 down. Chunk c is column major too, at chunk
#   coordinates (int(c/32), c%32).
#
#   Both orderings are column major, which is the thing to re-check first if
#   the output ever looks transposed.
#
# A cell full of "-1, N" runs is a healthy one: empty squares should be absent,
# not painted. If a tile shows a huge count in the "alone" column, every empty
# square in the cell is wearing it.

use strict;
use warnings;

my ($file, $want) = @ARGV;
die "usage: tiles.pl <world_X_Y.lotpack> [tile_name]\n" unless $file;

my ($cx, $cy) = $file =~ /world_(\d+)_(\d+)\.lotpack$/
    or die "cannot read the cell number out of '$file'\n";
(my $hdr = $file) =~ s/world_(\d+_\d+)\.lotpack$/$1.lotheader/;
my ($ox, $oy) = ($cx * 256, $cy * 256);

local $/;
open(my $f, "<:raw", $file) or die "$file: $!";
my $d = <$f>;
open(my $fh, "<:raw", $hdr) or die "$hdr: $!";
my $h = <$fh>;

my $tileCount = unpack("V", substr($h, 8, 4));
my $hp = 12;
my @names;
for (1 .. $tileCount) {
    my $e = index($h, "\n", $hp);
    push @names, substr($h, $hp, $e - $hp);
    $hp = $e + 1;
}
my %index;
$index{$names[$_]} = $_ for 0 .. $#names;

if (defined $want and not exists $index{$want}) {
    die "'$want' is not in this cell's palette. It has:\n  " . join("\n  ", @names) . "\n";
}

my $chunks = unpack("V", substr($d, 8, 4));
my @off = map { unpack("V", substr($d, 12 + $_ * 8, 4)) } (0 .. $chunks - 1);

my (%tally, %alone, @hits);
my ($squares, $empties) = (0, 0);

for my $c (0 .. $chunks - 1) {
    my $p = $off[$c];
    my $end = ($c < $chunks - 1) ? $off[$c + 1] : length($d);
    my ($chx, $chy) = (int($c / 32), $c % 32);
    my $e = 0;
    while ($p + 4 <= $end) {
        my $cnt = unpack("l<", substr($d, $p, 4));
        $p += 4;
        if ($cnt == -1) {
            my $skip = unpack("l<", substr($d, $p, 4));
            $p += 4;
            $e += $skip;
            $empties += $skip;
            next;
        }
        last if $cnt <= 0 or $p + $cnt * 4 > $end;
        my @v = map { unpack("l<", substr($d, $p + $_ * 4, 4)) } (0 .. $cnt - 1);
        $p += $cnt * 4;
        $squares++;
        my @tiles = grep { $_ >= 0 } @v[1 .. $#v];
        $tally{$_}++ for @tiles;
        $alone{$tiles[0]}++ if @tiles == 1;
        if (defined $want and grep { $_ == $index{$want} } @tiles) {
            my ($z, $s) = (int($e / 64), $e % 64);
            push @hits, [$ox + $chx * 8 + int($s / 8), $oy + $chy * 8 + ($s % 8), $z, $v[0]];
        }
        $e++;
    }
}

printf("%s  (cell %d,%d -> %d,%d)\n", $file, $cx, $cy, $ox, $oy);
printf("  %d tiles in the palette, %d squares with content, %d empty\n\n",
    scalar(@names), $squares, $empties);

if (defined $want) {
    printf("  %s x%d\n", $want, scalar @hits);
    printf("    %d,%d z=%d  roomID %d\n", @$_) for @hits;
    exit;
}

printf("  %-34s %8s %8s\n", "tile", "total", "alone");
for my $k (sort { $tally{$b} <=> $tally{$a} } keys %tally) {
    printf("  %-34s %8d %8d\n", $names[$k] // "?($k)", $tally{$k}, $alone{$k} // 0);
}
