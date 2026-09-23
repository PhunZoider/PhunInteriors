#!/usr/bin/perl
# Give every room building a black z=1 floor over its interior and a black
# fence ring around it, matching RV_3x9.tbx, which was done by hand and
# confirmed in game.
#
#   phuninteriors_01_001  a solidfloor that also declares `exterior`, painted
#                         as a USER TILE on the z=1 Floor layer over the
#                         interior rect. Hides the roof deck, and is what makes
#                         the roof square outdoor so rain collection works.
#   phuninteriors_01_008+ the black exterior_wall set, four objects ringing the
#                         same rect, which hides the barrels standing on it.
#
# Idempotent: re-running removes the ring it added before putting it back.
use strict; use warnings;
my $dry = grep { $_ eq "--dry" } @ARGV;
# The buildings folder: named, or beside PI_MAPSRC as tighten.pl finds the
# project. PI_MAPSRC is a Windows path, so normalise the separators.
my $dir = shift;
unless (defined $dir and length $dir) {
    my $src = $ENV{PI_MAPSRC} || "";
    $src =~ s{\\}{/}g;
    $dir = ($src =~ m{^(.*)/[^/]+$}) ? "$1/buildings/_" : "";
}
die "blackroof: no buildings folder given and PI_MAPSRC is not set\n" unless length $dir;
$dir =~ s{\\}{/}g;
my $bak = "$dir/../_backup_blackroof";
mkdir $bak unless $dry or -d $bak;
my @skip = qw(Border_N.tbx Border_NW.tbx Border_W.tbx _room.tbx);
my %skip = map { $_ => 1 } @skip;
my ($done,$skipped,$failed) = (0,0,0);
for my $path (sort glob("$dir/*.tbx")) {
    my ($f) = $path =~ m{([^/]+)$};
    if ($skip{$f}) { printf("%-28s SKIP (no interior / template)\n",$f); $skipped++; next }
    local $/; open(my $fh,"<",$path) or die "$f: $!"; my $d = <$fh>; close $fh;
    my $orig = $d;

    my ($w,$h) = $d =~ /<building version="\d+" width="(\d+)" height="(\d+)"/;
    unless ($w) { printf("%-28s FAIL no building tag\n",$f); $failed++; next }

    # tile_entry indices, 1-based in document order, flat across categories
    my ($i,$ext,$int) = (0,0,0);
    while ($d =~ /<tile_entry category="([^"]+)">(.*?)<\/tile_entry>/gs) {
        $i++; my ($c,$b) = ($1,$2);
        $ext = $i if $c eq "exterior_walls" && $b =~ /tile="phuninteriors_01_008"/;
        $int = $i if $c eq "interior_walls" && $b =~ /tile="phuninteriors_01_008"/;
    }
    unless ($ext) { printf("%-28s FAIL no black exterior_walls entry\n",$f); $failed++; next }
    $int ||= $ext;

    # interior rect from the z=0 rooms grid, ignoring the shell and the
    # generator box
    my @rooms; while ($d =~ /<room Name="([^"]*)" InternalName="([^"]*)"/g) { push @rooms,[$1,$2] }
    my %ignore = map { ($_+1)=>1 } grep { $rooms[$_][1] eq 'emptyoutside' or $rooms[$_][0] eq 'Generator' } 0..$#rooms;
    my @lvl = $d =~ /<floor>(.*?)<\/floor>/gs;
    unless (@lvl == 2) { printf("%-28s FAIL %d floor levels\n",$f,scalar @lvl); $failed++; next }
    my ($g0) = $lvl[0] =~ /<rooms>\s*\n(.*?)\n?<\/rooms>/s;
    my ($x1,$y1,$x2,$y2) = (9e9,9e9,-1,-1); my $cells = 0;
    my @r0 = split /\n/, $g0;
    for my $y (0..$#r0) { my @c = split /,/, $r0[$y];
        for my $x (0..$#c) { my $v = $c[$x];
            next if !$v or $v == 0 or $ignore{$v};
            $cells++; $x1=$x if $x<$x1; $x2=$x if $x>$x2; $y1=$y if $y<$y1; $y2=$y if $y>$y2 } }
    unless ($x2 >= 0) { printf("%-28s FAIL no interior room painted\n",$f); $failed++; next }
    my ($bw,$bh) = ($x2-$x1+1, $y2-$y1+1);
    unless ($cells == $bw*$bh) { printf("%-28s FAIL interior is not a rectangle (%d cells in %dx%d)\n",$f,$cells,$bw,$bh); $failed++; next }

    # user tile index for the black floor, 1-based, 0 meaning none
    my $uidx;
    if ($d =~ /<user_tiles>(.*?)<\/user_tiles>/s) {
        my $body = $1; my @t = $body =~ /tile="([^"]+)"/g;
        my ($at) = grep { $t[$_] eq 'phuninteriors_01_001' } 0..$#t;
        if (defined $at) { $uidx = $at+1 }
        else { $uidx = @t+1;
            $d =~ s{(<user_tiles>.*?)(\n\s*</user_tiles>)}{$1\n  <tile tile="phuninteriors_01_001"/>$2}s }
    } elsif ($d =~ m{<user_tiles\s*/>}) {
        $uidx = 1;
        $d =~ s{<user_tiles\s*/>}{<user_tiles>\n  <tile tile="phuninteriors_01_001"/>\n </user_tiles>};
    } else { printf("%-28s FAIL no user_tiles element\n",$f); $failed++; next }

    # rebuild the z=1 level
    my @parts = split /(<floor>.*?<\/floor>)/s, $d;
    my $seen = 0; my $patched = 0;
    for my $p (@parts) {
        next unless $p =~ /^<floor>/;
        $seen++; next unless $seen == 2;

        # drop a ring we put in on an earlier run
        $p =~ s{^[ \t]*<object type="wall"[^>]*Tile="$ext"/>\n}{}gm;

        my $ring = join("", map { qq(  <object type="wall" length="$_->[0]" InteriorTile="$int" ExteriorTrim="0" InteriorTrim="0" x="$_->[1]" y="$_->[2]" dir="$_->[3]" Tile="$ext"/>\n) }
            ([$bh,$x1,$y1,q(N)], [$bw,$x1,$y2+1,q(W)], [$bh,$x2+1,$y1,q(N)], [$bw,$x1,$y1,q(W)]));
        $p =~ s{(^[ \t]*<rooms>)}{$ring$1}m or die "$f: no rooms grid at level 1\n";

        # the black floor, on the user tile Floor layer, (h+1) x (w+1)
        my @grid = map { [ (0) x ($w+1) ] } 0..$h;
        if ($p =~ m{<tiles layer="Floor">\s*\n(.*?)\n?</tiles>}s) {
            my @r = split /\n/, $1;
            for my $y (0..$#r) { my @c = split /,/, $r[$y];
                for my $x (0..$#c) { $grid[$y][$x] = $c[$x] if $c[$x] } }
        }
        for my $y ($y1..$y2) { for my $x ($x1..$x2) { $grid[$y][$x] = $uidx } }
        my @lines = map { join(",", @$_) } @grid;
        # every row but the last carries a trailing comma, as BuildingEd writes them
        $lines[$_] .= "," for 0 .. $#lines - 1;
        my $body = join("\n", @lines);
        my $block = qq(  <tiles layer="Floor">\n$body\n</tiles>\n);
        if ($p =~ m{<tiles layer="Floor">\s*\n.*?\n?</tiles>\n}s) {
            $p =~ s{[ \t]*<tiles layer="Floor">\s*\n.*?\n?</tiles>\n}{$block}s;
        } else {
            $p =~ s{(^</attributes>\n)}{$1$block}m or die "$f: no attributes grid at level 1\n";
        }
        $patched = 1;
    }
    unless ($patched) { printf("%-28s FAIL could not reach level 1\n",$f); $failed++; next }
    $d = join("", @parts);

    printf("%-28s rect %d,%d..%d,%d (%dx%d)  wall=%-3d int=%-3d usertile=%d  %s\n",
        $f,$x1,$y1,$x2,$y2,$bw,$bh,$ext,$int,$uidx, ($d eq $orig ? "unchanged" : "patched"));
    unless ($dry) {
        rename($path, "$bak/$f") or die "backup $f: $!" unless -e "$bak/$f";
        open(my $o,">",$path) or die "$f: $!"; print $o $d; close $o;
    }
    $done++;
}
printf("\n%d patched, %d skipped, %d failed\n",$done,$skipped,$failed);
