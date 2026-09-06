# PhunInteriors

Project Zomboid **B42** mod. Instanced vehicle interiors: lease an off-grid room
to a vehicle, put the player inside. SP and MP share one code path.

Author: UburGeek. Part of the Phun mod family (PhunLib, PhunCure, PhunLewt,
PhunZones, PhunServer2...). GitHub org: `PhunZoider`.

## Status

**Playable in single player and on a dedicated server.** Confirmed working in
game: enter and exit, containment, seat and door restore, translations, per
slot blueprint capture, scrub (including restoring a working light switch), and
the whole lease lifecycle -- expiry, release to quarantine, reissue from
quarantine, and the scrub that follows it.

**Multiplayer is proven against a real dedicated server**, not a listen host.
That distinction matters: only a dedicated server unloads the vehicle's chunk
the way the entire exit design assumes. Position tracking, the three step
handshake, the arrival-driven weight application and *both* branches of the
moving-vehicle rule came through clean -- including the one expected to fail,
exiting into a free seat while somebody else drives the van.

Weight is confirmed applying. The `mass delta` line, which this file used to
record as having never once appeared in a log, now does.

**Towing is proven too.** One player inside, a second tows the van, and the
tenant exits into a seat of the moving towed vehicle. That exercises the
tracker's `getVehicleTowing()` push, the server resolving a towed vehicle, and
the moving-vehicle rule against something nobody is driving.

The **destroy guards** are confirmed both ways -- walls and light switches
refuse to break with `HardenShell` on and break normally with it off -- and the
**leash breach path** behaves as designed.

The fire dousing half of `HardenShell` was exercised and was broken -- it
reported success on every sweep while the fire kept burning. Fixed to vanilla's
`stopFire()` + `transmitStopFire()` pair and retested working. Dousing is gated
on the `HardenShell` sandbox option, so with it unticked fires burn rooms
normally; that is intended.

**So every mechanic in v1 is now proven in game except power binding**, which
is new and has never run. It needs a map with a generator sprite in the room.

Lease expiry is reachable without waiting out the sandbox:
`PhunInteriors.admin("age", {vehicleId = ..., days = 99})` then
`admin("sweepleases")`. Do not enter the room in between -- entering renews the
lease, which is the mechanic working, and it silently invalidates the test.

## Multiplayer

Proven on a dedicated server. Until that run, nothing had ever made a round
trip: `Core.isLocal` short circuits `dispatch`/`respond` into direct calls in
single player, so SP and coop host prove the logic and nothing about the wire.

Two of the suspected problems were real, and both came from one fact, now in
the API table: **vehicle level modData is never transmitted to a client.**

- `vehicle:transmitModData()` in `weight.lua` was a no-op at best -- removed,
  and nothing replaces it, because only the server reads the delta.
- The rejoin phase in `Client.teleport` matched on the modData UUID, which is
  always nil client side, so every dedicated server exit would have ended in a
  false "your vehicle is gone" with no re-seat. Replaced by the handshake.

Confirmed over the wire: enter and exit on foot; enter from a seat and be put
back in it; position tracking, including the send on stopping; the arrival
handshake and the weight application that rides it; both branches of the
moving-vehicle rule; reconnecting while inside; and recovery across a server
restart. That also settles the wire id -- `getId()` is a short and numbers
cross as doubles, and it resolves anyway -- and the seat and door capture read
client side in `Client.beginEnter`.

The leash is proven at 4Hz over the network for the exit tile, which is the
same handler, so `graceUntil` at 6s survives real latency. Its *breach* branch
is still unexercised.

Towing is confirmed as well: one player inside, a second towing, the tenant
exiting into a seat of the moving towed van.

Still unproven:

- **`Core.tools.onlinePlayers()`** returns only local players on a client and
  everyone on a server. `author.lua` reads `players:get(0)` for "where am I
  standing", which is correct on a listen server and wrong on a dedicated one
  with more than one admin.
- **The leash breach path** -- walking out of bounds rather than onto the exit
  tile. Same `Transit.leave` either way, so the risk is in `Leash.classify`,
  not in the exit.

### Prior art

`RV Interior` (workshop 2822286426, B41) solved the position problem first and
the tracker's shape is taken from it: driver-only, throttled, refreshed every
70 tiles and once more on stopping, pushing the towed vehicle alongside. Its
one genuinely better idea is that the client sends **only the vehicle id** --
the server reads the position off the vehicle itself, so there is nothing in
the message to take on trust.

Do not copy its exit path. It finds the vehicle client side with
`getCell():getVehicles()` then `allVehicles:get(vehicleIndex)`, one per
`OnPlayerUpdate` for 500 retries. That is `Set:get(i)`, which does not work in
B42 (see the API table), so the whole mechanism is dead here -- likely the
actual B41 to B42 break in that mod. It also seats with
`vehicle:enter(seat, player, offset)` rather than `ISEnterVehicle`, which is
why it needs the "inside" passenger position and a comment about doors, and it
has no equivalent of rule 5 -- with no free seat it clips the player into the
bodywork and prints a warning.

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
                                    weight, power, harden, admin, author,
                                    server_{commands,events}
  .../server/PhunInteriors/blueprints/  generated room set files, shipped
  media/lua/client/PhunInteriors/    client_{main,enter,context,guards,tracker,
                                    commands,events}
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
Released slots go to `quarantine`. The reference mod never freed a slot, so its
pool exhausted and the feature silently stopped working.

**A quarantined slot is reissued and then scrubbed, not scrubbed and then
reissued.** The original order could not work: a scrub needs the chunk loaded,
the chunk only loads when somebody is near the room, and nobody is near a room
that was released for being unused. The measured load radius is 61-120 tiles
against a 60 tile pitch, so only slots adjacent to an occupied one ever
drained; every other released slot was lost and the pool shrank until the set
reported itself full. That is the reference mod's failure reached from the
opposite direction.

So `Slots.acquire` prefers a clean slot, falls back to a quarantined one, and
returns a third value saying which. `Transit.enter` scrubs it immediately if
the chunk happens to be loaded; otherwise the leash does it on arrival, the
first moment the chunk is guaranteed to exist. The invariant is now "never
*used* dirty" rather than "never reissued dirty".

`Scrub.processQueue` still runs on a timer, but only as opportunistic cleanup
for slots that happen to be loaded. It is no longer the thing the pool depends
on.

**Exit position is live when it can be, and frozen when it cannot.**
`resolveReturn` in `transit.lua` tries `getVehicleById` first and reads the
vehicle's real position. Only loaded vehicles come back, so an unloaded one
falls through to the position stored on its lease.

That stored position is not a stale cache in any way that can hurt, and the
reason is the load rule: **an unloaded vehicle cannot move**, because unloaded
means no player is within the load radius, which means nobody is driving it.
So the stored position is frozen truth, not old data — *provided it was
accurate at the instant the vehicle unloaded*. Keeping it accurate is what
`client/PhunInteriors/client_tracker.lua` is for.

The earlier rule here was "never cache a position", written against the
reference mod's one-minute timer, which dropped you up to sixty seconds in the
past or inside geometry. That failure needs the vehicle to have *moved since
the sample*, which needs it to be loaded. The rule that actually holds is:
**never trust a stored position while the vehicle is loaded.** Sweep for it
instead — `liveVehicle` does exactly one 7x7 sweep at exit, which also covers
the case where the vehicle reloaded and every handle we hold is dead.

**Nothing about a vehicle's identity is ever sent to a client.** Vehicle level
modData is never transmitted (see the API table), so the UUID cannot be matched
client side and the attempt to do so broke every exit in multiplayer. Instead
the server names a *position*, the client takes whatever vehicle is there, and
reports its `getId()` back up for the server to check against the lease. That
is the direction vanilla proves: clients send `getId()` and servers resolve it
with `getVehicleById`, about thirty times in `VehicleCommands.lua`.

**Leaving is a three step handshake**, because no one side can answer the whole
question. The server decides where the player goes and which seat they are
owed; the client moves them, because vanilla only ever seats a character from a
client timed action; then the client reports what it found, which is the first
moment anybody can tell an unloaded vehicle from a destroyed one. Weight is
applied on that report rather than by a poll — same moment, one less timer.

**A seat and the interior are the same vehicle.** Moving between them is an
internal move and is allowed at any speed. Only the boundary between the
vehicle and the *ground* is gated on motion. So a passenger can step into the
back of a van doing forty, and step back out into a free seat, but nobody
boards or leaves a moving vehicle from outside it.

`Core.vehicleMotionAllows` is the one implementation, shared, called by
`Transit.canEnter` for authority and by `Client.beginEnter` so a refusal is
instant rather than arriving after a fifteen second action. Two things it
refuses: catching a vehicle you are not aboard, and leaving the wheel of one
you are driving -- `Core.isAtTheWheel`, which is `isDriver` **and**
`getVehicleTowedBy() == nil`, because sitting in seat 0 of something under tow
is not driving it.

This is why `Client.beginEnter` does not queue `ISExitVehicle` when the player
is already in the target vehicle. That is not an optimisation: `ISExitVehicle`'s
`isValid` is `vehicle:isStopped()`, so queueing it made entering a moving
vehicle impossible, and the queue dropped both actions without a word. The seat
is vacated by `vehicle:exit()` in `Client.teleport` instead, which is where it
always was. A player in a *different* vehicle still climbs out properly.

**You cannot step out of a moving vehicle onto the ground** unless there is a
seat free.
`Transit.leave` refuses before it teleports anybody, so there is no port-and-
bounce. The test is `getCurrentSpeedKmHour()`, never `getDriver()`: a towed
vehicle moves with nobody at its wheel, which is what vanilla's
`getDriverRegardlessOfTow` exists for. Refusing is self-resolving — the driver
parks, logs off or crashes.

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

**There is no golden slot.** Slot 0 is leasable like any other. It used to be
reserved as a pristine copy to scan blueprints from, which cost a room of map
per set and only worked when somebody happened to be standing near it; it failed
nearly every capture it attempted. `Manifest.anySibling` replaces it.

An empty scan means the chunk was not loaded, not that the room is
empty, and caching that would poison every future scrub, which is why it refuses to.

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
up after `Manifest.CAPTURE_ATTEMPTS` ticks, falling back to a sibling room.
The capture sits **above** every early return in `Leash.checkOne`, including
the noclip exemption and the arrival grace. Capture is not containment: it
only cares that the player is standing in the room. Placed under the exemption
it captured nothing at all, because an admin testing with noclip on is the
normal case.


**Blueprints are authored, not discovered.** `PhunInteriors.author(action,
args)` builds a room set from where an admin is standing -- corners, spawn,
exits and power are all read from the player position -- and emits a lua file
that calls `registerRoomSet`, `registerVehicleClass` and `registerBlueprints`.
That file goes in `server/PhunInteriors/blueprints/` and loads itself. There is
no file reading at runtime anywhere in this design, and no json.

`Manifest.forSlot` resolves shipped, then runtime capture, then any sibling in
the same set, and returns which it used. Runtime capture is only the fallback for
third party sets whose author has not run the tool.

The emitter pools one palette across every slot in a set, because rooms in a
strip share nearly all their sprites. Squares are written in sorted key order
so re-exporting an unchanged map produces an identical file -- otherwise every
export is a full diff and the file stops being reviewable, which is half the
reason for emitting lua rather than a blob.

**Scrub reconciles, it does not rebuild.** Keep every object the blueprint
expects and the square already has, remove the extras, create only what is
genuinely missing.

This reverses the original design, and not for style. The engine picks an
object's class from its sprite when the map loads -- the same sprite becomes an
`IsoLightSwitch`, an `IsoDoor`, an `IsoThumpable` -- and Lua cannot ask for
that. `IsoObject.new` returns a plain `IsoObject`, so a rebuilt light switch is
a picture of a light switch. Confirmed in game: switches stopped working after
the first scrub. Vanilla lua never constructs one of these, it only ever tests
with `instanceof`.

Reconciling is also *more* idempotent than the rebuild was: a second pass over
a restored room touches nothing at all.

What does get recreated goes through `Scrub.createFromSprite`, which reads
`sprite:getType()` and constructs the matching class. Only `lightswitch` is
handled so far, because a room with no working light was the reported failure;
doors, windows and walls have branches in vanilla worth copying when needed.

**The room runs off the vehicle battery, through a real generator.** There is
no alternative: `square:haveElectricity()` reads no field, it is
`chunk:isGeneratorPoweringSquare(x, y, z)`, so generator power is only ever an
actual activated `IsoGenerator` registered in the chunk.

**Its position is fixed data and does not move.** `set.power` is captured by
the authoring tool and emitted into the blueprint, and it sits at `z + 1` —
above the room and outside the leash, reached through a panel and never on
foot. That placement is also why there are no fumes: vanilla only makes a
building toxic for a generator on a non-exterior square, and nobody ever
stands next to this one.

What can change is whether the generator still *exists* — it caught fire, it
blew up, a scrub rebuilt the square and left an inert copy. So
`Power.ensureGenerator` places a fresh one when it has gone, following
vanilla's own recipe from `MOGenerator.lua`: `instanceItem("Base.Generator")`,
`IsoGenerator.new(item, cell, square)`, `transmitCompleteItemToClients()`. It
also clears any generator-*shaped* object that is not an `IsoGenerator` first —
a sprite recreated by name comes back as a plain `IsoObject`, the same trap
that cost us working light switches. Condition is reset to 100 on every visit,
because a generator that degrades eventually fails in a room where nobody can
reach it to fix it, which is a fault report rather than a mechanic.

A room set can opt out entirely with `powered = false` — a tent has no
generator and should not have one conjured for it.

`setActivated(true)` does everything else itself: registers the position with
the chunk, calls `setSurroundingElectricity`, syncs to clients.

Weight and power are measured at the same two moments and for the same reason.
The room is loaded on the way out because the player is standing in it; the
vehicle is not, and will not be until they land on top of it — so both ride the
arrival report.

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
| An object's behaviour lives in its class, and `IsoObject.new` always returns a plain `IsoObject` — a restored light switch is a picture of a switch. The class comes from `getSprite(name):getType()`, and vanilla constructs the right one in `ISMoveableSpriteProps.lua:2175-2196`: `IsoLightSwitch.new(getCell(), square, sprite, square:getRoomID())` then `addLightSourceFromSprite()`, with sibling branches on `IsoFlagType.doorN/windowN/WallN` for doors, windows and walls. | `Scrub.createFromSprite` mirrors the light switch branch. Two separate lessons: recreating an object from a sprite name alone loses its behaviour, **and** "vanilla never does X" was wrong here — a `grep` for `IsoLightSwitch` found only `instanceof` tests because the constructor call is 2000 lines into a Moveables file. Search for the *constructor*, not just the class name. |
| `IsoGridSquare` has **no `getContainer()`** and no `getDeadBody()`. Containers hang off the object (`isoObject:getContainer()`); bodies come from `square:getDeadBodys()`, plural, returning a list. `getDeadBody(index)` is a *hutch* method. Vanilla removes a body with `removeFromWorld()` then `removeFromSquare()`, in that order. | Both were wrong in `Scrub.clearSquare` and threw `Object tried to call nil` the first time a scrub ever ran. Note the jar check passes for both: a class's constant pool contains method names it **calls** as well as ones it owns, so "present" proves nothing on its own — cross-check against vanilla usage. |
| **Electricity, settled from the bytecode.** `haveElectricity()` reads no field at all: it is `chunk:isGeneratorPoweringSquare(x, y, z)`, with an early `false` for an exterior square when `AllowExteriorGenerator` is off. **`setHaveElectricity(boolean)` does not set anything** — it ignores its argument entirely and calls `update()` on any `IsoLightSwitch` on the square. It is a refresh with a setter's name. `hasGridPower()` is `not isNoPower() and doesPowerGridExist()`; `isNoPower()` is `isDerelict() or isUserDefinedRoom()` or the square sitting in a map zone of type `"NoPower"` or `"NoPowerOrWater"`. | Generator power is only ever a **real, active `IsoGenerator` in the chunk** — it cannot be faked with a flag, which is why RV Interior places one. The mains cannot be switched off from Lua, but it *can* on the map: a **`NoPower` zone painted over the interior block** makes `hasGridPower` false there permanently, leaving the generator as the only source. That is a map authoring job, and `admin("power")` reports whether it has been done. Note this row replaced an earlier, wrong one that reasoned from method names — hence `Docs/body.pl`. |
| **"Is this vehicle moving" is `vehicle:isStopped()`, not a speed threshold.** A stationary vehicle *under tow* reports a non-zero `getCurrentSpeedKmHour()` — the coupling never quite settles — so any epsilon is a guess about physics jitter. `isStopped()` is what vanilla gates vehicle interaction on (`ISExitVehicle:isValid`, `ISVehicleMenu.lua:185`). | Confirmed in game: a parked towed van refused boarding while telling the player it was moving. Seated players were unaffected, because `isAtTheWheel` short-circuits before the speed test — which is exactly the asymmetry that identified the cause. |
| Putting out a fire is `square:stopFire()` **then** `square:transmitStopFire()`, which is what vanilla's fire brush does (`FireBrushUI.lua:265`). `IsoFire.extinctFire()` and `IsoFireManager.RemoveAllOn(square)` are both declared and both read exactly right — and both have **zero** uses in vanilla lua. | `Harden.sweepFire` used `fire:removeFromWorld()` on the object from `square:getFire()`. That is `IsoObject`'s generic removal: the engine answered every call with `IsoFireManager.Remove unknown fire, ignoring`, so the same fires were re-found and "doused" on every sweep, forever, while still burning. The log said it worked. A plausible-looking declared method with no vanilla uses is the tell, and here there were *two* of them next to the right answer. |
| `IsoGridSquare` has **no `setBloodSplatLifetime`**. Vanilla `ISCleanBlood:complete()` uses `square:removeBlood(false, false)` then `square:removeGrime()`. | Confirmed absent from the jar. |
| Vanilla only ever exits a vehicle from a **client** timed action (`ISExitVehicle`). | `vehicle:exit()` lives in `Client.teleport`, not in server-side `Transit.enter`. |
| `getCell():getVehicles()` returns a **`java.util.Set`** — `size()` but no `get(i)`, so it cannot be indexed from Lua, and **loaded vehicles cannot be enumerated from Lua at all**. Vanilla's own `ISVehicleBloodUI.lua:81` does `vehicles:get(i-1)` and is therefore broken; so does RV Interior's entire exit path. | `resolveReturn` uses `getVehicleById(handle)`, and position tracking is pushed by the driver's client rather than swept for. Vanilla Lua shows intent, **not** correctness — and neither does a shipped mod that works on B41. |
| **Vehicle level modData is never transmitted to a client.** `IsoObject` declares the whole sync path — `transmitModData`, `sendObjectModData`, `ObjectModData`, `IsoObjectChange`. `BaseVehicle` declares `getModData`/`setModData`/`hasModData` and `transmitPartModData(VehiclePart)` and **none** of it. Vanilla never calls `transmitModData()` on a vehicle (only doors, players, characters, carcasses, plain objects) and every vanilla client-side vehicle modData read is `part:getModData()`. | Anything a client must know about a vehicle has to be *sent* to it, or discovered client side and confirmed by the server. A client-side UUID match cannot work. `transmitModData()` on a vehicle is worse than a no-op: `IsoObject`'s version addresses an object by square plus index in that square's object list, and a vehicle is not in `square:getObjects()`. |
| **B42 has no server side "a player left" event.** `OnDisconnect` is a *client* event meaning "you were disconnected"; it takes no player argument and vanilla uses it only in `ConnectToServer.lua` and `ISMPEditAccount.lua`. Dumping every name from `LuaEventManager` finds no `OnPlayerDisconnect` or equivalent. | `server_events.lua` deliberately has no disconnect handler. It had one, hooked to `OnDisconnect`, and it never fired once. Keeping the occupancy is the better behaviour anyway — `playerSetup` finds it on reconnect. |
| `BaseVehicle` declares `getCurrentSpeedKmHour`, `getSpeed2D`, `getDriver`, `getDriverRegardlessOfTow`, `getVehicleTowing`, `getTowingPartner`, `isSeatInstalled`, `isDriver`. `OnSwitchVehicleSeat` is **not** an engine event — vanilla registers it from `ISVehicleDashboard.lua:716`. | Rule 5 gates on speed, not on `getDriver()`, because a towed vehicle moves with nobody at its wheel. The tracker installs in the deferred setup, like the destroy guards, or the seat hook silently does nothing. |
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

For a conclusive answer, parse the method table rather than the constant
pool. `Docs/methods.pl` prints what a class actually declares, with real
signatures:

```bash
perl Docs/methods.pl /tmp/pzchk/zombie/iso/objects/IsoLightSwitch.class "<init>"
#   public <init> (IsoCell, IsoGridSquare, IsoSprite, long) -> void
```

**And when a declared method does not behave the way its name reads, disassemble
it.** `Docs/body.pl` dumps a single method body, resolving field and method
references and string constants. The game ships a JRE, so there is no `javap`;
this needs no JDK.

```bash
perl Docs/body.pl /tmp/pzchk/zombie/iso/IsoGridSquare.class haveElectricity
perl Docs/body.pl /tmp/pzchk/zombie/iso/IsoGridSquare.class hasGridPower "()Z"
```

Reach for it the moment behaviour contradicts a name. `setHaveElectricity` was
assumed to be a setter for two rounds of reasoning; one dump showed it ignores
its argument. A name is a claim, a signature is a contract, and only the body
is evidence.

Absent is conclusive. **Present is not**: a constant pool holds the names a
class calls on other classes as well as its own, so `getContainer` shows up in
`IsoGridSquare` purely because it calls it on an object. Present means "worth
checking", never "exists here".
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

0. **The map needs a `NoPower` zone over the interior block.** Without it the
   rooms sit on the mains until the grid shuts off, and the generator binding
   is invisible for the first weeks of a save. `hasGridPower()` is
   `not isNoPower() and doesPowerGridExist()`, and a `NoPower` (or
   `NoPowerOrWater`) map zone is the only way to force `isNoPower()` true --
   there is no Lua setter. It is a five minute job in WorldEd and it must go on
   the request to whoever builds the map, alongside the coordinates in gap #1.
   `PhunInteriors.admin("power")` verifies it.
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

The water barrel, the siege/breach system, a fuel penalty for load, and the
purpose-built map.

Power binding was on this list and has been pulled forward -- see Architecture.
It moved because the hooks it needed already existed for weight and blueprint
capture, so it cost far less than the v2 label implied.

## Open questions

- Should expired-room loot survive by default? Currently `ScrubKeepsLoot=false`.
  It is the most complaint-generating behaviour in the design.
- Is `WeightFactor=50` right? It is a guess and needs an overloaded van to
  calibrate against.
- ~~Should entering from the driver's seat make you climb out?~~ **Answered:
  no.** See "A seat and the interior are the same vehicle" in Architecture.
- **Where should you have to stand to get in?** Entry is currently allowed from
  anywhere the radial menu resolves the vehicle, which in practice is anywhere
  around it. Confirmed in game. Sketched, not decided: the back of a van, the
  side door of an RV, and never the driver's seat of a trailer. This is per
  vehicle class, so it belongs in the registry next to `requires`, not in the
  entry action. Needs a session of its own.

## Design note

Full rationale, including the analysis of the reference mod this reacts to:
https://claude.ai/code/artifact/67264759-901c-4bdb-9790-3681d200ccd0
