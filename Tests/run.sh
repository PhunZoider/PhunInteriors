#!/usr/bin/env bash
# Syntax check every lua file, then run the specs under LuaJIT.
#
# LuaJIT cannot catch API misuse -- PZ globals do not exist outside the game,
# and it will happily accept next(), which PZ's sandbox does not expose. What
# it can do is parse every file and run the parts of this mod that are pure
# Lua, which is most of the registry and all of the allocation logic.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LJ="${LUAJIT:-$HOME/AppData/Local/Programs/LuaJIT/bin/luajit}"

if [ ! -x "$LJ" ] && ! command -v "$LJ" >/dev/null 2>&1; then
    echo "luajit not found; set LUAJIT=/path/to/luajit" >&2
    exit 2
fi

status=0

for f in $(find Contents/mods/PhunInteriors -name "*.lua"); do
    if ! "$LJ" -bl "$f" >/dev/null 2>&1; then
        echo "SYNTAX $f"
        "$LJ" -bl "$f" 2>&1 | head -3
        status=1
    fi
done
[ $status -eq 0 ] && echo "syntax           all files parse"

# Nothing may be hung off the Core table under a name core.lua already
# declares. A function named for one of those fields REPLACES it, silently, at
# file load time -- Core.rooms was defined as a console helper in
# client_admin.lua and took out the registry table for every client and every
# single player session, so the first registerRoom indexed a function and the
# mod did not boot. The specs cannot see it: they load the shared and server
# halves, and the collision was in a client file.
clashes=$(perl -e '
    my ($core, @files) = @ARGV;
    open(my $c, "<", $core) or die "no core.lua";
    my (%field, $on);
    while (<$c>) {
        $on = 1, next if /^PhunInteriors = \{/;
        next unless $on;
        last if /^\}/;
        $field{$1} = 1 if /^    ([A-Za-z_][A-Za-z0-9_]*)\s*=/;
    }
    die "core.lua declared no fields -- has the table moved?" unless %field;
    for my $f (@files) {
        next if $f =~ m{shared/PhunInteriors/core\.lua$};
        open(my $h, "<", $f) or next;
        while (my $l = <$h>) {
            next unless $l =~ /^(?:function\s+)?(?:Core|PhunInteriors)\.([A-Za-z0-9_]+)\s*(\(|=\s*function)/;
            print "$f:$.: $1\n" if $field{$1};
        }
    }
' Contents/mods/PhunInteriors/common/media/lua/shared/PhunInteriors/core.lua \
  $(find Contents/mods/PhunInteriors -name "*.lua")) || status=1
if [ -n "$clashes" ]; then
    echo "NAMESPACE a function is replacing a Core field declared in core.lua:"
    echo "$clashes"
    status=1
elif [ $status -eq 0 ]; then
    echo "namespace        no Core field is shadowed by a function"
fi

# Occupancy is written in exactly one place, Transit.setOccupancy, which keeps
# the count the leash gates on. A second write site would not break anything
# visibly -- it would just leave the count low, so Leash.tick returns early
# while somebody is standing in a room and containment stops without a word.
# Matched on the setter's own line rather than on a line number, which would
# go stale the moment anything above it moved.
writes=$(grep -rn "Core\.occupants\[[^]]*\] *=" --include="*.lua" \
             Contents/mods/PhunInteriors \
         | grep -v "Core\.occupants\[key\] = occupancy$")
if [ -n "$writes" ]; then
    echo "OCCUPANCY something other than Transit.setOccupancy writes Core.occupants:"
    echo "$writes"
    status=1
else
    echo "occupancy        only setOccupancy writes the occupancy table"
fi

# A local redeclared at the top level of the same function. LuaJIT parses one
# happily and the damage shows up somewhere else entirely -- see Tests/shadow.pl.
shadows=$(perl Tests/shadow.pl $(find Contents/mods/PhunInteriors -name "*.lua"))
if [ -n "$shadows" ]; then
    echo "SHADOW a local is being redeclared inside one function:"
    echo "$shadows"
    status=1
else
    echo "shadows          no local shadows another in the same function"
fi

for spec in Tests/lua/*_spec.lua; do
    PI_ROOT="$ROOT" "$LJ" "$spec" || status=1
done

exit $status
