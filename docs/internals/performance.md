# Performance

What a large level costs to load and to hold.

## The test

Every number here comes from one real level from a building game, measured on
2026-10-28 on a Studio server with one player connected:

| | |
|---|---|
| Objects | 34,918 |
| Blocks with parts | 20,287 |
| Block attributes | 14,631 |
| Properties | 495,279, about 14 an object |
| Properties driving a part | 330,259 |

A range means the runs differed by that much. Nothing here has been measured on a
live server, so read these as a comparison between settings, not as a promise.

## Loading

A load builds objects for at most 1/120 of a second each frame, then waits for the
next, so the server keeps running while a large level loads. Waiting makes a load
take about four times as long as the building does.

`Budget` changes that per load, in seconds a frame:

| Budget | Load takes | Frames | Longest frame |
|---|---|---|---|
| 1/120 (default) | 18.8-19.4 s | 1,011-1,062 | 0.32-0.41 s |
| 1/30 | 7.2 s | 134-137 | 0.54-0.61 s |
| `math.huge` | 4.2-4.4 s | 1 | 4.2-4.4 s |

Choose by what the player is doing. The default suits a level loading into a running
game, and a game behind a loading screen can afford more. `math.huge` is the fastest
and stalls the server for the whole build.

- **The shortest possible frame** is the time to read the pack, which happens in one
  go before any building starts: about a third of a second for this level.
- **Most of the time is the engine's:** cloning, parenting and writing each part.
- **The budget covers telling players too.** Objects go out in chunks of 50, as many
  chunks a frame as the budget allows, so `math.huge` sends them all in the same
  stall that built them.

A budget that isn't a number above zero warns and falls back to 1/120.

## Memory

Lua heap, read with `gcinfo()` after allocating garbage until the collector had run,
since an idle VM barely collects:

| | Server | Each client |
|---|---|---|
| Prism required, nothing loaded | 3.4-4.4 MB | 7.4-9.9 MB |
| Level loaded | 114-115 MB | 131-137 MB |
| Per object | about 3.2 KB | about 3.6 KB |
| Per property | about 225 bytes | about 250 bytes |
| After unloading | 4.4-4.7 MB | 12.1-12.7 MB |

Parts are engine memory, not Lua heap, so they are not in this table.

Most of the heap is properties, so the design keeps each one small:

- **A property holds only its `Value`.** Its name, type, constraints, default and
  methods are read through a table shared by every property of its registry.
  `SetDefault` gives one a default of its own.
- **A linked property also holds the instance it drives.** Its link is the object
  type's own entry, shared the same way, and `Set` writes the instance itself. A
  link is not a listener, so `Listeners` stays nil until something else watches
  the property.
- **An object shares what its type shares.** Its methods come through a metatable,
  and its name map is frozen and shared by every object of the type.

Reading a shared field goes through `__index`, which is slower than reading a field
of its own, but that doesn't show in load times.

## Unloading

An unload gives the server everything back, and a client all but about 2.5 MB of it.

Every object, property and part of the level is collected on a client once the
collector has caught up. What stays is room in the client's tables of objects by
runtime id and of parts: a Luau table keeps that room after its keys are gone, and
the next load reuses it, so a second load and unload read the same.

The value the server last confirmed is kept only for a property this client edits,
and `Objects:CountConfirmed()` says how many that is.

The server holds on to anything still in a player's undo history until
`History:Clear` or the [history limits](/guides/history) let it go.

## While a level is loaded

Prism runs nothing per frame, so a loaded level that nobody edits has no per-frame
work of its own.
