# PhunInteriors

Instanced vehicle interiors for Project Zomboid **Build 42**, in single player
and multiplayer.

Right click a van, go inside, and you are standing in a room that belongs to
that van: a mechanic's workshop, a mail sorting room, a caravan, a classroom
in the back of a school bus. Leave something there and it is there next time.
Drive somewhere with a friend in the back and they come out wherever you
parked.

## Features

- **83 furnished rooms** for vans, step vans, ambulances, buses, trucks,
  semi trailers, caravans, RVs, shipping containers and tents, including
  vehicles from several popular vehicle mods. See
  [the full list](Docs/vehicles.md).
- **Walk in, walk out.** Board at the door, and leave by walking out of the
  room. Which way you walk out decides which side of the vehicle you land on,
  and rooms with a cab can put you straight into a free seat.
- **Your room is yours.** Rooms are only ever reused when every room is taken
  and yours has gone unused for two weeks (configurable, or never). You are
  told if it happens. A room claimed as a safehouse is never reused.
- **It costs something.** What you store adds to the vehicle's weight. The
  lights run off the vehicle battery. Zombies gather while you are inside.
- **Coming out is survivable.** The ground around you is cleared as you land,
  because you cannot see what you are stepping into.
- **Rain water.** Craft a reservoir kit and put barrels on your room's roof.
- **Tents** open onto rooms too, powered by a generator you park beside them.
- **Multiplayer first.** Tested on a real dedicated server, including towing
  and passengers going into the back of a moving van.
- **Every constraint is a sandbox option.** See
  [sandbox options](Docs/sandbox-options.md).
- **An in-game room editor** for admins, with changes saved to a file.
- **Open to other mods.** Register rooms for your own vehicles, bind your
  vehicles to ours, or put a room behind a placed object.

## Documentation

| Page | For |
|---|---|
| [Playing](Docs/playing.md) | Players: getting in, getting out, power, water, tents, keeping your room |
| [Supported vehicles](Docs/vehicles.md) | Which vehicle gets which room |
| [Sandbox options](Docs/sandbox-options.md) | Server owners: every option and its default |
| [Running a server](Docs/admin.md) | Admins: the room window, the editor, console commands |
| [Adding rooms and vehicles](Docs/modding.md) | Mod and map authors: the registry API and map rules |
| [How it works](Docs/how-it-works.md) | Anybody curious why it behaves the way it does |
| [Test plan](Docs/testplan.md) | Testers |

## Requirements

Build 42. Nothing else: there are no required mods. PhunServer2 adds an
`/interiors` chat command when it is installed.

The mod ships its own map: a separate block of 18 cells, away from anywhere a
player walks to, holding 990 room slots. It uses cells 87,46 to 91,48 and
89,49 to 91,49, and another map mod using any of them will conflict.

## Status

Proven in game in single player and on a dedicated server: entering and
leaving, containment, seat and door restore, blueprint capture and scrub, the
lease lifecycle, weight, towing, the wall and fire guards, and fire dousing.

Built and covered by the automated tests, but not yet seen in game: the
current exit rules (which side you land on, and the cab seat), reclaiming on
demand, power from the vehicle battery, the rain reservoir, tents and other
placed objects, the room editor and its save file, the exit zombie clearing,
and rooms with no vehicle behind them. `CLAUDE.md` under "Known gaps" says what
to watch for in each.

## Development

```bash
bash Tests/run.sh
```

Parses every Lua file, runs three static checks and then the specs (742
checks). It fakes just enough of the game to test the pure Lua logic; anything
needing a real map square is tested in game or not at all.

Every other tool is in `scripts/`, and the perl ones are run from the repo
root (`perl scripts/roomcheck.pl`):

- `deploy.cmd` builds the mod into `~/Zomboid/mods` on save, plus a test build
  under a separate id and Workshop staging for both.
- `map.cmd` copies a map export in, checks it, deploys and resets the test
  save. `tighten.cmd` fixes the editor's border lots before an export.
- `methods.pl` and `body.pl` show what a Java method in the game actually does.
- `tiles.pl`, `rooms.pl`, `zombies.pl` and `cells.pl` show what a map cell
  contains and who claims it.
- `roomcheck.pl` and `fencecheck.pl` check the registry and the fence against
  the map that ships.
- `gendefaults.pl` and `vehicledoc.pl` regenerate the room registry and
  [Docs/vehicles.md](Docs/vehicles.md) from the room and vehicle sheets. The
  sheets are not in the repository.

## Credits

By UburGeek, for the [PhunZoid](https://discord.gg/v2USyAtP6q) community.
