# PhunInteriors: first-playable test plan

Everything here is an **in-game** test. The bench suite already covers the
pure-Lua half and is a gate rather than a phase; see "Before the game" below.

The plan is ordered by **what strands a player**, not by how the code is laid
out. Phase A is the exit path, because a wrong answer there leaves somebody in
a room they cannot leave, and it is the newest thing in the mod. Phases B
onward are ordered so each depends only on phases above it.

CLAUDE.md is the reference for _why_ each of these is unproven. This file is
the list of things to actually do.

## How to run it

**Which build.** Deploy puts two mods side by side: `PhunInteriors` (live ids)
and `PhunInteriorsTest` (test ids, from the `Tests/root/` overlay). Test
against the live one unless you are checking the overlay itself.

**Turn Debug on first.** Sandbox option `PhunInteriors.Debug`. Several lines
this plan asks you to look for are `Core.debugLn`, which prints nothing with it
off. Every line the mod writes is prefixed `[PhunInteriors]`.

**Settings are cached** and refreshed on `EveryTenMinutes`, so a sandbox change
mid-session looks like it did nothing. `PhunInteriors.admin("reload")` re-reads
them now. Do that after every option change in this plan.

**Three entry points, all admin:**

- `PhunInteriors.admin(action, args)` from the Lua console, args a table.
- `/interiors <action> ...` in chat.
- The room list window: the admin panel button, the debug menu, or
  `PhunInteriors.roomList()`.

**The actions:** `list`, `rooms`, `bindings`, `enter`, `release`, `free`,
`reassign`, `reclaim`, `age`, `scrub`, `evict`, `open`, `close`, `power`,
`weight`, `doors`, `shove`, `gather`, `manifests`, `remanifest`, `editRoom`,
`editBinding`, `save`, `revertAll`, `reload`, `benchNext`, `benchClear`,
`benchBoarding`.

**Getting a vehicle id.** `admin("list")` prints every lease with its holder
id. That id is what `age`, `free` and `release` take.

**The reclaim shortcut.** A real reclaim needs 1190 leases. Instead:

```lua
PhunInteriors.admin("age", {vehicleId = "...", days = 99})
PhunInteriors.admin("reclaim")
```

**Do not enter the room between those two calls.** Entering renews the lease,
which is the mechanic working correctly, and it silently invalidates the test.

## Before the game: the two bench gates

Both run from the repo root, and both must be understood before any in-game
result means anything.

**1. `bash Tests/run.sh`** expects 1008 checks, 0 failures, plus the three
static checks and the syntax pass. A failure here makes every phase below
untrustworthy.

**2. `perl scripts/roomcheck.pl`** compares `defaults.lua` against the shipped
lotpacks, and it is the only thing that does.

It should exit 0 and print:

```
20 cells, 1190 registered slots, 16870 interior squares, 1630 door squares,
1190 slots with a front

the registry matches the map
```

Those are its two checks: no map content that no room claims, and no slot where
the floor and the registered box disagree. The second is the one containment
depends on. A failure names the squares and the slot.

Re-run roomcheck after any map re-export, and expect the number to change.

---

## Phase A: the exit contract

**The highest-risk phase, and the reason this plan is ordered the way it is.**
`landing` is gone. A room now states `front` (which edge faces the holder's
nose) plus `cab` as a boolean on that edge, and `Core.relativeFor` derives
front/rear/left/right from the edge the leash saw crossed. None of it has run.

Two things compound the risk. The leash **breach** branch is now the ordinary
way out, and that branch was never the one exercised when the exit was proven
over the network. And `Client.groundBeside` is the only place in the mod that
knows a vehicle part name, so it is where a wrong answer becomes a player
standing in geometry.

### A1. Leave by the front, no cab

Proves the whole chain: `Leash.classify` names the crossed edge,
`Core.relativeFor` turns edge plus `front` into a relative direction, the
direction rides down with the teleport, and `Client.groundBeside` resolves it
against the real vehicle after arrival.

1. Park a `Van` on open ground. Enter its interior.
2. Walk out through the room's north door.

**Pass:** you are standing beside the van, on walkable ground, not inside the
bodywork and not somewhere else entirely.

**Fails as:** landing in a wall, landing at the vehicle centre, or the teleport
appearing to do nothing. The last is the "destination chunk not loaded"
signature; watch whether your position is restored a frame later.

### A2. Leave by the cab edge, seat free

Proves the cab request path, which is the one way out that can fail, and the
`seated` flag on the arrival handshake.

Use a room that declares `cab` on its front edge. The `Step Van - *` rooms
carry a doorless south opening for exactly this.

1. Enter from beside a step van, such as `Base.StepVanMail`.
2. Leave through the **south** opening.

**Pass:** you are in the first fitted free seat, counting from the driver's. No
preference is sent, so which side you left by is what decided this, not where
you got in.

### A3. Leave by the cab edge with every seat taken

Proves `Transit.arrived` reading `seated = false` and putting you back, and
that the bounce is cheap because `Slots.touch` already renewed the lease.

1. Fill every seat of the vehicle.
2. Leave by the cab edge.

**Pass:** `IGUI_PhunInteriors_CabFull` and you are back inside **the same
slot**, not a newly allocated one. Confirm with `admin("list")` that the room
and index did not change.

### A4. Leave by a side, which no room maps

No vanilla script declares an area meaning "the flank", so left and right are
worked out from which way the vehicle is pointing, not from an area name.

1. From any room, walk out through the east or west edge of the box.

**Pass:** you land on that side of the vehicle, the first square past the
bodywork. If `getForwardVector` gives no answer you land at the nearest door
instead, which is the fallback working rather than a miss.

### A5. A side door

Every shipped room now states a `front`, the campers and caravans included,
whose doors are in the side. `Camper - *` rooms state `north`, the VW camper
`south`.

1. Enter a caravan, leave by its door.
2. Repeat with the caravan parked pointing each of the four compass directions.

**Pass:** you come out on the caravan's door side every time. Right on two
headings of four is the signature of reading the wrong component of
`getForwardVector`.

### A6. Breach the leash rather than using a door

The breach branch now carries every exit, and it was never exercised over the
network.

1. Inside a room, cross the box boundary somewhere that is not a doorway: the
   roof, or a wall gap if one exists.

**Pass:** same `Transit.leave`, same destination as A1. The only difference
between a door and a breach should be which edge was crossed.

### A7. Exit while the vehicle is moving

Proves `Core.vehicleMotionAllows` and rule 5 refusing **before** any teleport,
so there is no port-and-bounce.

1. A second player drives the van with a free seat. Leave by the cab edge.
   **Pass:** you land in the free seat. Already proven; here as a regression.
2. Repeat with every seat taken. **Pass:** `IGUI_PhunInteriors_VehicleMoving`,
   and you stay inside.
3. Leave by a ground edge while it moves. **Pass:** refused, you stay inside.

### A8. `getForwardVector`

Public on `BaseVehicle` with zero uses in vanilla Lua, so it is `pcall`'d and
nil-checked and every caller falls back to the nearest door.

Nothing to do beyond watching for a Lua error naming it during A1 to A5. If it
never resolves, the fallback should hide it completely, which is the point.

### A9. Walk straight back out

Enter, and walk out of the door the moment you land. **Pass:** the leash fires
within about a quarter second of crossing the edge. Six seconds means the
`landed` report is not reaching the server, and the grace is timing out in
full instead.

### A10. Boarding point

Use the enter option from the front of a van, from beside a caravan, and from
the far side of a VW bus. **Pass:** you walk to the back of the van, to the
caravan's side door, and to the bus's right-hand sliding door, and only then
does the entry action start. Also:
- An unreachable point (van backed against a wall): "You cannot get to the
  door", and no entry.
- Entering from a seat of the same vehicle: no walk at all.
- `EntryAtBoardingPoint` off: enter from anywhere, as before.
- A modded vehicle nobody listed: the rear if it declares one, else its nearest
  door.

### A11. Locked vehicles

Lock every door of a van, drop its key, and try to enter. **Pass:** "It is
locked, and you do not have the key", refused at once, with no walk. Also:
- Pick the key back up: you get in.
- Smash one window, or unlock any one door: you get in without the key.
- A doorless trailer: you get in.
- `EntryNeedsUnlocked` off, or the server's `VehicleEasyUse` on: you get in.
- As a non-admin on a dedicated server, so the server's own copy of the lock
  state is what refuses.

---

## Phase B: the reshaped registry and allocation

The reshaped registry has run in game, but has not had a full pass. 1008 bench
checks are real verification of the logic and none at all that PZ agrees.

### B1. Boot

**Pass:** `Core.describeRegistry` logs counts at boot: `94 room(s), 1190
slot(s), 93 binding(s)`, the bindings being 92 for vehicles and one for tents.
Zero anywhere means registration did not run, not that the map is missing.

### B2. Allocation order

Proves specificity drains the most specialised room first, counted per
**script** rather than per binding.

1. `admin("rooms")` or the room list window. Note the free counts.
2. Enter from a vehicle bound to exactly one room, then from one that overflows
   into the plain `Van` room.

**Pass:** the specialised room drains first; general-purpose capacity is saved
for the vehicles with nowhere else to go.

### B3. A vehicle nobody listed

The `phun.van` matcher is gone, so a modded van now gets no room rather than
the plain `Van` room.

**Pass:** refused with `IGUI_PhunInteriors_WrongVehicle`, and `Slots.acquire`
names the missing set in the log at the point of refusal. That self-diagnosis
is the whole reason dropping the matcher was acceptable.

### B4. Per-slot blueprint capture

**Capture is load bearing.** It failed on every attempt until the `bounds.z +
1` sweep stopped counting a nil square above the room as a failed read. Seen
working on a dedicated server on 2026-11-01: `captured slot for
phun.room.Camper_Medium#2: 53 objects, 31 distinct sprites`.

1. Open the room list, port into a slot, read its **Captured** column.
2. Or run `PhunInteriors.admin("manifests")`.

**Pass:** the slot reports a capture, and `manifests` reports real figures. A
fitted room runs to about 50 objects from about 30 sprites.

**Fails as:** Captured stays empty on every slot. The leash gives up after
`Manifest.CAPTURE_ATTEMPTS` ticks and that slot falls through to a sibling for
the rest of the save, silently.

### B5. Sibling fallback

Nothing ships a blueprint any more, so a slot that missed its window falls
through to another slot of the same room.

1. Find or force a slot with no capture, release it, re-enter it.

**Pass:** `Scrub.slot` logs which source it used. Tier 3 homogenises, so
saying so is the point.

### B6. Scrub reconciles

Proves the reversal from rebuild to reconcile, and `Scrub.createFromSprite`
rebuilding a door as a door and a light switch as a switch.

1. Wreck a room: break things, drop loot, move furniture.
2. Release the slot, then re-enter it so it scrubs on arrival.

**Pass:** the room is restored, **the light switch still works**, and **the
door still opens**. A door that comes back as a plain `IsoObject` is a room
nobody can leave, which was cosmetic before the exit tile went and is a
soft-lock now.

3. Enter again without wrecking anything. **Pass:** the second pass touches
   nothing at all.

---

## Phase C: the registry editor

The window and the Slots tab have run on a dedicated server, so C1 and C2 are
regressions now. What `shared/PhunInteriors/{overrides,json}.lua` and
`server/PhunInteriors/store.lua` do to the save file is still unconfirmed.

### C1. The window opens and the three tabs draw

**Fails as:** a form that opens blank, or a list with no rows. That is a hook
that did not survive the port from PhunMart2; look at `Core.isShippedKey` and
the `Core.references` stub in `ui/state.lua` first.

### C2. The payload survives at 1190 slots

The list carries room summaries and bindings; a room's slots are fetched when
its row is selected.

**Fails as:** an empty Slots tab, meaning the `roomSlots` round trip is not
completing. More likely on a dedicated server than in single player.

### C3. Edit a room's label, apply, see it stick

**Check this before anything else that looks like a data bug.** `FormPanel`
passes the **form** to `onApply`, not a values table. Getting that wrong drops
every field read the wrong way while numeric fields keep working. It has
happened once and cost `label`, `front`, `cab`, `selfPowered` and `reservoir`.

**Pass:** the label changes, the row gains the **overridden** stripe, and the
form closes.

### C4. Sparse patching

1. Open a room form and press Apply without changing anything.
   **Pass:** no entry is left behind. `Core.setRoomOverride` diffs against the
   snapshot and drops what matches.
2. Change one field. **Pass:** only that field is in the patch.

### C5. `clear` on a nullable field

`generator` and `front` are the two fields whose whole contract is that nil
means something, and JSON null cannot say it.

**Pass:** a generator added to a room can be taken away again.

### C6. Delete a stamp

**Pass:** the slot goes and **a gap is left**. Over the wire this is
`removeSlots = {3}` rather than a `false` tombstone, because a table value of
`false` may not survive PZ's command serialisation.

**Fails as:** a delete that reports success while the slot is still there.

### C7. Refuse a delete of a leased slot

**Pass:** refused outright.

### C8. The Slots tab dropdowns

Nothing can test these, because the specs cannot load a file needing
`ISComboBox`.

1. Narrow the rooms with the vehicle picker. **Pass:** the room picker offers
   only that vehicle's rooms and names the room on screen. `ISComboBox:clear()`
   empties the options and does **not** reset `selected`, so a dropdown drawing
   blank or naming the wrong room is the signature.
2. Watch a core while a room's detail is fetching. The refresh path fetches
   from inside the event the fetch answers; it converges because `showRoom`
   only dispatches when the detail is missing.

### C9. Save, restart, see it come back

**The one that matters most.** `getFileReader` and `getFileWriter` are server
side by design, so on a dedicated server the file is the server's.

1. Make an edit. Press Save.
2. Look for `PhunInteriors.json` in the Lua folder, next to
   `PhunMart_Shops.json`.
3. Restart. **Pass:** the edit is still applied.

**Fails as:** Save reports success and the customisation does not come back,
which means the file landed somewhere else.

### C10. Nothing autosaves

1. Edit, do not save, close the window. **Pass:** you are prompted.
2. Edit, do not save, restart. **Pass:** the edit is gone. This is correct.

### C11. A corrupt file

1. Put a stray comma in `PhunInteriors.json` by hand. Restart.

**Pass:** the server starts, reports the problem, and ignores only the bad
line. A whole file refused for one typo loses every other customisation in it.

---

## Phase D: power

**The one mechanic in v1 with nothing proven at all.** It needs a map with a
generator sprite in the room, which the shipped map has at
`{x = 1, y = 17, z = 0}` in a sealed 1x1 box.

### D1. The probe

`PhunInteriors.admin("power")` while standing in a room, or with `room` and
`index`.

**Pass:** it reports the grid state and the slot's generator. This is also how
you confirm the `NoPowerOrWater` zone was painted. Without it the rooms sit on
the mains for the first weeks of a save and the generator binding is invisible.

### D1b. The generator is silent

In a save that already had a powered room, enter it, then run
`admin("power")`. Then stand outside the generator's box, 17 south of the room.

**Pass:** the generator line ends `silent (phuninteriors_01_2)`, nothing hums
near the box, and the room is still lit. Expect one vanilla stopping sound the
first time an old generator is swapped. A generator placed anywhere else in the
world still hums. **Fail:** `HUMS`, or `silent` with the hum still audible
(the sound script did not load).

### D1a. A save missing a zone gets it back

On a world created before cell 92,46 shipped (or any world, after editing its
`map_zone.bin` out of date by restoring an older copy), start the server.

**Pass:** the log has `zones: this save was missing N of 3 power/water
zone(s)` once, PhunServer's `/diag health` reads `present` on the server for
`phuninteriors`, and `admin("power")` in a 92,46 room reports `isNoPower` on
every square. Then restart again and note whether the line comes back. Either
is a pass; it says whether a zone registered after load is written into
`map_zone.bin`, which nothing has settled yet.

### D1b. A missing map is refused, not entered

Start a throwaway server with `phuninteriors` taken out of `Map=` (the mod
still enabled), and log in as a non-admin and as an admin.

**Pass:** the log has the `not in this world's map list` warning and a
`WARNING: N of N registered slot(s) have no room on the map` block naming the
cells. Both players see "Vehicle interiors are unavailable" on login. Entering
any bound vehicle says "This interior is missing from your world" at the end
of the action, nobody is teleported, and `admin("list")` shows no new lease.
Put the map back, restart, and every room works and no lease was lost. If
every slot reads present with the map out, `countRoomsIntersecting` is not
answering from Lua: look for nothing at all in the log.

### D2. The generator exists and the lights come on

**Pass:** `haveElectricity()` is true on the room squares. That call reads no
field: it is `chunk:isGeneratorPoweringSquare`, so only a real activated
`IsoGenerator` can do it.

### D3. `Power.ensureGenerator` replaces one that has gone

1. Destroy or remove the generator, or scrub the square so it comes back as a
   plain `IsoObject`.
2. Re-enter.

**Pass:** a fresh one is placed and activated, and any generator-**shaped**
object that is not an `IsoGenerator` is cleared first.

### D4. The ledger

`fuelOwed`, `fuelLast`, `batteryKnown` on the lease. The two halves are never
loaded together.

1. Enter, stay a while, leave, drive.
2. Watch for the battery being debited on entry, on the arrival report, and on
   every tracker position push.

**Pass:** battery alive means a full tank, battery flat means a dark room.
**The tank is a buffer, not a fuel gauge**: it is topped to full whenever there
is charge, because `IsoGenerator.update()` catches up for time the chunk spent
unloaded.

### D5. Admin port resets `fuelOwed`

**Pass:** an admin port never darkens the room. Nothing settles that debt,
because there is no battery, and left to accumulate it sends the projected
charge negative.

### D6. `selfPowered`

New, never run. It suppresses the ledger only; the room still needs a real
`generator` offset.

**Pass:** the room stays lit for free. `registerRoom` warns for `selfPowered`
with no generator, because that room is simply dark and nothing downstream can
tell it from one meant to be.

---

## Phase E: reclaiming on demand

Replaced a daily expiry sweep. `Slots.acquire`'s reclaim fallback,
`Slots.oldestReclaimable`, `admin("reclaim")` and the notice are all new.

### E1. A reclaim happens and the room changes hands

Use the `age` then `reclaim` shortcut. Do not enter in between.

**Pass:** `reclaimed <room>#<index> from <holder>`, and it is scrubbed when it
is next handed out rather than now.

### E2. The owner is told afterwards

Not warned before, because there is no date to warn about.

1. Enter a van, leave, age its lease, reclaim, enter again.

**Pass:** `IGUI_PhunInteriors_RoomReclaimed`. It rides `consts.leasedKey` in
vehicle modData, the same persistence the lease UUID already proves on a
dedicated server, so it should survive a restart. Note it is deliberately not
keyed on the UUID: that is written before allocation, so a vehicle refused its
first room would carry one too.

### E3. Protection holds

1. Set `RoomProtectedDays` high, `admin("reload")`, then try to reclaim.
   **Pass:** "nothing reclaimable: every lease is occupied or used within N
   day(s)".
2. Set it to the maximum. **Pass:** a vehicle is refused once the last room is
   gone, rather than taking anybody's. That is how an admin says never.

### E4. An occupied room is never taken

Including a tenant who disconnected inside.

### E5. The option rename

`LeaseDays` became `RoomProtectedDays`, and `LeaseWarningDays` was removed. A
server that set the old one silently gets the default of 14. Nothing has
shipped, so this costs nobody anything yet; confirm the new name is what the
sandbox page shows.

---

## Phase F: world-object holders

A tent can be bound, leased, entered and left. A tent has been entered in game
and a toilet bound to a room confirmed working; the pickup lock and the rest of
this phase have not had a full pass.

### F1. Enter a tent

**Pass:** a context-menu option appears on a bound tent and puts you in
`phun.room.Tent`. Any tile of the tent resolves to one holder square,
because a multi-tile moveable normalises through its sprite grid.

**Fails as:** `IGUI_PhunInteriors_WrongHolder`, or two leases taken on one
object from two different tiles.

### F2. The lease id survives a save and a reload

Object modData does survive both, where vehicle modData does not.

**Pass:** quit to the main menu, come back, and the tent still holds its room.

### F3. The pickup lock, occupied

1. Somebody inside. Try to pick the tent up.

**Pass:** refused with `IGUI_PhunInteriors_HolderOccupied`. This is
unconditional and outranks the contents test, because picking up a tent with a
tenant inside strands them on bare ground whether or not the room holds
anything.

### F4. The pickup lock, non-empty

Contents are **banked on exit**, not measured at pickup, because at pickup the
tent is loaded and the room is not.

1. Drop one item inside. Leave. Try to pick the tent up.
   **Pass:** refused with `IGUI_PhunInteriors_HolderNotEmpty`. One dropped rag
   is enough, and that is deliberate: the alternative means packing a tent
   silently bins what is in it.
2. Sweep the room, leave, try again. **Pass:** it packs.

**Test this as a non-admin, or with the movables cheat off.** The guard
mirrored vanilla's movables-cheat bypass once, so the first in-game test ran
with the guard silently disabled and the tent came up as though nothing had
been built. **A guard that exempts admins cannot be tested by an admin, and
everybody who tests this mod is one.**

### F5. The tally itself

`Weight.surveySlot` needs real squares, so the counting is covered by nothing.
It counts loose floor items, container contents, and objects the tenant brought
in.

**Fails as:** a tent that will not pack when it looks empty.

### F6. A stale lock heals

`Slots.release` clears it when the object happens to be loaded, which after a
reclaim it usually is not.

**Pass:** walking into the tent and back out re-asserts the lock against a
fresh room, which for an empty one means clearing it.

### F7. Known gap, not a bug

A reclaimed tent tells nobody. `consts.leasedKey` and the `RoomReclaimed`
notice are stamped on vehicles only. Confirm the behaviour, do not file it.

---

## Phase G: the rain reservoir

The kit has not been installed in game, and the scrub has not run since it
stopped demanding squares above the room. In rough order of risk:

### G1. Can a sink be plumbed to the map's own barrels?

The map ships `carpentry_02_122` on roof squares in the ambulance bays and
several fitted rooms. Settled on 2026-10-10: a map-loaded one is a plain
`IsoObject` that fills with rain but cannot be plumbed to.
`Rainwater.rebuildCollectors` now swaps each one for a real collector, once per
visit, and that swap has not run.

1. Enter one of those rooms and right click its sink.

**Pass:** the sink plumbs to the barrel above it and draws water. Whatever the
barrel already held is still in it.

### G2. Install a kit

1. Craft `PhunInteriors.RainReservoirKit` (Carpentry, Woodwork 5, Mechanics 2) or spawn one.
2. Stand inside a room with a clear roof. Install.

**Pass:** `IGUI_PhunInteriors_ReservoirInstalled`, barrels on the roof at one
per three squares, and **the kit is consumed**. Two for a 3x4, five for a 3x13.

**Fails as:** the barrels going up and the kit not being spent, or the reverse.
The install is a request, not a server-side `complete()`: the client sends only
the kit's item id and `Rainwater.install` finds the kit in the player's own
inventory.

### G3. The refusals

`ReservoirNotHere`, `ReservoirHasOne`, `ReservoirNoRoof`, `ReservoirNotInside`,
`ReservoirNoKit`. A room that already has a collector refuses the kit, tested
by sprite name as well as by behaviour.

### G4. The tag survives, and the scrub removes ours

`consts.reservoirKey` in the object's modData makes `Manifest.isStructural`
refuse it, so a capture never records one and the next scrub removes it.

**Pass:** our barrels go on a scrub; **the map's own barrels stay**.

**Fails as:** the tag not surviving a save, so the next capture of that slot
records the barrels and they become permanent.

### G5. Plumbing

1. Put a sink in the room.

**Pass:** it draws from a barrel. Vanilla searches the 3x3 around the square
directly above a fixture, one level up and nowhere else, which is why one
barrel per three squares covers the floor.

### G6. Known gap, undecided

Weight charges a barrel's own moveable weight but reads `ItemContainer`s, and
water is in a `FluidContainer`. Whether it should count the water is undecided.
Record the number, do not fix it.

---

## Phase H: the safehouse guard

Covered against a stand-in that mirrors the disassembled overlap test. What
only the game can say:

### H1. Can one of these rooms be claimed at all?

Vanilla claims a **building**, and each stamp is a room def wrapped in an
`emptyoutside` shell def, which is kept out of `BuildingDef.rooms`.

**Pass:** the claim is taken, and `admin("list")` names it on the lease. If
claiming is refused for these rooms, the guard simply never fires and the rest
of this phase is moot.

### H2. Does the claim rectangle reach a neighbouring slot?

Stamps are 25 apart across and 42 down, so a box around one 7x7 shell should
not.

**Pass:** `admin("list")` names a claim on one lease, not two.

### H3. Entry is refused on a claim

1. Claim a slot as one player. Have another vehicle allocated into it.

**Pass:** refused. `Transit.enter`, `enterObject` and `adminEnter` all check
after allocation and **before `Slots.touch`**, so a refused entry must not
renew the lease the reclaim measures.

### H4. No admin exemption

An admin is allowed in for exactly the reason they are allowed into any other
safehouse: vanilla's `playerAllowed` is member OR owner OR the role capability
`CanGoInsideSafehouses`.

**Pass:** an admin **without** that capability is refused. If they get in
anyway, somebody wrote an exemption.

### H5. Recover does not check

Somebody already standing inside should stay contained and walk out. Refusing
there would leave them uncontained in a stranger's safehouse.

### H6. Reset refuses a claimed slot

**Pass:** the Reset button refuses both a slot somebody is standing in and a
slot somebody has claimed. Guarded in the action, not in `Slots.release`,
because that call is also how a vehicle moves between rooms and how
`removal.lua` frees a scrapped wreck.

---

## Phase I: the entrance position

`Transit.entranceOf`, `fallbackReturn`, `rescueStranded`, the write inside
`setOccupancy` and the capture in `placeInside` are all new.

### I1. `rescueStranded` on login

**The whole reason for the feature, and reachable in about a minute.**

1. Enter a room. Log off.
2. `admin("age", {vehicleId = ..., days = 99})` then `admin("reclaim")`.
3. Log back in.

**Pass:** `<name> logged in inside <room>#<index> with no lease on it; putting
them back outside`, then `IGUI_PhunInteriors_RoomLost`, and you are standing
where you went in. Before this you were simply stuck.

### I2. It sorts last

1. Enter from beside a van. Have somebody drive the van to the next town.
2. Leave.

**Pass:** you come out **at the van**, not on the kerb it left from. The
entrance is a different fact from where the holder is, and putting you back at
the kerb would be the exact failure the tracker exists to prevent.

### I3. Player modData persists server side

Settled from the jar, unproven on a dedicated server: `IsoPlayer.save` reaches
`IsoMovingObject.save`, which writes the modData table into the character
record. Nothing transmits ours, deliberately.

**Fails as:** the entrance coming back empty after a rejoin, so the fallback
silently never fires.

### I4. The cab bounce re-captures an entrance

`placeInside` is the capture point, and `Transit.arrived` calls it when a cab
exit finds every seat taken.

**Pass:** a bounced player's entrance becomes the kerb beside the van. Correct
rather than incidental, but nothing has watched it happen.

### I5. The staleness guard

`getMetaGrid():isValidSquare` is the strongest check available with the
destination chunk unloaded. It cannot catch a wall built there since, and
nothing server side can. Accepted, because the alternative is a tenant who
cannot leave at all.

---

## Phase J: releasing a removed vehicle's room

`removal.lua` and its client half are new.

### J1. Scrap a leased wreck

1. Blowtorch a leased burnt-out vehicle (`ISRemoveBurntVehicle:complete()`).

**Pass:** `released the room leased to <id>: vehicle scrapped`.

**On a dedicated server this is the open question.** The action has a
`serverStart`, which is B42's server-side shape, so the wrap is server side. If
it turns out to run on the client, a dedicated server never sees it and a
scrapped wreck's room stays leased silently until a full pool reclaims it.

### J2. Admin remove

`VehicleCommands.remove` is a local table, so the client warns first
(`vehicleRemoving`) and the server watches for five seconds.

**Pass:** the room is released.

**Fails as:** `watched <id> and it was not removed` in the log, meaning our
warning did not reach the server ahead of the removal.

### J3. Release on the flag changing, never on its value

`isRemovedFromWorld()` is true of **every** parked vehicle out of range,
because an ordinary chunk unload calls `removeFromWorld()`.

**Pass:** parked vehicles out of range keep their rooms. A wave of spurious
releases is the signature of testing the value.

---

## Phase J2: the W900 Semi-Truck

`compat_rsemitruck.lua` is new. Needs the W900 Semi-Truck mod (3409472393)
and Debug on. Reported in game before it existed: leaving a box truck's room
took its hood and rear door off, and the game crashed minutes later.

### JW1. Box truck exit

1. Put something heavy in a `SemiTruckBox` room and step out.

**Pass:** the hood and rear door are still there, the truck sits still, and
the log has `payload delta 0.0 -> N` rather than `mass delta`. Ten minutes
beside it with no crash.

**Fails as:** a `mass delta` line for the box truck, which means
`isTargetVehicle` did not say yes and the old path ran.

### JW2. The weight is felt

1. `admin("weight")` names the delta. Drive the truck, empty the room, drive
   it again.

**Pass:** slower to pull away with the room full. The room counts at their
0.65 on top of `WeightFactor`, so it is a smaller effect than on a van.

### JW3. A truck leased before the patch

**Pass:** `took a legacy mass delta of N back off` once, on its first exit
under the new code, and never again.

---

## Phase J3: Project Viewpoint

`client_viewpoint.lua`, the guarded `showRadialMenuOutside` hook and the model
pack are new. Needs Project Viewpoint (3809306528) and ZombieBuddy, with its
Java approved. **Use a fresh save, or reset our cells out of the test save**
(`map.cmd`): the ground and inner wall fixes are in the lotpacks, and a chunk
the save has already loaded keeps the old map, which reads exactly like these
tests failing.

### JV1. The menus

1. In first person, look at a supported vehicle and press [F].
2. Inside, look at the room's door and press [F].

**Pass:** **Go inside** on the vehicle, **Step outside** on the door, each
exactly once. **Fails as:** two Go inside slices (the guard), or none on a
world object (the trailing argument).

### JV2. The pack loads

**Pass:** the console has no `ModelPacks` complaint naming our manifest, and
the block outside a shell is black ground, not grey slabs and sky.

### JV3. A room from inside

**Pass:** floor all the way to every wall, no sky along the foot of the south
and east walls, those two walls showing the room's own wallpaper rather than
truck-body metal, and a pale grey ceiling with no dark discs from the roof
barrels.

### JV4. An old chunk, deliberately

In a save that visited a room before the map update, port into it.

**Pass:** it looks as it did before (metal south and east walls, gaps along
them). That is expected and documented, not a failure. Nothing about entering,
leaving or containment differs.

---

## Phase J4: Project A-Life

`compat_alife.lua` is new. Needs Project A-Life (`ProjectALifeNPCs`) and an NPC
that follows you or stands still near a supported vehicle. Run it on a
dedicated server as well as in single player: every check is server side, and
there the NPC's modData flag is the marker that counts.

### JA1. Entry beside an NPC

1. With an NPC within 10 squares and no zombies, enter the vehicle.

**Pass:** you go inside. **Fails as:** "zombies too close" with nothing but the
NPC nearby, which means `ProjectALifeOwned` / `ProjectALifeActor` is not what
A-Life writes (the names were taken from PhunZones2, not from A-Life).

### JA2. A zombie still counts

1. Repeat JA1 with a real zombie inside the radius as well.

**Pass:** refused, as without the mod.

### JA3. The exit shove

1. Leave a room with an NPC standing within 6 squares of the landing.
2. `PhunInteriors.admin("shove")` with an NPC and a zombie beside you.

**Pass:** the NPC stays where it was; the zombie is pushed to the ring.

---

## Phase J5: reassigning a room

Reported working on 2026-11-01. Run as a regression after any change to leases.

### JR1. A move, end to end

1. Enter a vehicle, leave something in its room, step out.
2. Beside a vehicle nobody has entered, open the Slots tab, select that slot and
   press **Reassign**.

**Pass:** the confirm names the vehicle, a dialog gives the result, and going in
through the new vehicle finds the same room with the item in it. Stepping out
lands you at the new vehicle, not where the old one stood. Going in through the
old vehicle, if it still exists, gives a new empty room and the reclaim notice.

### JR2. The refusals

Each ends in a dialog, and the lease does not move: a destination that already
holds a room, one with no rooms bound to it, somebody inside the room, and
pressing it while standing in any room yourself.

### JR3. The weight

**Pass:** `admin("weight")` shows no delta left on the old vehicle if it was
loaded, and the new vehicle is charged at its first exit.

---

## Phase J6: other mods and late additions

Each of these has a Known gap in CLAUDE.md saying what to watch for.

- **Doors (#21).** Leave a door open, walk out, come back: it is closed, and
  the log says so. A garage door closes all three squares.
- **Respawning (#25).** Claim a room, tick Respawn in Safehouse, die and make a
  new character; nothing asks where to spawn. You wake on the floor, contained,
  and can leave. Do it in a 2x3 (Van), a 3x6 (Truck - Furniture) and a 3x9 (Bus
  or Camper - Large). The last two log `after a safehouse respawn`.
- **AVCS (Dependencies).** A claimed vehicle's room is refused unless its trunk
  would open for you. Leaving is never refused.
- **Boats (#26).** Needs BoatCore SP Gold. Enter from a seat and from a dock,
  leave by the door, and check you land in a seat rather than the water. The
  Enter slice appears exactly once while seated. Boarding from a dock must not
  be refused as moving, since nobody knows yet what `isStopped()` says afloat.
- **The vehicle bench (#24).** `PhunInteriors.vehicleBench()`: spawn, bind,
  walk in, next.

---

## Phase J7: split screen

Never run since the fix. Reported broken on 2026-11-02. Run it twice if you can:
in single player, and as a non-admin on a dedicated server. P1 is the first
player, P2 the one who joined.

### JS1. The door

1. Both enter a vehicle. P1 walks out through the door. Then P2 does.

**Pass:** each comes out at the vehicle when they cross the line, and the other
stays exactly where they were.

### JS2. Step Outside

1. Both inside. P1 chooses **Step outside** from the context menu.
2. P2 still has the option, and P1 now offers Enter on the vehicle.

**Pass:** only P1 leaves. Repeat with P2 choosing it.

### JS3. Entering

1. P2 inside and standing away from the spawn square. P1 enters the same vehicle.

**Pass:** P2 does not move. Repeat with P2 entering while P1 is inside.

### JS4. Two vehicles

1. P1 sits in one RV. P2 enters the interior of a different one.

**Pass:** P2 is in the room of the RV they chose, and P1 is still in their seat.
Stepping out puts P2 back at their own RV.

### JS5. Both moving at once

1. Each enters a different vehicle as near to the same moment as you can manage.

**Pass:** each lands in their own room. Look in the log for `matches nobody on
this client`, which means a command was addressed to neither player and dropped.

### JS6. Joining and dying

1. P2 joins while P1 is inside. P1's room and position are undisturbed.
2. P2 dies and respawns as a new character.

**Pass:** the log has a `playerSetup` outcome for P2, and neither death nor join
moves P1.

## Phase K: multiplayer

Everything above is single player unless noted. **Re-run on a real dedicated
server, not a listen host.** Only a dedicated server unloads the vehicle's
chunk the way the entire exit design assumes.

Minimum set to re-run: **A1, A2, A3, A6, A7, B4, C2, C9, I1, I3, J1.**

Also still unproven, and needing two admins connected:

- **`Core.tools.onlinePlayers()`** returns only local players on a client and
  everyone on a server. `author.lua` reads `players:get(0)` for "where am I
  standing", which is correct on a listen server and **wrong on a dedicated one
  with more than one admin.**

---

## Regression set

Proven before the reshape. Re-run once each, because the registry underneath
them changed even though the mechanics did not.

|     | what                                                                          |
| --- | ----------------------------------------------------------------------------- |
| R1  | Enter and exit on foot, and from a seat back into the same seat               |
| R2  | Containment: the leash ejects from the roof, a neighbouring stamp, a teleport |
| R3  | Seat and door restore                                                         |
| R4  | Translations resolve, with no raw `IGUI_` keys on screen                      |
| R5  | Weight applies: the `mass delta` line appears with Debug on                   |
| R6  | Release to quarantine, reissue, and the scrub that follows                    |
| R7  | Destroy guards both ways: `HardenShell` on refuses, off breaks normally       |
| R8  | Fire dousing with `HardenShell` on, and fires burning normally with it off    |
| R9  | Reconnect while inside, and recover across a server restart                   |
| R10 | Towing: one player inside, a second tows, the tenant exits into a seat        |

## What this plan cannot cover

- **A room with four solid walls.** `roomcheck.pl` lost that check along with
  the `landing` table, because a doorless opening, a window and a garage door
  are all invisible in a lotpack. It is now caught by walking into the room.
- **Climbing out of a window.** The `GAGE KI5` room has no door at all, only a
  window in its north wall and another in its south. Nothing has confirmed a
  tenant can climb one, and if they cannot, the room is a
  soft-lock. Worth an explicit visit.
- **The zombie perimeter.** The block is fenced, but the void starts
  immediately beyond it on every edge, and a fence stops pathing rather than
  realisation. Expect zombies to appear inside eventually. That is Known gap
  #0, not a test failure.
