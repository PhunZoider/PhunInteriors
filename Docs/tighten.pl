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
    # in it, and the backups alongside must not be rewritten.
    opendir my $dh, $arg or die "$arg: $!\n";
    my @pzw = grep { /\.pzw$/ and -f "$arg/$_" } readdir $dh;
    closedir $dh;
    my ($main) = grep { $_ eq "phuninteriors.pzw" } @pzw;
    if    ($main)        { @files = ("$arg/$main") }
    elsif (@pzw == 1)    { @files = ("$arg/$pzw[0]") }
    elsif (@pzw)         { die "tighten: several .pzw in $arg, name one:\n"
                               . join("", map { "  $arg/$_\n" } sort @pzw) }
    else                 { die "tighten: no .pzw in $arg\n" }
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
    $d =~ s{(<lot x="-?\d+" y="-?\d+" level="\d+" width=")(\d+)(" height=")(\d+)(" map="[^"]*/(Border_[A-Z]+)\.tbx"/>)}{
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
