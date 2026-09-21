#!/usr/bin/perl
# Size every border lot rect to its building, in the WorldEd project file.
#
#   perl Docs/tighten.pl                    # $PI_MAPSRC/.. , or the dir below
#   perl Docs/tighten.pl <dir or .pzw>
#   perl Docs/tighten.pl --detect           # exit 2 if anything needed fixing
#
# WorldEd stores a lot rect as the building PLUS ONE in each axis, and rewrites
# it on every save -- so this is a normalisation step, not a one-off fix. For a
# border building that fills a whole cell edge, that extra square lands in the
# NEXT CELL, and a lot writes its whole rect, blanks included, with the foreign
# lot winning over the cell's own. The result is one missing wall at every seam
# WorldEd has touched, and it comes back one cell at a time as you work.
#
# The buildings cannot cover it themselves: a wall object outside a building's
# own width is dropped by the exporter, so content can never reach the last
# rect column. Tightening the rect is the only thing that works.
#
# Run it AFTER any WorldEd session and BEFORE exporting. `map.cmd` also runs it,
# but that is after the fact -- there it repairs the file for the NEXT export
# and tells you the one you just made was built from spilled rects.
# `Docs/fencecheck.pl` is what checks the lotpacks that actually shipped.
#
# Exit status is 0 when nothing needed changing, 2 when something did.
use strict;
use warnings;

# Building footprints. A rect equal to these spills nowhere; anything larger
# reaches into the neighbouring cell.
my %want = (
    "Border_N"  => [256, 1],
    "Border_W"  => [1, 256],
    "Border_NW" => [1, 1],
);

# Repairing the file is the NORMAL outcome of the pre-export run, so that exits
# 0. `--detect` is for map.cmd, which runs AFTER the export and wants a non-zero
# exit to mean "the lotpacks you just copied were built from spilled rects".
my $DETECT = grep { $_ eq "--detect" } @ARGV;
@ARGV = grep { $_ ne "--detect" } @ARGV;

my $arg = shift // (($ENV{PI_MAPSRC} || "") =~ m{^(.*)[\\/][^\\/]+$} ? $1 : "");
die "tighten: no project given and PI_MAPSRC is not set\n" unless length $arg;
$arg =~ s{\\}{/}g;      # PI_MAPSRC is a Windows path; glob and -d want slashes

my @files;
if (-d $arg) {
    # readdir rather than glob: a project folder can hold a name with a space
    # in it.
    opendir my $dh, $arg or die "$arg: $!\n";
    my @pzw = grep { /\.pzw$/ and -f "$arg/$_" } readdir $dh;
    closedir $dh;
    # EVERY project in the folder, not just phuninteriors.pzw. pi5 now holds
    # three -- phunspawn and phunhub took the cells that were 87,49 and 88,49
    # -- and they share buildings/_, so they have the same border lots and
    # WorldEd spills their rects on save exactly the same way. Tightening one
    # and leaving the others is how a fence comes back with a hole in it.
    #
    # A `.pzw.bak` or `.pzw.pre-shrink` is not caught by the `.pzw$` test, but
    # a `something - Copy.pzw` is, and it is normalised along with the rest.
    # That costs nothing: tightening only ever makes a border lot rect match
    # the building it points at, and it is idempotent.
    die "tighten: no .pzw in $arg\n" unless @pzw;
    @files = map { "$arg/$_" } sort @pzw;
} else {
    @files = ($arg);
}
@files = grep { -f $_ } @files;
die "tighten: no .pzw found at $arg\n" unless @files;

my $total = 0;
for my $p (@files) {
    open my $fh, "<", $p or die "$p: $!\n";
    local $/;
    my $d = <$fh>;
    close $fh;
    my $before = $d;
    my $n = 0;

    # No /x on this pattern: it would strip the literal spaces out of it.
    #
    # The building name takes DIGITS as well as letters, and the pattern says
    # so even though the three current names do not need it. `Border_[A-Z]+`
    # was written when they were all letters and it silently skipped the one
    # `Border_W1` that briefly existed: that rect sat spilled at 2x2 through a
    # whole export while this printed "all border lot rects already tight".
    # A check that passes by not looking is worse than no check, and the shape
    # of that one is worth keeping -- the pattern was exactly right for every
    # name in existence when it was written.
    $d =~ s{(<lot x="-?\d+" y="-?\d+" level="\d+" width=")(\d+)(" height=")(\d+)(" map="[^"]*/(Border_[A-Z][A-Z0-9]*)\.tbx"/>)}{
        my ($p1, $w, $p2, $h, $p3, $b) = ($1, $2, $3, $4, $5, $6);
        my $t = $want{$b};
        if ($t and ($w != $t->[0] or $h != $t->[1])) { $n++; "$p1$t->[0]$p2$t->[1]$p3" }
        else                                         { "$p1$w$p2$h$p3" }
    }gse;

    if ($d eq $before) {
        printf "%s: all border lot rects already tight\n", $p;
        next;
    }
    open my $out, ">", $p or die "$p: $!\n";
    print $out $d;
    close $out;
    printf "%s: tightened %d border lot rect(s)\n", $p, $n;
    $total += $n;
}
exit(($DETECT and $total) ? 2 : 0);
