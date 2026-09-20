#!/usr/bin/perl
# ---------------------------------------------------------------------------
# Generate shared/PhunInteriors/defaults.lua from the three authoring CSVs.
#
#   Docs/pi-assigned.csv   one row per ROOM: its contract, and the room it
#                          overflows into when full.
#   Docs/pi-mappings.csv   one row per ROW OF TEN STAMPS: which cell, which
#                          row, which room is stamped there.
#   Docs/pi-vehicles.csv   one row per BINDING: a game script (or a moveable
#                          item type, for a tent) and the room it reaches.
#
# Nothing here reads the map. The grid is an assertion --
#
#     x = cellX * 256 + 15 + 25 * col        col 0..9, west to east
#     y = cellY * 256 +  5 + 42 * (row - 1)  row 1..6, north to south
#
# -- and `perl Docs/roomcheck.pl` is what checks it against the lotpacks. Run
# that after this, every time; a stamp registered where the arithmetic says
# rather than where it is puts the leash a square off the room, which reads in
# game as being ejected while walking into a wall.
#
# The SLOT INDEX is the identity a lease persists, so the ordering below is
# load bearing: (chunk x, chunk y, row, position in row), which is a map
# coordinate rather than a row number in a spreadsheet. Inserting a line in a
# CSV must not renumber anything below it.
#
#   perl Docs/gendefaults.pl            write the file
#   perl Docs/gendefaults.pl --stdout   print it instead
# ---------------------------------------------------------------------------
use strict;
use warnings;
use Text::ParseWords;

my $OUT = "Contents/mods/PhunInteriors/common/media/lua/shared/PhunInteriors/defaults.lua";
my $STDOUT = grep { $_ eq "--stdout" } @ARGV;

my $CELL    = 256;
my $OFF_X   = 15;   # floor corner of column 0 within its cell
my $OFF_Y   = 5;    # floor corner of row 1 within its cell
my $PITCH_X = 25;
my $PITCH_Y = 42;
my $COLS    = 10;

sub read_csv {
    my $path = shift;
    open my $fh, "<:raw", $path or die "$path: $!\n";
    my @lines = <$fh>;
    close $fh;
    $lines[0] =~ s/^\xEF\xBB\xBF//;
    s/\r?\n\z// for @lines;
    @lines = grep { /\S/ } @lines;
    my @head = parse_line(",", 0, shift @lines);
    my @rows;
    for my $line (@lines) {
        my @cells = parse_line(",", 0, $line);
        my %row;
        @row{@head} = @cells;
        push @rows, \%row;
    }
    return \@rows;
}

sub trim { my $v = shift; $v = "" unless defined $v; $v =~ s/^\s+|\s+$//g; return $v }
sub truthy { my $v = trim(shift); return $v =~ /^(true|yes|1)$/i }
sub falsy  { my $v = trim(shift); return $v =~ /^(false|no|0)$/i }
sub lua_str { my $v = shift; $v =~ s/(["\\])/\\$1/g; return '"' . $v . '"' }

# --- read ------------------------------------------------------------------
my $assigned = read_csv("Docs/pi-assigned.csv");
my $mappings = read_csv("Docs/pi-mappings.csv");
my $bindings = read_csv("Docs/pi-vehicles.csv");

my %room;
for my $r (@$assigned) {
    my $id = trim($r->{id});
    next unless length $id;
    die "duplicate room id '$id' in pi-assigned.csv\n" if $room{$id};
    $room{$id} = $r;
}

# --- placements -> locations ------------------------------------------------
# A placement is either a ROW of ten stamps on the grid, or a single stamp at
# an explicit floor corner within its cell -- `Floor X` and `Floor Y` in
# pi-mappings.csv, both cell-local, and both filled in or neither. The grid is
# what a cell laid out as ten-by-six wants; an explicit corner is for a
# building placed on its own, which no arithmetic describes.
#
# Sorted by (cell x, cell y, y, x), which for a grid row is exactly
# (cell x, cell y, row, col) -- y rises with the row and x with the column --
# and which also puts a one-off stamp where it actually sits rather than where
# a `Row` column claims. That is the index order a lease persists, so appending
# to a CSV claims fresh indexes only if it sorts last by THAT key, not by line
# number. Indexes are per room, so a brand new room can never renumber another.
my @placed;
for my $m (@$mappings) {
    my $id = trim($m->{Building});
    next unless length $id;
    die "pi-mappings names room '$id', which pi-assigned does not declare\n"
        unless $room{$id};
    my $cx = trim($m->{"Chunk X"}) + 0;
    my $cy = trim($m->{"Chunk Y"}) + 0;
    my ($fx, $fy) = (trim($m->{"Floor X"}), trim($m->{"Floor Y"}));
    my $row = trim($m->{Row});

    if (length $fx or length $fy) {
        die "pi-mappings places '$id' in $cx,$cy with only one of Floor X / "
          . "Floor Y; a one-off stamp needs both or neither\n"
            unless length $fx and length $fy;
        push @placed, {
            id    => $id,
            cx    => $cx,
            cy    => $cy,
            at    => [[$cx * $CELL + $fx, $cy * $CELL + $fy]],
            where => "$cx,$cy at $fx,$fy",
        };
    } else {
        die "pi-mappings places '$id' in $cx,$cy with no Row and no floor "
          . "corner\n" unless length $row;
        my $y = $cy * $CELL + $OFF_Y + ($row - 1) * $PITCH_Y;
        push @placed, {
            id    => $id,
            cx    => $cx,
            cy    => $cy,
            at    => [map { [$cx * $CELL + $OFF_X + $_ * $PITCH_X, $y] }
                          0 .. $COLS - 1],
            where => "$cx,$cy row $row",
        };
    }
}
@placed = sort { $a->{cx} <=> $b->{cx}
              || $a->{cy} <=> $b->{cy}
              || $a->{at}[0][1] <=> $b->{at}[0][1]
              || $a->{at}[0][0] <=> $b->{at}[0][0] } @placed;

my %locations;   # room id => [ [x, y, z], ... ] in index order
my %rowsfor;     # room id => ["87,46 row 1", ...] for the comment
for my $p (@placed) {
    push @{$locations{$p->{id}}}, [@$_, 0] for @{$p->{at}};
    push @{$rowsfor{$p->{id}}}, $p->{where};
}
for my $id (sort keys %room) {
    die "room '$id' is declared but never placed\n" unless $locations{$id};
}

# --- bindings ---------------------------------------------------------------
# A tent is bound by its moveable ITEM type and reaches registerObjects; a
# vehicle is bound by its script name. Nothing in the CSV says which, because
# nothing has to -- it is decided by the room, which is the fact that actually
# settles it. A room reached by items takes no vehicles and vice versa:
# Core.roomsForVehicle walks only vehicle bindings and roomsForObject only
# object ones, so the kinds cannot cross.
my %ITEM_ROOM = map { $_ => 1 } ("Tent");

my (%scripts, %items);
for my $b (@$bindings) {
    my $what = trim($b->{vehicle});
    my $id   = trim($b->{room});
    next unless length $what && length $id;
    die "pi-vehicles binds '$what' to room '$id', which pi-assigned does not declare\n"
        unless $room{$id};
    if ($ITEM_ROOM{$id}) { $items{$id}{$what} = 1 }
    else                 { $scripts{$id}{$what} = 1 }
}

# Overflow. `fallback` is TRANSITIVE: a beer step van whose own room is full
# falls back to the generic step van room, and when that is full to the shed,
# because that is what the chain plainly reads as and it is what the old
# matcher did. Cycles are tolerated and simply mean "these rooms are
# interchangeable" -- the three semi trailer rooms name each other.
#
# An overflow room ends up reachable by every script of every room that names
# it, so it is reachable by MORE scripts than any of them, and specificity
# sorts it last without anybody having to say so. That is why there is no
# `priority` column: general purpose capacity is saved for the vehicles with
# nowhere else to go, which is the starvation the ordering exists to stop.
#
# It only stays true while every room is entered through a binding of its own
# or through a chain that runs one way. Two rooms reachable by the IDENTICAL
# set of scripts tie on specificity and fall through to the id tiebreak, which
# is alphabetical and therefore arbitrary -- so bind each vehicle to the room
# it should get FIRST and let the chain carry it onward, rather than binding
# both to one room and hoping the letters fall the right way.
sub overflow_for {
    my ($start) = @_;
    my (%seen, @out, @queue);
    @queue = ($start);
    $seen{$start} = 1;
    while (my $id = shift @queue) {
        my $next = trim($room{$id}{fallback});
        next unless length $next;
        die "room '$id' falls back to '$next', which is not a room\n"
            unless $room{$next};
        next if $seen{$next}++;
        push @out, $next;
        push @queue, $next;
    }
    return @out;
}

my %reach;   # room id => { script => 1 } including everything that overflows in
for my $id (sort keys %room) {
    for my $s (keys %{$scripts{$id} || {}}) {
        $reach{$id}{$s} = 1;
        $reach{$_}{$s} = 1 for overflow_for($id);
    }
}

# --- emit -------------------------------------------------------------------
my @out;
sub w { push @out, @_ }

my $rooms  = scalar keys %room;
my $stamps = scalar @placed;
my $slots  = $stamps * $COLS;
my $lastcol = $COLS - 1;

w(<<"HEAD");
require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- The stock rooms and the vehicles entitled to them.
--
-- GENERATED by Docs/gendefaults.pl from Docs/pi-assigned.csv,
-- Docs/pi-mappings.csv and Docs/pi-vehicles.csv. Edit those and regenerate;
-- an edit made here is lost on the next run.
--
-- $rooms rooms, $stamps rows of ten stamps, $slots slots.
--
-- A ROOM is a contract: one shape, and every place on the map it is stamped.
-- Two rooms whose CONTRACT differs are two registrations. What is on the
-- squares is not part of the contract -- wallpaper, overlays, the roof, the
-- door frame are all captured in game, per slot, on first lease -- so a
-- difference in decor alone does not make a second room.
--
-- The grid is regular across every cell that carries rooms:
--
--     x = cellX * 256 + $OFF_X + $PITCH_X * col        col 0..$lastcol, west to east
--     y = cellY * 256 +  $OFF_Y + $PITCH_Y * (row - 1)  row 1..6, north to south
--
-- so a cell laid out as ten by six needs no coordinate written down. A
-- building placed on its own is not on that grid and states its floor corner
-- outright -- `Floor X` and `Floor Y` in pi-mappings.csv, cell-local -- because
-- no arithmetic describes it. `perl Docs/roomcheck.pl` is what checks either
-- against the lotpacks, and it is not optional: the registry declares a
-- FOOTPRINT and the map draws a FLOOR, and this map puts the south and east
-- walls outside the floor, so `size` is the floor plus one in each direction.
--
-- The slot INDEX is the identity a lease persists, and it runs in map order --
-- (chunk x, chunk y, y, x), which for a grid row is (cell, row, column) --
-- never the order rows happen to appear in a CSV. A map coordinate is
-- stable under editing; a line number is not.
--
-- No room states `requires`. It is a vehicle vocabulary and it only ever did
-- one job beyond documentation -- refusing the wrecks a `match` predicate
-- over-claimed -- and there is no predicate here: every binding below names a
-- script outright. Carrying it would have risked silently refusing a bound
-- vehicle whose cargo space resolves through a template rather than a
-- container block, which is a refusal nobody could see.
--
-- Third party mods register alongside these using the same calls. See the
-- author notes in CLAUDE.md: hook Events.OnInitGlobalModData, not one of ours.
-- ---------------------------------------------------------------------------

local SOURCE = "phuninteriors"

local function registerRooms()
HEAD

for my $id (sort keys %room) {
    my $r = $room{$id};
    my $locs = $locations{$id};
    my $fw = trim($r->{"floor-w"}) + 0;
    my $fh = trim($r->{"floor-h"}) + 0;
    my $where = join(", ", @{$rowsfor{$id}});

    w("\n    -- " . trim($r->{label}) . " -- floor ${fw}x${fh}, " . scalar(@$locs)
        . " slots, room def '" . trim($r->{roomdef}) . "'.\n");
    w("    -- Stamped at $where.\n");
    w("    Core.registerRoom(\"phun.room.$id\", {\n");
    w("        label = " . lua_str(trim($r->{label})) . ",\n");
    w("        source = SOURCE,\n");
    w("        size = {w = " . ($fw + 1) . ", h = " . ($fh + 1) . "},\n");
    w("        spawn = {x = " . (trim($r->{"spawn-x"}) + 0)
        . ", y = " . (trim($r->{"spawn-y"}) + 0) . "},\n");

    my $front = trim($r->{front});
    if (length $front) {
        die "room '$id' has front '$front', which is not an edge\n"
            unless $front =~ /^(north|south|east|west)$/;
        w("        front = " . lua_str($front) . ",\n");
    }
    w("        cab = true,\n") if truthy($r->{cab});
    w("        selfPowered = true,\n") if truthy($r->{selfPowered});

    my ($gx, $gy, $gz) = map { trim($r->{$_}) } ("gen-x", "gen-y", "gen-z");
    if (length $gx && length $gy && length $gz) {
        w("        generator = {x = " . ($gx + 0) . ", y = " . ($gy + 0)
            . ", z = " . ($gz + 0) . "},\n");
    }
    # `reservoir` is the one contract field that defaults ON, so only a room
    # that opts out says anything at all.
    w("        reservoir = false,\n") if falsy($r->{plumable});

    w("        locations = {\n");
    for my $i (0 .. $#$locs) {
        my ($x, $y, $z) = @{$locs->[$i]};
        w("            [$i] = {$x, $y, $z}" . ($i == $#$locs ? "\n" : ",\n"));
    }
    w("        }\n    })\n");
}

w("end\n\nlocal function registerVehicles()\n");

for my $id (sort keys %room) {
    next if $ITEM_ROOM{$id};
    my @all = sort keys %{$reach{$id} || {}};
    unless (@all) {
        w("\n    -- " . trim($room{$id}{label}) . ": NOTHING REACHES IT. No vehicle is\n"
            . "    -- bound to phun.room.$id and no room overflows into it, so its "
            . scalar(@{$locations{$id}}) . "\n    -- slots stand empty.\n");
        next;
    }
    my @direct = sort keys %{$scripts{$id} || {}};
    my $over = scalar(@all) - scalar(@direct);
    w("\n    -- " . trim($room{$id}{label}) . ": " . scalar(@direct) . " bound directly"
        . ($over ? ", $over more overflowing in" : "") . ".\n");
    w("    Core.registerVehicles({\n");
    w("        id = \"phun.vehicles.$id\",\n");
    w("        source = SOURCE,\n");
    w("        rooms = {\"phun.room.$id\"},\n");
    w("        scripts = {" . join(", ", map { lua_str($_) } @all) . "}\n");
    w("    })\n");
}

w("end\n");

w(<<"OBJHEAD");

-- ---------------------------------------------------------------------------
-- Holders that are not vehicles.
--
-- Bound by moveable ITEM type rather than by sprite name, because every sprite
-- of a tent carries `CustomItem = Base.TentGreen` in its tile properties --
-- one string a third party can write down, against thirty-two sprite names a
-- colour. These rooms state no `requires` either, and for a sharper reason
-- than the vehicles do: `trunk` and `battery` are questions a tent cannot
-- answer, and answering "no" would be wrong in a way that is hard to see.
-- ---------------------------------------------------------------------------
local function registerObjectHolders()
OBJHEAD

for my $id (sort keys %ITEM_ROOM) {
    my @i = sort keys %{$items{$id} || {}};
    die "no items bound to object room '$id'\n" unless @i;
    w("    Core.registerObjects({\n");
    w("        id = \"phun.objects.$id\",\n");
    w("        source = SOURCE,\n");
    w("        rooms = {\"phun.room.$id\"},\n");
    w("        items = {" . join(", ", map { lua_str($_) } @i) . "}\n");
    w("    })\n");
}

w("end\n");

w(<<'TAIL');

-- Rooms on the room event, vehicles on the vehicle event, same as any third
-- party. Ours land first within each phase only because we load first; a mod
-- that wants to add rooms for a script of ours does it on the same event and
-- is unioned in, not overridden.
--
-- The sandbox script overrides go last of all, on OnReady, because they add
-- scripts to bindings and every binding has to exist by then -- including one
-- registered by a mod that loaded after us.
Events[Core.events.OnRegisterRooms].Add(registerRooms)
Events[Core.events.OnRegisterVehicles].Add(registerVehicles)
Events[Core.events.OnRegisterVehicles].Add(registerObjectHolders)
Events[Core.events.OnReady].Add(Core.applySandboxScriptOverrides)

return Core
TAIL

my $text = join("", @out);
if ($STDOUT) {
    print $text;
} else {
    open my $fh, ">:raw", $OUT or die "$OUT: $!\n";
    print $fh $text;
    close $fh;
    printf STDERR "wrote %s\n  %d rooms, %d rows of stamps, %d slots, %d bindings\n",
        $OUT, $rooms, $stamps, $slots, scalar(@$bindings);
}
