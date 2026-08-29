# Handover — first build session

Written at the end of the session that created this repo. `CLAUDE.md` at the
repo root carries the same material in the form a new Claude Code session will
load automatically; this file is the human version, plus the things that are
about the *session* rather than the code.

## Where this came from

You wanted your own take on the PZ RV interior mods, finding them all "a little
problematic". We reviewed the most common one — workshop `3543229299`,
`modPROJECTRVInterior` 2.3, 1,782 lines of Lua plus a map mod — and built
around its failures.

Its five real problems, all of which became requirements here:

1. Room slots were assigned once and never freed. Destroy the van and the slot
   was gone forever; at 38 slots per class the pool exhausted and the feature
   silently stopped working with no message and no log.
2. Exit position came from a one-minute client ping, so another player driving
   your van dropped you up to sixty seconds in the past, or inside geometry.
3. Recovery minted a fresh random player id and rebuilt state by proximity.
4. Power and water were props — `setFuel(10)` on every entry, every fluid
   container topped to capacity.
5. Exit cleanup deleted corpses along with zombies, so loot vanished.

Structurally it also shipped SP and MP as two drifting implementations and
leaked six globals.

## Decisions you made during design

These are settled. If a future session proposes reopening one, this is why it
was closed.

- **Borrow any map for the PoC.** It genuinely does not matter which; the room
  set is data, so the provider swaps later with no code change.
- **One exit, three doors into it.** Door, hole in the wall, and leash
  violation are the same event: respawn relative to the vehicle. You said
  explicitly not to treat a breach as anything more than that.
- **PhunServer2 is a hook, never a dependency.** PhunLib was the only hard
  requirement at the time. *Superseded:* PhunLib is now deprecated and its three
  helpers are folded into `shared/PhunInteriors/tools.lua`. The mod has no hard
  dependencies at all.
- **Registry built for many, phase 1 uses one.** Vans and semis get separate
  room sets by design; the second class is authoring work, not architecture.
- **Every constraint is a sandbox switch,** defaults set to the balanced
  behaviour, so an admin turns the constraints *off* rather than being denied.
- **Interior weight transfers as a percentage,** default 50%.

## What changed during the build

Three things were discovered by checking rather than assuming, and two of them
contradicted the plan you approved. Details and evidence are in `CLAUDE.md`
under "B42 API constraints".

1. **`ISOpenCloseDoor` does not exist in B42.** The plan said to hook it for
   door-as-exit. It is Java-side with no Lua hook, so the exit became
   positional. This turned out better — it made the exit test and the leash
   test the same test, which is the collapse you had asked for.
2. **Walls cannot be made unbreakable from Lua.** `IsoObject` has
   `getThumpable` with no setter, and `IsoGridSquare` exposes no fire flags.
   `HardenShell` now means what is achievable: refuse the player destroy
   actions, and douse fires inside occupied rooms. This matters less than it
   would have, because containment never depended on it.
3. **The weight mechanic works, but will not touch fuel.** `setMass` and
   friends are Lua-reachable and proven by the shipped More Traits mod. But
   vanilla's burn formula reads the *static* script mass, so a loaded interior
   degrades handling and not consumption.

Two options were cut for honesty rather than scope: `SleepRequiresPower`
(depends on the v2 power system) was removed entirely, and `LeaseWarningDays`
was implemented rather than left dead.

## State of the code

20 Lua files, ~2,150 lines. All parse under LuaJIT. Options, defaults and
translation keys cross-check. Require graph resolves.

**Nothing has been run in-game.** That is the single most important caveat.
The riskiest areas, in order:

1. **Manifest capture** — needs the golden slot's chunk loaded. It refuses to
   cache an empty scan and retries on a ten-minute timer, but this path has
   never actually fired.
2. **Teleport and occupancy** — the whole enter/leave loop is untested.
3. **Mass application** — `pcall`-wrapped, so failure degrades to "no weight
   penalty" rather than breaking entry, but it has never been called.
4. **The client destroy guards** — they assume `ISDestroyStuffAction` and
   `ISDestroyCursor` shapes that were read from the vanilla source but not
   exercised.

## Suggested first session back

1. Get it loading. Deploy via VS Code save, start a SP world with the reference
   mod enabled (needed for the borrowed coordinates), check the log for the
   `ready. 14 day leases, weight factor 50%` line.
2. Drive a van somewhere, use the radial menu, see whether you end up in a room.
   Everything downstream depends on this working.
3. Walk onto the exit tile. Then deliberately walk out of bounds and confirm
   the leash catches you.
4. Only then worry about manifest, scrub and weight.

Turn `Debug` on in sandbox options first — most of the interesting paths log
through `Core.debugLn`.

## Then

Your own map, which is the thing that takes this from a proof of concept to a
mod. When it exists, only `origin` and `count` in `defaults.lua` change.
