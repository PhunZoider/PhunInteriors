# Playing with PhunInteriors

What a player sees, and the rules they play by. Every number here is the
default a new server gets; the server owner can change all of them (see
[sandbox-options.md](sandbox-options.md)).

## Getting in

Right click a supported vehicle and choose **Go inside**. The option is also on
the vehicle radial menu, seated or standing.

- **You get in at the door.** On a van that is the back, on a caravan or RV it
  is the side door. Your character walks there first. If they cannot reach it,
  you are told so.
- **It takes a moment**, and walking, running or aiming cancels it.
- **Not with zombies close.** If one is within 10 squares when the action
  finishes, you stay outside. Starting clear and finishing surrounded does not
  count as clear.
- **Not while it is moving**, unless you are already aboard. A passenger can
  climb into the back of a moving van. Nobody boards one from the road.
- **Not from the driver's seat of a moving vehicle.** Somebody has to drive.

The first time a vehicle goes in, it is given a room of its own. That room is
its room from then on: anything you leave there is still there next time,
and everybody who goes in through the same vehicle ends up in the same room.

## What is inside

Each vehicle gets a room that suits it. A mechanic's van opens onto a small
workshop, a mail van onto a sorting room, a school bus onto a classroom, a
caravan onto a caravan. There are 83 room designs; see
[vehicles.md](vehicles.md) for which vehicle gets which.

Rooms are furnished, and their containers roll loot the first time they load,
the same way any building of that kind would.

## Getting out

**Walk out of the door.** That is the normal way out, and there is also a
**Step outside** option on the context menu.

**Which way you walk out decides where you come out.** Leave by the back of a
van and you land behind it. Rooms with a cab (the step vans, the ambulance
bays, the RVs and the buses among them) put you in a free seat when you leave
by the front, starting from the driver's. If every seat is taken you are told
so and put back inside.

If the vehicle has nothing on the side you asked for, you land by its nearest
door instead.

**You come out where the vehicle is now**, not where it was when you went in.
If a friend drove off with you in the back, you come out wherever they parked.

**You cannot step onto the road from a moving vehicle.** If there is a free
seat you can go to it; otherwise you wait until it stops.

## What waits outside

**Zombies gather while you are inside.** The longer you stay, the bigger the
crowd around the vehicle when you come out. Waiting out the night has a cost.

**The ground around you is cleared as you land.** Coming out is a teleport and
you cannot see what you are stepping into, so anything standing within 6
squares is pushed back to the edge of that ring, as far as walls allow. It is
not removed. It is still there and it is still coming; you just get a second
or two to see it.

## Weight

Half the weight of everything in the room is added to the vehicle. A room full
of generators and ammunition makes the van slower to accelerate and brake. It
does not change fuel use.

## Power

**The lights run off the vehicle battery.** A real generator powers the room,
and the vehicle's battery pays for its fuel. Time spent with the fridge
running costs charge, and a flat battery means a dark room.

A tent has no battery, so a tent room is lit only if you park a working
generator beside the tent, close enough to power the tent's own square. The
fuel for the room comes out of that generator.

## Water

Rooms with a flat roof can collect rain. Craft a **Rain Reservoir Kit**
(Carpentry, Woodwork 5 and Mechanics 2: a hammer, 8 planks, 8 nails and 2
tarps), stand in your room, and choose **Install rain reservoir**. Barrels go
up on the roof, and a sink in the room that has been plumbed draws from
them.

A room that already collects rain, or has no roof to put barrels on, refuses
the kit.

## Tents

The four coloured tents (blue, brown, green and yellow) open onto a small
room of their own. Pitch one, right click it and **Go inside**.

You cannot pack a tent away while anybody is inside, or while anything is left
in its room, including items dropped on the floor. Empty the room first. This
is deliberate: packing the tent would otherwise throw away everything in it.

## Walls and fire

By default the outer walls of a room cannot be broken and fires inside are put
out. If a server turns that off, you can break through a wall, but stepping
through the hole puts you back at the vehicle rather than letting you wander
off between the rooms.

## Keeping your room

A room is never taken from you while there are free ones. When every room of
that kind is in use and another vehicle needs one, it is given the room that
has gone unused the longest, and only if nobody has been in it for 14 days.
Whatever was in it is cleared out. The next time you go in through that
vehicle you get a fresh, empty room and a message saying what happened.

Going inside resets the clock. So does claiming the room as a **safehouse**,
which keeps it for as long as the claim stands.

A room somebody else has claimed as a safehouse refuses entry to anybody the
claim does not allow.

If a vehicle is scrapped with a blowtorch, or removed by an admin, its room is
freed for somebody else.

## Logging out inside

Log out in a room and you log back in in it. If your room was taken while you
were away, you are put back where you went in.
