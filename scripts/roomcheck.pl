#!/usr/bin/perl
# Does the registry describe the map that ships?
#
#   perl scripts/roomcheck.pl                  # every cell under media/maps
#   perl scripts/roomcheck.pl <dir>            # a different map folder
#   perl scripts/roomcheck.pl --mod ../PhunSpawn --mod ../PhunHub
#
# `--mod <repo>` folds another mod of the family into the SAME run: its lua on
# the require path, its `<Mod>/interiors` required, and every cell under its
# media/maps added to the scan. That is one run for the whole family rather
# than one per mod, and it has to be, because the two halves cannot be
# separated. Those mods call PhunInteriors.registerRoom from their own files,
# so checking their map without their lua reports every interior square as
# claimed by nobody -- and checking it without OUR lua reports all 990 of our
# slots as sitting on ground that is not there.
#
# Give `--mod <repo>:<Name>/<file>` to require something other than
# `<Mod>/interiors`.
#
# Reads the interior squares and the door squares straight out of every
# lotpack, asks the registry (loaded under Tests/lua/stubs.lua) where it thinks
# its slots are, and reports the two ways those can disagree:
#
#   * an interior square inside no registered slot -- the leash ejects a tenant
#     for standing in their own room
#   * a square where the floor and the registered box disagree -- the registry
#     declares a FOOTPRINT and the map draws a FLOOR, and getting the
#     relationship between them wrong is silent
#
# Written after cell 88,46 was registered at 22546 while the map put it at
# 22545. All sixty of that cell's slots were a square east of their rooms, so
# the leash covered the east WALL column and excluded the west FLOOR column.
# It read in game as the leash being broken, and no amount of reading leash.lua
# would have found it -- the leash was right about the box it was given.
#
# Run it after moving anything on the map. The registry is hand-written data
# and the map is the truth; this is the only thing that compares them.

use strict;
use warnings;

my $root = ".";
my (@mods, @argv);
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a ne "--mod") { push @argv, $a; next }
    my $spec = shift(@ARGV) // die "--mod wants a repo folder\n";
    my ($repo, $req) = split /:(?=[^\\\/]*$)/, $spec, 2;
    $repo =~ s{[\\/]+$}{};
    $repo =~ s{\\}{/}g;
    die "--mod $repo is not a folder\n" unless -d $repo;
    # The mod NAME is the folder's, which is also the name of the one folder
    # under Contents/mods and the prefix of every require path. That is the
    # family convention rather than a guess, and a mod that breaks it can say
    # so with the `:<Name>/<file>` form.
    my ($name) = $repo =~ m{([^/]+)$};
    push @mods, {repo => $repo, name => $name, require => $req // "$name/interiors"};
}

my $maps = shift(@argv)
        // "Contents/mods/PhunInteriors/common/media/maps/phuninteriors";
die "no map folder at $maps\n" unless -d $maps;

# --- what the map says ------------------------------------------------------
my (%interior, %door);
my @cells = sort glob("$maps/world_*.lotpack");
for my $m (@mods) {
    my @theirs = sort glob("$m->{repo}/Contents/mods/$m->{name}/common/media/maps/*/world_*.lotpack");
    warn "$m->{name}: no lotpacks yet, only its rooms are checked\n" unless @theirs;
    push @cells, @theirs;
}
die "no lotpacks in $maps\n" unless @cells;

for my $file (@cells) {
    my ($cx, $cy) = $file =~ /world_(\d+)_(\d+)\.lotpack$/ or next;
    (my $hdr = $file) =~ s/world_(\d+_\d+)\.lotpack$/$1.lotheader/;
    my ($ox, $oy) = ($cx * 256, $cy * 256);

    local $/;
    open(my $f, "<:raw", $file) or die "$file: $!";
    my $d = <$f>;
    open(my $fh, "<:raw", $hdr) or die "$hdr: $!";
    my $h = <$fh>;

    my $tileCount = unpack("V", substr($h, 8, 4));
    my ($hp, @names) = (12);
    for (1 .. $tileCount) {
        my $e = index($h, "\n", $hp);
        push @names, substr($h, $hp, $e - $hp);
        $hp = $e + 1;
    }

    # The room defs follow the palette: four ints, a count, then per room a
    # name, a level, its rects and its objects. A lotpack square's room id is
    # an index into this list.
    #
    # A room named "empty" or "emptyoutside" is usually the light-blocking
    # shell wrapped round a stamp, or the 1x1 box the roof generator stands on.
    # The leash deliberately does not cover the shell -- stepping into it is
    # leaving -- so it is not interior as far as this check is concerned.
    #
    # The shell is "emptyoutside" and the generator box is "empty", and the
    # difference is load bearing rather than cosmetic. IsoGridSquare.setRoomID
    # unsets IsoFlagType.exterior for ANY square with a room id, so a shell
    # carrying a room def can never be sunlit and no window into it can ever
    # bring daylight to the room inside. IsoMetaGrid.getRoomAt skips
    # "emptyoutside" defs -- they live in their own lookup, out of
    # BuildingDef.rooms -- so such a square keeps roomID -1 and stays exterior.
    # The generator box stays a real room because it needs its ceiling, which
    # is the tile the generator actually stands on.
    #
    # But "empty" is also a vanilla distribution room, and 91,49 has a row of
    # real rooms under that name. They are told apart by shape: a shell is a
    # ring of four rects, or the 1x1 box under a roof generator, while a room
    # is a single rect bigger than one square.
    my (@rooms, @shell);
    my $rp = $hp + 16;
    my $roomCount = unpack("V", substr($h, $rp, 4));
    $rp += 4;
    for (1 .. $roomCount) {
        my $e = index($h, "\n", $rp);
        die "$hdr: room list ends early at room " . scalar(@rooms) . "\n" if $e < 0;
        my $name = substr($h, $rp, $e - $rp);
        push @rooms, $name;
        $rp = $e + 1 + 4;
        my $rects = unpack("V", substr($h, $rp, 4));
        my (undef, undef, $rw, $rh) = unpack("V4", substr($h, $rp + 4, 16));
        push @shell, (($name eq "empty" or $name eq "emptyoutside")
                      and ($rects != 1 or $rw * $rh <= 1)) ? 1 : 0;
        $rp += 4 + $rects * 16;
        $rp += 4 + unpack("V", substr($h, $rp, 4)) * 12;
    }

    my $chunks = unpack("V", substr($d, 8, 4));
    my @off = map { unpack("V", substr($d, 12 + $_ * 8, 4)) } (0 .. $chunks - 1);

    for my $c (0 .. $chunks - 1) {
        my $p = $off[$c];
        my $end = ($c < $chunks - 1) ? $off[$c + 1] : length($d);
        my ($chx, $chy) = (int($c / 32), $c % 32);
        my $e = 0;
        while ($p + 4 <= $end) {
            my $cnt = unpack("l<", substr($d, $p, 4));
            $p += 4;
            if ($cnt == -1) { $e += unpack("l<", substr($d, $p, 4)); $p += 4; next }
            last if $cnt <= 0 or $p + $cnt * 4 > $end;
            my @v = map { unpack("l<", substr($d, $p + $_ * 4, 4)) } (0 .. $cnt - 1);
            $p += $cnt * 4;
            my ($z, $s) = (int($e / 64), $e % 64);
            $e++;
            next unless $z == 0;
            my $key = ($ox + $chx * 8 + int($s / 8)) . "," . ($oy + $chy * 8 + ($s % 8));
            $interior{$key} = 1 if $v[0] != -1 and !$shell[$v[0]];
            for my $t (grep { $_ >= 0 } @v[1 .. $#v]) {
                $door{$key} = 1 if ($names[$t] // "") =~ /^fixtures_doors_\d+_\d+$/;
            }
        }
    }
}

# --- what the registry says -------------------------------------------------
my $lua = <<'LUA';
local ROOT = os.getenv("PI_ROOT")
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)
require "PhunInteriors/core"; require "PhunInteriors/registry"; require "PhunInteriors/bounds"
local Core = PhunInteriors
Core.logLn = function() end; Core.debugLn = function() end
require "PhunInteriors/defaults"
--@MODS@
triggerEvent("PhunInteriorsOnRegisterRooms")
-- The family registers from the vanilla hook rather than from ours, which is
-- what the author docs tell a third party to do, so this has to fire too or
-- their rooms never arrive. Ours is unaffected: nothing required above hooks
-- it -- server_events does, and this harness does not load it.
triggerEvent("OnInitGlobalModData")
for id, room in pairs(Core.rooms) do
    for _, i in ipairs(room.indices) do
        local b = Core.slotBounds(room, i)
        local o = Core.slotOrigin(room, i)
        print(("%s\t%d\t%d\t%d\t%d\t%d\t%s"):format(id, i, b.x1, b.y1, b.x2, b.y2,
            (room.front or "-") .. (room.cab and " cab" or "")))
    end
end
LUA

my $inject = "";
for my $m (@mods) {
    # pcall'd and reported rather than fatal: a mod whose lua will not load is
    # a fact worth printing beside the map it failed to account for, not a
    # reason to stop checking the other eighteen cells.
    $inject .= qq{stubs.addRoot("$m->{repo}", "$m->{name}")\n}
            .  qq{do local ok, err = pcall(require, "$m->{require}")\n}
            .  qq{   print("#mod\\t$m->{name}\\t" .. (ok and "ok" or "FAILED " .. tostring(err))) end\n};
}
$lua =~ s/--\@MODS\@/$inject/;

my $tmp = ($ENV{TEMP} || "/tmp") . "/roomcheck_$$.lua";
open(my $w, ">", $tmp) or die; print $w $lua; close $w;
my $lj = $ENV{LUAJIT} || "$ENV{HOME}/AppData/Local/Programs/LuaJIT/bin/luajit";
$ENV{PI_ROOT} = $root;
my @reg = `"$lj" "$tmp" 2>&1`;
unlink $tmp;
die "could not load the registry:\n@reg" if $? != 0 or !@reg;

my (%covered, %slotbox, %fronts, $slots, @modstatus);
for my $line (@reg) {
    if ($line =~ /^#mod\t(\S+)\t(.*?)\s*$/) { push @modstatus, [$1, $2]; next }
    my ($id, $i, $x1, $y1, $x2, $y2, $exits) = split /\t/, $line;
    next unless defined $y2;
    $slots++;
    $slotbox{"$id#$i"} = "$x1,$y1..$x2,$y2";
    for my $x ($x1 .. $x2) {
        for my $y ($y1 .. $y2) {
            $covered{"$x,$y"} = "$id#$i";
        }
    }
    # Which edge faces the holder's front, as "south cab" or "-". Matched
    # loosely rather than split, because the lua comes back with CRLF line
    # endings on Windows and a trailing \r on the last field once made two
    # identical-looking keys compare unequal, putting the same square in two
    # contradictory failure lists at once.
    $fronts{"$id#$i"} = 1 if $exits =~ /^(north|south|east|west)/;
}

# --- the disagreements ------------------------------------------------------
#
# Only what a lotpack can actually settle. It carries room ids and sprite
# names, not tile flags, so "is this square walkable" is not answerable here --
# a doorway cut into a wall is an opening with no door object in it, and the
# ambulance bays' cab exit is exactly that. A check that called those broken
# would be worse than no check.
#
# What IS decidable:
#
#   * every interior square belongs to some slot         -- the leash's box
#   * the floor fills its box bar the south row and east column, which is
#     where this map puts those two walls. The registry declares a FOOTPRINT
#     and the map draws a FLOOR, and getting the relationship wrong is silent:
#     registering the 3x4 ambulance bays as though they were the 2x3 rooms
#     they replaced left a box that fitted their floor exactly and excluded
#     both their walls -- and every other check here passed.
#
# There used to be a third: that a slot had a door object or its room declared
# a landing edge, so there was SOME way out. It went with the landing table.
# A doorless opening, a window and a garage door are all invisible in a
# lotpack, so the check could only ever rest on the author asserting a way out
# existed -- and an assertion checks the author against himself. What it cost
# is real and worth knowing: a room generated with four solid walls is now
# caught by walking into it rather than by this script.
my @orphan = grep { !$covered{$_} } sort keys %interior;

my @misfit;
for my $slot (sort keys %slotbox) {
    my ($x1, $y1, $x2, $y2) = $slotbox{$slot} =~ /(\d+),(\d+)\.\.(\d+),(\d+)/;
    for my $x ($x1 .. $x2) {
        for my $y ($y1 .. $y2) {
            my $wall = ($x == $x2 or $y == $y2);
            my $floor = $interior{"$x,$y"} ? 1 : 0;
            push @misfit, "$slot at $x,$y is " . ($floor ? "floor where a wall should be"
                                                         : "not floor")
                if $floor == ($wall ? 1 : 0);
        }
    }
}
printf("%d cells, %d registered slots, %d interior squares, %d door squares, %d slots with a front\n",
    scalar(@cells), $slots, scalar(keys %interior), scalar(keys %door), scalar(keys %fronts));
printf("  %-14s %s\n", $_->[0], $_->[1]) for @modstatus;

my $bad = 0;
$bad += grep { $_->[1] ne "ok" } @modstatus;
for ([\@orphan,   "interior squares inside no registered slot"],
     [\@misfit,   "squares where the floor and the registered box disagree"]) {
    my ($list, $what) = @$_;
    next unless @$list;
    $bad += @$list;
    printf("\nFAIL %d %s:\n", scalar(@$list), $what);
    printf("   %s%s\n", $_,
           $slotbox{$_}  ? "  (box $slotbox{$_})"
         : $covered{$_}  ? "  (in slot $covered{$_})" : "")
        for @$list[0 .. ($#$list < 19 ? $#$list : 19)];
    printf("   ... and %d more\n", @$list - 20) if @$list > 20;
}

print "\nthe registry matches the map\n" unless $bad;
exit($bad ? 1 : 0);
