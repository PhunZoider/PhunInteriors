#!/usr/bin/perl
# Face each room's south and east walls with the room's own interior wall
# set, in every room building. Run from the repo root, then Generate Lots.
#
#   perl scripts/innerwalls.pl [--dry] [buildings folder]
#
# PZ keeps one sprite per wall edge, chosen by the square the wall stands on.
# A room's west and north walls stand on its own floor, so they take the
# room's InteriorWall. Its south and east walls stand on the squares BEYOND
# the floor, which no room claims, so the exporter gives them the wall
# object's exterior Tile -- the truck-body metal. The iso view never shows
# those faces from inside, since it cuts them away; Project Viewpoint draws
# the one sprite on both faces, so from inside two walls were metal.
#
# So the exterior Tile of those runs is pointed at a copy of the room's
# InteriorWall. Wall object indices are into the building's flat, 1-based
# tile_entry list, and a wall's Tile must name an exterior_walls entry, so the
# interior set is copied into a new exterior_walls entry, APPENDED after the
# last one so no existing index moves. An identical entry is reused, which
# also makes a second run change nothing.
#
# The trim is deliberately left alone. The iso view draws those two walls cut
# away to stubs whenever a tenant is inside, and the stub is mostly trim, so
# carrying the room's wainscot over turned the whole near edge of the room
# into a band of panelling. The exterior trim it already had stays.
#
# A run whose squares face more than one room, or a room with a different
# interior set, is split into runs per room. Only level 0 is edited; the z=1
# black rings belong to the shell. The shell ring and the generator box are
# left alone, since nothing on their inside is a real room.
use strict; use warnings;
my $dry = grep { $_ eq "--dry" } @ARGV;
@ARGV = grep { $_ ne "--dry" } @ARGV;
my $dir = shift;
unless (defined $dir and length $dir) {
    my $src = $ENV{PI_MAPSRC} || "";
    $src =~ s{\\}{/}g;
    $dir = ($src =~ m{^(.*)/[^/]+$}) ? "$1/buildings/_" : "";
}
die "innerwalls: no buildings folder given and PI_MAPSRC is not set\n" unless length $dir;
$dir =~ s{\\}{/}g;
my $bak = "$dir/../_backup_innerwalls";
mkdir $bak unless $dry or -d $bak;

my %skip = map { $_ => 1 } qw(Border_N.tbx Border_NW.tbx Border_W.tbx _room.tbx
    hub.tbx hub_generic.tbx hub_market.tbx hub_pvp.tbx spawn.tbx);
my ($done, $same, $skipped, $failed) = (0, 0, 0, 0);

sub norm { my $b = shift; $b =~ s/\s+/ /g; $b =~ s/^ | $//g; $b }

for my $path (sort glob("$dir/*.tbx")) {
    my ($f) = $path =~ m{([^/]+)$};
    if ($skip{$f}) { printf("%-28s SKIP\n", $f); $skipped++; next }
    local $/; open(my $fh, "<", $path) or die "$f: $!"; my $d = <$fh>; close $fh;

    # the flat tile_entry list
    my @ent;
    while ($d =~ /<tile_entry category="([^"]+)">(.*?)<\/tile_entry>\n?/gs) {
        push @ent, { cat => $1, body => $2, end => pos($d) };
    }
    unless (@ent) { printf("%-28s FAIL no tile entries\n", $f); $failed++; next }
    my @new;   # entries to append: [category, body]
    my $entryFor = sub {
        my ($srcIdx, $cat) = @_;
        my $src = $ent[$srcIdx - 1] or return;
        my $want = norm($src->{body});
        for my $i (0 .. $#ent) {
            return $i + 1 if $ent[$i]{cat} eq $cat and norm($ent[$i]{body}) eq $want;
        }
        for my $i (0 .. $#new) {
            return @ent + $i + 1 if $new[$i][0] eq $cat and norm($new[$i][1]) eq $want;
        }
        push @new, [$cat, $src->{body}];
        return @ent + @new;
    };

    my @rooms;
    while ($d =~ /<room Name="([^"]*)" InternalName="([^"]*)"[^>]*?InteriorWall="(\d+)" InteriorWallTrim="(\d+)"/g) {
        push @rooms, { name => $1, def => $2, wall => $3, trim => $4 };
    }

    my @parts = split /(<floor>.*?<\/floor>)/s, $d;
    my ($lvl) = grep { $parts[$_] =~ /^<floor>/ } 0 .. $#parts;
    my $p = $parts[$lvl];
    my ($g) = $p =~ /<rooms>\s*\n(.*?)\n?<\/rooms>/s;
    unless (defined $g) { printf("%-28s FAIL no rooms grid at level 0\n", $f); $failed++; next }
    my @rg = map { [ split /,/ ] } split /\n/, $g;
    # the real room at a square, 1-based, or 0
    my $real = sub {
        my ($x, $y) = @_;
        return 0 if $x < 0 or $y < 0;
        my $v = $rg[$y] && $rg[$y][$x];
        return 0 unless $v;
        my $r = $rooms[$v - 1] or return 0;
        return 0 if $r->{def} eq "emptyoutside" or $r->{name} eq "Generator";
        return $v;
    };

    my ($changed, $runs) = (0, 0);
    my $out = "";
    for my $line (split /(?<=\n)/, $p) {
        my ($len, $x, $y, $dr) = $line =~ /<object type="wall" length="(\d+)"[^>]*? x="(\d+)" y="(\d+)" dir="([NW])"/;
        unless (defined $len) { $out .= $line; next }
        # each square of the run: the room on its inside, if the square
        # itself is outside every real room
        my @inside;
        for my $i (0 .. $len - 1) {
            my ($sx, $sy) = $dr eq "N" ? ($x, $y + $i) : ($x + $i, $y);
            my ($ix, $iy) = $dr eq "N" ? ($sx - 1, $sy) : ($sx, $sy - 1);
            push @inside, $real->($sx, $sy) ? 0 : $real->($ix, $iy);
        }
        unless (grep { $_ } @inside) { $out .= $line; next }

        # split into runs of one inside room each
        my @seg;
        for my $i (0 .. $#inside) {
            if (@seg and $seg[-1][2] == $inside[$i]) { $seg[-1][1]++ }
            else { push @seg, [$i, 1, $inside[$i]] }
        }
        my $text = "";
        for my $s (@seg) {
            my ($i0, $n, $room) = @$s;
            my $l = $line;
            my ($nx, $ny) = $dr eq "N" ? ($x, $y + $i0) : ($x + $i0, $y);
            $l =~ s/ length="\d+"/ length="$n"/;
            $l =~ s/ x="\d+" y="\d+"/ x="$nx" y="$ny"/;
            if ($room) {
                my $r = $rooms[$room - 1];
                my $t  = $r->{wall} ? $entryFor->($r->{wall}, "exterior_walls") : undef;
                if ($t) {
                    $l =~ s/ Tile="\d+"/ Tile="$t"/;
                    $runs++;
                }
            }
            $text .= $l;
        }
        $changed = 1 if $text ne $line;
        $out .= $text;
    }
    if (!$changed and !@new) { printf("%-28s unchanged\n", $f); $same++; next }
    $parts[$lvl] = $out;
    $d = join("", @parts);

    if (@new) {
        my $add = join("", map { qq( <tile_entry category="$_->[0]">$_->[1]</tile_entry>\n) } @new);
        # after the last tile_entry; the list is contiguous at the head of the file
        my $at = 0;
        $at = pos($d) while $d =~ /<\/tile_entry>\n?/g;
        substr($d, $at, 0) = $add;
    }

    printf("%-28s %d run%s refaced, %d entr%s added\n", $f, $runs, $runs == 1 ? "" : "s",
        scalar @new, @new == 1 ? "y" : "ies");
    unless ($dry) {
        rename($path, "$bak/$f") or die "backup $f: $!" unless -e "$bak/$f";
        open(my $o, ">", $path) or die "$f: $!"; print $o $d; close $o;
    }
    $done++;
}
printf("\n%d patched, %d unchanged, %d skipped, %d failed%s\n",
    $done, $same, $skipped, $failed, $dry ? " (dry run)" : "");
