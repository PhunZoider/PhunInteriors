#!/usr/bin/perl
# Does the exported map actually have an unbroken border fence?
#
# Reads the perimeter out of the lotpacks -- the only place that answers for
# what SHIPS rather than for what the editor intended. Two things it catches
# that reading the .pzw cannot:
#
#   * a lot rect one square bigger than its building, which spills into the
#     next cell and blanks the neighbour's first wall, because the last lot to
#     claim a square writes it whether it has content there or not;
#   * a corner square claimed by two different lots, where one wall face wins
#     and the other is lost, leaving a hole with no WallNW post.
#
#   perl Docs/fencecheck.pl                  # PhunInteriors' map
#   perl Docs/fencecheck.pl <dir>            # any map folder
#   perl Docs/fencecheck.pl --tiles <prefix> <dir>
#
# THE PERIMETER IS DERIVED, not listed. It used to be a hand-written table of
# segments and corners, which was right for a rectangle and had to be rewritten
# by hand the moment the block became an L. Deriving it means the check follows
# the map: carve a cell out, add one, or point it at a one-cell map like
# PhunSpawn's, and it asks the right question with no edit here.
use strict;
use warnings;
use File::Basename qw(dirname);

# PZ only has West and North wall sprites -- an east wall is the west wall of
# the next square -- so every face below is one of those two, plus the NW post
# that carries both in one sprite.
my ($W, $N, $NW) = (8, 9, 10);
my $PREFIX = "phuninteriors_01";
my @argv;
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq "--tiles") { $PREFIX = shift(@ARGV) // die "--tiles wants a prefix\n" }
    else                 { push @argv, $a }
}
my $M = shift(@argv)
     // "Contents/mods/PhunInteriors/common/media/maps/phuninteriors";

# $0 arrives as Docs\fencecheck.pl from cmd and Docs/fencecheck.pl from a
# shell, and File::Basename does not treat a backslash as a separator -- so
# without this it looks for tiles.pl in the wrong place, every subprocess
# produces nothing, and that reads as the whole fence being missing.
(my $self = $0) =~ s{\\}{/}g;
my $TILES = dirname($self) . "/tiles.pl";
my $CELL = 256;

# --- which cells ship -------------------------------------------------------
my (%cell, %cxs, %cys);
for my $p (glob("$M/world_*.lotpack")) {
    next unless $p =~ /world_(\d+)_(\d+)\.lotpack$/;
    $cell{"$1,$2"} = 1;
    $cxs{$1} = 1;
    $cys{$2} = 1;
}
die "no lotpacks in $M\n" unless %cell;

# --- what is inside the fence -----------------------------------------------
#
# Every square of every cell we ship, MINUS the last row of a cell whose south
# neighbour is absent and the last column of a cell whose east neighbour is
# absent. That subtraction is the whole convention: a WallN blocks the north
# edge of its own square and a WallW the west edge of its own, so the north and
# west runs sit on the first line INSIDE the block while the south and east
# runs sit on the first line outside it. Line 255 of an outer cell is the map
# edge and costs nothing.
#
# A predicate rather than a materialised set: eighteen cells is 1.18M squares
# and nothing here needs them all at once.
sub inside {
    my ($x, $y) = @_;
    return 0 if $x < 0 or $y < 0;
    my $cx = int($x / $CELL);
    my $cy = int($y / $CELL);
    return 0 unless $cell{"$cx,$cy"};
    return 0 if $x % $CELL == $CELL - 1 and not $cell{($cx + 1) . ",$cy"};
    return 0 if $y % $CELL == $CELL - 1 and not $cell{"$cx," . ($cy + 1)};
    return 1;
}

# --- which squares must carry which face ------------------------------------
#
# A boundary of the inside set only ever falls on a cell edge, so only three
# lines per cell can carry one: local 0, local 255, and local **254**. That
# third is the one worth spelling out. A cell whose south neighbour is absent
# has its last row excluded, so the boundary sits between 254 and 255 rather
# than at the cell edge -- and the square doing the asking is the one at 254,
# INSIDE, looking south at a 255 that is outside. Scanning only 0 and 255
# visited no square that could see it, so the entire new south fence came back
# as "not required" and the check passed with a hole in it.
my @cx = sort { $a <=> $b } keys %cxs;
my @cy = sort { $a <=> $b } keys %cys;
my $x0 = $cx[0] * $CELL;
my $x1 = ($cx[-1] + 1) * $CELL - 1;
my $y0 = $cy[0] * $CELL;
my $y1 = ($cy[-1] + 1) * $CELL - 1;

my (%needW, %needN);
for my $c (@cx) {
    for my $x ($c * $CELL, $c * $CELL + $CELL - 2, $c * $CELL + $CELL - 1) {
        for my $y ($y0 .. $y1) {
            next unless inside($x, $y);
            # Inside, with nothing inside to the west: this square's own west
            # face is the fence.
            $needW{"$x,$y"} = 1 unless inside($x - 1, $y);
            # Inside, with nothing inside to the east: the fence is the west
            # face of the square BEYOND, which is itself outside.
            $needW{($x + 1) . ",$y"} = 1 unless inside($x + 1, $y);
        }
    }
}
for my $c (@cy) {
    for my $y ($c * $CELL, $c * $CELL + $CELL - 2, $c * $CELL + $CELL - 1) {
        for my $x ($x0 .. $x1) {
            next unless inside($x, $y);
            $needN{"$x,$y"} = 1 unless inside($x, $y - 1);
            $needN{"$x," . ($y + 1)} = 1 unless inside($x, $y + 1);
        }
    }
}

# --- where the fence turns --------------------------------------------------
#
# A west face of square (x,y) runs between the POINTS (x,y) and (x,y+1); a
# north face runs between (x,y) and (x+1,y). Where a required west face and a
# required north face share a point the fence turns, and the square whose
# north-west corner is that point takes the WallNW post -- one sprite carrying
# both faces, rather than two sprites meeting at a notch.
#
# That rule is what the hand-written corner table used to be, and it is better
# than the table was: it finds the CONCAVE turn too, which is the one somebody
# reading a rectangle does not think to write down.
my (%wpt, %npt);
for my $k (keys %needW) {
    my ($x, $y) = split /,/, $k;
    $wpt{"$x,$y"} = 1;
    $wpt{"$x," . ($y + 1)} = 1;
}
for my $k (keys %needN) {
    my ($x, $y) = split /,/, $k;
    $npt{"$x,$y"} = 1;
    $npt{($x + 1) . ",$y"} = 1;
}
my @turns = sort grep { $npt{$_} } keys %wpt;

# --- read the walls that shipped --------------------------------------------
#
# Only the cells a required face falls in. On the L that is fourteen of the
# eighteen; on a one-cell map it is the one.
my %want;
for my $k (keys %needW, keys %needN, @turns) {
    my ($x, $y) = split /,/, $k;
    $want{int($x / $CELL) . "_" . int($y / $CELL)} = 1;
}
my (%hasW, %hasN, %hasNW);
for my $c (sort keys %want) {
    my $p = "$M/world_$c.lotpack";
    next unless -f $p;
    for my $t ($W, $N, $NW) {
        # Backticks, not a list-form `open "-|"`: that needs fork, and the
        # Windows perl map.cmd picks up silently produces nothing, which reads
        # as every wall being missing. roomcheck.pl shells out the same way.
        for (`"$^X" "$TILES" "$p" ${PREFIX}_$t 2>&1`) {
            next unless /^\s*(\d+),(\d+)\s+z=0/;
            my $k = "$1,$2";
            if    ($t == $W) { $hasW{$k}  = 1 }
            elsif ($t == $N) { $hasN{$k}  = 1 }
            else             { $hasNW{$k} = 1 }
        }
    }
}

# --- report -----------------------------------------------------------------
my @bad;
for my $k (sort keys %needW) {
    push @bad, ["west", $k] unless $hasW{$k} or $hasNW{$k};
}
for my $k (sort keys %needN) {
    push @bad, ["north", $k] unless $hasN{$k} or $hasNW{$k};
}
my @postless = grep { not $hasNW{$_} } @turns;

printf "%d cells, %d faces required (%d west, %d north), %d turns\n",
    scalar(keys %cell), scalar(keys %needW) + scalar(keys %needN),
    scalar(keys %needW), scalar(keys %needN), scalar(@turns);
printf "%d gaps, %d turns without a post\n", scalar(@bad), scalar(@postless);

for my $b (@bad) {
    my ($face, $k) = @$b;
    my ($x, $y) = split /,/, $k;
    printf "  gap   %-5s %5d,%-5d  cell %d,%d local %d,%d\n",
        $face, $x, $y, int($x / $CELL), int($y / $CELL), $x % $CELL, $y % $CELL;
}
print "\nturns (each needs the WallNW post, ${PREFIX}_$NW):\n";
for my $k (@turns) {
    my ($x, $y) = split /,/, $k;
    printf "  %-13s cell %d,%d local %-3d,%-3d  WallNW=%-4s W=%-4s N=%s\n",
        $k, int($x / $CELL), int($y / $CELL), $x % $CELL, $y % $CELL,
        ($hasNW{$k} ? "YES" : "no"),
        ($hasW{$k}  ? "yes" : "no"),
        ($hasN{$k}  ? "yes" : "no");
}
print "\nthe fence is unbroken\n" unless @bad or @postless;
exit((@bad or @postless) ? 1 : 0);
