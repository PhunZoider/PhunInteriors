# PhunInteriors

Project Zomboid **B42** mod. Instanced vehicle interiors: lease an off-grid room
to a vehicle, put the player inside. SP and MP share one code path.

Author: UburGeek. Part of the Phun mod family (PhunLib, PhunCure, PhunLewt,
PhunZones, PhunServer2...). GitHub org: `PhunZoider`.

## Status

**v1 code complete, never run in-game.** Everything parses and the internal
wiring cross-checks, but nothing has been exercised against a live world.
Treat runtime behaviour as unverified.

## Verify before you claim anything works

```bash
LJ=~/AppData/Local/Programs/LuaJIT/bin/luajit
for f in $(find Contents/mods/PhunInteriors -name "*.lua"); do
  "$LJ" -bl "$f" >/dev/null || echo "FAIL $f"
done
```

LuaJIT is installed and is the fastest way to catch syntax errors. It cannot
catch API misuse — PZ globals do not exist outside the game.

There are no automated tests. Deployment is VS Code `emeraldwalk.runonsave`
(see `.vscode/settings.json`), which runs `deploy.cmd` on every save. That
builds four trees: `~/Zomboid/mods/PhunInteriors`, the test-id variant
`PhunInteriorsTest` (the live mod overlaid with `Tests/root/PhunInteriors/`),
and Workshop upload staging for each. `xclude` is the xcopy exclude list for
the staging copies.

## Layout

Standard Phun conventions, mirroring PhunCure2. Everything ships under
`common/`. There is no root `mod.info` and no versioned (`42.x/`) folder.

```
Contents/mods/PhunInteriors/common/
  mod.info                  id=phuninteriors, versionMin=42.0.0, no require line
  icon.png  poster.png
  media/sandbox-options.txt
  media/lua/shared/PhunInteriors/    core, tools, registry, bounds, defaults
  media/lua/server/PhunInteriors/    slots, transit, leash, manifest, scrub,
                                    weight, harden, admin, server_{commands,events}
  media/lua/client/PhunInteriors/    client_{main,enter,context,guards,commands,events}
  media/lua/shared/Translate/EN/     ContextMenu_EN, IG_UI_EN, Sandbox_EN

Tests/root/PhunInteriors/common/   overlay carrying the test ids, applied by
                                   deploy.cmd to build PhunInteriorsTest. The
                                   path must mirror the live mod folder or the
                                   overlay silently does nothing.
Tests/workshop.txt                 dev Workshop item text
```

House style, taken from PhunCure and PhunLewt 2.1:

- `core.lua` holds `name`, `consts`, `commands`, `events`, `settings`, `modules`.
- `*_commands.lua` **returns** a `Commands` table; `*_events.lua` dispatches into it.
- Server files open with `if isClient() then return end`, client files with
  `if isServer() then return end`. In SP both are false, so both load.
- Everything hangs off the `PhunInteriors` global. **No other globals.** The
  reference mod leaked `tableContains`, `check`, `look` and collided with half
  the workshop; do not repeat that.
- Settings cached via `Core.getOption` and refreshed on `EveryTenMinutes`.

## Architecture, and why

**One code path for SP and MP.** `Core.dispatch` / `Core.respond` in `core.lua`
check `Core.isLocal` and either round-trip through `sendClientCommand` or call
the handler directly. Never write a separate SP implementation — the reference
mod did and the two halves drifted apart.

**Containment is the leash, not the walls.** `server/leash.lua` runs one
bounding-box test per occupant every 250ms. That single test covers roof
access, neighbouring instances, wall breaches and teleport exploits. Because
containment does not depend on the walls, the walls can be destructible later
for the v2 siege.

**There is exactly one way out.** Exit tile, hole in the wall, and tripped
leash all call `Transit.leave`, which puts the player back at the vehicle. Do
not add a separate breach handler — collapsing these was a deliberate decision.

**Rooms are leased, not assigned.** Every assignment carries `lastSeen`.
Released slots go to `quarantine` and are scrubbed before reissue, never
straight back to the pool. The reference mod never freed a slot, so its pool
exhausted and the feature silently stopped working.

**Exit position is resolved live.** `resolveReturn` in `transit.lua` looks the
vehicle up with `getVehicleById(occupancy.vehicleHandle)` and reads its current
position. Only loaded vehicles come back, which is the wanted semantics: an
unloaded vehicle falls through to the cached position. Do not reintroduce a
position cache as the primary source.

`vehicleHandle` is `BaseVehicle:getId()`, a short that is only unique within a
session — safe to hold because `Core.occupants` is in-memory and never
persisted. The UUID remains the lease key and is re-checked after the lookup.

**The manifest is scanned, not authored.** Slot 0 of every room set is a
golden slot, never leased. `manifest.lua` scans it once and caches it. An empty
scan means the chunk was not loaded, not that the room is empty — caching that
would poison every future scrub, which is why it refuses to.

**Scrub is an idempotent rebuild, not a diff.** Clear every non-floor object,
re-place the manifest. Added furniture, smashed walls, damaged walls and moved
furniture then all become the same operation.

**Weight composes additively.** `weight.lua` tracks only our own delta and does
`setMass(getMass() - ourLastDelta + ourNewDelta)`. Do NOT cache an absolute
baseline and restore it — that is what More Traits does, and it stomps any
other mod touching mass on the same vehicle.

## B42 API constraints (verified against the jar and shipped mods)

These cost real investigation. Do not re-derive them, and do not assume a
B41 tutorial applies.

| Fact | Consequence |
|---|---|
| `ISOpenCloseDoor` **does not exist** in B42. Door toggling is Java-side with no Lua hook. | The exit had to be positional. This is why exit and leash are one handler. |
| `IsoObject` exposes `getThumpable` but **no setter**. `IsoGridSquare` has no fire flags. | "Unbreakable walls" is not reachable from Lua. `HardenShell` means: refuse player destroy actions + douse fires. Say so honestly. |
| `BaseVehicle` **does** expose `setMass`, `setInitialMass`, `getInitialMass`, `updateTotalMass` to Lua. Proven by the shipped More Traits mod. | The weight mechanic works. |
| Fuel burn in vanilla `Vehicles.lua:467` uses `vehicle:getScript():getMass()` — the **static** script value, not runtime mass. | Interior weight affects handling but **not** fuel consumption. A fuel penalty is separate v2 work. |
| No Lua call reloads a chunk from its lotpack; PZ persists modified chunks into the save. | "Reset after N days" is a manifest scrub, not a true revert. Do not promise otherwise in the workshop description. |
| `getVehicleById(id)`, `getCell():getVehicles()`, `getRandomUUID()`, `getGameTime():getWorldAgeHours()` all exist. | Safe to use. |
| **`next()` is not exposed** by PZ's Lua sandbox. Confirmed in-game, and PhunMart2's `restockTypes` hit the same wall. `pairs`, `ipairs`, `table.*`, `string.*`, `math.*` are all fine. | Use `Core.tools.isEmpty(t)` to test a table for emptiness. LuaJIT will **not** catch this — `next` exists there. |
| `BaseVehicle` has **no `isInVehicle`**. The occupancy test is `player:getVehicle()`, compared against the vehicle. `vehicle:exit(chr)` and `vehicle:getSeat(chr)` are real. | Confirmed absent from the jar constant pool. |
| `IsoGridSquare` has **no `setBloodSplatLifetime`**. Vanilla `ISCleanBlood:complete()` uses `square:removeBlood(false, false)` then `square:removeGrime()`. | Confirmed absent from the jar. |
| Vanilla only ever exits a vehicle from a **client** timed action (`ISExitVehicle`). | `vehicle:exit()` lives in `Client.teleport`, not in server-side `Transit.enter`. |
| `getCell():getVehicles()` returns a **`java.util.Set`** — `size()` but no `get(i)`, so it cannot be indexed from Lua. Vanilla's own `ISVehicleBloodUI.lua:81` does `vehicles:get(i-1)` and is therefore broken. | `resolveReturn` uses `getVehicleById(handle)`. Vanilla Lua shows intent, **not** correctness — check the jar. |
| Moving a player is `IsoGameCharacter:teleportTo(x, y, z)` (overloads `(FFI)`, `(III)`, `(FF)`, `(II)`). `setX`/`setLastX` also works — PhunZones2 ports players that way. | `Client.teleport` uses `teleportTo`, `+ 0.5` to centre on the tile, as vanilla's `StreamMapWindow` does. |
| **One teleport call is not enough across the map.** The player moves, but the destination chunk is not loaded, and the engine restores anyone on a square that does not exist. It reads as "the teleport silently did nothing" — the position log shows the move landing and then being undone. | `Client.teleport` re-asserts the position every tick until `getGridSquare` at the destination is non-nil (`HOLD_TICKS`). Applies leaving a room too: the vehicle's chunk unloads while the player is inside. The leash `graceUntil` **must** outlast that window. |
| **A B42 map cell is 256 squares, not B41's 300.** From the jar: `IsoCell.CELL_SIZE_IN_SQUARES = 256`, `CELL_SIZE_IN_CHUNKS = 32`, `IsoChunkMap.CHUNK_SIZE_IN_SQUARES = 8`. B41 chunks were 10 squares — still there as `OLD_CHUNKS_PER_WIDTH` — so 30x10 = 300 became 32x8 = 256. | Cell = `floor(coord / 256)`. `22560, 12060` is cell `88, 47`, so the map must ship `88_47`. Assuming B41's 300 makes correct coordinates look out of range. |

### Checking an API call before you use it

Method names sit in plain text in the class constant pool, so the jar answers
this in seconds and does not need a JDK:

```bash
P="/c/Program Files (x86)/Steam/steamapps/common/ProjectZomboid"
cd /tmp && unzip -o -q "$P/projectzomboid.jar" "zombie/vehicles/BaseVehicle.class"
perl -e 'local $/; open($f,"<:raw",shift); $d=<$f>; %s=();
         $s{$1}=1 while $d=~/([\x20-\x7e]{3,})/g;
         printf("%-24s %s\n",$_,$s{$_}?"present":"ABSENT") for @ARGV' \
     zombie/vehicles/BaseVehicle.class isInVehicle exit getSeat
```

A name being present proves the string is in that class; absent is conclusive.
Cross-check intent against how vanilla's own Lua in `media/lua/` uses it — zero
vanilla uses of a plausible-sounding method is the tell that it was invented.

## Dependencies

- **There are no hard dependencies.** `mod.info` carries no `require` line.
  PhunLib is deprecated; `onlinePlayers()`, `getPlayerByUsername()` and
  `isAdmin()` are folded into `shared/PhunInteriors/tools.lua` and reached as
  `Core.tools`, the same way PhunServer2 and PhunZones2 did it. Do not
  reintroduce a dependency to get them back.
- **PhunServer2 is a soft hook, never a dependency.** `admin.lua` guards with
  `if not PhunServer2 or not PhunServer2.registerCommand then`. Keep it that
  way — this was an explicit decision.

## Known gaps

1. **Room set coordinates are borrowed.** `defaults.lua` points at
   `22560, 12060`, marked `-- BORROWED`. This is space belonging to the
   reference mod (workshop 3543229299) so v1 could be built without map
   authoring blocking it. **Must be replaced with a purpose-built map before
   release.** Only `origin` and `count` change — that is why the room set is data.
2. **No icon.png / poster.png.** `mod.info` references them; they do not exist yet.
3. **`workshop.txt` has an empty `id=`.** Fill on first publish.
4. Only one vehicle class (`phun.van`) is registered. The registry supports
   many; shipping the second is authoring work, not architectural work.

## v2, deliberately not in v1

Power binding (generator state driven by vehicle battery + fuel, and actually
drained), the water barrel, the siege/breach system, a fuel penalty for load,
and the purpose-built map.

## Open questions

- Should expired-room loot survive by default? Currently `ScrubKeepsLoot=false`.
  It is the most complaint-generating behaviour in the design.
- Is `WeightFactor=50` right? It is a guess and needs an overloaded van to
  calibrate against.

## Design note

Full rationale, including the analysis of the reference mod this reacts to:
https://claude.ai/code/artifact/67264759-901c-4bdb-9790-3681d200ccd0
