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
  media/lua/shared/Translate/EN/     ContextMenu.json, IG_UI.json, Sandbox.json

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

`vehicleHandle` is `BaseVehicle:getId()`. It is unique within a session but
**does not survive the vehicle unloading** — the id is assigned when a vehicle
enters the world, and a vehicle that unloads and reloads comes back with a
different one. Since the vehicle always unloads while its owner is in a room,
`resolveReturn` correctly falls through to the cached position on the way out;
the live lookup only pays off when somebody else kept the vehicle loaded, and
in that case the id is still good.

Anything that has to find the vehicle *after* a reload must match on the
modData UUID instead, which is written into the save. `Client.teleport`'s
rejoin phase sweeps squares around the destination with
`square:getVehicleContainer()` and compares `Core.vehicleId`.

**The manifest is scanned, not authored.** Slot 0 of every room set is a
golden slot, never leased. `manifest.lua` scans it once and caches it. An empty
scan means the chunk was not loaded, not that the room is empty — caching that
would poison every future scrub, which is why it refuses to.

Stored as `version = 2`: a `palette` of distinct sprite names plus per square
lists of indices into it. Measured on the borrowed van room: 29 objects, 11
distinct sprites, 379 bytes against 699 without the palette. So a few hundred
blueprints is on the order of 100KB either way — the palette halves it and is
worth keeping, but manifest size was never the constraint it was assumed to
be. `Manifest.spritesAt` resolves either format; v1 stored names inline and is
read, not migrated. `PhunInteriors.admin("manifests")` reports the real figures.

**A manifest holds exactly what a scrub removes.** `Manifest.isStructural` and
`Scrub.clearSquare` must agree object for object, or a scrub either loses the
floor or stacks a second one on every pass. Both now identify the floor by
identity against `square:getFloor()`.

Capture is per slot, taken the first time a slot is leased, when it is
pristine by definition. `Slots.markUsed` is what makes that trustworthy: a
slot only ever gets one capture attempt window, because after a tenant it is
no longer evidence of anything. The leash drives it -- "the leash can see this
player inside this room" is exactly the condition a capture needs -- and gives
up after `Manifest.CAPTURE_ATTEMPTS` ticks, falling back to the golden slot.
The capture sits **above** every early return in `Leash.checkOne`, including
the noclip exemption and the arrival grace. Capture is not containment: it
only cares that the player is standing in the room. Placed under the exemption
it captured nothing at all, because an admin testing with noclip on is the
normal case.


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
| `ISEnterVehicle:new(character, vehicle, seat)` is the only sanctioned way into a seat, and its `start()` silently returns without entering if the character is more than 2 tiles from `getPassengerPosition(seat, "outside")`. `isValid` then fails and the queue drops it, so a failed re-seat degrades to standing there rather than hanging — **this happens by default**, because the only position the server can send is the vehicle centre, which is further than 2 tiles on anything van sized. Teleport to the outside position first (`getWorldPos(pos:getOffset(), Vector3f)`, as vanilla does). `getBestSeat`, `isSeatOccupied`, `getMaxPassengers`, `getCharacter` all exist on `BaseVehicle`. | Re-seating on exit is a client action in `Client.teleport`'s second phase, run only once the destination chunk has streamed in. |
| `vehicle:getSeat(player)` returns -1 once the character is out of the seat, and our entry action refuses to run until exactly that. | The seat **must** be captured client side in `Client.beginEnter`, before `ISExitVehicle` is queued, and sent with the enter request. Reading it server side in `Transit.enter` always yielded -1. |
| From the server, an unloaded vehicle and a destroyed one are indistinguishable: `getVehicleById` returns nil for both. The vehicle's chunk is always unloaded while its owner is in a room, **and it reloads with a different `getId()`**, so the captured handle never resolves again. Confirmed from the logs. | `Transit.leave` must **not** warn `VehicleGone`; it fired on every normal exit. The client raises it after arrival, where the chunk is loaded and the question is answerable. `getVehicleById` is in `LuaManager$GlobalObject`, so it works client side too. |
| `instanceof(object, "IsoFloor")` has **zero** uses in vanilla Lua and filters nothing — a room captured with and without it returned the identical 29 objects. Vanilla finds a floor with `square:getFloor()`, which every build and debug tool uses. | Identify a floor by identity against `square:getFloor()`, not by class. Zero vanilla uses of a plausible-sounding call is the tell, and it applies to `instanceof` class names as much as to methods. |
| **B42 translations are `.json`, not `.txt`.** The stock install ships 43 `.json` files in `media/lua/shared/Translate/EN` and zero `.txt`. The format is a flat JSON object of key/value pairs, with no `ContextMenu_EN = {}` wrapper, and the `_EN` filename suffix is gone: `ContextMenu.json`, `IG_UI.json`, `Sandbox.json`. | The B41 `.txt` files load silently and every `getText` falls through to the raw key. Confirmed in game: nothing translated until these were converted. Sandbox keys are still `Sandbox_<Mod>_<Option>` and `_tooltip`. |
| `ISVehicleMenu.showRadialMenu` delegates to `showRadialMenuOutside` when the player is not seated, but **inside the call**, so wrapping `showRadialMenu` alone covers both seated and standing. `showRadialMenuOutside` has exactly one caller, that delegation. `ISRadialMenu:addSlice` forwards to the java object, so a slice added after the base displayed the menu still appears, and the menu is a fixed size circle so the base's centring stays correct. `menu:isReallyVisible()` reads **false** immediately after `addToUIManager` in the same call stack; vanilla only ever tests it at the start of the *next* call. | One hook on `showRadialMenu`, no visibility gate. Wrapping `showRadialMenuOutside` as well just duplicates the slice, and gating on `isReallyVisible()` silently removes it — both were tried and both broke the menu. Pick the vehicle with `ISVehicleMenu.getVehicleToInteractWith` (seat, then useable, then near). |
| `IsoPlayer` has both `isGhostMode()` and `isNoClip()`. The admin cheat panel (`ISAdminPowerUI.lua`) toggles **`isNoClip`**, gated by `Capability.ToggleNoclipHimself`; `GameServer` references `setNoClip` and `AntiCheatNoClip`, so the flag is server-visible for a remote player. `isGhostMode` is only used by debug menus and the trailer scenarios. | `Leash.isExempt` uses `isNoClip()` as the "an admin is deliberately debugging" signal. There is no admin-mode flag as such. |
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
   The placeholder lotpacks under `common/media/maps/phuninteriors/` are
   **gitignored**, so a fresh clone has no map and rooms will not load until
   that folder is supplied locally. They are the reference mod's map verbatim
   (`map.info` still reads `title=map_distanciado`), which has two
   consequences: the reference mod must be **disabled** when testing, because
   it declares the same cells, and `deploy.cmd` strips `media\maps` from both
   Workshop staging trees so it cannot be published by accident. The playable
   and Test mod folders keep it.
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
- **Where should you have to stand to get in?** Entry is currently allowed from
  anywhere the radial menu resolves the vehicle, which in practice is anywhere
  around it. Confirmed in game. Sketched, not decided: the back of a van, the
  side door of an RV, and never the driver's seat of a trailer. This is per
  vehicle class, so it belongs in the registry next to `requires`, not in the
  entry action. Needs a session of its own.

## Design note

Full rationale, including the analysis of the reference mod this reacts to:
https://claude.ai/code/artifact/67264759-901c-4bdb-9790-3681d200ccd0
