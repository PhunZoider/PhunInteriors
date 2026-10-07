#!/usr/bin/perl
# Put the black ground under every wall that stands outside a room, in every
# room building. Run from the repo root, then Generate Lots in WorldEd.
#
#   perl scripts/blackground.pl [--dry] [buildings folder]
#
# The exporter writes no floor on a square that carries a wall unless a real
# room claims that square. A room's own west and north walls stand on its
# floor, so they are fine; its south and east walls stand on the squares
# BEYOND the floor, and so does every wall of the emptyoutside shell, and
# none of those squares had any ground at all. In the iso view the wall
# sprite hides that. In Project Viewpoint it was a strip of bare sky-blue
# ground along the outside of every room, under the shell ring too.
#
#   phuninteriors_01_000  the block's ground tile, the shell's own Floor,
#                         painted as a USER TILE on the z=0 Floor layer over
#                         each such square. A square a real room claims is
#                         left alone, since that room writes its own floor.
#
# Idempotent: a square already carrying a user floor tile is not touched, so
# a second run changes nothing. Only level 0 is edited. Walls are read from
# the <object type="wall"> list, where `dir` is the direction a wall RUNS:
# dir="N" is a west wall along x, dir="W" a north wall along y. Each run also
# claims the square one past its end, which is where the corner post goes.
use strict; use warnings;
my $dry = grep { $_ eq "--dry" } @ARGV;
@ARGV = grep { $_ ne "--dry" } @ARGV;
my $dir = shift;
unless (defined $dir and length $dir) {
    my $src = $ENV{PI_MAPSRC} || "";
    $src =~ s{\\}{/}g;
    $dir = ($src =~ m{^(.*)/[^/]+$}) ? "$1/buildings/_" : "";
}
die "blackground: no buildings folder given and PI_MAPSRC is not set\n" unless length $dir;
$dir =~ s{\\}{/}g;
my $bak = "$dir/../_backup_blackground";
mkdir $bak unless $dry or -d $bak;

# Not ours, or no rooms: the fence lots, the template, and the PhunRooms and
# PhunTaxi buildings that share this folder.
my %skip = map { $_ => 1 } qw(Border_N.tbx Border_NW.tbx Border_W.tbx _room.tbx
    hub.tbx hub_generic.tbx hub_market.tbx hub_pvp.tbx spawn.tbx);
my $TILE = "phuninteriors_01_000";
my ($done, $same, $skipped, $failed) = (0, 0, 0, 0);

for my $path (sort glob("$dir/*.tbx")) {
    my ($f) = $path =~ m{([^/]+)$};
    if ($skip{$f}) { printf("%-28s SKIP\n", $f); $skipped++; next }
    local $/; open(my $fh, "<", $path) or die "$f: $!"; my $d = <$fh>; close $fh;
    my $orig = $d;

    my ($w, $h) = $d =~ /<building version="\d+" width="(\d+)" height="(\d+)"/;
    unless ($w) { printf("%-28s FAIL no building tag\n", $f); $failed++; next }

    my @rooms; push @rooms, $1 while $d =~ /<room Name="[^"]*" InternalName="([^"]*)"/g;

    # user tile index for the ground, 1-based
    my $uidx;
    if ($d =~ /<user_tiles>(.*?)<\/user_tiles>/s) {
        my @t = $1 =~ /tile="([^"]+)"/g;
        my ($at) = grep { $t[$_] eq $TILE } 0 .. $#t;
        if (defined $at) { $uidx = $at + 1 }
        else {
            $uidx = @t + 1;
            $d =~ s{(<user_tiles>.*?)(\n\s*</user_tiles>)}{$1\n  <tile tile="$TILE"/>$2}s;
        }
    } elsif ($d =~ m{<user_tiles\s*/>}) {
        $uidx = 1;
        $d =~ s{<user_tiles\s*/>}{<user_tiles>\n  <tile tile="$TILE"/>\n </user_tiles>};
    } else { printf("%-28s FAIL no user_tiles element\n", $f); $failed++; next }

    my @parts = split /(<floor>.*?<\/floor>)/s, $d;
    my ($lvl) = grep { $parts[$_] =~ /^<floor>/ } 0 .. $#parts;
    unless (defined $lvl) { printf("%-28s FAIL no levels\n", $f); $failed++; next }
    my $p = $parts[$lvl];

    my ($g) = $p =~ /<rooms>\s*\n(.*?)\n?<\/rooms>/s;
    unless (defined $g) { printf("%-28s FAIL no rooms grid at level 0\n", $f); $failed++; next }
    my @rg = map { [ split /,/ ] } split /\n/, $g;
    my $claimed = sub {
        my ($x, $y) = @_;
        my $v = $rg[$y] && $rg[$y][$x];
        return 0 unless $v;
        my $name = $rooms[$v - 1] // "";
        return $name ne "emptyoutside";
    };

    my %want;
    while ($p =~ /<object type="wall" length="(\d+)"[^>]*? x="(\d+)" y="(\d+)" dir="([NW])"/g) {
        my ($len, $x, $y, $dr) = ($1, $2, $3, $4);
        for my $i (0 .. $len) {
            my ($sx, $sy) = $dr eq "N" ? ($x, $y + $i) : ($x + $i, $y);
            next if $sx > $w or $sy > $h;
            $want{"$sx,$sy"} = 1 unless $claimed->($sx, $sy);
        }
    }

    my @grid = map { [ (0) x ($w + 1) ] } 0 .. $h;
    my $had = $p =~ m{<tiles layer="Floor">\s*\n(.*?)\n?</tiles>}s;
    if ($had) {
        my @r = split /\n/, $1;
        for my $y (0 .. $#r) { my @c = split /,/, $r[$y];
            for my $x (0 .. $#c) { $grid[$y][$x] = $c[$x] if $c[$x] } }
    }
    my $added = 0;
    for my $k (keys %want) {
        my ($x, $y) = split /,/, $k;
        next if $grid[$y][$x];
        $grid[$y][$x] = $uidx; $added++;
    }
    if (!$added) {
        printf("%-28s unchanged (%d wall squares already floored)\n", $f, scalar keys %want);
        $same++; next;
    }
    my @lines = map { join(",", @$_) } @grid;
    $lines[$_] .= "," for 0 .. $#lines - 1;
    my $block = qq(  <tiles layer="Floor">\n) . join("\n", @lines) . qq(\n</tiles>\n);
    if ($had) {
        $p =~ s{[ \t]*<tiles layer="Floor">\s*\n.*?\n?</tiles>\n}{$block}s;
    } else {
        $p =~ s{(^</attributes>\n)}{$1$block}m
            or $p =~ s{(^[ \t]*</floor>)}{$block$1}m
            or do { printf("%-28s FAIL nowhere to put the layer\n", $f); $failed++; next };
    }
    $parts[$lvl] = $p;
    $d = join("", @parts);

    printf("%-28s +%d squares, usertile=%d\n", $f, $added, $uidx);
    unless ($dry) {
        rename($path, "$bak/$f") or die "backup $f: $!" unless -e "$bak/$f";
        open(my $o, ">", $path) or die "$f: $!"; print $o $d; close $o;
    }
    $done++;
}
printf("\n%d patched, %d unchanged, %d skipped, %d failed%s\n",
    $done, $same, $skipped, $failed, $dry ? " (dry run)" : "");
