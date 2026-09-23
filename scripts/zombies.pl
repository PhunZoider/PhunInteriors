#!/usr/bin/perl
# What a map cell's zombie density actually is, read out of the lotheader.
#
#   perl scripts/zombies.pl <X_Y.lotheader> [...]      # tally per cell
#   perl scripts/zombies.pl -v <X_Y.lotheader>         # and the 32x32 grid
#
# Density is per meta chunk and lives in a 1024 byte tail on the .lotheader --
# one byte per chunk, 32 x 32, written straight after the building defs.
# IsoMetaGrid$MetaGridLoaderThread.loadCell reads it into a byte[1024] and
# throws EOFException if the file is short, so the block is always exactly
# there and exactly that size. It is the chunk a lotheader parse cannot
# otherwise account for.
#
# The loader then multiplies each byte by the product of the ZombieVoronoi
# cutoffs for that chunk and clamps to 0..255. A multiply, so a stored zero
# stays zero however the noise falls, and IsoMetaChunk.getZombieIntensity only
# scales further by the distribution and zombies sandbox options. Zero here
# means no zombies, which is what the interior cells want.
#
# Written because "the density layer should be nothing" is unanswerable by
# looking at the map editor, and because the first attempt to answer it from a
# vanilla baseline picked cell 38_23 -- world (9728, 5888), empty forest -- saw
# all zeros and concluded the byte was unused everywhere. Pick a baseline cell
# by world coordinate over an actual town: 42_38 is Muldraugh, 46_26 West
# Point, 50_7 Louisville, and all three are plainly non-zero.
#
#   P="/d/Steam/steamapps/common/ProjectZomboid/media/maps/Muldraugh, KY"
#   perl scripts/zombies.pl "$P/42_38.lotheader"

use strict;
use warnings;

my $verbose = (@ARGV and $ARGV[0] eq "-v") ? shift : 0;
die "usage: zombies.pl [-v] <X_Y.lotheader> [...]\n" unless @ARGV;

local $/;
for my $file (@ARGV) {
    open(my $f, "<:raw", $file) or die "$file: $!\n";
    my $h = <$f>;
    close $f;

    die "$file: too short to hold a 1024 byte intensity block\n"
        if length($h) < 1024;

    my @b = unpack("C*", substr($h, length($h) - 1024, 1024));

    my %count;
    $count{$_}++ for @b;
    my ($max) = sort { $b <=> $a } keys %count;
    my $nonzero = 1024 - ($count{0} || 0);

    printf "%s\n  %s\n", $file,
        $nonzero
            ? "$nonzero of 1024 chunks populated, max $max  ("
              . join(", ", map { "$_ x$count{$_}" } sort { $a <=> $b } keys %count) . ")"
            : "all 1024 chunks zero -- nothing spawns here";

    next unless $verbose;

    # Chunk c is column major, matching tiles.pl and the loader's own indexing:
    # index = chunkX * 32 + chunkY, so a row of output is one y across all x.
    for my $cy (0 .. 31) {
        print "  ", join("", map { my $v = $b[$_ * 32 + $cy]; $v ? ($v > 9 ? "+" : $v) : "." } 0 .. 31), "\n";
    }
}
