# How it works

The design in brief, for anybody curious why it behaves the way it does.
`CLAUDE.md` at the repository root is the full record, including every engine
fact the design rests on and how each was established.

## Compared with the usual RV interior mods

| | Common RV mods | PhunInteriors |
|---|---|---|
| Room slots | Assigned once, never freed, so the pool quietly runs out | Leased, reclaimed only when needed, and cleaned before reuse |
| Where you come out | A position cached on a timer, up to a minute stale | Read live off the vehicle, with a tracked position for when it is unloaded |
| Interior loot | Weightless | A share of its weight is added to the vehicle |
| Containment | Indestructible walls | A bounding box test, so walls could be breakable |
| Leaving | A context menu | Walk out of the door |
| Supported vehicles | A hard coded list | A registry other mods extend by game script name |
| Single player and multiplayer | Two implementations that drift apart | One code path |

## Containment is the floor, not the walls

While anybody is inside, the server tests each occupant against the floor of
their room four times a second. That one test covers the roof, the rooms next
door, a hole in the wall and any teleport exploit. Because containment does
not rely on the walls, the walls can be breakable.

**There is one way out.** Walking out of the door, through a hole in the wall,
or anywhere else off the floor all end in the same call, which takes the
player back to the vehicle. There are no exit tiles. The door has to actually
open, which is why a scrub rebuilds a broken door as a working door rather
than a picture of one.

**Which edge you cross decides where you land.** A room states which of its
edges faces the front of the vehicle. The edge you crossed, relative to that,
is front, rear, left or right, and the client asks the real vehicle where that
side is. A room with a cab puts you in a seat when you leave by the front.
Nothing in the containment code knows a vehicle part name.

## Rooms are leased, not assigned

Every lease records when it was last used. A lease never expires on a clock.
When a vehicle needs a room, it gets a free one if any exist; only when every
room it could have is taken does it get the one unused the longest, and only
if that one has gone unused for the server's protection period with nobody in
it. Its owner is told the next time they go in.

A released room goes to quarantine. It is **reissued, then cleaned**, not
cleaned and then reissued: cleaning needs the room's chunk loaded, and nothing
loads the chunk of a room nobody has been near. So the cleaning happens the
moment the next tenant arrives. The rule is "never used dirty", not "never
handed out dirty".

## Cleaning a room

A scrub reconciles rather than rebuilds: it keeps whatever the blueprint
expects and the square already has, removes the extras, and creates only what
is genuinely missing. Rebuilding everything would break things, because the
engine decides what an object *is* (a working light switch, a door) when the
map loads, and an object recreated from Lua is a plain picture of one.

The blueprint is **captured in game, per stamp**, the first time that stamp is
leased, when it is untouched by definition. A map author can decorate every
stamp differently and each is restored to what they built there.

It is not a chunk revert. Nothing in Lua can reload a chunk from the map file,
and PZ saves modified chunks into the save.

## Power

`square:haveElectricity()` has no flag behind it: it asks whether a real,
running generator is in range. So each room has a real generator, out of
sight, and the mod keeps it fuelled.

The vehicle and the room are never loaded at the same time, so a ledger on
the lease carries the debt between them. The room banks what its generator
burned; the vehicle's battery pays it off the next time the vehicle is
loaded. The generator tank is only a buffer, topped up whenever the battery
has charge to cover it. The battery is the real limit.

A tent has no battery, so a tent room bills the generator the player parked
beside the tent, found the same way vanilla decides whether a fridge there
would run.

## Water

A rain reservoir puts vanilla rain collectors on the room's roof. Vanilla
plumbing looks for a water source in the 3x3 squares above a fixture, so one
barrel on every third square covers the whole floor. The barrels the kit
places are tagged so the next scrub removes them; the barrels a map ships
with are part of the room and stay.

## Weight

The mod only ever adds and removes its own share of a vehicle's mass, so it
does not fight other mods that change mass too. Fuel use in vanilla reads the
vehicle's fixed script weight, so interior weight changes handling but not
fuel.

## Multiplayer

The server is the authority on who is in which room and where they come out.
The client does the teleport and the seating, because vanilla only seats a
character from a client action, then reports back what it found. That
report is the first moment anybody can tell a parked vehicle from a destroyed
one, and it is when weight is applied and the ground is cleared of zombies.

The driver's client tells the server where a leased vehicle is as it moves,
sending only the vehicle's id. The server reads the position off the vehicle
itself, so there is nothing in the message to trust.
