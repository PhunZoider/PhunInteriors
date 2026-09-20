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
#   perl Docs/fencecheck.pl                  # every cell under media/maps
#   perl Docs/fencecheck.pl <dir>            # a different map folder
use strict; use warnings;
my $M = shift // "Contents/mods/PhunInteriors/common/media/maps/phuninteriors";
use File::Basename qw(dirname);
# $0 arrives as Docs\fencecheck.pl from cmd and Docs/fencecheck.pl from a
# shell, and File::Basename does not treat a backslash as a separator -- so
# without this it looks for tiles.pl in the wrong place, every subprocess
# produces nothing, and that reads as the whole fence being missing.
(my $self = $0) =~ s{\\}{/}g;
my $TILES = dirname($self) . "/tiles.pl";
my ($X0,$Y0,$X1,$Y1) = (22272, 11776, 23551, 12799);
my @cells = qw(87_46 88_46 89_46 90_46 91_46 87_47 87_48 87_49
               88_49 89_49 90_49 91_49 91_47 91_48);
my (%W, %N, %NW);
for my $c (@cells) {
    my $p = "$M/world_$c.lotpack";
    next unless -f $p;
    for my $t (8, 9, 10) {
        # Backticks, not a list-form `open "-|"`: that needs fork, and the
        # Windows perl map.cmd picks up silently produces nothing, which reads
        # as every wall being missing. roomcheck.pl shells out the same way.
        for (`"$^X" "$TILES" "$p" phuninteriors_01_$t 2>&1`) {
            next unless /^\s*(\d+),(\d+)\s+z=0/;
            my $k = "$1,$2";
            $t == 8 ? ($W{$k} = 1) : $t == 9 ? ($N{$k} = 1) : ($NW{$k} = 1);
        }
    }
}
my @bad;
for my $x ($X0..$X1) {
    push @bad, "north $x,$Y0" unless $N{"$x,$Y0"} or $NW{"$x,$Y0"};
    push @bad, "south $x,$Y1" unless $N{"$x,$Y1"} or $NW{"$x,$Y1"};
}
for my $y ($Y0..$Y1) {
    push @bad, "west $X0,$y" unless $W{"$X0,$y"} or $NW{"$X0,$y"};
    push @bad, "east $X1,$y" unless $W{"$X1,$y"} or $NW{"$X1,$y"};
}
printf "perimeter %d squares, %d gaps\n", 2*($X1-$X0+1)+2*($Y1-$Y0+1), scalar @bad;
for (@bad) {
    my ($side,$x,$y) = /(\w+) (\d+),(\d+)/;
    printf "  %-6s %5d,%-5d  cell %d,%d local %d,%d\n",
        $side,$x,$y,int($x/256),int($y/256),$x%256,$y%256;
}
print "\ncorners (each needs the WallNW post, phuninteriors_01_10):\n";
for my $c (["NW",$X0,$Y0],["NE",$X1,$Y0],["SW",$X0,$Y1],["SE",$X1,$Y1]) {
    my ($n,$x,$y) = @$c; my $k = "$x,$y";
    printf "  %-3s %-13s WallNW=%-4s WallW=%-4s WallN=%s\n",
        $n, $k, ($NW{$k}?"YES":"no"), ($W{$k}?"yes":"no"), ($N{$k}?"yes":"no");
}
my $missing = grep { !$NW{$_} } ("$X0,$Y0","$X1,$Y0","$X0,$Y1","$X1,$Y1");
exit((@bad or $missing) ? 1 : 0);
