# PhunInteriors

Project Zomboid **B42** mod. Instanced vehicle interiors: lease an off-grid room
to a vehicle, put the player inside. SP and MP share one code path.

Author: UburGeek. Part of the Phun mod family (PhunLib, PhunCure, PhunLewt,
PhunZones, PhunServer2...). GitHub org: `PhunZoider`.

## Status

**The registry was reshaped and has not run in game since.** Rooms, bindings
and blueprints all changed shape -- see "A room is a contract" in Architecture.
`Tests/run.sh` is green across 552 checks, which is real verification of the
logic and no verification at all that PZ agrees. Everything below describes
what was proven *before* that change; the mechanics are the same, but the
registry underneath them is not.

**And the registry can now be edited from inside the game, which has also never
run.** An edit is a sparse patch kept in `PhunInteriors.json` in the Lua
folder, applied over the shipped registration by re-running `registerRoom` --
see "An edit is a patch" in Architecture. The old two-list room window is a
three-tab editor built on panels vendored from PhunMart2. It is the newest
thing here and the least proven: Known gaps #12 says what to watch.

**And the exit contract has since been reshaped again, also unproven in game.**
`landing` is gone. A room now states `front` -- which of its edges faces the
holder's nose -- plus `cab` as a boolean on that edge, and `Core.relativeFor`
derives `front`/`rear`/`left`/`right` from the edge the leash saw crossed.
`Client.groundBeside` takes that relative direction instead of a vehicle area
name. **This is the exit path, which is the one that strands a player when it
is wrong**, so it is the first thing to watch. Four rooms deliberately register
*no* front -- `2x4_campingstorage` and the three `*_camping` caravans, whose
doors are in the side -- so their tenants land beside the vehicle until
somebody says which way a caravan points. `selfPowered` is new and has never
run either.

**Playable in single player and on a dedicated server.** Confirmed working in
game: enter and exit, containment, seat and door restore, translations,
blueprint capture, scrub (including restoring a working light switch), and
the whole lease lifecycle as it then was -- expiry, release to quarantine,
reissue from quarantine, and the scrub that follows it. Expiry has since been
replaced by reclaiming on demand, which has not run in game; release,
reissue and scrub are unchanged underneath it.

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

A reclaim is reachable without waiting out the sandbox or filling 1200 rooms:
`PhunInteriors.admin("age", {vehicleId = ..., days = 99})` then
`admin("reclaim")`, which picks with the same function allocation uses. Do not
enter the room in between -- entering renews the lease, which is the mechanic
working, and it silently invalidates the test.

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

The leash was proven at 4Hz over the network back when an exit tile ran
through the same handler, so `graceUntil` at 6s survives real latency. That
tile is gone and **the breach branch is now the ordinary way out**, so the path
that carries every exit is the one that was never exercised. It is the first
thing to watch in game.

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
bash Tests/run.sh
```

That parses every lua file with LuaJIT, runs three static checks — no function
shadowing a field declared on the `PhunInteriors` table in `core.lua`, no local
redeclared at the top level of one function (`Tests/shadow.pl`), and no writer
of `Core.occupants` other than `Transit.setOccupancy` — and then runs the specs
in `Tests/lua/`.

Each of those three exists because the bug it catches had already happened and
none of them is visible to LuaJIT: a `Core.rooms()` console helper replaced the
registry table, a second `local destination` in `Transit.leave` replaced a
position with a string so every exit teleported to nil, and the occupancy count
the leash gates on fails open if anything writes the table behind it.
LuaJIT is the fastest way to catch syntax errors, but it cannot catch API
misuse — PZ globals do not exist outside the game, and LuaJIT will happily
accept `next()`, which PZ's sandbox does not expose.

`Tests/lua/stubs.lua` fakes the handful of globals the files touch while
loading, which is enough to exercise the pure-Lua half of the mod: location
placement in both entry forms, sparse indices, the reverse indexes, `slotAt`,
script binding and its union across bindings, the allocation order in
`Slots.acquire`, the nullable generator, per-slot
blueprint capture under a pooled palette with its resolution order, and a full
`author` session driven through to the emitted file and loaded back into a
fresh registry.

It also fakes the **Lua folder**, as an in-memory table, which is enough to run
`store.lua` end to end — save, read back, save again — because the override
file is the only durable state the admin editor has and every way it can go
wrong is silent. Deliberately not the real filesystem: the game resolves those
calls against `~/Zomboid/Lua`, so a test writing there would either need that
folder or would write into the developer's own save. The stub truncates on open
exactly as the real `getFileWriter` does, because `Store.save` encodes before
it opens the file precisely to survive that, and a stub that appended would let
the regression past.

That last one earns its keep. The emitter builds every shipped room, its output
is only ever exercised on the *next* boot, and a mistake in it is a map's worth
of work written out wrong. Writing the test found two: an emitted `[0] = ...`
table that `ipairs` would have silently dropped slot 0 from, shifting every
room by one, and a blueprint loop still reading a session field that had been
removed.

The specs have since earned it twice more, both on the reshape. They caught
`normaliseLocations` losing every location after a deleted one -- the failure
this whole indexing scheme exists to prevent -- and they caught specificity
being counted per *binding* rather than per script, which silently reintroduced
the starvation the ordering exists to stop. Neither would have shown up as an
error in game; both would have shown up as rooms quietly going missing.

It is **not** a mock of the game — anything needing an `IsoGridSquare` is
tested in game or not at all. Add to it when you change registry, allocation or
emitter logic; do not try to grow it into a simulator.

Deployment is VS Code `emeraldwalk.runonsave`
(see `.vscode/settings.json`), which runs `deploy.cmd` on every save. That
builds four trees: `~/Zomboid/mods/PhunInteriors`, the test-id variant
`PhunInteriorsTest` (the live mod overlaid with `Tests/root/PhunInteriors/`),
and Workshop upload staging for each. `xclude` is the xcopy exclude list for
the staging copies.

`map.cmd` is the map loop: it copies the editor export (`PI_MAPSRC`) into the
repo without touching `map.info`, runs `roomcheck.pl`, calls `deploy.cmd`, and
deletes our cells plus `global_mod_data.bin` from a test save (`PI_TESTSAVE`,
or the first argument; `-` skips it). Quit the world to the main menu first --
the game writes loaded chunks back on the way out. The VS Code task "Map: sync,
check, deploy, reset" runs it.

## Layout

Standard Phun conventions, mirroring PhunCure2. Everything ships under
`common/`. There is no root `mod.info` and no versioned (`42.x/`) folder.

```
Contents/mods/PhunInteriors/common/
  mod.info                  id=phuninteriors, versionMin=42.0.0, no require line
  icon.png  poster.png
  media/sandbox-options.txt
  media/lua/shared/PhunInteriors/    core, tools, registry, bounds, defaults,
                                    reservoir, holders, overrides, json
  media/lua/server/PhunInteriors/    slots, transit, leash, manifest, scrub,
                                    weight, power, harden, removal, admin,
                                    author, rainwater, loot, store,
                                    server_{commands,events}
  .../server/PhunInteriors/blueprints/  NOT SHIPPED, deleted before release.
                                    Nothing ships a blueprint any more, because
                                    capture is per slot and falls back to a
                                    sibling. Create it by hand if you drop an
                                    `author` export in; the game loads lua under
                                    media/lua/server recursively.
  media/lua/client/PhunInteriors/    client_{main,enter,context,guards,tracker,
                                    reservoir,rooms,admin,commands,events}
  .../client/PhunInteriors/ui/       the registry editor: shell, {rooms,slots,
                                    bindings}_tab, {room,binding,slot}_form,
                                    state, plus form_panel/list_panel/ui_utils
                                    VENDORED from PhunMart2
  media/lua/shared/Translate/EN/     ContextMenu.json, IG_UI.json, Sandbox.json,
                                    ItemName.json, Recipes.json
  media/scripts/PhunInteriors.txt    the reservoir kit item and its recipe
  media/maps/phuninteriors/          the map: 20 cells of lotpack, lotheader
                                    and chunkdata, plus map.info, objects.lua
                                    (the NoPowerOrWater zone) and roomtones.lua.
                                    17MB, tracked, binary -- see .gitattributes
  media/phuninteriors.tiles          our own tiledefs, incl. the black lid tile

Tests/run.sh                       syntax check + specs; the whole test suite
Tests/lua/stubs.lua                PZ globals, faked just enough to load
Tests/lua/*_spec.lua               registry placement/links, allocation order,
                                   occupancy count, author, vehicle removal,
                                   reservoir coverage, world-object holders,
                                   the tent pickup lock, the override layer,
                                   the entrance position and its fallback,
                                   the PhunInteriors.json round trip and the
                                   admin actions the editor drives
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
- **And nothing may be hung off `PhunInteriors` under a name `core.lua` already
  declares.** One namespace for the registry tables and for every function is
  convenient right up to the collision, which is silent: a `function
  Core.rooms()` console helper in `client_admin.lua` *replaced* the registry
  table at file load time, so the first `registerRoom` indexed a function and
  the mod did not boot on any client or in single player. `Tests/run.sh` reads
  the field names out of the `PhunInteriors = {` literal and refuses any file
  that defines a function over one of them.
- Settings cached via `Core.getOption` and refreshed on `EveryTenMinutes`.
- **No em dashes. Anywhere.** Not in this file, not in code comments, not in
  commit messages, not in anything written for a player to read, and not in a
  reply. Where one would go, use `--` as the newer half of this file already
  does, or recast around a comma, a colon or a full stop.

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

**The leash contains on the floor, not the footprint.** `size` is a footprint,
and PZ puts the south and east walls on the edge of the squares *beyond* the
floor, so the footprint's last row and column are outside the room.
`Core.slotFloor` drops them; `Leash.classify` uses it. Everything that has to
*reach* the walls — scrub, capture scan, fire sweep, weight, the destroy
guards, `Transit.recover` — keeps `Core.slotBounds`. Testing the footprint went
unnoticed until the ambulance bays' south doorway: a tenant was two squares out
before the leash fired, because the square just past the wall still counted as
inside. A north exit never shows it, since that wall is on the floor's own row.

**Do not replace the box with a floor-sprite test** ("standing on
`phuninteriors_01_0` means outside"). It was considered. The box is what catches
a neighbouring stamp, the roof, and a teleport onto somebody else's floor —
none of which is black — and it has to exist anyway to say *which edge* was
crossed. A sprite test would also couple containment to decor, which is
captured per slot and belongs to the map author, and it would mean nothing to a
third party room pack that paints its ground with something else.

**The tick is always registered, and gates on a count rather than
unregistering.** `Transit.anyoneInside()` is one integer compare, and it is the
first thing `Leash.tick` does — before reading the clock, which an empty map
used to do sixty times a second to work out it had nothing to do.

**Do not "fix" this by adding and removing the `OnTick` handler.** `Event.trigger`
walks its callbacks by index, re-reading `size()` each time round, so removing
one during dispatch shifts the list under the cursor and **silently skips the
next handler** — somebody else's, from another mod. It does not throw. And the
exit path runs from inside this very tick, which is precisely when the
unregister would happen.

The count is kept by `Transit.setOccupancy`, which is the **only** thing that
writes `Core.occupants`; there are three callers — entering, recovering a
player who logged in already inside, and leaving. It counts the *transition*
rather than the value, so setting the same holder twice or clearing an empty
slot both leave it alone. `Tests/run.sh` refuses any second write site, because
a count maintained in two of three places fails open, and failing open here
means a recovered tenant nobody is containing.

**The leash is server-side because it is the authority**, and that should not
change. A client-side copy for responsiveness is reasonable and would follow
the pattern `Core.vehicleMotionAllows` already sets — one shared implementation
called from both sides, the client for feel and the server for truth, with
`Core.slotAt` and `Core.inBounds` already living in `shared/bounds.lua` for
exactly that. It would be an addition, never a replacement: the client does not
know whose lease is whose, and a client that simply declines to run the check
must still be contained.

**There is exactly one way out.** Walking out of a doorway, a hole in the wall,
and a tripped leash all call `Transit.leave`, which puts the player back at the
vehicle. Do not add a separate breach handler — collapsing these was a
deliberate decision.

**And there are no ordinary exit tiles, because the leash already was the
exit.** A declared tile and a breach both ended in the same call differing by a
string, so the tile earned nothing: open the door, step off the last square of
the box, and containment takes you home. What a declared tile is for now is
saying that *this* way out goes somewhere different — which is `cab`, and the
only kind there is.

That has a consequence the tile used to hide: **the door has to actually
open.** With a tile you left by standing on the doorway whether or not the door
worked. So `Scrub.createFromSprite` had to learn doors — `isStructural`
captures a door into the blueprint, and a room whose door came back as a plain
`IsoObject` after a scrub is a room nobody can leave. That was cosmetic before
and is a soft-lock now.

**A seat is one of the destinations, not a different mechanism.** `cab = true`
says the **front** edge puts you in a seat: first fitted, free one, counting
from the driver's. No preference is sent, so *which side you leave by decides
where you come out, rather than where you got in*. A room that names no front
lands you beside the vehicle, exactly as before.

`cab` is a boolean rather than an edge of its own because a cab is always at
the front of the thing — across the whole shipped map there was never a seat
exit anywhere else. Two fields would have been two ways to say one fact, and
they could disagree.

**Say it as an edge, never as a tile.** A cab exit was a declared tile for
about an hour and it was wrong: a tile in a doorway is a square you walk
*through*, the leash samples at 4Hz, and a player at a run is quite likely
never seen on it — so the cab door would have worked at a walk and dropped you
in the road at a run. Deriving the edge back off the tile fixed that but kept
two concepts to say one thing. Being outside the box is a state you *stay* in,
which is why the edge is reliable and the square is not.

It is the one way out that can **fail**, and only the client can see it fail:
whether a seat is free is a question about a vehicle that is not loaded when
the player leaves. So a cab exit is a *request*. The client reports `seated`
back on the arrival handshake, and `Transit.arrived` puts the player back in
the room when it is false. Cheap, because only the occupancy was torn down —
`Slots.touch` renewed the lease on the way out, so going back in re-enters the
same slot rather than allocating anything.

**The room says which way its holder points, and everything else is
arithmetic.** A room is 3x4 and a van is about 2x5; there is nothing
proportional between them. But *which side you left by* is a question both
shapes can answer, so `Leash.classify` returns the edge of the box that was
crossed, `room.front` says which edge faces the holder's nose, and
`Core.relativeFor` turns the pair into `"front"`, `"rear"`, `"left"` or
`"right"`. Nothing in `leash.lua` or `registry.lua` knows a vehicle part name.

**This replaced a `landing` table, and the reason is worth keeping.** It mapped
each edge to a **vehicle script area name** — `landing = {north = "TruckBed",
south = "cab"}` — which was wrong twice over. It put vehicle vocabulary in the
room contract, so a room carried by anything else had no way to answer: the
same category error `requires` made, which is why that field no longer exists
at all. And it
made authors lie. Across the whole shipped map the deployed vocabulary was
`"TruckBed"` and `"cab"`, and two of those TruckBeds sat on an **east or west**
door — the camper vans and the caravans, whose door is in the *side*. A side
door does not lead to the truck bed; the name was standing in for "outward"
because it was the only area that resolved to a sane direction. One stated edge
says the true thing once instead of a false thing per edge.

Resolved **client side**, after arrival, because the vehicle is not loaded when
the player leaves — the direction rides down with the teleport and the client
asks the real vehicle. That is the arrival half of a handshake that already
existed rather than a new one.

`Client.groundBeside` is the vehicle-side half and the only place in the mod
that knows a part name. It tries a **list** of candidate areas per direction
(`rear` → `TruckBed`, `TrunkDoor`), because declaring one is optional and
widely skipped — **the StepVan declares neither `TruckBed` nor `Engine`** and
`lockMartM577` declares no `TruckBed`. Failing that it asks the vehicle which
way it is pointing. There is deliberately **nothing listed for left and
right**: no vanilla script declares an area meaning "the flank", so a guess
there would resolve to something that is not the side, which is exactly the lie
the old table told.

`getForwardVector` is public on `BaseVehicle` but has **zero uses in vanilla
Lua**, which by this file's own rule is a reason to probe rather than trust. It
is `pcall`'d and nil-checked, and every caller already falls back to the nearest
door, so nothing depends on it working. `Vector3f.new()` is proven reachable
from Lua — `client_main.lua` already uses one.

A landing is a preference, not a position. There is no default front, for the
reason `generator` has no default — a room whose long axis ran east-west would
be handed a wrong answer that looks deliberate.

**Rooms are leased, not assigned.** Every assignment carries `lastSeen`.
Released slots go to `quarantine`. The reference mod never freed a slot, so its
pool exhausted and the feature silently stopped working.

**The admin can turn reclaiming off, and it is the same number that does it.**
`RoomProtectedDays` runs 0 to 99999999, and both ends mean something: 0 lets
any unused room be taken the moment the pool is full, and the top of the range
never takes one at all -- a vehicle is simply refused once the last room is
gone. Absurd as a maximum, and deliberately so: it is how an admin says never.

There is no separate "allow reclaiming" tick beside it, because a tick and a
threshold are two controls for one decision and they can disagree -- a server
with the tick off and a threshold of three is saying two different things about
the same room. Nor is the maximum a special-cased sentinel; it is just a number
large enough that the comparison cannot come true inside a save, so there is no
third meaning hiding in the field.

**A lease never expires on a clock. It is reclaimed when somebody needs it.**
`Slots.acquire` spends every free and quarantined slot in every room the
vehicle could have, and only then takes the lease unused the longest -- if it
has gone unused for `RoomProtectedDays` and nobody is inside, counting a tenant
who disconnected in there. There is no daily sweep and no advance warning.

This replaced a daily sweep that released anything idle past `LeaseDays`, and
it replaced it because that sweep threw away a tenant's belongings on schedule
with a thousand rooms standing empty. Reclaiming on demand dominates it: every
room lives at least as long as it did, the pool fills at exactly the same rate,
and what is lost is only predictability -- "safe for N days, at risk after that
if the server fills" rather than a date.

Three orderings, each deliberate:

- **After every free slot in every room**, not per room like clean-then-
  quarantined. Those orders decide which spare capacity to spend; this one
  decides whose room to take, and a general purpose slot is always worth
  spending first.
- **Longest unused across all eligible rooms**, not most specialised first.
  With everything full there is no capacity left to save for anybody, so the
  question is fairness.
- **Ties break on candidate rank, room, index, then id.** Ties are routine --
  `adoptBaseline` stamps every lease with one hour -- and `pairs()` order is
  not stable, so without the tail one save could reclaim differently twice.

The owner is told afterwards rather than warned before, because there is no
date to warn about. `Transit.enter` stamps `consts.leasedKey` on a vehicle the
first time it gets a room; a vehicle carrying it with no lease has lost one and
gets `IGUI_PhunInteriors_RoomReclaimed`. Not the UUID: that is written before
allocation, so a vehicle refused its first room would carry one too.

`admin("reclaim")` takes what a full pool would take next, through the same
`Slots.oldestReclaimable`, because on the shipped map the real trigger needs
1200 leases.

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

**It used to say so on every pass, which was the wrong kind of honest.** A
quarantined slot sits in the queue precisely because nobody is near it, so
"chunk not loaded" is its normal and near-permanent state — and the deferral
was logged every ten minutes for as long as the queue was non-empty. Same for
"no blueprint for this slot yet", which is true forever of a slot that missed
its one capture window. Both are now silent and anything else still logs,
because a message that fires when nothing is wrong is how a log becomes
something nobody reads and the one that matters gets lost in it.

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

**And behind both of those sits the player, who is the only one who remembers
where the visit started.** `Transit.entranceOf` reads a position out of
**player** modData, written on the way in and cleared on the way out, and
`resolveReturn` falls back to it when everything about the holder has come back
empty.

It is a **different fact**, not a third copy of the same one. The two ahead of
it describe where the *holder* is, and the tracker exists precisely because a
van moves; this one says where *this visit* began. So it sorts last, always: a
tenant whose friend drove the van into the next town comes out at the van, and
putting them back on the kerb it left from would be the exact failure the
tracker was built to prevent.

**It is per player because it cannot be anything else.** A room holds one lease
and any number of occupants — `Core.occupants` is keyed by player and
`isOccupied` only asks whether anyone at all points at the holder — so four
people who walked in from four places have four answers and the lease has one
field. That is not a shortage of bookkeeping: the fact is per visit, and there
is no value of it a lease could carry. It is also the reason a community hub
room needs no new registry surface, and the reason the `admin:<username>`
lease — the one lease in the system keyed by a player — is not the pattern to
copy for one.

**Player modData, and the asymmetry with the vehicle row below is the point.**
`IsoPlayer.save` reaches `IsoMovingObject.save`, which writes the modData
`KahluaTable` into the character record, so this survives a restart, a reclaim,
and the loss of `global_mod_data.bin` — none of which a vehicle's modData
survives, and it is not even transmitted.

Surviving our own store is what earns the second use. `Transit.rescueStranded`
runs on `playerSetup` when `Transit.recover` finds no lease covering a player
who is standing in a registered slot: their room was reclaimed while they were
logged off, or released out from under them, and with no occupancy there is no
leash, no exit option and no containment. Before this they were simply stuck —
`Transit.leave` refused with `VehicleGone` and an admin had to evict them.

**It is the one return position that can be genuinely stale**, so it is the one
that is validated. The others describe a holder that cannot have moved; this is
wherever somebody stood, possibly months ago. `getMetaGrid():isValidSquare` is
the strongest check available with the destination chunk unloaded, and it is
the same one `placeInside` makes. It cannot catch a wall built there since, and
nothing server side can — which is the accepted cost of the alternative being a
player who cannot leave at all.

**Written and cleared by `Transit.setOccupancy` and nothing else**, for the
reason that function is already the only writer of `Core.occupants`. The
invariant is "an entrance exists precisely while an occupancy does", and the
asymmetry between its two branches is load bearing: clearing is unconditional,
but *setting* happens only when the occupancy carries an `enteredFrom`. That is
because `Transit.recover` sets an occupancy for a player standing **inside** the
room — reading their position there would store the interior square as the
place to escape to, and the fallback would teleport them back into the room
they were trying to leave. `placeInside` captures it, which is one site rather
than three and also covers the fourth caller: a cab exit that bounces off a
full vehicle re-enters from beside it, which is a true new entrance.

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

**A room is a contract, and a set of stamps of it.** `registerRoom` takes the
shape (`size`, `spawn`, `front`, `cab`, `generator`, `selfPowered`,
`reservoir`, `baseWeight`) once, and a
`locations` table saying every place on the map it is stamped. Two rooms whose
*contract* differs are two registrations — the shipped map has two because one
cell is roofed with a solid north wall and the other is open with a double
door.

**What a room deliberately does not fix is what is on the squares.** Wallpaper,
carpet, overlays, fittings — those are captured in game, per slot, on first
lease, so a map author can decorate the stamps differently and each is restored
to what they actually built there. Opinionated about the shape, indifferent to
the decor.

That is a deliberate reversal. Blueprints were per room for a while, on the
reasoning that a room is one design so a stamp that came out wrong should be
*repaired* rather than preserved. True, and worth very little here:
containment is the leash and not the walls, so a mis-stamped room is cosmetic.
The price was that every stamp had to look identical, and the only functional
thing a blueprint restores is the light switch.

It also stopped the shipped blueprint being load bearing, which removed a
silent trap: repaint a room in the editor, forget to re-export, and the first
scrub quietly undid the repaint.

**Where a room is, is data — not arithmetic.** `locations` is keyed by index,
with `{x, y, z}` or `{x = , y = , z = }` entries. `origin` + `pitch` + `count`
is gone; a genuinely uniform grid is three lines of `for` loop in the caller,
and `defaults.lua` has that helper.

The arithmetic was not merely limiting, it was actively wrong: it forced the
map to fit an arithmetic series, and the first two cells that were built came
out on grids 21 and 22 apart with a 35 tile gap between them — a layout the
old `origin + pitch * index` could not describe at all. A map gets laid out to
suit the map.

The slot **index** is the identity and is what a lease persists. Appending is
safe; renumbering re-points every lease after the change at somebody else's
room. **A deleted location must leave a gap**, and `normaliseLocations`
collects keys with `pairs` and sorts them so that it can. It used to count up
from zero until it found a nil, which meant deleting location 12 of 50 silently
deleted 13..49 as well, `count` reported 11, and the room quietly shrank with
no warning anywhere — the reference mod's pool exhaustion reached from a third
direction. `Tests/lua/registry_spec.lua` covers exactly that.

**And when `defaults.lua` is generated, the index must be derived from the map,
not from the spreadsheet.** Decided: `(chunk x, chunk y, row, position in
row)`, with ten stamps per row. Never the order rows happen to appear in a CSV
or a sheet, because inserting a line — which is a thing somebody will do — then
silently renumbers every slot below it and re-points every lease after the
change at somebody else's room. A map coordinate is stable under editing; a row
number is not. This is the same failure the grid move already caused once, when
a row added at the *north* end shifted every index after it; it cost nothing
then only because nothing had shipped.

Two consequences. `Core.slotOrigin` is a lookup, so a stale index yields nil
rather than a plausible-looking box in the middle of nowhere — every geometry
helper returns nil for a missing slot and `Slots.acquire` is what notices and
releases the lease. And `Core.slotAt` cannot recover the index by dividing by
the pitch, so slots are bucketed by 64 squares at registration; it runs on the
leash at 4Hz and on every guarded destroy action, so it could not become a
linear scan.

**A binding says which vehicles may lease which rooms, and it names game
scripts — not ids of ours.** `registerVehicles{scripts = {...}, rooms = {...}}`,
one direction only.

The link used to be declarable from either end and unioned, on the reasoning
that whoever ships second is the only party who knows both ids. Binding by
script name dissolves that problem instead of solving it: a map pack writes
`{scripts = {"Base.StepVan"}, rooms = {"theirmod.vanrooms"}}` and a car mod
writes `{scripts = {"TheirVan"}, rooms = {"phun.van.roofed"}}`. Both know a
vanilla script name without having to ask anybody, and neither needs an id of
the other's. So the second direction earns nothing and is gone.

Bindings are keyed by id, so re-registering your own replaces it. What is never
replaced is somebody else's: the script → rooms answer is **unioned** across
every binding when the index is built, so a map pack naming `Base.StepVan` adds
its rooms to the ones our binding already offers rather than taking the vehicle
over. `id` is optional and exists so the sandbox script-override option has
something to name.

A binding may also carry `match`, a predicate that only ever **adds** to its
script list — it beats maintaining every StepVan livery in the game, at the
cost of claiming modded ones sight unseen. The room's own `requires` used to
filter those back out; that field no longer exists, so a predicate is now the
only thing between a modded van and a room and should be written tightly.

**We no longer use one ourselves, and the reason is measured rather than
stylistic.** `phun.van` matched `^Van` or `^StepVan` with a `NOT_VANS`
blocklist, and once every vehicle was listed explicitly in the master sheet the
two could be compared. Over the 140 listed vehicles the matcher's answer
differs from the authored one on about ten, **in both directions**: it misses
`63Type2Van` (a van whose name starts with "63"), `87fordF700bank`/`box`,
`90fordF350ambulance` and the two SWAT trucks; it wrongly claims `VanCattle`,
which belongs to a semi-trailer room, and `VanMetalworker`/`VanCarpenter`,
which is the entire reason `NOT_VANS` exists. A rule that is wrong 7% of the
time where it can be checked is not a safety net.

So the overflow is authored per room instead — the `fallback` column in
`Docs/pi-assigned.csv`, which generates an ordinary extra binding and lets
specificity do the ordering exactly as before. Dropping the matcher costs
**one** binding among the listed vehicles, and that one was already suspect.

What it does cost is vehicles nobody has listed: a modded van now gets no room
rather than the shed, refused with `IGUI_PhunInteriors_WrongVehicle`. That is
accepted, because the supported path already exists and `Slots.acquire` names
the missing set at the point of refusal, so it diagnoses itself. Note also that
`requires = {trunk = true}` stopped doubling as a filter for over-claiming — it
was what quietly refused the `StepVan*Smashed*` wrecks the matcher grabbed, and
losing that last real user is why the field was removed outright.

`match` stays in the registry API, and so does the rule that a room reached
through one sorts **last**. Both are for third parties; we simply do not use
them.

**A room states nothing about what may carry it, and `requires` is gone.**
A room could once declare demands on the vehicle leasing it — `trunk`, whether
there was cargo space to put the room in, and `battery`, whether there was
charge — tested per candidate inside `Slots.acquire` by `Core.roomAllows`. The
field, the function, both refusal messages and the "every room refused you"
branch in allocation have all been removed.

**It was removed because nothing used it.** Across the whole shipped map not
one room declared either flag, and the only job `requires` ever did beyond
documentation was refuse the `StepVan*Smashed*` wrecks the `phun.van` **matcher**
over-claimed — and the matcher went when every vehicle was listed explicitly.
A feature whose last real user was deleted is not a safety net; it is a thing
that still has to be understood.

**And it was a category error that had already cost a session.** It is a
*vehicle* vocabulary, asked during allocation, which is holder agnostic. Put
"have you a trunk" to a tent and it cannot answer, and answering "no" is wrong
in a way that is hard to see: the demand is *inapplicable*, not unmet. That is
not hypothetical — **every room on the shipped map once declared
`requires = {trunk = true}`**, so there was no room anywhere a tent could be
given, and the refusal arrived as "this vehicle has no interior" about a tent.
It was patched by confining the vocabulary to vehicles; deleting it removes the
class of bug instead. The general lesson is the one `generator` taught from the
other end: a demand asked of something that cannot answer it does not fail
loudly, it fails *plausibly*.

**Which holder may lease which room is the binding's answer, and always was.**
`Core.roomsForVehicle` walks only bindings made by `registerVehicles` and
`Core.roomsForObject` only those made by `registerObjects`, so by the time
allocation runs, a candidate has already been named by a binding of this
holder's own kind. That is why nothing replaces `requires`: the question it
answered was already answered upstream, and a room-side field was a second
place to state one fact — the `powered`/`power` trap again, and the two could
disagree.

If a room ever does need to refuse a holder on a fact about the holder, the
lesson from this one is to put it on the **binding**, which knows what kind of
thing it is naming, rather than on the room, which does not.

A def still carrying `requires` is **ignored rather than refused**, so an old
third party room set loads unchanged. `registry_spec.lua` checks that, because
"silently ignored" and "silently breaks the room" look identical from outside.

`Transit.canEnter` only ever asked whether the vehicle has rooms *at all*, and
that is unchanged.

So a community room or a spawn room needs no new registry surface at all:
register the room, then `registerVehicles` or `registerObjects` to say what
reaches it. `registry_spec.lua` proves the kinds cannot cross.

**Allocation drains the most specialised room first**, where specificity is how
many distinct **scripts** can reach it. Without that ordering the pool starves
in a way that reads as a bug: if room A is reachable by vans and pickups and
room B only by vans, first-fit hands vans slots out of A, A fills, and pickups
— which have nowhere else to go — are refused while B sits empty. General
purpose capacity has to be saved for the vehicles with no alternative.

Scripts, not bindings, and the difference is not academic — it was a test
failure. One binding naming two scripts makes its rooms reachable by two
vehicles, which is exactly the generality being measured, and counting the
binding as one hides it. Two rooms then tie, fall through to the id tiebreak,
and the starvation is back.

A room reachable through a `match` predicate is weighted to sort **last**.
That is not a fudge around an uncountable set — it is the right answer, because
anything at all might claim that room, so it is the worst possible place to put
a vehicle that had somewhere else to go.

Ties break on room id so the same save allocates the same way twice.

Within a room it is clean slots then quarantined ones, and deliberately not
every clean slot across every room before any quarantined one — that reaches
into the general purpose rooms while the specialised ones still have slots
free, which is the same starvation arrived at from the other side.

**Third party mods register in two phases**, `OnRegisterRooms` then
`OnRegisterVehicles`, with `OnReady` after both. Events rather than an "is
PhunInteriors loaded" test on their side: if the mod is absent they never fire
and the registration never runs.

The split is a **convention, not a constraint** — registering anything on any
of the three works, because the reverse indexes rebuild on the first read after
any registration. What it buys is a point at which the rooms are known to
be complete, and that is the only way to tell "that set has not registered yet"
from "the mod that owns it is not installed". Before the split those were the
same silence; `Core.unresolvedFor` now separates them, and `Slots.acquire`
names the missing set when a vehicle is refused a room.

Both fire from `Core.openRegistration`, on `OnInitGlobalModData` server side
and the first `OnTick` client side — long after every mod's lua has loaded, so
every listener that will ever be attached already is. It is guarded, because in
SP both `server_events` and `client_events` run the boot sequence and without
the guard every handler runs twice.

**The load order trap is not about when we fire — it is about whether the
author's `.Add` line can run at all.** Those are two different moments and it
is easy to conflate them:

1. *File load time*: their file executes `Events["PhunInteriorsOnRegisterRooms"].Add(fn)`.
2. *Fire time*: we `triggerEvent`. This is genuinely order-independent.

`Events` is a plain Kahlua table with no metatable —
`LuaEventManager.AddEvent` ends with `LuaManager.env.rawget("Events")` then
`event.register(...)`, so a key exists only once `AddEvent` has been called for
it. If a third party's file loads before our `core.lua`, `Events[ours]` is nil
at step 1 and their `.Add` throws. Firing later cannot rescue a listener that
was never attached.

**So the advice to give a third party is to hook a vanilla event, not one of
ours**, and register from inside it:

```lua
Events.OnInitGlobalModData.Add(function()
    if not PhunInteriors then return end     -- definitive by now
    PhunInteriors.registerRoom("theirmod.vanrooms", {
        size = {w = 5, h = 15},
        locations = {[0] = {22538, 11779, 0}},
        generator = {x = 0, y = 17, z = 0},  -- omit for a room with no power
    })
    PhunInteriors.registerVehicles({
        scripts = {"Base.StepVan"},          -- a vanilla script name, so no
        rooms = {"theirmod.vanrooms"},       -- id of ours has to be looked up
    })
end)
```

Every property falls out of that. `Events.OnInitGlobalModData` always exists,
so their position in the load order cannot break the `.Add`. By the time it
fires, all lua has loaded, so `PhunInteriors` either exists or genuinely is not
installed — the nil check is decisive rather than a race. No hard dependency,
no event declaration, and it works identically for rooms and for vehicles.

**It must be `OnInitGlobalModData`, not `OnGameStart`.** Settled from the jar:
`OnGameStart` is triggered only from `zombie.gameStates.IngameState`, which a
dedicated server does not have, so a room pack hooking it would register on
every client and never on the server — where `Transit`, `Slots` and `Leash`
actually read the registry. `OnInitGlobalModData` comes from
`zombie.world.moddata.GlobalModData` and fires everywhere; this mod already
boots off it server side, proven on a real dedicated server.

Registering that way can land *after* our own events have fired, and that is
fine — the indexes rebuild on first read, and a binding that names a room
registered later resolves the moment it arrives. There is a test for exactly
that, so nobody later mistakes the phase order for something correctness
depends on.

The consequence is that **nothing may warn about a missing link at boot**,
because at boot it cannot know whether the set is absent or merely late.
`Slots.acquire` says it at the point of refusal instead, where the answer is
always current and where somebody is actually asking. `Core.describeRegistry`
logs counts at boot, which are always true.

Our own two events remain, and are what `defaults.lua` and generated blueprint
files use. They are worth keeping for the phase ordering and because they read
better in a generated file, but an author who declares one himself
(`LuaEventManager.AddEvent` is idempotent — its first act is
`EventMap.get(name)` — and it is vanilla's own idiom at `forageClient.lua:47`)
gets the same result. Both routes are supported; the vanilla hook is the one to
put in the author docs, because it is the one nobody can get wrong.

What does *not* work is `if PhunInteriors then ... end` at **file scope**: it
works standalone but fails silently when their file loads first. The nil check
belongs inside the deferred handler, not around it.

Note that link resolution never needed the ordering: a class may name a set
that registers later, because links are unioned when the index is built rather
than when the call is made. The phases are for diagnostics and for readability,
not for correctness.

**More rooms means a new room, never a re-registration.** There is no append —
`registerRoom` with an existing id replaces it, and an author "adding" rooms to
`phun.van.roofed` that way would delete the stock ones out from under live
leases. Their own id plus a binding is the supported path, and it keeps their
blueprint with their room.

Rooms of equal specificity are separated by an optional **`priority`**, lower
drained first, then by room id for determinism. That field was speculative
until the real map arrived and immediately needed it: two rooms reachable by
exactly the same scripts, one of them unlit, and the id tiebreak alone would
have given the first fifty tenants a dark room because `phun.van.plain` sorts
before `phun.van.roofed`. Priority is only a preference and sits **below**
specificity in the sort, because specificity is what prevents starvation and a
preference must never be able to reintroduce it.

**There is no golden slot.** Slot 0 is leasable like any other. It used to be
reserved as a pristine copy to scan blueprints from, which cost a room of map
per set and only worked when somebody happened to be standing near it; it
failed nearly every capture it attempted. Capture rides the leash now — "the
leash can see this player inside this room" is exactly the condition a capture
needs, so it runs with the chunk provably loaded.

**Sibling borrowing is back, but only as a last resort.** `Manifest.forSlot`
resolves in this order:

| | source |
|---|---|
| 1 | this slot's own capture — what the author built *here* |
| 2 | a shipped room-level blueprint, if the author registered one |
| 3 | any other slot of the same room |

The order is the whole point. Shipped used to win, which meant a per-slot
capture could never mean anything and every stamp was flattened to one decor.
The slot's own observation is the most specific truth available, so it wins,
and tier 2 sets a floor rather than a ceiling.

Tier 3 homogenises — it restores this slot to look like a different one — so it
is genuinely last, and `Scrub.slot` logs which source it used because a scrub
about to overwrite somebody's paintwork should not do it silently. It exists
because the alternative is worse: a slot with no blueprint can never be
scrubbed at all, so it accumulates every tenant's leavings forever. It only
fires for a slot that missed its one capture window.

An empty scan means the chunk was not loaded, not that the room is
empty, and caching that would poison every future scrub, which is why it refuses to.

Stored as `version = 2`: a `palette` of distinct sprite names plus per square
lists of indices into it. Measured on the borrowed van room: 29 objects, 11
distinct sprites, 379 bytes against 699 without the palette. The shipped rooms
are denser — about 42 placements from 14 sprites, so ~500 bytes a slot — which
puts 120 slots at roughly 60KB unpooled and 30KB with the palette shared per
room. Small either way; manifest size was never the constraint it was assumed
to be, and the pooling is worth having because it is the *duplication* that
grows with the slot count, not the content.
`Manifest.spritesAt` resolves either format; v1 stored names inline and is
read, not migrated. `PhunInteriors.admin("manifests")` reports the real
figures, and reports the pooled palette once per room rather than folding it
into every slot — otherwise it would report exactly the duplication the
pooling exists to avoid.

**A manifest holds exactly what a scrub removes.** `Manifest.isStructural` and
`Scrub.clearSquare` must agree object for object, or a scrub either loses the
floor or stacks a second one on every pass. Both now identify the floor by
identity against `square:getFloor()`.

Capture is per **slot**, taken the first time that slot is leased, when it is
pristine by definition. `Slots.markUsed` is what makes that trustworthy: a slot
only ever gets one capture attempt window, because after a tenant it is no
longer evidence of anything. The leash drives it and gives up after
`Manifest.CAPTURE_ATTEMPTS` ticks, after which that slot falls through to a
sibling for the rest of the save.

The capture sits **above** every early return in `Leash.checkOne`, including
the noclip exemption and the arrival grace. Capture is not containment: it
only cares that the player is standing in the room. Placed under the exemption
it captured nothing at all, because an admin testing with noclip on is the
normal case.

The leash gates on `Manifest.hasCapture(room, index)` and deliberately **not**
on whether `forSlot` resolves — resolution falls through to a sibling, so
gating on it would mean the first slot to capture froze the whole room at its
decor and no other stamp ever recorded its own.

**Only the room's own level has to read completely.** `scan` sweeps
`bounds.z` to `bounds.z + 1` so a roof is captured too, but a nil square
*above* the room is empty air rather than a chunk that failed to load, and
counting it as missing made capture impossible on this map: an unroofed room
has no z=1 squares at all, and a roofed one has six — its 2x3 floor — against
a 3x4 footprint, so the wall column and row come back nil either way. Every
capture refused, on every attempt, silently, and the slot's one window closed
with nothing in it. The strictness is still right for the room's own level,
where a nil square really does mean the chunk is not there.

**The palette is pooled per room, the squares are per slot.**

```lua
data.roomManifests[roomId] = {
    version = 2,
    palette = {"walls_garage_01_36", "lighting_indoor_01_1", ...},
    slots   = {[7] = {["0,0,0"] = {1, 2}}}
}
```

Sprite names are long — `overlay_grime_wall_01_16` is 24 characters — and a
room's fourteen or so of them are over half of each manifest. Stored per slot
that is the same list 120 times, tens of KB of pure repetition, and repetition
precisely because the stamps are near identical. Pooled, a slot with different
wallpaper adds an entry or two rather than a whole second copy: measured on the
shipped rooms that is roughly 30KB total against 60KB unpooled. Each scan
builds its own local palette, so `pool` remaps every index onto the room's as
it folds a capture in.

**Blueprints are captured, not authored.** `PhunInteriors.author(action, args)`
builds a room from where an admin is standing — corners, spawn, exits and the
generator are all read from the player position — and emits a lua file that
calls `registerRoom` and `registerVehicles`. That file goes in
`server/PhunInteriors/blueprints/` and loads itself. That folder is not
shipped: create it when you have something to put in it.

This used to say there is no file reading at runtime anywhere in this design
and no json. That stopped being true when the admin editor learned to save —
see "An edit is a patch" below. The blueprint path is unchanged: what `author`
emits is still lua, loaded by the game as a mod file at boot, and nothing reads
it back at runtime.

It no longer emits `registerBlueprint`, and that changes what the tool is for.
What it writes is the **contract**, all of which is now plainly hand-writable —
which inverts the old argument that generating all three calls was right
*because* the blueprint could not be hand written. The tool is a convenience
for reading coordinates off your feet rather than the only way to ship a room.
`author('sweep')` is kept as a check that a room reads cleanly before you ship
it, not as a prerequisite for emitting.

Locations are written in sorted index order so re-exporting an unchanged map
produces an identical file — otherwise every export is a full diff and the file
stops being reviewable, which is half the reason for emitting lua rather than a
blob.

**The admin room list ports you in, and it ports you in the ordinary way.**
`client/PhunInteriors/ui/shell.lua` is a window over `admin("rooms")`, opened
from the admin panel, the debug menu, or `PhunInteriors.roomList()`. Three
tabs — Rooms, Slots, Bindings. It names every registered room, its contract,
which scripts and items can reach it, how many of its slots are free, and per
slot whether that stamp has ever captured its own decor. Select a room, press
Enter, and you are standing in it.

`client_rooms.lua` used to *be* that window, hand drawn, with rooms in the top
third and slots below. It is three lines in front of the shell now, and the
map forced the move rather than taste: that layout was right for 2 rooms of 60
slots and is wrong for 81 rooms of about 12, so the rooms became the long list
and a room's stamps became a detour off one. The payload followed the same
shape — it carried every slot of every room on every refresh, which was 120
records and is 960, all but one room's worth of it drawn by nothing. Slots are
fetched per room now (`Core.commands.roomSlots`).

**The Slots tab has its own two dropdowns**, because reaching it otherwise
means going back to Rooms, finding the row again and pressing Slots — most of
the work when the job is walking a set of stamps one room at a time. They
*narrow*: the vehicle picker decides which rooms the room picker offers, and
the room picker decides whose slots are drawn. That is deliberately a different
question from the filter box at the bottom of the same panel, which searches
*within* the slots on screen; two controls both labelled "filter" meaning
different things would be worse than either. The vehicle one earns its place on
this map specifically — 81 rooms, most reachable by exactly one script, so
"which room does the mail van get" is otherwise a scroll through ids that do
not mention the van.

Both routes in end at `showRoom`, which re-selects the picker rather than
assuming it is right, so the dropdown always names the room on screen. And
`refresh` rebuilds the pickers *and* re-fetches, because a fresh room list
clears every cached slot payload — `State.receive` does that on purpose, since
slot states are exactly what a refresh is likely to have changed.

That needed one addition to the vendored list panel: `layoutHeaderRow(y, width)`,
an optional hook between the description and the list, four lines and marked as
ours. The existing `_filterTabs` row sits in that position and could not be
used — it is a row of toggles over a fixed handful of values, not a dropdown
over eighty rooms.

The name `Client.openRooms` is kept, because `client_admin.lua`, the debug menu
entry and `PhunInteriors.roomList()` all call it, and renaming a function to
say "shell" instead of "rooms" is churn in three files to describe the same act
of opening one window.

What it deliberately does **not** do is invent a second way of being inside a
room. `Transit.adminEnter` takes a real lease, writes a real occupancy, and the
leash really watches — so the capture fires, a quarantined slot is scrubbed on
arrival, and the generator is fed, exactly as they would be for a tenant. A
room that behaves differently when an admin is in it is a room nobody has
tested. The lease key is `admin:<username>` rather than a vehicle UUID, which
is the only thing that differs, and three places read it: `resolveReturn`
returns the square the admin was standing on rather than sweeping for a vehicle
that was never there, the exit files no arrival paperwork (there is nothing to
weigh and nothing to re-seat into, and the handshake would have ended in a
false "your vehicle is gone"), and the ledger is told the battery is full so the
lights come on.

That last one is the one worth remembering: `fuelOwed` is reset on every port,
because nothing ever settles that debt — there is no battery to take it off —
and left to accumulate it would eventually send the projected charge negative
and darken the room a designer is standing in for no reason they could see.

It exists because entering through the front door is not merely tedious for a
room low in the specificity order, it is impossible: allocation drains the most
specialised room first, so a general purpose room can only be reached by
filling the specialised one first. `Slots.acquireIn` is therefore deliberately
not a flag on `Slots.acquire` — it answers a different question, "the room I
pointed at", and none of the entitlement machinery applies to it. It will take
a quarantined slot and hand it back flagged dirty, which is what makes release
→ re-enter → watch it scrub a loop an admin can actually run.

**A claim also decides who may walk in, and that part is ours.** Nothing in
the engine keeps a player off a claimed square -- the whole enforcement surface
is `BaseVehicle.isExitBlocked2`, getting out of a seat onto one -- so a
teleport lands unopposed and a tenant simply stands in somebody's safehouse.
It does not self-correct into an eviction.

So `Slots.trespassOn` asks the second question, and the entry paths refuse on
it: `Transit.enter`, `enterObject` and `adminEnter` all check after allocation
-- `canEnter` runs before there is a slot to ask about -- and before
`Slots.touch`, because a refused entry must not renew the lease that the
reclaim measures. The lease itself is untouched: the claim is over the SLOT,
not over the vehicle's right to it, so whoever holds it is let back in the
moment the claim goes.

**There is no admin exemption written anywhere in this**, and that is the
point. Vanilla's `playerAllowed` is member OR owner OR the role capability
`CanGoInsideSafehouses`, so an admin is allowed here for exactly the reason
they are allowed into any other safehouse, and one without it removes the claim
through vanilla's own tools. Writing our own would repeat the tent pickup
guard's mistake: a guard that exempts admins cannot be tested by an admin, and
everybody who tests this mod is one.

It reads no square, so it answers with the room's chunk unloaded -- which it
always is at the moment somebody asks to go in. `Transit.recover` deliberately
does NOT check: somebody already standing inside should stay contained and walk
out, and refusing there would leave them uncontained in a stranger's safehouse.

**`Reset` is `Slots.release`** with the usual consequence: the slot goes to
quarantine and is scrubbed the next time it is handed out, not now.

Called Reset on the button and `release` on the wire, and the split is
deliberate: "release" is what happens to the LEASE, and "reset" is what happens
to the SLOT, which is the thing an admin is looking at. Release also reads as
handing back something the admin owns, which is the wrong relationship.

It refuses two things. A slot somebody is standing in, because pulling the
lease out from under a live occupancy leaves the leash ejecting them to
nowhere. And a slot somebody has **claimed as a safehouse** -- that was a hole,
found by asking rather than by it going wrong: every other path already
respects a claim (`Scrub.slot` refuses one, `isReclaimable` refuses one,
`Slots.acquire` skips one) and the admin reset did not, so it would have
dropped the lease and quarantined the slot, losing the owner the room they
claimed and scrubbing its contents the next time it was handed out. Guarded in
the ACTION rather than in `Slots.release`, because that call is also how a
vehicle moves between rooms and how `removal.lua` frees a scrapped wreck --
refusing there would leave a claimed slot leased to a vehicle that no longer
exists.

The slot list shows **how long since anybody was in, and who**, rather than the
holder id. That is what decides whether a slot is worth resetting, and it is
the same `lastSeen` measurement `Slots.isReclaimable` makes against
`RoomProtectedDays`, so the number on screen and the number that decides a
reclaim cannot disagree. The id is a 36 character UUID nobody can recognise and
960 of them would be most of the payload; `admin("list")` prints them.

**An edit is a patch, kept beside the registration rather than inside it.**
The registry is code, and `defaults.lua` is *generated* from three CSVs by
`Docs/gendefaults.pl` — so an edit written back into it is lost on the next
run, and an edit written anywhere else in the lua needs a redeploy and a
restart. Neither is a loop an admin can run while standing in the room being
fixed. So `shared/PhunInteriors/overrides.lua` keeps what changed in
`PhunInteriors.json`, in the game's Lua folder, beside `PhunMart_Shops.json`
and the rest of the family's override files.

Three states fall out of that, and the editor draws all three as a stripe down
the left of a row: **shipped** (registered by lua, no patch), **overridden**
(registered by lua, and patched), **new** (in the file and nowhere else).

**Sparse, and that is the design rather than a saving.** A patch naming only
what differs means a room whose shipped definition changes in a later version
picks the change up everywhere the admin had no opinion. A file holding whole
rooms would pin all of it: re-export the map, ship a new `front`, and the
admin's copy quietly keeps the old one on every room they ever opened,
including the fields they never looked at. `Core.setRoomOverride` diffs against
the snapshot and drops what matches, so opening a form and pressing Apply
without changing anything leaves no entry behind.

**Applying one re-runs `registerRoom`.** The tempting version writes the fields
straight onto `Core.rooms[id]`, and that is wrong for `locations`: the built
room carries `slots`, `indices` and `count` derived from them, so a patch
writing locations alone leaves three derived fields describing the old set.
Re-registering from a merged definition gets all of that from the code that
owns the arithmetic, gets the validation and warnings free, and cannot drift
from what a boot-time registration produces — because it *is* one. That is what
`Core.roomDefs` is for: the raw definition as first registered, deep copied
before anything is applied, and what revert rebuilds from.

The copy has to be **deep**. A shallow one shares `spawn` and every `locations`
entry with whatever the author passed, so the thing revert restores from tracks
later edits — and revert then appears to work and changes nothing.

**A deleted stamp leaves a gap, and the file can say so.** `locations` is
patched entry by entry, and `false` is a tombstone. Closing the gap up would
renumber every slot after it and re-point every lease beyond the change at
somebody else's room, which is the failure `normaliseLocations` sorts `pairs`
keys to prevent. Over the wire it is `removeSlots = {3}` rather than the
tombstone, folded into one immediately on arrival: a table value of `false` has
to survive PZ's command serialisation, and one that arrived as nil would read
as "this patch mentions no such slot", delete nothing, and report success.

**`clear` is how a patch says a field goes back to nothing**, because JSON null
cannot. The parser returns nil for null and a nil value in a Lua table is an
absent key, so "no front" and "no opinion about the front" would be the same
thing on the way in. It matters most for `generator` and `front`, the two
fields whose whole contract is that nil means something — without it an admin
could add a generator to a room and never take it away again.

**A room registered late still gets its patch**, because `registerRoom` applies
one at the end. Not a pass after boot: registration is never complete — a third
party is free to register from any vanilla hook, which can land long after our
sequence — and a room that turned up late would be the one room the admin's
edits silently did not reach. Same reasoning as the lazy index rebuild.

**Bindings are replaced whole, not patched.** A binding is two lists, and
"patch a list" has no good meaning: an entry removed by omission and a list not
mentioned look identical. The registry replaces too, so whole is what the
underlying call does. Deleting one that lua registered lasts until the next
boot, and deliberately so — a tombstone the loader honoured would be a file
that can permanently disable another mod's binding.

**Nothing autosaves.** An edit applies to the live registry immediately,
because standing in the room you just changed is the loop the window exists
for, but it reaches the file only when somebody presses Save. A mistake still
in memory is undone by Revert or by a restart; a mistake already on disk has to
be undone by hand.

The cost of that is a way to lose work silently — an edit is live, so the room
*looks* changed right up until the server restarts and every unsaved patch is
gone. So closing the window with anything unwritten prompts, and Save is the
one green button in the row. Neither is decoration: nothing else in the window
would have told them.

**A form takes the FORM, not a values table.** `FormPanel` calls
`self._onApply(self)`, and writing the handler as though it received values is
the mistake that reads as a data bug — every field fetched that way comes back
nil, so the patch silently drops them while any field read through
`form:getFieldValue` goes through fine. It presented as "changing a room's
label does not persist", `label` being the field somebody tries first; `front`,
`cab`, `selfPowered` and `reservoir` were going the same way and the numeric
fields were not. The caller also closes the form, which is why Apply shuts it.

**The file is written to be read.** Sorted keys, two-space indentation, so an
admin can diff one save against the next and put it in git — which is most of
why it is a file rather than a blob in GlobalModData. Sorting also means
re-saving an unchanged registry produces an identical file; without it `pairs()`
order decides the layout and every save is a full diff, the same failure
`Author.emit` sorts its locations to avoid.

**A file that cannot be read is reported and ignored, never fatal**, and one
bad line drops only itself. A server that will not start because of a stray
comma in a customisation file is worse than one that starts stock and says so;
a whole file refused for one typo loses every other customisation in it.

**The UI panels are vendored from PhunMart2**, not depended on:
`ui/form_panel.lua` and `ui/list_panel.lua` came across near verbatim, with
`ui/ui_utils.lua` trimmed to the generic slice. It cost far less than it looked
— the two files reach for four font constants and `wrapText` and nothing of
PhunMart's own vocabulary. The list panel brings the filter box, the sortable
columns and the three-state stripe, which is why it was worth copying rather
than rewriting: those states are exactly the ones the override layer produces.
The trade is a fork that has to be maintained by hand, and the reason it was
taken is that an admin running several Phun mods should not have to learn a
second kind of form to do the same job. `ui/state.lua` supplies the two hooks
the list panel asks for and stubs the cross-reference feature off.

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

**Its position is fixed data and does not move.** `room.generator` is an offset
from the slot origin, captured by the authoring tool and emitted into the
blueprint. Two things it must satisfy, and both are the map author's problem
rather than the code's: every tile of the room within `GeneratorTileRange` of
it, and the square **exterior** (roomID -1), because vanilla only makes a
building toxic for a generator on a non-exterior square.

The shipped map puts it at `{x = 1, y = 17, z = 0}` — a square east of the
room's west edge, 17 south, at ground level. The far corner of the room is
`sqrt(2² + 17²)` = 17.1 away, inside the radius of 20, and it is far outside
the slot bounds so the leash keeps tenants away from it.

**It sits in a sealed, lidded 1x1 box, and every part of that is load
bearing.** The square is painted with the `emptyoutside` preset rather than a
real room, so `setRoomID` never runs on it — four explicit wall objects ring
it, because BuildingEd only auto-rings a *room* — and its ceiling is
`phuninteriors_01_1`, the unused solid-black twin of the ground tile. Walls
keep zombies off it, and the black lid hides it from anyone standing between
the stamps.

That lid costs the square its `exterior` flag, because `IsoChunk` strips the
flag from anything under a `solidfloor`, and **that is accepted rather than
overlooked**. `IsoGenerator.setActivated` is
`if (!square.has(exterior)) if (square.getBuilding() != null) setToxic(true)` —
so the building it can poison is the 1x1's own, seventeen tiles from the room
and not adjacent to it, and nobody can path into a sealed 1x1 to breathe it.

**Power is unaffected, which is the part worth checking before copying this.**
`haveElectricity()`'s early `false` for an exterior square tests the square
being *asked*, and a room square always carries a room id so it is never
exterior. `setSurroundingElectricity` reads `allowExteriorGenerator` only to
skip **appliances** standing on exterior squares — it never tests the
generator's own square. `power.lua` asserts nothing about either flag.

**It used to be at z=1, on the roof of that box**, which was then a real
`empty` room because a room is what writes a ceiling and the ceiling is what
the generator stood on. That was changed because a generator at z=1 is one
level above the only thing that could hide it: the shell's south wall is
directly between the tenant and the generator, but it is a z=0 wall, so a z=1
object beyond it draws over the top and every generator on the block is visible
from open ground. Raising the shell to z=1 fixes that and is **not** the answer
— see the z=1 course under "Known gaps". Dropping the generator to the wall's
own level is.

**Nil means no generator, and there is deliberately no default.** A tent says
nothing here and gets nothing conjured for it — which is what the old
`powered = false` flag was for, two fields to say one thing, and the *other*
one was the trap. `power` used to default to `{x = 0, y = 0, z = 1}`, and
carrying that onto the real map cost a debugging session:
`Power.ensureGenerator` looked one level above the room, found nothing, and
conjured a generator on the roof of every room while fifty perfectly good ones
sat 17 tiles south. The symptom read as "why are we creating generators at
all".

The lesson generalises past this field: **a wrong position fails silently and
self-heals into something that looks deliberate**, so the only safe default is
none. Unlike `size` and `spawn`, which fail visibly, a defaulted `power` was
never distinguishable from a chosen one. `Core.slotPower` now returns nil for a
room with no generator and every caller reads that as "no power here" rather
than "look somewhere sensible instead".

**Who pays for the fuel follows the lease kind, and needs no field.** A vehicle
pays out of its battery; a world object out of a generator its owner parked
nearby; a player-keyed lease — an admin port, a spawn room — pays nothing,
because there is nothing to charge. That last path is already proven in game:
`fuelOwed` is reset on every admin port precisely because nothing will ever
settle it, and left to accumulate it would send the projected charge negative
and darken a room for no reason a designer could see.

**`selfPowered` is the one case that derivation cannot reach** — a room you
*drive* to and still want lit for free. It suppresses the ledger only: the room
still needs a real `generator` offset, because `haveElectricity()` reads no
field and is only ever `chunk:isGeneratorPoweringSquare`. `registerRoom` warns
for `selfPowered` with no generator, since that room is simply dark and nothing
downstream can tell it from one meant to be.

Deliberately **not** called `powered`. That name is taken — the admin payload
field meaning `room.generator ~= nil`, on screen in the room list as "powered" /
"no generator". One word meaning both "has a generator" and "has a free one" is
how a reader ends up confidently wrong.

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

`setActivated(true)` does everything else itself: registers the position with
the chunk, calls `setSurroundingElectricity`, syncs to clients.

**Almost none of the arithmetic is ours.** `IsoGenerator.update()` burns
`totalPowerUsing * generatorFuelConsumption` for every world hour since its
`lastHour`, and `totalPowerUsing` is accumulated by `setSurroundingElectricity`
from the objects actually in range. An empty room draws nothing and burns
nothing; put a fridge in and it burns. `lastHour` is compared against world age
rather than ticked, so the burn **catches up for time the chunk spent
unloaded** — two days away costs two days of fuel the moment the room reloads.

**Which is why the tank is a buffer, not a fuel gauge.** Sizing it to the
battery does not survive that catch-up: half a battery buys half a tank, and
returning after a couple of days empties it while the van outside is perfectly
healthy, losing the tenant a fridge of food for a reason they cannot see. So it
is topped to *full* whenever there is any charge to draw on, and the **battery**
is the limiting resource. Battery alive, generator golden; battery flat, dark
room. Running dry with charge left needs an absence long enough to burn a whole
tank, which reads honestly as having been away too long.

**The two halves are never loaded together**, so a ledger on the lease carries
the debt between them: `fuelOwed`, `fuelLast`, `batteryKnown`. The room banks
what burned and tops the tank up if `projectedCharge` — known charge minus
outstanding debt — is still positive, which is how it decides without being
able to read the battery. The vehicle settles the debt when it can.

Nothing is periodic. The room half rides the leash, already the hook meaning
"chunk loaded, tenant standing in it". The vehicle half rides entry, the
arrival report, **and every position push from the tracker** — free, because a
push only ever happens when somebody is driving a leased vehicle, which is
exactly when it is loaded. RV Interior sweeps `getCell():getVehicles()` hourly
for the same job, and that sweep is dead on B42 for the usual reason.

Weight is measured at the same two moments and for the same reason: the room is
loaded on the way out because the player is standing in it, the vehicle is not,
so it rides the arrival report.

**A rain reservoir is barrels on the roof, placed from a kit, and wiped by the
scrub like anything else a tenant brought in.** `PhunInteriors.RainReservoirKit`
is a real item -- craftable at Woodwork 5, a 0.01 weight in `CrateCarpentry`
and `CrateFarming`, and nameable by PhunMart. Installing it puts vanilla's
`RainCollectorRound` on the roof with `square:addWorkstationEntity`, the call
vanilla's own lid toggle makes, and consumes the kit server side.

*Enough to cover the floor, not one per square*, because vanilla plumbing
(`IsoObject.FindExternalWaterSource`) searches the 3x3 around the square
directly above a fixture, one level up and nowhere else. A barrel on every
third square reaches the whole floor: two for a 3x4, five for a 3x13, where one
per square was thirty-nine at 600 units apiece from one item.
`Core.reservoirSpots` is that arithmetic, over the *floor* rather than the
footprint, and `Tests/lua/reservoir_spec.lua` checks coverage per size.

*On by default*, opted out with `reservoir = false` on the room. That breaks
the "no default" rule `generator` follows, deliberately: that rule is about
positions, and nothing here is one. `Core.reservoirPlan` refuses unless every
spot is an existing, outdoor (`isOutside`, the only thing rain collection asks)
roof square with a floor, nothing solid on it, and no other slot's floor.

*A room that already has a collector refuses the kit.* The map ships them:
`carpentry_02_122` on every roof square over the floor (`defaults.lua` called
it a timber platform, which it is not), in the ambulance bays and several
fitted rooms. The `_barrels` tier variants carried them too and were where the
sprite was first found, but every one of those cells has since been reworked
and no `*_barrels` room is registered any more. So the test looks at the roof over
the whole footprint, by sprite name as well as by behaviour, because a
map-placed barrel may have loaded as a plain `IsoObject`. No room carries a
flag saying it has water; the roof is the truth.

*Our barrels are tagged, the map's are not*, and that is the whole removal
mechanism. `consts.reservoirKey` in the object's modData makes
`Manifest.isStructural` refuse it, so a capture never records one and the next
scrub removes it. Excluding every rain collector instead would have made the
scrub delete the map's own barrels, since they are part of what it restores.

*The install is a request, not a server side `complete()`.* The client runs
`PhunInteriorsReservoirAction` for the felt cost and sends only the kit's item
id through `Core.dispatch`; `Rainwater.install` reads the room off the
occupancy, finds the kit in the player's own inventory, plans again, and spends
the kit only if a barrel went up. Same shape as entering, on the path already
proven over the wire.

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
| **Vehicle battery charge.** The part is `vehicle:getBattery()` (declared on `VehiclePartOwner`, not `BaseVehicle`); the charge is `getCurrentUsesFloat()` / `setCurrentUsesFloat()` on its inventory item, both on `InventoryItem` itself. **`getUsedDelta()` does not exist** in B42 outside `Clothing` — a car battery is a `DrainableComboItem`, which declares `setUsedDelta` and **no getter at all**. `setUsedDelta` is a one-line alias for `setCurrentUsesFloat`. A server-side write must be followed by **`vehicle:transmitPartUsedDelta(part)`** or it never reaches clients. The whole pattern is `VehicleUtils.chargeBattery` in `Vehicles.lua`. | Ported from RV Interior and it threw on the first entry: the write worked, the read did not. Vanilla's own asymmetry hides it — `Vehicles.lua` writes with `setUsedDelta` and reads with `getCurrentUsesFloat`, so grepping for either alone tells you the wrong half. A working B41 mod is not evidence about B42, and a setter existing says nothing about its getter. Copy the whole vanilla function, not the one line you were looking for. |
| **Electricity, settled from the bytecode.** `haveElectricity()` reads no field at all: it is `chunk:isGeneratorPoweringSquare(x, y, z)`, with an early `false` for an exterior square when `AllowExteriorGenerator` is off. **`setHaveElectricity(boolean)` does not set anything** — it ignores its argument entirely and calls `update()` on any `IsoLightSwitch` on the square. It is a refresh with a setter's name. `hasGridPower()` is `not isNoPower() and doesPowerGridExist()`; `isNoPower()` is `isDerelict() or isUserDefinedRoom()` or the square sitting in a map zone of type `"NoPower"` or `"NoPowerOrWater"`. | Generator power is only ever a **real, active `IsoGenerator` in the chunk** — it cannot be faked with a flag, which is why RV Interior places one. The mains cannot be switched off from Lua, but it *can* on the map: a **`NoPower` zone painted over the interior block** makes `hasGridPower` false there permanently, leaving the generator as the only source. That is a map authoring job, and `admin("power")` reports whether it has been done. Note this row replaced an earlier, wrong one that reasoned from method names — hence `Docs/body.pl`. |
| **"Is this vehicle moving" is `vehicle:isStopped()`, not a speed threshold.** A stationary vehicle *under tow* reports a non-zero `getCurrentSpeedKmHour()` — the coupling never quite settles — so any epsilon is a guess about physics jitter. `isStopped()` is what vanilla gates vehicle interaction on (`ISExitVehicle:isValid`, `ISVehicleMenu.lua:185`). | Confirmed in game: a parked towed van refused boarding while telling the player it was moving. Seated players were unaffected, because `isAtTheWheel` short-circuits before the speed test — which is exactly the asymmetry that identified the cause. |
| Putting out a fire is `square:stopFire()` **then** `square:transmitStopFire()`, which is what vanilla's fire brush does (`FireBrushUI.lua:265`). `IsoFire.extinctFire()` and `IsoFireManager.RemoveAllOn(square)` are both declared and both read exactly right — and both have **zero** uses in vanilla lua. | `Harden.sweepFire` used `fire:removeFromWorld()` on the object from `square:getFire()`. That is `IsoObject`'s generic removal: the engine answered every call with `IsoFireManager.Remove unknown fire, ignoring`, so the same fires were re-found and "doused" on every sweep, forever, while still burning. The log said it worked. A plausible-looking declared method with no vanilla uses is the tell, and here there were *two* of them next to the right answer. |
| `IsoGridSquare` has **no `setBloodSplatLifetime`**. Vanilla `ISCleanBlood:complete()` uses `square:removeBlood(false, false)` then `square:removeGrime()`. | Confirmed absent from the jar. |
| Vanilla only ever exits a vehicle from a **client** timed action (`ISExitVehicle`). | `vehicle:exit()` lives in `Client.teleport`, not in server-side `Transit.enter`. |
| `getCell():getVehicles()` returns a **`java.util.Set`** — `size()` but no `get(i)`, so it cannot be indexed from Lua, and **loaded vehicles cannot be enumerated from Lua at all**. Vanilla's own `ISVehicleBloodUI.lua:81` does `vehicles:get(i-1)` and is therefore broken; so does RV Interior's entire exit path. | `resolveReturn` uses `getVehicleById(handle)`, and position tracking is pushed by the driver's client rather than swept for. Vanilla Lua shows intent, **not** correctness — and neither does a shipped mod that works on B41. |
| **Vehicle level modData is never transmitted to a client.** `IsoObject` declares the whole sync path — `transmitModData`, `sendObjectModData`, `ObjectModData`, `IsoObjectChange`. `BaseVehicle` declares `getModData`/`setModData`/`hasModData` and `transmitPartModData(VehiclePart)` and **none** of it. Vanilla never calls `transmitModData()` on a vehicle (only doors, players, characters, carcasses, plain objects) and every vanilla client-side vehicle modData read is `part:getModData()`. | Anything a client must know about a vehicle has to be *sent* to it, or discovered client side and confirmed by the server. A client-side UUID match cannot work. `transmitModData()` on a vehicle is worse than a no-op: `IsoObject`'s version addresses an object by square plus index in that square's object list, and a vehicle is not in `square:getObjects()`. |
| **B42 has no server side "a player left" event.** `OnDisconnect` is a *client* event meaning "you were disconnected"; it takes no player argument and vanilla uses it only in `ConnectToServer.lua` and `ISMPEditAccount.lua`. Dumping every name from `LuaEventManager` finds no `OnPlayerDisconnect` or equivalent. | `server_events.lua` deliberately has no disconnect handler. It had one, hooked to `OnDisconnect`, and it never fired once. Keeping the occupancy is the better behaviour anyway — `playerSetup` finds it on reconnect. |
| **B42 has no "a vehicle was destroyed" event either**, and **`isRemovedFromWorld()` does not mean removed.** `LuaEventManager` declares no `OnVehicleDestroyed`. From the bytecode, `permanentlyRemove()` is exit every passenger, `breakConstraint`, `removeFromWorld()`, `removeFromSquare()`, `VehiclesDB2.removeVehicle` — and `removeFromWorld()` is also what an ordinary chunk unload calls (it starts with `VehiclesDB2.setVehicleUnloaded`), so the `removedFromWorld` flag is true of every parked vehicle out of range. Vanilla calls `permanentlyRemove()` from exactly three places: `ISRemoveBurntVehicle:complete()` (blowtorch on a wreck), and the admin "remove vehicle" cheat in `ISVehicleMechanics.onCheatRemoveAux` and `VehicleCommands.remove`. Stripping parts never removes a vehicle. | `server_events.lua` had an `OnVehicleDestroyed` handler guarded by an existence test, so it skipped itself and a removed vehicle's room stayed leased — which under reclaim-on-demand means a full pool may take a living player's older room instead of this abandoned one. `removal.lua` now hooks the removal *calls* and releases on the flag **changing** across them, never on its value: `complete()` is wrapped server side, and since `VehicleCommands` is a local table the client warns first (`vehicleRemoving`) and the server watches for five seconds. Anything else calling `permanentlyRemove()` is not seen; its room goes unrenewed and is reclaimed like any other. |
| **Safehouse claims are a global list, and the overlap test is half open.** `SafeHouse` (`zombie/iso/areas`) declares static `getSafehouseOverlapping(int, int, int, int)`; from the bytecode it walks `safehouseList` and returns the first house where `arg0 < house.x + w`, `arg2 > house.x`, `arg1 < house.y + h` and `arg3 > house.y` — so the arguments are corners `x1, y1, x2, y2` with the far edge **exclusive**, which is how vanilla's zone editor passes them. `getX2()` is `x + w`. It reads no square, so it answers for an unloaded chunk. `SafeHouse.getSafeHouse(square)` also exists but needs a loaded square. | `Slots.safehouseOn` passes `Core.slotBounds`, whose far edges are inclusive, as `x1, y1, x2 + 1, y2 + 1`. Passing them unadjusted misses a claim covering only the footprint's last row or column — which is where the south and east walls stand. A claimed slot is never scrubbed (`Scrub.slot`), reclaimed (`isReclaimable`) or handed to a vehicle that does not hold it (`Slots.acquire`, and `acquireIn`'s own pick). |
| **Nothing in the engine keeps a player OFF a claimed safehouse square.** The whole enforcement surface is one method — `SafeHouse.isPlayerAllowedOnSquare(IsoPlayer, IsoGridSquare)` — which reads `ServerOptions.safehouseAllowTrepass` (PZ's own spelling) and otherwise asks `SafeHouse.isSafeHouse(square, username, true)`. Across the entire jar exactly two classes reference it: `SafeHouse` itself, and `BaseVehicle`, from **`isExitBlocked2`** — "can you get out of this seat onto that square". There is no movement gate, no periodic sweep and no ejection anywhere. | So a claim protects a safehouse from being *driven into and stepped out of*, and from nothing else. Teleporting a player onto a claimed square is not undone by the engine, so **porting a tenant into a room somebody else has claimed just works** — they stand in it and the leash contains them there normally. It does not self-correct into an eviction, which was the hope. If a claim should gate ENTRY as well as protect the room, that is ours to build in `Transit.canEnter`, and it needs an answer for a refusal that has to be explained in terms of a vehicle the player is standing next to rather than a building they can see. |
| `BaseVehicle` declares `getCurrentSpeedKmHour`, `getSpeed2D`, `getDriver`, `getDriverRegardlessOfTow`, `getVehicleTowing`, `getTowingPartner`, `isSeatInstalled`, `isDriver`. `OnSwitchVehicleSeat` is **not** an engine event — vanilla registers it from `ISVehicleDashboard.lua:716`. | Rule 5 gates on speed, not on `getDriver()`, because a towed vehicle moves with nobody at its wheel. The tracker installs in the deferred setup, like the destroy guards, or the seat hook silently does nothing. |
| Moving a player is `IsoGameCharacter:teleportTo(x, y, z)` (overloads `(FFI)`, `(III)`, `(FF)`, `(II)`). `setX`/`setLastX` also works — PhunZones2 ports players that way. | `Client.teleport` uses `teleportTo`, `+ 0.5` to centre on the tile, as vanilla's `StreamMapWindow` does. |
| **One teleport call is not enough across the map.** The player moves, but the destination chunk is not loaded, and the engine restores anyone on a square that does not exist. It reads as "the teleport silently did nothing" — the position log shows the move landing and then being undone. | `Client.teleport` re-asserts the position every tick until `getGridSquare` at the destination is non-nil (`HOLD_TICKS`). Applies leaving a room too: the vehicle's chunk unloads while the player is inside. The leash `graceUntil` **must** outlast that window. |
| `ISEnterVehicle:new(character, vehicle, seat)` is the only sanctioned way into a seat, and its `start()` silently returns without entering if the character is more than 2 tiles from `getPassengerPosition(seat, "outside")`. `isValid` then fails and the queue drops it, so a failed re-seat degrades to standing there rather than hanging — **this happens by default**, because the only position the server can send is the vehicle centre, which is further than 2 tiles on anything van sized. Teleport to the outside position first (`getWorldPos(pos:getOffset(), Vector3f)`, as vanilla does). `getBestSeat`, `isSeatOccupied`, `getMaxPassengers`, `getCharacter` all exist on `BaseVehicle`. | Re-seating on exit is a client action in `Client.teleport`'s second phase, run only once the destination chunk has streamed in. |
| `vehicle:getSeat(player)` returns -1 once the character is out of the seat, and our entry action refuses to run until exactly that. | The seat **must** be captured client side in `Client.beginEnter`, before `ISExitVehicle` is queued, and sent with the enter request. Reading it server side in `Transit.enter` always yielded -1. |
| From the server, an unloaded vehicle and a destroyed one are indistinguishable: `getVehicleById` returns nil for both. The vehicle's chunk is always unloaded while its owner is in a room, **and it reloads with a different `getId()`**, so the captured handle never resolves again. Confirmed from the logs. | `Transit.leave` must **not** warn `VehicleGone`; it fired on every normal exit. The client raises it after arrival, where the chunk is loaded and the question is answerable. `getVehicleById` is in `LuaManager$GlobalObject`, so it works client side too. |
| `instanceof(object, "IsoFloor")` has **zero** uses in vanilla Lua and filters nothing — a room captured with and without it returned the identical 29 objects. Vanilla finds a floor with `square:getFloor()`, which every build and debug tool uses. | Identify a floor by identity against `square:getFloor()`, not by class. Zero vanilla uses of a plausible-sounding call is the tell, and it applies to `instanceof` class names as much as to methods. |
| **B42 translations are `.json`, not `.txt`.** The stock install ships 43 `.json` files in `media/lua/shared/Translate/EN` and zero `.txt`. The format is a flat JSON object of key/value pairs, with no `ContextMenu_EN = {}` wrapper, and the `_EN` filename suffix is gone: `ContextMenu.json`, `IG_UI.json`, `Sandbox.json`. | The B41 `.txt` files load silently and every `getText` falls through to the raw key. Confirmed in game: nothing translated until these were converted. Sandbox keys are still `Sandbox_<Mod>_<Option>` and `_tooltip`. |
| **B42.20.4 removed `loadstring`, `load` and `loadfile`.** Not deprecated — absent. The classic "write a Lua table as `return { ... }` and read it back with loadstring" round trip no longer completes. | Any config a mod persists and re-reads has to be in a format that needs a *parser* rather than an interpreter, which is why `PhunInteriors.json` is json and why `shared/PhunInteriors/json.lua` is vendored from PhunMart2 (which hit this first, in `utils_file.lua`). The failure mode is the dangerous part: nothing errors, `loadstring` is simply nil, the pcall around it fails, and every override file on disk reads back as nil — so an admin's customisations quietly do not come back after a restart and the next save writes defaults over them. `author.lua` still emits lua and is unaffected: the game loads that as a mod file at boot, not through loadstring. |
| **`getFileWriter` truncates on open.** `getFileWriter(name, createIfNotExists, append)` with `append` false empties the file the moment it is opened, before anything is written. | Encode, serialise or otherwise build the whole payload **before** calling it. Opening the file and then discovering there is nothing to write replaces a good file with an empty one — which is exactly what a failed `json.encode` would do, and the most likely cause of one is a non-string table key, which Lua allows and JSON does not. `Store.save` and PhunMart's `saveTable` both order it that way deliberately, and it is the reverse of how the code reads most naturally. |
| `ISVehicleMenu.showRadialMenu` delegates to `showRadialMenuOutside` when the player is not seated, but **inside the call**, so wrapping `showRadialMenu` alone covers both seated and standing. `showRadialMenuOutside` has exactly one caller, that delegation. `ISRadialMenu:addSlice` forwards to the java object, so a slice added after the base displayed the menu still appears, and the menu is a fixed size circle so the base's centring stays correct. `menu:isReallyVisible()` reads **false** immediately after `addToUIManager` in the same call stack; vanilla only ever tests it at the start of the *next* call. | One hook on `showRadialMenu`, no visibility gate. Wrapping `showRadialMenuOutside` as well just duplicates the slice, and gating on `isReallyVisible()` silently removes it — both were tried and both broke the menu. Pick the vehicle with `ISVehicleMenu.getVehicleToInteractWith` (seat, then useable, then near). |
| `IsoPlayer` has both `isGhostMode()` and `isNoClip()`. The admin cheat panel (`ISAdminPowerUI.lua`) toggles **`isNoClip`**, gated by `Capability.ToggleNoclipHimself`; `GameServer` references `setNoClip` and `AntiCheatNoClip`, so the flag is server-visible for a remote player. `isGhostMode` is only used by debug menus and the trailer scenarios. | `Leash.isExempt` uses `isNoClip()` as the "an admin is deliberately debugging" signal. There is no admin-mode flag as such. |
| **A B42 map cell is 256 squares, not B41's 300.** From the jar: `IsoCell.CELL_SIZE_IN_SQUARES = 256`, `CELL_SIZE_IN_CHUNKS = 32`, `IsoChunkMap.CHUNK_SIZE_IN_SQUARES = 8`. B41 chunks were 10 squares — still there as `OLD_CHUNKS_PER_WIDTH` — so 30x10 = 300 became 32x8 = 256. | Cell = `floor(coord / 256)`. `22560, 12060` is cell `88, 47`, so the map must ship `88_47`. Assuming B41's 300 makes correct coordinates look out of range. |
| **Zombie density is only ever set for a cell some map covers, and zero is not the default — "never set" is.** `MapCollisionData.init` is the sole feed to the native population manager: per cell it calls `n_initMetaChunk(cellX, cellY, cx, cy, max(LotHeader.getZombieIntensityForChunk(info, cx, cy), 0))` for all 32x32 chunks, but only when `metaGrid.getCellData(x, y)` is non-null — and that resolves to `getCell`, a bare array index into a grid only `getCellOrCreate` fills. `getZombieIntensityForChunk` itself resolves through `IsoLot.MapFiles` by priority (converting to B41 300-cell coordinates to test `bgHasCell300`), so the winning intensity is the highest-priority map covering that cell, not necessarily the header passed in. | A map's own cells can be painted to zero and still have zombies walk in **from the void cells around it**, which were never initialised at all. Proven in a save: 70 zombies across four cells with no lotheader, zero in ours. Ship a ring of empty cells rather than trusting the density layer alone. Two bypasses make the whole layer moot: `Distribution = 2` (Uniform) substitutes a hardcoded `UniformZombiesPerChunk = 0.2` everywhere, and `MinZombiesPerChunk` (Lua `setMinMaxZombiesPerChunk`, default 0) floors every chunk. |
| **A B42 tent is a placed moveable, and its identity is a sprite property.** `camping.addTent` and `MOTent.lua` are B41 leftovers — the latter is commented out top to bottom — and `camping_01_*` is not what a player puts down. The seven vanilla tents (`CampingTentKit2`, `ImprovisedTentKit`, `HideTent`, `Tent{Yellow,Blue,Brown,Green}`) are `base:moveable` items, and **every sprite of one carries `CustomItem = Base.TentGreen`** in its tile properties — `object:getSprite():getProperties():get("CustomItem")`. Placement copies the item's `Tooltip` and an `itemCondition` table into the object's modData, which is why a placed tent already has modData before we touch it. | Bind a world object by its **moveable item type**, never by sprite name: four colours at 32 sprites apiece against one string a third party can write down. Confirmed in game — `camping_04_100` reports `Base.TentGreen`, `camping_03_24` reports `Base.ImprovisedTentKit`. `sprite:getType()` is `MAX` for every one of them, and for the floor, so it is no help at all here. |
| **A multi-tile moveable normalises through its sprite grid, not through a rule of ours.** `sprite:getSpriteGrid()` yields `getAnchorSprite()` — one name shared by every instance of that design — and `getSpriteGridPosX/Y(sprite)`, this tile's offset within it. Vanilla's own pickup path computes the origin as `square:getX() - spriteGrid:getSpriteGridPosX(sprite)` (`ISMoveableSpriteProps.lua:1003`). | Any tile of a tent resolves to one holder square, so a lease cannot be taken twice on one object and no `anchor` callback is needed on a binding. Two TentGreens three tiles apart both reported anchor `camping_04_99`, at grid positions `1,3` and `1,0` — the anchor names the *design*, the position names the *tile*. Note a green tent is therefore at least 2x4; B41's two-square tent is not the shape to design against. |
| **`instanceof` cannot identify a placed moveable, and the inconsistency is *within one object*.** Of a single TentGreen's tiles, `camping_04_100` loads as a plain `IsoObject` and `camping_04_103` as an `IsoThumpable`. | Identify by `CustomItem`; reach for `instanceof` only to guard behaviour you are about to invoke. Same lesson as the light switches from the other end — there the class was lost by rebuilding, here it was never uniform to begin with. |
| **Object modData survives a save and a reload, and `AddSpecialObject` adds to `square.objects` as well as `specialObjects`.** A key written client side and left through a quit to the main menu came back intact on both a tent and the floor beneath it. `IsoObject.transmitModData` addresses a plain object by `square:getObjects():indexOf(object)` (`MovingObject.set`, objectType 1), and in single player both network flags are false so it falls through to `flagForHotSave()`. | A world object can hold a durable lease id across a save, a reload and a chunk unload, which a **vehicle cannot** — see the vehicle modData row. So a non-vehicle holder needs neither position keying nor the client-side identity workaround the exit handshake exists for. It does **not** survive being picked up; see the next row, which is the one that decides the design. |
| **modData does not survive a tent being picked up, and whether it does depends on which tile was clicked.** Every tent carries the `ForceSingleItem` tile property, and that branch of `ISMoveableSpriteProps:pickUpMoveable` builds a fresh item from the anchor sprite and puts modData on it in exactly one place: `if instanceof(obj, "IsoThumpable") then self:saveThumpableParameters(item:getModData(), obj) end`, where `obj` is the object on the **clicked** square. The per-tile `pickUpMoveableInternal` calls run with `createItem = false`, so the items that *do* carry `movableData` are built and thrown away. And a single TentGreen is both classes at once — `camping_04_103` is an `IsoThumpable`, `camping_04_100` is not. | Picking a tent up by one corner carries its whole modData and by another carries **nothing at all**, not even `movableData`. Writing the id to every tile does not help: what is tested is the clicked tile's *class*, not whether it holds the id. So a lease must **never depend on surviving a pickup** — a tent put back down would mint a fresh id, take a different room, and leave the old one leased to an id nothing carries until reclaim took it, which is a tenant's belongings quietly disappearing. Refusing the pickup is what makes this moot; see "Known gaps" #11. |

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

**`body.pl` used to stop dead at the first lambda, and it did it silently.**
Tags 17 and 18 (`Dynamic` / `InvokeDynamic`) put a *bootstrap method* index
where a `Fieldref` puts a class index, so resolving one as a class reached a
Utf8 entry and threw — after the output was already partly printed. The result
looked exactly like a method that ended there, which is how a `stream().map()`
midway through `IsoMetaGrid$MetaGridLoaderThread.loadCell` hid the answer to
"what does zombie density actually do". Unresolvable operands now print as
`dynamic.<name>` and decoding carries on. If a disassembly ends somewhere
implausible, check stderr before believing it.

**Present in the constant pool is not conclusive**: a constant pool holds the
names a class calls on other classes as well as its own, so `getContainer`
shows up in `IsoGridSquare` purely because it calls it on an object. Present
means "worth checking", never "exists here".

**Absent from `methods.pl` is not conclusive either**, and this cost real time.
It reads one class's method table, so it cannot see anything inherited — and
in particular it cannot see **default methods on an implemented interface**.
`BaseVehicle` reports no `getBattery` and no `getPartById`, while vanilla calls
the latter 138 times; both are declared on `VehiclePartOwner`, which
`BaseVehicle` implements. So absent means "not declared *here*". Before
concluding a method does not exist, check the superclass chain (the `super`
entry in the class file) and the interfaces, or grep the whole package:

```bash
for f in zombie/vehicles/*.class; do
  perl Docs/methods.pl "$f" 2>/dev/null | grep -q " getBattery " && echo "$f"
done
```

The one thing that *is* conclusive is heavy use in vanilla's own Lua. If
`methods.pl` and 138 vanilla call sites disagree, the tool is wrong.
Cross-check intent against how vanilla's own Lua in `media/lua/` uses it — zero
vanilla uses of a plausible-sounding method is the tell that it was invented.

### Checking what a map actually contains

`Docs/tiles.pl` reads a cell straight out of the lotpack — a tally by default,
or the world coordinates of one tile if you name it:

```bash
M=Contents/mods/PhunInteriors/common/media/maps/phuninteriors
perl Docs/tiles.pl $M/world_88_46.lotpack
perl Docs/tiles.pl $M/world_88_46.lotpack appliances_misc_01_0
```

It has paid for itself three times.

**Counting.** A test map rendered a generator on every square of open ground,
and the obvious suspect was `Power.ensureGenerator`. The log said it had placed
exactly one; the tally said the cell contained 35,768. The sprites were in the
map file, and no amount of reading our own code would have found that.

**A baseline.** "Is 35,768 a lot?" is unanswerable until you run the same count
over a vanilla cell. The column that matters is **alone** — squares carrying
one tile and nothing else are the cell's background. Muldraugh `0_18`'s is
`blends_natural_02_0`, a ground blend. If yours is something solid, every empty
square in the cell is wearing it. A healthy cell is mostly `-1, N` empty runs:
after the fix, 88,46 went from 65,536 squares with content to 1,250.

**That heuristic now fires on our own map, and it is a false alarm.** Both
cells paint `phuninteriors_01_0` across all 65,536 squares — a tiledef we ship
ourselves in `media/phuninteriors.tiles`, a `solidfloor` on `Road_06`, and it
is the ground for the whole block. So a fully painted cell is a fault only
when the tile is one you did not intend; check the palette name against the
tiles file before believing the count. The room squares themselves are not
painted with it.

**Locating.** Naming a tile prints every world coordinate and room id, which is
how the generator offset was corrected from the inherited `{0,0,1}` to the map's
actual `{0,17,0}` — one per room, all on roomID -1, confirmed rather than
guessed.

The standing lesson: **check the data before the code** when the symptom is
"the world looks wrong" rather than "the logic is wrong". The log line saying
we placed one generator was already conclusive and took thirty seconds to find.

`Docs/roomcheck.pl` answers the question those two cannot: **does the registry
describe the map that ships?**

```bash
perl Docs/roomcheck.pl
#   20 cells, 990 registered slots, 16140 interior squares, 1330 door squares,
#   990 slots with a front
#   FAIL 1600 interior squares inside no registered slot
```

It reads the interior squares and the door squares out of every lotpack, loads
`defaults.lua` under `Tests/lua/stubs.lua` to ask where the registry thinks its
slots are, and reports two ways those can disagree: an interior square inside
no registered slot, and a square where the floor and the registered box
disagree. Exit status is non-zero on either, and it names the squares and the
slot.

**It asserts only what a lotpack can settle.** There are room ids and sprite
names in there, not tile flags, so "is this square walkable" is not answerable
— a doorway cut into a wall is an opening with no door object in it, which is
exactly what the ambulance bays' south exit is. An earlier version failed those,
and a check that calls a working room broken is worse than no check.

**There used to be a third check** — that a slot had a door object or its room
declared a landing edge, so there was *some* way out. It went with the `landing`
table. A doorless opening, a window and a garage door are all invisible in a
lotpack, so that check could only ever rest on the author asserting a way out
existed, and an assertion checks the author against himself. The cost is real
and worth knowing: **a room with four solid walls is now caught by walking into
it rather than by this script.** Dropping it was a deliberate call, not an
oversight.

The second of the two is the one that earns its keep. The registry declares a
**footprint** and the map draws a **floor**, and this map puts the south and
east walls outside the floor, so the floor is the box less its last row and
column. Registering the 3x4 ambulance bays as though they were the 2x3 rooms
they replaced left a box that fitted their floor exactly and excluded both
their walls — and every other check here passed.

**Run it whenever the map moves.** `locations` is hand-written data and the
lotpack is the truth; nothing else compares them. It was written after cell
88,46 was registered at 22546 while the map put it at 22545 — all sixty of that
cell's slots a square east of their rooms, so the leash covered the east *wall*
column and excluded the west *floor* column. That presents as "the leash is
broken", and reading `leash.lua` can never find it: the leash was entirely
right about the box it was handed. The same run found a second fault nobody had
noticed, one stamp a square south of its row, which had left that slot's exit
tile on open ground outside its north wall.

`Docs/rooms.pl` dumps one cell's room DEFS — name, level and each rect in
world coordinates — which is what `tiles.pl` cannot see and what decides both a
room's loot and its shape:

```bash
perl Docs/rooms.pl $M/87_48.lotheader
#   0  empty  z=0 rects=4 [22286,12292 6x2] ...      <- the shell ring
#   1  empty  z=0 rects=1 [22288,12294 2x3]          <- the room itself
```

It answered two questions in one run that nothing else could: cell 87,49 holds
**zero** room defs, so the sixty slots registered over it were pointing at open
ground; and 87,48's rows 0-1 are 2x3 floors at 22288,12294, which is where the
tent room is registered from rather than from arithmetic. A shell is a ring of
four rects, the room is the single rect, and a 1x1 is the roof generator box.

`Docs/zombies.pl` is its sibling for the other half of a cell — the zombie
density block, which lives in the lotheader rather than the lotpack:

```bash
perl Docs/zombies.pl $M/87_46.lotheader $M/88_46.lotheader
#   all 1024 chunks zero -- nothing spawns here
perl Docs/zombies.pl -v "$PZ/Muldraugh, KY/42_38.lotheader"
#   692 of 1024 chunks populated, max 4  (0 x332, 1 x230, 2 x432, ...)
#   and the 32x32 grid, which draws the town
```

Same lesson as `tiles.pl`, arrived at from the same direction: the map editor
cannot tell you what it wrote, and a baseline read off the wrong cell is worse
than no baseline. See "Known gaps" #0 for the arithmetic and for which vanilla
cells are actually towns.

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

0. **The zones are painted.** `objects.lua` ships one `NoPowerOrWater`
   rectangle covering all twenty cells exactly. Zombie density is a
   separate question and is answered below rather than by a zone.

   **Power and water.** Without it the rooms sit on the mains until the grid
   shuts off, and the generator binding is invisible for the first weeks of a
   save. `hasGridPower()` is `not isNoPower() and doesPowerGridExist()`, and
   `isNoPower()` compares zone types against the literal strings `"NoPower"`
   and `"NoPowerOrWater"` (`StringUtils.equals`, straight out of the
   `IsoGridSquare.isNoPower` bytecode) — there is no Lua setter, so a zone is
   the only way. `NoPowerOrWater` covers both. What ships:

   ```lua
   objects = {
     { name = "Waterless", type = "NoPowerOrWater",
       x = 22272, y = 11776, z = 0, width = 1280, height = 1024 },
   }
   ```

   That is the whole 5 x 4 block — x 22272..23551 across cells 87..91, y
   11776..12799 across 46..49. It is **one** zone object drawn at 0,0 in the
   north-west cell of `phuninteriors.pzw` at 1280 x 1024; the exporter offsets
   it by the world origin and does not clip it to its cell, so one rectangle
   in the editor covers the lot. Read it out of the export rather than the
   editor -- the shipped `objects.lua` still carries the pre-resize 1536 and
   is corrected by the next re-export.

   `Zone.contains` is half open — `x >= zone.x` and `x < zone.x + width` — so
   the width is the cell count times 256 **exactly**, not one more. A first
   pass at this file had `x = 22527, width = 513`, which covers 88,46 and one
   column of 87,46, silently leaving the whole `phun.van.plain` set on the
   mains. Check the arithmetic against the cell bounds, not against a corner
   read off a map editor.

   `isNoPower` calls `getZonesAt(x, y, 0, ...)` with the level **hardcoded to
   zero** whatever level the square is on, and `Zone.contains` requires
   `z == zone.z`. So one `z = 0` rectangle covers the z=1 roofs in 88,46 too;
   there is no need for a second zone per level. `NoPowerOrWater` satisfies
   `isNoWater` as well, which tests the same string.

   It does not affect the generators — `NoPower` kills the mains, not
   `isGeneratorPoweringSquare`, which is the whole point.
   `PhunInteriors.admin("power")` verifies it.

   **Zombies is not a zone. It is the density layer, and ours is already
   zero.** Density is per meta chunk (`IsoMetaChunk.setZombieIntensity`), and
   the loader reads it as a **1024 byte tail on the `.lotheader`** — one byte
   per chunk, 32x32, straight after the building defs, with an `EOFException`
   if it is short. That is the block `Docs/tiles.pl` does not model and the
   one unaccounted-for chunk in a lotheader parse.

   `IsoMetaGrid$MetaGridLoaderThread.loadCell` then evaluates
   `IsoWorld.getZombieVoronois()` — noise layers declared as plain Lua in
   `media/lua/server/Zombies/VoronoiNoise.lua`, gated by the
   `ZombieVoronoiNoise` sandbox option — and combines them with the stored
   byte by **multiplication**:

       final = clamp(storedByte * product(voronoiCutoff[chunk]), 0, 255)

   written to `LotHeader.setZombieIntensity(index, byte)` and to the
   `IsoMetaChunk`. So a stored zero stays zero whatever the noise does, and
   `IsoMetaChunk.getZombieIntensity` only scales it further by the
   `distribution` and `zombies` sandbox options. Both our cells read all zero
   across all 1024 chunks, so nothing spawns in them.

   **Do not conclude "vanilla is all zero too" from a rural cell.** That
   mistake was made here: `38_23` is world (9728, 5888), empty forest, not
   Muldraugh. Sampled properly, real town cells carry real values —
   Muldraugh town `42_38` runs 0-4, West Point `46_26` 0-7, Louisville `50_7`
   0-7 — while wilderness beside them (`43_38`) is a flat zero. Pick the cell
   by world coordinate over the actual town before drawing a baseline.

   **`regions.lua` is not a lever on this and neither is `spawnpoints.lua`.**
   `media/lua/server/metazones/metazoneHandler.lua` loads `regions.lua`
   beside `objects.lua`, with the identical entry shape, and every entry ends
   at the same `getWorld():registerZone(name, type, x, y, z, width, height)`.
   It is a second file for the same content model, conventionally holding the
   `Region` and `BuildingName` naming zones. `spawnpoints.lua` and
   `spawnregions.lua` are **player** start selection, which is why we ship
   neither. And no zone type suppresses zombies: across every vanilla
   `objects.lua` and `regions.lua` the only zombie-related type is
   `ZombiesType` (1553 uses), which names an *outfit* — `Offices`, `Police`,
   `Factory` — not a count.

   **And zero density inside the block is not enough, because the leak is
   OUTSIDE it.** Confirmed in a real save, not reasoned about.
   `zombie.MapCollisionData.init` is the only thing that ever hands a density
   to the native population manager (`PZPopMan64.dll`), and it does it per
   cell:

   ```
   cell = metaGrid.getCellData(x, y)
   if (cell != null)
       for cx,cy in 32x32:
           n_initMetaChunk(x, y, cx, cy,
               max(LotHeader.getZombieIntensityForChunk(cell.info, cx, cy), 0))
   ```

   `getCellData` falls through to `getCell`, which is a bare array index into
   a grid only `getCellOrCreate` ever fills — so a cell **no map covers
   returns null and `n_initMetaChunk` is never called for it at all**. Its
   density is not zero; it was never set, and the native side uses whatever
   it defaults to.

   That is where the zombies come from. In
   `Saves/Sandbox/2026-09-18_17-54-55/zpop/`, decoding the coordinates out of
   the population files gives 26 zombies in cell 86,45, 39 in 87,45, one in
   88,45 and four in 89,45 -- **all void cells, none of which ships a
   lotheader** -- against **zero** in 88,46 and 89,46, whose files are
   byte-identical to the empty baseline. Every one of the 70 sits at y
   11704-11750, a band 26 to 72 squares north of the map's north edge at y =
   11776, on ground that does not exist. They cannot have walked there: the
   save's only other population is Muldraugh at 41,37-41,39, 45 cells west,
   with nothing in between. They were spawned in cells the game was never
   told the density of, and the manager realises them onto real squares when
   a tenant loads the chunk.

   So the fix is at the perimeter, not in the density layer: a ring of empty
   cells that ship a lotheader (which makes `n_initMetaChunk(..., 0)` get
   called for them), and a border wall on every edge. Note a wall stops
   pathing, not realisation -- `IsoGridSquare` has `getZombieCount()` and
   `getZombie()` if the leash ever needs to sweep a slot, which is a v2
   question because the siege wants the opposite.

   **`Distribution = 2` (Uniform) bypasses the density layer entirely**, and
   no map work survives it. `MapCollisionData.init` pushes
   `SandboxOptions.Distribution` straight into native game state and
   `ZombiePopulationManager.onConfigReloaded` passes
   `UniformZombiesPerChunk = 0.2` (a hardcoded float) alongside it, so every
   chunk in the world gets a target whatever the intensity map says. All five
   vanilla presets use `Distribution = 1` (Urban Focused); check the preset
   before blaming the map. `MinZombiesPerChunk` is the other bypass -- it
   defaults to 0 and only Last Stand sets it, through the Lua global
   `setMinMaxZombiesPerChunk`.

   **Reading a zpop file.** `zpop_<cellX>_<cellY>.bin` opens with an outfit
   name dictionary and then one record per chunk; a cell with no zombies is
   byte-identical to any other empty cell in the same save (24122 bytes in
   the save above). Anything larger holds zombie records, and their positions
   are plain big-endian float pairs. `zpopClearZombies(cellX, cellY)` is a
   Lua global if you want to flush one while testing.

1. **The map is cut and `defaults.lua` matches it** — verified, not asserted:
   `perl Docs/roomcheck.pl` compares the two and is the only thing that does.
   **It currently FAILS, deliberately and temporarily**: the grid has just
   been shifted one square north-west and `defaults.lua` is regenerated for
   the new origin, but the shipped lotpacks are still the old export. Re-export
   from WorldEd and run `map.cmd`, and it goes green. **Everything in the rest
   of this item below the next few paragraphs still describes the superseded
   two-cell, two-room map and needs a pass.** The top of `defaults.lua` is the
   current description.

   **Twenty cells** -- five across (87..91) by four down (46..49) -- each a
   10 x 6 grid at a pitch of 25 across and 42 down: **960 registered slots,
   13910 interior squares, 1300 door squares** as of 2026-09-19. The cell
   contents below are older than that -- 92,49 now holds zero room defs and
   the camping designs have moved to 90,48 -- so read the totals here and the
   layout from `roomcheck.pl` and `defaults.lua`, not from the table. Of the
   five original floor sizes (2x3, 3x4, 3x6, 3x9, 3x13) only 3x9 still ships
   as a tier — the rest have been reworked cell by cell into fitted rooms —
   and all of 87,47 is the ambulance bays. Every origin, and the pitch, came out of
   the lotpacks.

   **The 92 column is gone and the block is fenced on all four sides.** Those
   four cells held no lots and no room defs, and each was still a 776 KB
   lotpack because the whole 65,536 squares are painted with
   `phuninteriors_01_0` -- 3 MB of a 20 MB map for nothing. Dropping the
   **east** column is the cheap direction: `worldOrigin` stays `87,46`, every
   other cell keeps its local coordinates and no room moves. Note `map.cmd`
   copies and never mirrors, so a dropped cell has to be deleted by hand from
   the repo *and* from the editor's export folder, or robocopy puts it back.

   The fence needed the grid to move, and the reason is a PZ rule rather than
   a layout preference: **PZ only has West and North wall sprites -- an east
   wall is the west wall of the next square.** That is what the border
   buildings encode. `Border_W` is 1 x 256 carrying `dir="N"` walls at its own
   x=0, which land on the *west edge* of that column; `Border_N` is 256 x 1
   with `dir="W"` walls on the *north edge* of its row. (`dir` is the
   direction the wall runs, not the edge it sits on.) So **no new building was
   needed**: `Border_W` placed at cell-local x=255 is the east fence and
   `Border_N` at y=255 is the south fence, leaving line 255 itself outside the
   fence, which is the map edge and costs nothing.

   What it does cost is a square of grid. Lots were at `x = 6 + 25*col` and
   `y = 4 + 42*row`, 25 x 42 each, so they filled **x 6..255 and y 4..255** --
   flush against the east and south cell edges with no margin at all. The
   budget is 256 - 250 = 6 spare columns and 256 - 252 = **4** spare rows, and
   each new fence wants one line. So every lot moved **one square west and one
   north**: lots now occupy x 5..254 and y 3..254, with the west wall at x=0
   and a 4-square verge, the north wall at y=0 and a 2-square verge, and the
   new fences on 255. A lot butting the fence is harmless -- the shell sits
   around lot-local x 8..15, so the outer 8 or 9 columns of every lot are bare
   ground.

   Registry side that is two constants: `$OFF_X` and `$OFF_Y` in
   `Docs/gendefaults.pl` went 16 -> 15 and 6 -> 5, and the file was
   regenerated. Every room moved one square north-west; **slot indices did not
   change**, so nothing re-points.

   **This is a step backwards on zombies and was taken knowingly.** The 92
   column was doing the job Known gap 0 describes -- a 256-square ring of
   cells that *do* ship a lotheader, so `n_initMetaChunk(..., 0)` was called
   for them and they were a genuine zero-density buffer on the east side. A
   fence stops pathing, not realisation, so it is not a substitute. The right
   answer is a deliberate ring on all four sides; until there is one, the
   block is fenced but the void starts immediately beyond it on every edge.

   **A cell can hold more than one design**, which is why `stamps()` takes a
   row count — 87,47 was half 2x3 rooms and half bays for a while, and is all
   bays now. The bays took indexes 60..119 of `phun.room.2x3`, and those are
   left as a **gap** rather than dropped: the index is the identity a lease
   persists, so a cell appended later must not inherit numbers a stale lease
   may still name. `normaliseLocations` sorts `pairs` keys precisely so a gap
   is expressible.

   The bays are 3x3 of floor in a 4x4 footprint, with a single door at offset
   1,0 and a second doorway at 1,3 — in the south wall line, so it is inside
   the box — which is the `cab` edge. They spawn a tenant at 1,1, the middle
   of the floor.

   **Each bay is wrapped in a shell**: a 7x7 ring two squares wide, open to
   the sky, one wall course high. The shell is deliberately outside the slot's
   bounds, so stepping into it is leaving.

   The walls are explicit objects rather than a room's auto-generated ring, and
   that is not a style choice. BuildingEd rings a *room* with exterior walls,
   so an `emptyoutside` shell -- which is not a room, see below -- generates
   none, and renaming it silently left every perimeter square with a floor and
   no wall. Explicit wall objects export regardless of room, and the exporter
   still picks the right W/N/NW variant per position.

   **A second course at z=1 has now been tried twice and removed twice. Do not
   try it a third time.** It was standing in for the ceiling, which had to go
   for daylight, and it does block the neighbours -- but it will not fade. PZ's
   wall cutaway and upper-level hiding both trigger on the player being inside
   a *building*, and an `emptyoutside` shell is not one, so from inside the
   shell it reads as a solid black wall at eye level rather than as something
   the camera sees past. The ceiling did the same job from above your head,
   where you never looked at it.

   The second attempt was to hide the roof generators, which at z=1 were
   visible over the shell's z=0 south wall from anywhere on the block. It
   worked and banded exactly as before. **The generator came down to z=0
   instead** -- see "The room runs off the vehicle battery" in Architecture --
   which puts it on the same level as the wall that already hides it and leaves
   no z=1 geometry anywhere to band.

   The lesson generalises past the shell: **anything drawn at z=1 outside a
   building is drawn at eye level and never fades**, so the fix for "I can see
   X over the wall" is to lower X, never to raise the wall.

   **The shell is named `emptyoutside`, and that name is load bearing.**
   `IsoGridSquare.setRoomID` unsets `IsoFlagType.exterior` for **any** square
   carrying a room id, so a shell that is an ordinary room can never be
   sunlit -- and no window into it can ever bring daylight to the room inside.
   `IsoMetaGrid.getRoomAt` skips `emptyoutside` defs (they live in their own
   lookup, out of `BuildingDef.rooms`), so such a square keeps roomID -1 and
   stays exterior. Removing the shell's ceiling is necessary too, because
   `IsoChunk.loadInWorldStreamerThread` strips `exterior` from everything under
   a `solidfloor` or `BlockRain` tile -- but on its own it does nothing, which
   is how a session went looking for a roof that was not the problem.

   **The price is fog, and it is a proof rather than a tradeoff to tune.** Fog
   is skipped when `IsoPlayer.isInARoom()`, which is `getRoom() != null ||
   isoWorldRegion.isPlayerRoom()` -- and the second clause is
   `isEnclosed() && isFullyRoofed()`. Both routes need the very thing daylight
   needs you not to have. So fog draws while a player stands in the shell.
   The tenant standing in the interior room is unaffected: the test is on the
   player's own square, per frame.

   Confirmed in game, and worse than hoped: **fog shows the outline of the
   neighbouring stamps.** It is a screen-space layer, so the black shell does
   not hide what it draws. Accepted as a known cost of daylight rather than
   solved.

   **The 1x1 generator box is `emptyoutside`, not a room**, and it holds the
   generator at z=0 with a black lid over it. It was an `empty` room with the
   generator on its roof, for the good reason that only a room writes a
   ceiling and that ceiling was what the generator stood on; at ground level
   the cell's own painted floor is there regardless, so the square cannot stop
   existing and `Power.ensureGenerator` can always replace what it finds.
   Making it `emptyoutside` is what keeps `setRoomID` off the square. Full
   reasoning in "The room runs off the vehicle battery" in Architecture.

   Note this is the one place on the map with **two** ceiling entries in a
   `.tbx`: the room's own, and an appended `category="ceiling"` entry holding
   `phuninteriors_01_1` that only the box points at. It must be appended
   rather than inserted -- tile entries are flat and 1-based in document
   order, so an insert renumbers every `Tile=`, `Floor=` and `Ceiling=` after
   it, including the ones in the `<building>` element's own attributes.

   **`empty` is also a real room.** It is a vanilla distribution room (no
   loot), and 91,49 row 4 is ten 2x3 rooms under that name, for the passenger
   vans. Nothing in the lua keys on the def name, so only `roomcheck.pl` has to
   tell them apart, and it does it by shape: a shell is four rects in a ring, or
   the 1x1 box under a roof generator; a room is a single rect bigger than one
   square. No need to flag them differently on the map.

   **The base rooms are being reworked cell by cell.** 87,46 (2x3, double
   north door), 87,47 (the bays), 88,46 and 88,47 are done, and the rework
   changed two things the registry has to follow: every room origin moved **a
   square west and north** (22288,11782, 22288,12038, 22544,11782 and
   22544,12038), and the generator moved to **`{x = 1, y = 17, z = 0}`**,
   inside a sealed 1x1 `emptyoutside` box. Every room on the map now states
   that one offset, so there is no per-variant generator left to carry.
   (The offset went `{0,17,0}` → `{1,17,1}` on the roof of an `empty` box →
   back down to `{1,17,0}`; only the last is current.) Re-read them with
   `roomcheck.pl` rather than assuming.

   **88,46 to 88,48, 89,46 to 89,49, 90,46 to 90,49 and 91,46 hold fitted
   rooms of two rows apiece**, registered by `registerFitted`. **91,47 to 91,49
   are 2x3 trades of a whole row or half of one** -- ten stamps, or five west
   at 23312 and five east at 23437 -- registered by `registerDesign` with
   locations from `place()`. A 91 design with the same furniture contract as an
   88,46 or 88,47 room appends to that room from index 20 rather than
   registering a second one; 91,46 rows 2-3 are shed rooms appended to
   `phun.room.2x3` at 120..139. 88,48 rows 0-1 and 91,46 rows 4-5 are bare
   ground awaiting new designs. Script names below drop `Base.`:

   | room `phun.room.…` | cell, rows | spawn | vehicle |
   |---|---|---|---|
   | `2x3` (shed) | 87,46 all, 91,46 2-3 | 1,1 | `Van`, `VanDeerValley`, `VanJonesFabrication`, `VanMetalheads`, `VanOldMill`, `VanRiversideFabrication`, `VanSeats_Valkyrie`, `Van_BugWipers`, `Van_Locksmith`; and every other van, as overflow |
   | `2x3_bookstore` | 88,46 0-1, 91,49 r0 east | 1,1 | `VanMail` |
   | `2x3_mechanic` | 88,46 2-3, 91,49 r1 | 1,1 | `VanMechanic`, `VanBrewsterHarbin`, `VanKorshunovs`, `VanMobileMechanics`, `VanPlattAuto` |
   | `2x3_weldingstorage` | 88,46 4-5, 91,49 r5 east | 1,0 | `VanMeltingPointMetal`, `VanSchwabSheetMetal`, `Van_MassGenFac` |
   | `2x3_electronicsstorage` | 88,47 0-1, 91,48 r0 | 0,1 | `Van_LectroMax`, `VanPluggedInElectrics`, `Van_VoltMojo` |
   | `2x3_gardeningstorage` | 88,47 2-3, 91,48 r2 | 0,1 | `VanGardener`, `VanGardenGods`, `VanLouisvilleLandscaping`, `VanMooreMechanics`, `VanTreyBaines` |
   | `2x3_policehall` | 88,47 4-5, 91,49 r2 west | 1,0 | none, the SWAT van moved to `3x4_policeswat` |
   | `2x3_medical` | 91,47 r0 | 0,1 | `VanAmbulance`, `90fordF350ambulance`, after the bays (priority 1) |
   | `2x3_bar` | 91,47 r1 west | 0,1 | `Van_Charlemange_Beer`, `Van_KnoxDisti` |
   | `2x3_artstore` | 91,47 r1 east | 1,1 | `Van_CraftSupplies` |
   | `2x3_butcher` | 91,47 r2 west | 0,0 | none |
   | `2x3_blacksmith` | 91,47 r2 east | 1,0 | `Van_Blacksmith` |
   | `2x3_carpentryworkshop` | 91,47 r3 | 0,1 | `VanJohnMcCoy`, `VanMccoy`, `VanMicheles`, `VanRosewoodworking`, `VanWPCarpentry` |
   | `2x3_communications` | 91,47 r4 | 0,1 | `VanKnoxCom`, `VanRadio`, `VanRadio_3N`, `VanUtility` |
   | `2x3_construction` | 91,47 r5 | 1,1 | `VanBeckmans`, `VanBuilder`, `VanCoastToCoast`, `VanKerrHomes`, `VanPennSHam` |
   | `2x3_fossoil` | 91,48 r1 west | 0,1 | `VanFossoil` |
   | `2x3_farmstorage` | 91,48 r1 east | 1,1 | `VanOvoFarm` |
   | `2x3_glassesstore` | 91,48 r3 west | 1,1 | `Van_Glass` |
   | `2x3_gasstore` | 91,48 r3 east | 0,1 | `VanKnobCreekGas` |
   | `2x3_grocers` | 91,48 r4 west | 1,0 | `VanGreenes`, `Van_Perfick_Potato` |
   | `2x3_leatherworkshop` | 91,48 r4 east | 0,1 | `Van_Leather` |
   | `2x3_stripclubvip` | 91,48 r5 | 0,1 | `VanSeats_LadyDelighter`, `VanSeats_Mural`, `VanSeats_Space`, `VanSeats_Trippy`, `Van_Transit` |
   | `2x3_masonrystore` | 91,49 r0 west | 0,1 | `Van_Masonry` |
   | `2x3_plumber` | 91,49 r2 east | 0,1 | `VanUncloggers` |
   | `2x3_prisoncells` | 91,49 r3 west | 1,2 | `VanSeats_Prison` |
   | `2x3_spiffoskitchen` | 91,49 r3 east | 0,0 | `VanSpiffo` |
   | `2x3_empty` | 91,49 r4 | 1,2 | `VanSeats`, `VanSeatsAirportShuttle`, `VanSeats_Creature` |
   | `2x3_tailoringworkshop` | 91,49 r5 west | 0,1 | `Van_HeritageTailors` |
   | `2x4_campingstorage` | 88,48 2-3 | 0,0 | `63Type2Van`, `63Type2VanHippie`, `63Type2VanApocalypse` |
   | `2x4_bank` | 92,46 0-1 | 0,1 | `87fordF700bank` |
   | `4x5_armysurplus` | 92,46 2-3 | 1,1 | `84gageV300apc`, `84gageV300fsv`, `lockMartM577` |
   | `4x4_armytent` | 92,46 4-5 | 1,1 | `86chevyM1010`, `86chevyM1031` |
   | `3x9_armystorage` | 92,47 0-1 | 0,1 | `87fordF700box`, `87fordB700military` |
   | `3x9_prison` | 92,47 2-3 | 0,1 | `87fordB700prison` |
   | `3x9_school` | 92,47 4-5 | 0,1 | `87fordB700school` |
   | `3x6_bedroom` | 92,48 0-1 | 1,1 | `87fordF700box` |
   | `2x3_camping` | 92,49 0-1 | 1,1 | `Trailer87Scamp13` |
   | `3x5_camping` | 92,49 2-3 | 1,1 | `Trailer61Bambi16`, `Trailer87Scamp16` |
   | `3x9_camping` | 92,49 4-5 | 1,1 | `Trailer54FlyingCloud22` |
   | `3x4_barn` | 88,48 4-5 | 1,1 | `Base.Trailer_Livestock`, `Base.Trailer_Horsebox` |
   | `3x9_shed` | 88,49 2-3 | 1,1 | `TrailerM128van` |
   | `3x9_armysurplus` | 88,49 4-5 | 1,1 | `TrailerM129van` |
   | `3x6_armystorage` | 92,48 4-5 | 1,1 | `isoContainer2`, `isoContainer4`, `isoContainer5`, `TrailerM747lowbed` |
   | `3x4_blacksmith` | 89,46 0-1 | 1,1 | `Base.StepVan_Blacksmith` |
   | `3x4_cafeteriakitchen` | 89,46 2-3 | 1,1 | `Base.StepVanAirportCatering`, `Base.StepVan_SouthEasternHosp` |
   | `3x4_captainoffice` | 89,46 4-5 | 1,1 | `Base.StepVanMail` |
   | `3x4_butcher` | 89,47 0-1 | 1,1 | `Base.StepVan_Butchers` |
   | `3x4_grocery` | 89,47 2-3 | 1,1 | `Base.StepVan_Cereal` |
   | `3x4_conveniencestore` | 89,47 4-5 | 1,1 | `Base.StepVan_Citr8`, `Base.StepVan_Zippee` |
   | `3x4_toolstore` | 89,48 0-1 | 1,1 | `Base.StepVan_CompleteRepairShop` |
   | `3x4_florist` | 89,48 2-3 | 1,1 | `Base.StepVan_Florist` |
   | `3x4_beergarden` | 89,48 4-5 | 1,1 | `Base.StepVan_Genuine_Beer` |
   | `3x4_glassmakingworkshop` | 89,49 0-1 | 1,1 | `Base.StepVan_Glass` |
   | `3x4_newspaperprint_herald` | 89,49 2-3 | 1,1 | `Base.StepVan_Heralds` |
   | `3x4_laundry` | 89,49 4-5 | 1,1 | `Base.StepVan_HuangsLaundry` |
   | `3x4_carpentryworkshop` | 90,46 0-1 | 1,1 | `Base.StepVan_Jorgensen` |
   | `3x4_mechanic` | 90,46 2-3 | 1,1 | `Base.StepVan_LouisvilleMotorShop` |
   | `3x4_policeswat` | 90,46 4-5 | 1,1 | `Base.StepVan_LouisvilleSWAT`, `Base.87fordF700swat`, `Base.90fordF350SWAT` |
   | `3x4_masonrystore` | 90,47 0-1 | 1,3 | `Base.StepVan_Masonry` |
   | `3x4_gas2go` | 90,47 2-3 | 1,1 | `Base.StepVan_Plonkies` |
   | `3x4_gasstorage` | 90,47 4-5 | 1,1 | `Base.StepVan_Propane` |
   | `3x4_tableshipping` | 90,48 0-1 | 1,1 | `Base.StepVan_USL` |
   | `3x4_paintershop` | 90,48 2-3 | 1,1 | `Base.StepVan_SouthEasternPaint` |
   | `3x4_tailoringstore` | 90,48 4-5 | 1,1 | `Base.StepVan_SmartKut` |
   | `3x4_catfish_dining` | 90,49 0-1 | 1,1 | `Base.StepVan_MarineBites` |
   | `3x4_bookstore` | 90,49 2-3 | 1,1 | `Base.StepVan_MobileLibrary` |
   | `3x4_greenhouse` | 90,49 4-5 | 1,1 | `Base.StepVan_RandisPlants` |
   | `3x4_bar` | 91,46 0-1 | 1,1 | `Base.StepVan_Scarlet` |

   **Every `Van*` and `StepVan*` also overflows into the shed.** The
   `phun.van` binding's matcher claims them all, and a matcher sorts last, so
   each drains its own rooms first. `NOT_VANS` in `defaults.lua` keeps
   `VanMetalworker` and `VanCarpenter` out of that: they are trucks in all but
   name and get no room until a truck room exists. `StepVan_Mechanic` is the
   one vanilla van with nothing but the overflow.

   `2x4_campingstorage` is the one room whose door is not in the north wall:
   a double door in the west wall at 0,1 and 0,2, so it lands `west`. It is
   registered and unbound for want of a camper; the 63Type2Van mod is three.

   The 89,46 to 91,46 rooms carry a doorless opening in the south wall at 1,4,
   like the ambulance bays, and land `south = "cab"`. 89,46 to 89,49 were the
   whole plain 3x4 and 3x13 tiers, so neither `phun.room.3x4` nor
   `phun.room.3x13` is registered any more -- `registerTier` skips a variant
   passed as nil -- and only their barrel rooms remain. 90,46 and 90,47
   were the 3x4 barrel cells, so the 3x4 tier is gone entirely and
   `registerTier` is no longer called for it. 90,48 and 90,49 were the 3x13
   barrel cells, so the 3x13 tier is gone too. 91,46 and 91,47 were the plain
   3x6 cells and 92,46 and 92,47 the barrel ones, so the 3x6 tier is gone as
   well -- 92,48's `3x6_bedroom` has that floor by coincidence, not as a
   survivor of it.

   **No tier is registered any more.** 3x9 was the last and it was PHANTOM
   rather than merely retired: 87,49 has been emptied -- its lotheader reports
   zero room defs -- so all sixty of its slots pointed at open ground, and
   87,48 was reworked, rows 0-1 into the tent rooms and rows 2-5 a square west
   and north into a partitioned bedroom/kitchen/bathroom design that is **not
   registered yet**. `roomcheck.pl` reports those 1200 squares as orphans and
   that is the one outstanding failure on the map. Nothing bound to
   `phun.room.3x9`, so removing it cost no capacity; leaving it registered
   would have overlapped the tent rooms, which is two leases over one piece of
   ground. The superseded description follows.

   **The only tier still registered was 3x9**, in 87,48 and 87,49 -- and only
   its plain variant: 88,49 has been rebuilt as two fitted rooms, so
   `phun.room.3x9_barrels` has no stamps left at all and is not registered.
   There is no barrel room anywhere on the map now.

   **92,46 to 92,49 are the mod rooms**, ten stamps of two rows each at origin
   23568, reworked like the 88..91 cells but shelled in a truck body:
   `industry_trucks_01_*` walls on an `industry_railroad_05_39` metal floor.
   Three things there are new to the map, and each one is a way out that
   `roomcheck.pl` cannot see:

   - **`4x5_armysurplus` has no door at all.** Its way out is a window in the
     north wall at offset 3 and another in the south wall line at offset 0,
     both `industry_trucks_01_13`, which is `WindowN`. The declared landings
     are what tell `roomcheck.pl` there is a way out. **Nothing has confirmed
     in game that a tenant can actually climb one**, and if they cannot the
     room is a soft-lock.
   - **`3x6_bedroom`'s north wall is a garage door** across all three squares
     (`walls_garage_01_51` to `_53`, which carry `doorN`). Not a
     `fixtures_doors_*` sprite, so again the landing is the assertion.
   - **`3x9_prison` is the one room with no cab landing.** All three 3x9
     designs have a north door at 1,0, an east door at 2,8 and a doorless
     south opening at offset 1; in the prison that last row is a rect of its
     own behind `location_community_police_01_*` bars whose door is
     `forceLocked`, and its east door, `fixtures_doors_01_32`, is `forceLocked`
     too. Both of those exits are on the wrong side of a locked gate, so only
     the north door works and naming them would declare a way out that is not
     one.

   The east door of `3x9_armystorage` and `3x9_school` is deliberately left
   unnamed, so it lands the tenant beside the vehicle: none of these trucks
   declares an area meaning "the side". Those four mods all declare
   `TruckBed`, so the north landing resolves for every one of them.

   **`lockMartM577` is the one bound vehicle that declares no `TruckBed`.**
   Its areas are `Engine`, `ToolboxLeft`/`Right`, the seats, `GasTank` and the
   tires, so `4x5_armysurplus`'s north landing does not resolve for it and its
   tenant comes out at the nearest door. That is the landing being a
   preference rather than a position, working as designed, and it is only
   worth recording because it is the first time on this map that a *bound*
   vehicle has missed a landing the room declares. The south `cab` still
   works: fifteen seats.

   **88,49 is the two army trailer rooms**, reworked out of the 3x9 barrel
   cell to origin 22544 -- a square WEST of the 22545 the barrels stood on,
   the same shift every reworked cell has made. Rows 0-1 are bare, rows 2-3
   are `3x9_shed` and rows 4-5 `3x9_armysurplus`. Two more ways out
   `roomcheck.pl` cannot see, which makes five on this map:

   - **`3x9_shed`'s north wall is a garage door** across all three squares, as
     `3x6_bedroom`'s is.
   - **`3x9_armysurplus`'s door is a pizza restaurant's.** The north wall at
     1,0 is `location_military_tent_01_11`, a `DoorWallN` opening, and the
     door standing in it is `location_restaurant_pizzawhirled_01_61`, which
     carries `Material=Door` and `doorN`. A real working door, just not a
     `fixtures_doors_*` sprite -- so once again the landing is the assertion.

   **92,48 rows 4-5 are a second `armystorage`**, a 3x6 where 92,47's is a
   3x9. Same def, so the same loot; different shape, so a different contract
   and a different room. Garage door north, like the bedroom above it. Rows
   2-3 are still bare.

   **92,49 is the camper cell**, and its three designs are the first rooms on
   the map whose way out is EAST -- a side door, which is where a caravan's
   door is. All three land `east = "TruckBed"` and none declares a cab. The
   doors are `fixtures_doors_01_20` at 2,0 (2x3) and 3,0 (3x5) and
   `fixtures_doors_01_60` at 3,1 (3x9), all read out of the lotpack and
   regular across all sixty stamps.

   `3x9_camping` is the one stamp on the map that is more than one room def.
   The editor split it three ways -- a 3x3 galley plus the 1x2 corridor beside
   the bathroom, a 2x2 bathroom, and a 3x4 bedroom -- all three named
   `camping`, with `fixtures_doors_01_4` and `_5` between them. Those internal
   doors are **inside** the box and mean nothing to the leash: an internal door
   is not a way out, and one stamp being three defs does not make it three
   slots. Nothing in the lua reads a def, so only `roomcheck.pl` sees the
   split, and it counts all three as interior because the shell test it does
   apply -- ring of rects, or a 1x1 box -- is only ever reached for a def named
   `empty`.

   All three designs use room def `camping`, which is a vanilla distribution
   room and is a camping **store**: counter, shelves, fridge, clothingrack and a
   catch-all `other`, so every fitting in a camper rolls tents, sleeping bags
   and backpacks. Vanilla has no def for a lived-in caravan -- no `caravan`,
   `trailer` or `motorhome` -- so this is the nearest that exists.

   **The mods spell their scripts inconsistently and the bindings follow the
   scripts, not the names.** The school and prison buses are `87fordB700*`
   while the box and bank trucks on the same chassis are `87fordF700*`, and
   there is no plain `84gageV300` -- the mod ships `84gageV300apc` and
   `84gageV300fsv`. None of these names starts with `Van` or `StepVan`, so the
   `phun.van` matcher does not claim them: each reaches its own twenty slots
   and is refused once they are taken, as the animal trailers are. Five of them
   share a room rather than having one of their own: `87fordF700swat` and
   `90fordF350SWAT` join the SWAT step van in `3x4_policeswat`,
   `90fordF350ambulance` joins the vanilla ambulance in the bays and the
   medical 2x3s, `87fordB700military` joins the box truck in
   `3x9_armystorage`, and `lockMartM577` joins the V300s in
   `4x5_armysurplus`. Unbound so far: `63Type2VanMilitary`, the rest of the
   CUCV family, and the tankers and the stake trailer of the M911 and
   isoContainers mods (`82oshkoshM911`, `82oshkoshM911B`, `TrailerM127stake`,
   `TrailerM967tanker`, `isoContainer3tanker`) -- a tanker has no cargo space
   to put a room in. 88,49 rows 0-1 and 92,48 rows 2-3 are the bare ground
   left for them.

   `3x4_bookstore` used to be 89,46 rows 4-5, now `3x4_captainoffice`, and the
   id was reused for 90,49's bookstore. That broke the "an id is what a lease
   persists" rule on purpose, and only because nothing has shipped.

   **The room def name picks the loot, and a def vanilla does not know gets
   none.** This cost two rooms. 92,47 rows 4-5 were named `school` and 92,46
   rows 0-1 `bank`, and neither is in `Distributions.lua`. An unknown name
   does fall back to the `all` room -- `ItemPickerJava.fillContainerInternal`
   -- but `all` is not a generic loot table, it has holes, and `all.locker` is
   one: `rolls = 1`, no items, no procList. Both rooms' only containers were
   lockers (the bank's chest is `furniture_storage_02_29`, `container=locker`)
   so both spawned **nothing whatever**, reported in game and confirmed
   against the lotpacks. They are now `elementaryschool` and `jewelrystorage`,
   which is a map-editor rename and not a lua change -- a room *id* is what a
   lease persists and does not follow the def.

   Two non-vanilla defs remain and both are survivable: `grocers` (vanilla's
   is `grocery`) loses its smallcrates, since `smallcrate` has no `all` entry,
   and keeps its grocerstand and smallbox; `plumber` is fine because
   `all.metal_shelves` is populated.

   Do not assume a plausible def name is a real one, and do not assume the
   `all` fallback covers a container type -- check both. B42 room entries are
   mostly `procedural = true` with a `procList`, so grepping for an `items`
   list under a room finds nothing and reads as "empty" when it is not.

   89,46 rows 4-5 and 90,48 rows 0-1 are both `poststorage`
   now, for the mail step van and the USL parcel van; their ids stay
   `3x4_captainoffice` and `3x4_tableshipping`.

   Each is its own contract because **the
   furniture decides the spawn square**: a `solid`/`solidtrans` tile on it
   drops a tenant inside a locker. Each spawn was checked against the tile
   properties in `newtiledefinitions.tiles`, and a door square is an accepted
   spawn where the furniture leaves nothing else. Furnishing a room is
   therefore a registry change, not just decor: re-check the spawn square
   after moving furniture.

   Every def in these cells is a vanilla `Distributions.lua` room -- 88,47's
   were renamed to `gardenstore` and `policeswat`. The room *ids* were deliberately not renamed to follow: an id
   is what a lease persists.

   88,46 and 88,47 were the 2x3 roof-platform rooms, so `phun.room.2x3_barrels`
   is gone. 88,48 and 88,49 were the two 3x9 roof-platform cells and both have been
   reworked, so `phun.room.3x9_barrels` is gone entirely -- `registerTier`
   takes a nil `barrels` and skips it. `phun.trailer.animal` is
   back, bound to the barns, without the sandbox option it used to have.

   **The pre-rework 88,46 was not where the arithmetic said**, found by
   `roomcheck.pl` rather than by reading code: it started at 22545 where 88,47
   starts at 22546, and its index 39 sat a square south of its row. Registering
   on the grid put the leash a square off every room, which reads in game as
   the leash being broken. `stamps()` keeps its `fixups` table for the next
   one. Do not tidy an inset into shared arithmetic — re-read the map with
   `roomcheck.pl` whenever it moves.

   **The 2x3 tier's door is two squares wide** (`fixtures_doors_02_49` and
   `_53`, offsets 0 and 1) in all four of its cells, so that tier registers two
   exits and the other four register one (`fixtures_doors_01_61` at offset 1,
   confirmed in all sixteen of their cells). Listing one exit for a two-square
   door made half a visible door do nothing.

   **The grid has moved once already and it renumbered every slot.** It was a
   10 x 5 at 22540,11779 / 22283,11779 with a pitch of 43 down; the map was
   shifted south and east and a sixth row added. Because `locations` is row
   major from the north-west and the slot index is what a lease persists, a
   row added at the north end re-points every existing lease at somebody
   else's room. That cost nothing this time — the reshaped registry has never
   run in game, so there are no leases — but a future row belongs at the
   *south*, where it appends indexes instead of shifting them.

   Two rooms, and now for two reasons: 88,46 carries a roof at z=1 (360
   ceiling squares, six per room) and a solid north wall, while 87,46 has no
   roof and a double door in the north wall (`fixtures_doors_02_49` and `_53`
   on a `fixtures_doors_frames_01_1` frame). Either difference alone is
   enough: under the room model, two designs that differ in any way are two
   registrations, and that is what lets one blueprint serve every stamp. The
   roof is where the rain barrels go when plumbing lands; it has **nothing to
   do with power**. Both cells hold 60 generators at the identical offset,
   `{x = 0, y = 17, z = 0}`, on exterior squares — read out of the lotpack
   with `Docs/tiles.pl`, not guessed. An
   earlier revision of this file had `phun.van.plain` marked as unpowered
   on the theory that the z=1 platform was the generator's home; it was not.

   `spawn` and `size` are **confirmed against the shipped cells**, out of the
   lotpack rather than by standing in a room. The north-west room of 88,46 is
   floor at x 22545-22546, y 11783-11785 (the 2x3 the map records), a wall
   column at x 22547, a wall row at y 11786 and a corner at 22547,11786 — so
   the footprint is 3 x 4 and `size = {w = 3, h = 4}` is right.

   The north and west walls sit **on** the floor squares rather than outside
   them, which is how PZ draws those two edges — so row y = 0 is inside the
   room and is the doorway. `spawn = {1,1}` is the square directly south of it,
   which is why walking one step north takes you out: that row is the door, not
   a wall. It is a design call rather than a defect, but it is the thing that
   reads as the leash misfiring, so it is worth knowing before debugging one.

   Everything under `common/media/maps/phuninteriors/` is **tracked**. It was
   gitignored while the map was borrowed; it is ours now and the rooms do not
   exist without it, so a fresh clone has to get a working map. It is binary
   and `core.autocrlf` is on for this checkout, hence `.gitattributes`.
   `deploy.cmd` no longer strips `media\maps` from the Workshop staging trees
   — a build that drops them is a mod with no rooms.

   **A map folder needs a `map.info` or the game never registers it.** Every
   mod map on the Workshop ships one next to the lotpacks. Without it the cell
   silently never loads and it reads as "my coordinates are wrong" — which is
   exactly how it presented, because the coordinates *were* also wrong.
   Symptoms are indistinguishable; check the file exists first.

   **Its contents matter as much as its presence, and the map editor rewrites
   it.** A re-export left it holding nothing but `title=`, and two lines have
   to be put back every time:

   ```
   title=phuninteriors
   lots=Muldraugh, KY
   fixed2x=true
   description=Instanced vehicle interiors
   ```

   `lots=` is the one that decides whether the map loads at all.
   `ChooseGameInfo.getMapDetails` accumulates every `lots=` line into
   `Map.lotsDir`; `MapGroups.getDirsRecursively` walks that chain transitively
   and `findGroupWithAnyOfTheseDirectories` puts maps sharing a directory into
   one world. A map naming nobody has a set of just itself, so it forms **its
   own group** — a separate selectable world whose cells never load beside
   vanilla. Every vanilla map except the root `Muldraugh, KY` carries the line,
   and so does every Workshop map checked. Note the grouping identity is the
   **directory name**, not `title=`, which is cosmetic.

   `fixed2x=true` reaches `LotHeader.fixed2x` via `MapFiles.createLotHeader`,
   and `IsoChunk.Fix2x` returns its input unchanged **only** when that is set —
   otherwise every tile goes through the B41 to B42 tiledef remap. None of this
   map's palette names are in that table, so the practical effect today looks
   like nil, but every vanilla and Workshop map sets it and it costs a line.

   Room geometry is constrained by the generator, and the constraints are
   tighter than they look. `GeneratorTileRange` is a **sandbox option**
   defaulting to 20, and it is a Euclidean **radius** (`isPoweringSquare` is
   `DistanceToSquared <= r*r`), with `GeneratorVerticalPowerRange` at 3.
   - Power needs every room tile within 20 of the generator. With the generator
     centred on the room in x, that is `(W/2)² + (D + s)² <= 400` for a room
     `W` wide and `D` deep with the generator `s` south of it. Note depth does
     not enter into the *north* corner, so one rule covers every length: keep
     the generator within 19 of the room's north edge.
   - Isolation needs the generator to reach no tile of the neighbouring room:
     `P - W/2 > 20`. This is the one that bites, because a long room reaches
     south toward the generator row and gets caught almost broadside — 20 wide
     footprints edge to edge put the neighbour at `sqrt(18² + 5²)` = 18.7, well
     inside. **24 is the working pitch** for rooms up to 5x15; it is also 3
     chunks, and 256/24 gives 10 per cell against 9 for 26.
   - Overlapping generators are not just free power: `setSurroundingElectricity`
     clears and re-accumulates `totalPowerUsing` per generator, so an appliance
     inside two circles is billed to **both** tanks.
   - The generator hum (`GeneratorLoop`) has `distanceMax = 100`, so it cannot
     be separated from the power by distance. In practice it is reportedly
     inaudible at range; `distanceMax` is the cutoff, not the audible radius,
     and the rolloff curve is in the FMOD bank where it cannot be read.
2. **Icon and poster are done.** `icon.png` and `poster.png` both ship, and
   `Tests/root/PhunInteriors/common/` carries its own pair for the test id.
   GIMP sources are in `Docs/images/` and are deliberately untracked.
3. **`workshop.txt` has an empty `id=`.** Fill on first publish.
4. **The registry is fully populated.** `defaults.lua` registers 83 rooms, 80
   vehicle bindings and one object binding, generated by `Docs/gendefaults.pl`
   from the three CSVs. There is no `phun.van` binding any more -- every
   binding is `phun.vehicles.*` and the matcher is gone, so the sandbox
   script-override option that named it has been removed too. The mechanism
   itself (`Core.applySandboxScriptOverrides`, keyed on binding id) is live and
   unused; a server wanting it back declares an option per binding it cares
   about.
5. **The reshaped registry has never run in game.** Rooms, bindings, per-slot
   blueprint capture and the nullable generator are all
   covered by `Tests/lua/` — 552 checks, all green — which is real verification
   of the logic and no verification at all that PZ agrees. In particular:
   - **Capture is now load bearing and has never succeeded on this map.** The
     `bounds.z + 1` sweep used to count a nil square above the room as a
     failed read, which refused every capture on both cells — see "Only the
     room's own level has to read completely". That is fixed but unproven;
     the 30-second test is to open the admin room list, port into a slot and
     read its Captured column — or run `PhunInteriors.admin("manifests")`.
   - Nothing ships a blueprint any more, so a slot whose capture fails falls
     through to a sibling. That path exists and is tested against stubs, but
     it has never been reached in game.
   - Nothing about the assignment ordering has been seen with two vehicle
     bindings and overlapping rooms on a server.
6. **The admin room list has never run in game.** `client_rooms.lua`,
   `client_admin.lua`, `Transit.adminEnter` and `Slots.acquireIn` are new. The
   allocation half is covered by `Tests/lua/slots_spec.lua` and the reverse
   index by `registry_spec.lua`; the window is not covered by anything, because
   none of it is reachable without a running game.

   The parts most likely to be wrong are the ones the specs cannot see: whether
   the room state payload survives `sendServerCommand` on a dedicated server at
   960 slots, and whether `ISAdminPanelUI`'s end-of-create grid layout still
   places our button now that a second mod may also be adding one. Both are
   visible immediately — an empty list, or a button in the wrong place.

   The payload half has since been **halved on purpose**: the list carries room
   summaries and bindings, and a room's slots are fetched when its row is
   selected. That is the change most likely to have fixed the thing this entry
   was worried about, and it is also the change most likely to have introduced
   a new one — a Slots tab that stays empty means the `roomSlots` round trip is
   not completing.

7. **Releasing a removed vehicle's room has never run in game.** `removal.lua`
   and its client half in `client_tracker.lua` are new, and
   `Tests/lua/removal_spec.lua` covers the logic: release on the flag changing
   and not on its value, tenants put out first, and the room kept when one
   cannot be. What the specs cannot see:
   - **Where `ISRemoveBurntVehicle:complete()` runs in MP.** It has a
     `serverStart`, which is B42's server side action shape, so the wrap is
     server side. If it turns out to run on the client, a dedicated server
     never sees it and a scrapped wreck's room stays leased until a full pool
     reclaims it — silently.
     Scrap a leased wreck on a dedicated server and look for `released the
     room leased to ... vehicle scrapped` in the log.
   - **Whether our warning reaches the server ahead of `VehicleCommands.remove`.**
     Both leave the same client in order, so it should; if the log shows
     `watched ... and it was not removed` after an admin removal, it did not.
8. **Reclaiming on demand has never run in game.** `Slots.acquire`'s reclaim
   fallback, `Slots.oldestReclaimable`, `admin("reclaim")` and the
   `RoomReclaimed` notice are new; `slots_spec.lua` covers the ordering, the
   protection, occupied rooms, free-before-reclaim and ties, and each of those
   checks was confirmed to fail against a deliberately broken copy. What it
   cannot see:
   - **The notice.** It rides `consts.leasedKey` in vehicle modData, the same
     persistence the lease UUID already proves on a dedicated server, so it
     should survive a restart. To see it: enter a van, leave, `age` its lease,
     `reclaim`, and enter again.
   - **The sandbox option was renamed** from `LeaseDays` to
     `RoomProtectedDays` and `LeaseWarningDays` was removed. A server that set
     the old one silently gets the default of 14. Nothing has shipped, so that
     costs nobody anything yet.
9. **The safehouse guard has never met a real claim.** `Slots.safehouseOn`
   is covered in `slots_spec.lua` against a stand-in that mirrors the
   disassembled overlap test, edges included, and every guard was confirmed to
   fail when removed. What only the game can say:
   - **Whether a room can be claimed at all.** Vanilla claims a *building*,
     and each stamp is a room def wrapped in an `emptyoutside` shell def. An
     `emptyoutside` def is kept out of `BuildingDef.rooms`, so the building is
     the interior room alone and the shell does not enlarge its box -- which
     also makes it less likely a claim reaches a neighbouring slot. If the
     claim rectangle is the building's bounding box it should cover the slot;
     if claiming is refused for these rooms the guard simply never fires.
   - **Whether the claim rectangle reaches a neighbouring slot.** Stamps are 25
     apart across and 42 down, so a building box around one 7x7 shell should
     not; `admin("list")` names a claim on every lease it touches, which is the
     quick way to see.
   - **A claim makes a room permanent** for as long as it stands. That is the
     intent, and vanilla's one-safehouse-per-player rule and inactivity removal
     are what bound it -- worth confirming both apply to these rooms.

10. **The rain reservoir has never run in game**, and neither has the scrub
    since it stopped demanding squares above the room. The spec covers where
    barrels go and the opt out; everything that touches a square does not.
    In rough order of risk:
    - **Whether the map's barrels are working collectors at all.** Map-loaded
      `carpentry_02_122` may be a plain `IsoObject`. Port into a `_barrels`
      room and check a roof barrel for fluid. The kit refuses those rooms
      either way.
    - **`addWorkstationEntity` from our code**, and whether our modData tag
      survives a save and reload -- if it does not, the next capture of that
      slot records the barrels and they become permanent.
    - **The scrub removing a tagged barrel** with `transmitRemoveItemFromSquare`
      plus `RemoveTileObject`, the pair vanilla's lid toggle uses, and whether
      that unregisters the entity cleanly.
    - **The kit being spent over the wire**: `sendRemoveItemFromContainer`
      from a command handler rather than from a timed action's `complete()`.
    - **The item script and recipe** parse, the kit shows its name, and the
      recipe appears under Carpentry at Woodwork 5.
    - **A sink in the room plumbing to a barrel.** Vanilla also requires the
      sink's square to be `isInARoom()`, which ours are.
    - **Weight does not count the water.** `weight.lua` charges a barrel's own
      moveable weight but reads `ItemContainer`s, and water is in a
      `FluidContainer`. Whether it should is undecided.

11. **World-object holders are built but have never run in game, and one
    decision is still open.** A tent can be bound, leased, entered and left;
    `Tests/lua/holders_spec.lua` covers the binding, the specificity it
    contributes, the holder-kind prefixes, the sprite-grid anchoring and where
    the id is stored, and the storage checks were confirmed to fail against a
    deliberately broken copy. None of it has been in front of the game.

    What landed: `shared/PhunInteriors/holders.lua` (identity, the moveable
    item read, anchoring), `Core.registerObjects` with an `itemLookup` folded
    into the existing specificity sort, `Transit.enterObject`, the
    `enterObject` command, and a context-menu option. `Slots.acquire` goes
    through `Core.roomsForHolder` and no longer assumes a vehicle.

    Two things changed underneath, and both are worth knowing before reading
    that code:
    - The occupancy field `adminPort` is now **`noVehicle`**. Five sites read
      it, all testing the same fact, and it stopped being about admins the
      moment a tent could hold a lease.
    - Bindings carry a **`kind`**, set by which register call made them, and it
      is what decides who a `match` predicate is shown. That fixed a latent
      bug in the *vehicle* path: `roomsForVehicle` used to run every binding's
      matcher, so an object predicate written to read a sprite would have been
      handed a `BaseVehicle`. It cannot be inferred from the lists, because a
      binding that is nothing but a matcher names neither scripts nor items and
      that is a legitimate shape -- `phun.van` is one.

    **The pickup refusal is now built**, and it is the answer to the question
    the API row above forces: the id cannot survive a pickup, so the lease must
    not depend on it, so the tent must refuse to be picked up. None of it has
    run in game either.
    - **Two checks, not one**, and `Slots.lockReason` returns which. Occupied
      is measured live and is unconditional -- picking up a tent with a tenant
      inside strands them on bare ground whether or not the room holds
      anything, so it is not about belongings at all. Contents is a stored
      fact and is the second, separate test. Occupied outranks it.
    - **"Contains anything" is banked, not measured.** At pickup the tent is
      loaded and the room is not, which is the same split that killed
      scrub-on-release. So it is banked on exit, where the room is loaded
      because the tenant is standing in it. The value is exact rather than
      stale: nobody can add to a room without being inside it, so a room's
      contents cannot change while nobody is there to change them.
    - **It counts all three categories** -- loose floor items, container
      contents, and objects the tenant brought in -- which is the question that
      was open. A floor pile is real storage in this game, and the alternative
      reading, "leavings a scrub would remove anyway", means packing a tent
      silently bins it. So one dropped rag refuses a pickup until the tenant
      sweeps, which is friction the player can see and undo, and nothing is
      ever lost without being asked.
    - **One walk, two numbers.** `Weight.ofSlot` became `Weight.surveySlot`,
      returning weight and count, with `ofSlot` a wrapper. Sharing the walk is
      the point rather than a saving: "what a scrub takes" and "what the tenant
      is charged for" have to be the same set, and two walks would drift.
      `Transit.leave` now surveys for EVERY holder, where the weight half used
      to be skipped when there was no vehicle to charge.
    - **The client half is a copy of the server's answer**, in the object's
      `movableData` beside the id, because `canPickUpMoveable` answers
      synchronously and a client does not know whose lease is whose. Stamped by
      `Transit.enterObject` on the way in and by `Transit.refreshHolderLock` on
      the way back out -- which is why a world object exit now files a small
      piece of arrival paperwork where it used to file none, the tent being
      loaded again only once the tenant is standing on it. The guard is
      `ISMoveableSpriteProps.canPickUpMoveable`, one choke point covering both
      the cursor and the menu, and it mirrors vanilla's movables-cheat escape
      so an admin is never stuck behind a stale flag.
    - **A stale flag heals rather than being chased.** `Slots.release` clears
      it when the object happens to be loaded, which a reclaim's usually is
      not -- nobody has been near that room for days. Walking into the tent and
      back out re-asserts the lock against a fresh room, which for an empty one
      means clearing it.

    And the cost, which is real and was accepted rather than overlooked:
    storing things in the room is the point of the feature, so "leased and
    non-empty" is most tents most of the time. Moving camp means emptying the
    room first. Defensible -- a tent is a thing you pack -- but it is friction
    in the common case rather than the rare one.

    **What the specs cannot see, and what to watch for in game:**
    - **The tally itself.** `Weight.surveySlot` needs real squares, so the
      counting is not covered by anything -- only `Slots.lockReason`'s use of
      the number is. A miscount reads as a tent that will not pack when it
      looks empty.
    - **Whether a tent's `movableData` write reaches other clients.** The id
      write proves persistence in single player; nothing has proved the
      transmit on a dedicated server.
    - **The guard under the moveable cursor**, which asks
      `canPickUpMoveable` once per frame. The refusal is silent by design and
      the note is throttled to one every three seconds.
    - **A reclaimed tent tells nobody.** `consts.leasedKey` and the
      `RoomReclaimed` notice are stamped on vehicles only, so a tent whose
      room is reclaimed loses its contents with no message. The vehicle path
      has an answer and this does not yet.

    **Two bugs found on the way, stacked**, and neither had anything to do
    with pickups. Together they meant a tent could not be given a room
    anywhere, reported in game as "this vehicle has no interior" about a tent.
    - `registerRoom` normalised `requires` to `{}`, so `Core.roomAllows`'s
      `not room.requires` guard was false for **every** room and never short
      circuited. Every non-vehicle holder then fell into the branch below and
      was refused as an author error. It became `Core.tools.isEmpty`.
    - And underneath that, every one of the 70 shipped rooms declared
      `requires = {trunk = true}`, which a tent can never satisfy. Fixing the
      first bug alone changed nothing. `requires` was then put only to
      vehicles, so the Scamp trailer was still asked for its cargo space and a
      tent was not.

    **Both are moot now: `requires` and `Core.roomAllows` have been removed
    outright** -- see "A room states nothing about what may carry it" in
    Architecture. Kept here because the shape of the failure is the lesson,
    and it is the reason the field went rather than being patched a third time.

    Nothing caught either because no spec had called `Slots.acquire` with an
    object holder until one did. `registry_spec.lua` covers both now, and its
    vehicle fakes had to grow a `getScript` to stay vehicles.

    **And a third, found only by running it: the guard mirrored vanilla's
    movables-cheat bypass, which is a tickbox in the same admin power panel as
    noclip.** So the first in-game test ran with the guard silently disabled
    and the tent came up as though nothing had been built. The bypass is gone.
    Vanilla's cheat skips *requirements* -- skill, tool, carry weight -- and
    this is not one: picking the tent up orphans a lease and destroys a
    tenant's belongings, and that is as true for an admin as for anybody. An
    admin who wants the tent back uses Release in the room list, which drops
    the lease and clears the lock properly.

    The standing lesson is about testing rather than about moveables: **a guard
    that exempts admins cannot be tested by an admin**, and every person who
    will test this mod is one.

    **Tents have their own room now**: `phun.room.2x3_tent`, cell 87,48 rows
    0-1, twenty slots, floor corner 22288,12294 read out of the lotpack. It is
    the first room on the map that stated no `requires`, back when every other
    one demanded a trunk -- a tent has no cargo space and no battery to be
    asked about. The field has since been removed outright, so that is no
    longer what distinguishes it; its own binding is.
    Its room def on the map is `empty`, a real vanilla distribution room that
    spawns no loot, which is right for a tent: what is in it should be what its
    owner put there. They used to point at `phun.room.2x3_camping` and share
    the Scamp trailer's twenty slots.

12. **The registry editor has never run in game, and none of it is reachable
    without one.** `shared/PhunInteriors/{overrides,json}.lua`,
    `server/PhunInteriors/store.lua`, the `editRoom` / `editBinding` /
    `roomSlots` commands and the whole of `client/PhunInteriors/ui/` are new.
    The logic underneath is covered — `overrides_spec.lua` is 87 checks,
    `store_spec.lua` 49 and `admin_spec.lua` 24, and the load-bearing ones were
    confirmed to fail against deliberately broken copies — which is real
    verification of the patch model and none at all that PZ agrees.

    In rough order of risk:
    - **Whether `getFileReader` / `getFileWriter` resolve where expected on a
      dedicated server.** They are server side by design, so the file is the
      server's; if it lands somewhere else, Save reports success and the
      customisations do not come back. Look for `PhunInteriors.json` next to
      the PhunMart files.
    - **Whether `removeSlots` and the rest survive `sendClientCommand`.** The
      wire spelling exists because a `false` table value may not; if a delete
      reports success and the slot is still there, that is the one.
    - **The vendored panels.** `form_panel` and `list_panel` came from
      PhunMart2 with the namespace changed, and neither has been drawn once in
      this mod. A form that opens blank or a list with no rows is a hook that
      did not survive the port — `Core.isShippedKey` and the
      `Core.references` stub in `ui/state.lua` are the two most likely.
    - **`setSections` taking `section` and not `key`.** A descriptor keyed the
      wrong way matches nothing and hides every field behind tabs that do
      nothing. It is written correctly; it is worth knowing as the symptom.
    - **Anything reading a form.** `FormPanel` passes the FORM to `onApply`,
      not a values table, and getting that wrong drops every field silently
      while the numeric ones keep working. It has happened once and cost the
      label, front, cab, selfPowered and reservoir fields on the room form and
      the kind field on the binding form. If an edit appears to do nothing,
      check that before anything else.
    - **The Slots tab's two dropdowns**, which nothing can test: they are
      client UI, and the specs cannot load a file that needs `ISComboBox`.
      Two things to watch. `ISComboBox:clear()` empties the options and
      deliberately does **not** reset `selected`, so narrowing 81 rooms to one
      can leave it pointing at row 40 of a one-row list —
      `rebuildPickers` sets `selected` on every path for that reason, and the
      symptom if it is wrong is a dropdown that draws blank or the wrong name.
      And the refresh path fetches from inside the same event the fetch
      answers, so a room whose detail never arrives would re-request on every
      tick; it converges because `showRoom` only dispatches when the detail is
      missing, but that is the loop to look for if the tab pegs a core.
    - **Editing a room somebody is standing in.** Nothing refuses it, and it is
      not obviously wrong — moving a stamp under a live tenant leaves the leash
      containing them against a box that is somewhere else, and the leash will
      eject them home, which is the designed behaviour for being out of bounds.
      Unverified. Deleting a *leased* slot is refused outright.
    - **`roomcheck.pl` does not know about the file.** It loads `defaults.lua`
      under the stubs and compares that to the lotpacks, so a stamp moved in
      the editor is invisible to it. An edit that moves geometry should be
      folded back into the CSVs; the file is for testing and for a server admin
      re-pointing a binding, not a substitute for the map pipeline.

13. **The entrance position has never run in game.** `Transit.entranceOf`,
    `fallbackReturn` and `rescueStranded`, the write inside `setOccupancy` and
    the capture in `placeInside` are all new. `entrance_spec.lua` is 23 checks
    and the load-bearing four were each confirmed to fail against a
    deliberately broken copy: writing the entrance on every `setOccupancy`
    rather than only when one is carried, dropping the staleness guard, never
    clearing on exit, and logging per call instead of per visit.

    What the specs cannot see:
    - **Whether a server-side write to player modData is actually persisted on
      a dedicated server.** Settled from the jar rather than in game:
      `IsoPlayer.save` -> `IsoLivingCharacter.save` -> `IsoGameCharacter.save`
      -> `IsoMovingObject.save`, which writes `IsoMovingObject.table` -- the
      modData KahluaTable -- with an is-empty flag byte ahead of it. Vanilla
      keeps per-player state there and transmits it (`ISWidgetTitleHeader.lua`
      :518-519, `ISHotbar.lua:676`, `LastStandSetup.lua:79`). Nothing
      transmits ours, deliberately: only the server reads it. If it turns out
      the client's copy wins on a dedicated server, the entrance would come
      back empty after a rejoin and the fallback would silently never fire.
    - **`Transit.rescueStranded` on login**, which is the whole reason for the
      feature and is reachable in about a minute: enter a room, log off,
      `PhunInteriors.admin("age", {vehicleId = ..., days = 99})` then
      `admin("reclaim")`, log back in. It should say `logged in inside ...
      with no lease on it` and put you back where you went in.
    - **Whether the square is still somewhere a player can stand.**
      `isValidSquare` catches coordinates this world does not have and nothing
      else; a wall built on the spot since is not detectable server side with
      the chunk unloaded. Accepted, because the alternative it replaces is a
      tenant who cannot leave at all.
    - **The cab bounce re-capturing an entrance.** `placeInside` is the capture
      point, and `Transit.arrived` calls it when a cab exit finds every seat
      taken, so a bounced player's entrance becomes the kerb beside the van.
      That is correct rather than incidental -- it is where they went back in
      from -- but nothing has watched it happen.

## v2, deliberately not in v1

The siege/breach system, a fuel penalty for load, and the purpose-built map.
The water barrel was on this list and has been pulled forward as the rain
reservoir.

Power binding was on this list and has been pulled forward -- see Architecture.
It moved because the hooks it needed already existed for weight and blueprint
capture, so it cost far less than the v2 label implied.

**Interiors for things that are not vehicles** are sketched and probed, not
built. The seam already exists: a lease key is a string, and `admin:<username>`
proves a non-vehicle holder works. So the work is turning the three
`Core.isAdminLease` sites into a dispatch on holder kind, answering four
questions -- which rooms, where you come back out, what settles the power debt,
what carries the weight. The leash, scrub, capture, quarantine, reclaim and
safehouse guard never see a holder at all and need no change.

**"Where you come back out" is answered for a holder that has no position of
its own**, which is the shape a community hub takes: a fixed room anybody may
walk into, owned by nobody, holding several tenants at once. The entrance
position covers it, and covers it *because* it is per player -- see "And behind
both of those sits the player" in Architecture. What such a room must not do is
copy the `admin:<username>` lease: a lease keyed by a player would make the
room that player's, and a hub is exactly the case where the next person in gets
whatever the last one left behind.

A tent is the obvious first one, and it is simpler than a vehicle rather than
harder: it does not move, so the tracker, the live sweep, `vehicleMotionAllows`,
the `cab` landing and the seat half of the exit handshake all have nothing to
do. Its stored position is frozen truth by construction rather than by the load
rule. The four API rows above are what the spike settled -- bind on
`CustomItem`, normalise tiles through the sprite grid, keep the lease id in
object modData.

One thing the spike does **not** answer: weight has no meaning on a tent, and
weight is what stops an interior being free storage, so a tent room has to be
kept small by design because there is no rule that will keep it small.

The other thing it did not answer has since been settled by deletion.
`Core.roomAllows` used to put `requires` to whatever it was handed and refuse a
non-vehicle as an author error; that was patched to confine the vocabulary to
vehicles, and the field and the function have since been removed entirely --
see "A room states nothing about what may carry it" in Architecture. What a
room is for is the binding's answer, which is also what makes a community room
or a spawn room reachable with no new registry surface at all.

Power is the part that gets *better*. The room half of the ledger does not know
what is on the other end, so swapping the vehicle battery for a real
`IsoGenerator` the player parked near the tent leaves `Power.syncRoom`
untouched and makes the units match: `PowerDrainFactor` exists today only to
convert burned fuel into battery percentage because the two are not the same
quantity, and generator to generator it is 1:1. Which generator is vanilla's
own question -- `haveElectricity()` on the tent's square, the same test that
decides whether a fridge beside it would run -- and the answer is then stored
on the lease, because a generator does not move either. Probed in game at 2.2
tiles: activated, full, and the tent square reading `electricity=true`.

The spike had its own scaffolding -- `client/PhunInteriors/client_probe.lua`,
an admin-only context menu that dumped a square, its generators, and tagged
objects for a persistence test. It answered all four of its questions, which
are now rows in the API table above, and has been deleted along with its
require in `client_events.lua`. The API table is the durable record; the probe
was the means.

## Open questions

- Should reclaimed-room loot survive by default? Currently `ScrubKeepsLoot=false`.
  It was the most complaint-generating behaviour in the design while leases
  expired on a clock. Reclaiming on demand means loot is only ever lost on a
  full server, to a room unused past `RoomProtectedDays`, and the owner is told
  -- so the question matters much less than it did.
- Is `WeightFactor=50` right? It is a guess and needs an overloaded van to
  calibrate against.
- ~~Should entering from the driver's seat make you climb out?~~ **Answered:
  no.** See "A seat and the interior are the same vehicle" in Architecture.
- **Where should you have to stand to get in?** Entry is currently allowed from
  anywhere the radial menu resolves the vehicle, which in practice is anywhere
  around it. Confirmed in game. Sketched, not decided: the back of a van, the
  side door of an RV, and never the driver's seat of a trailer. This is per
  vehicle, so it belongs on the binding -- not on the room, because where the
  door is is a fact about the van and not about the room it is carrying. That
  is the same conclusion removing `requires` reached from the other direction:
  a fact about the holder goes on the thing that knows what kind of holder it
  is naming. Needs a session of its own.

## Design note

Full rationale, including the analysis of the reference mod this reacts to:
https://claude.ai/code/artifact/67264759-901c-4bdb-9790-3681d200ccd0
