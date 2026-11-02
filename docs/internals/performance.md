# Performance

What a large level costs to load and to hold.

## The test

Every number here comes from one real level from a building game. Loading and
memory were measured on 2026-10-28 on a Studio server with one player connected.
Frames, edits, garbage, the parts and the undo history were measured on
2026-10-31 with three players, in the same place with the game's own scripts
taken out:

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

On 2026-10-31, without the game's scripts and with three players connected, the
default budget took 10.4-13.4 s over 594-770 frames, the longest 0.40-0.53 s.
`math.huge` took 7.5 s with three players on 2026-11-01, against 8.9 s on the
code of 2026-10-23. A stall that long can trip Studio's script timeout when the
load runs from a Script while players are joining, as it once did here.

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

Parts are engine memory, not Lua heap, so they are not in this table. By the
`Instances` memory tag they cost a client about 8.6 MB: 98.5 MB with nothing
loaded against 107.1 MB with the level.

Building the level allocates far more than it keeps. Building it into a scene
took 10.8 s, after which the server's heap read 194 MB, and 5.8-7.9 MB once the
collector had run.

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
of its own: a property's `Name` took 33.6 ns a read against 13.9 ns for its
`Value`, 28 ns against 8 once the loop's own 5.5 ns is taken off. That doesn't
show in load times.

## Unloading

An unload of a level nobody edited gives the server everything back, and a client
all but about 2.5 MB of it.

Every object, property and part of the level is collected on a client once the
collector has caught up. What stays is room in the client's tables of objects by
runtime id and of parts: a Luau table keeps that room after its keys are gone, and
the next load reuses it, so a second load and unload read the same.

The value the server last confirmed is kept only for a property this client edits,
and `Objects:CountConfirmed()` says how many that is.

The server holds on to anything still in a player's undo history until
`History:Clear` or the [history limits](/guides/history) let it go. After the
edit bursts below, that was 1.8 MB: 112.1 MB against 110.3 MB after
`History:Clear`, which is what the level read before anyone edited it.

After those bursts the server read 11.9 MB once the level was unloaded, against
3.9 MB before it was loaded. The 2026-10-28 run, with one player and no edits,
got everything back.

## While a level is loaded

Prism runs nothing per frame. The microprofiler shows no Prism timer on a server
holding the level, and frames read the same with it as without, on the server
and on all three clients:

| | Level loaded | Nothing loaded |
|---|---|---|
| Average frame | 16.66-16.67 ms | 16.70-16.96 ms |
| p99 | 20.0-23.1 ms | 22.9-30.0 ms |

Nothing loaded read slightly worse, just after an unload, while the engine was
still freeing the parts. The spikes in both are Studio's.

## Edits

Three players at once, on the loaded level:

| Burst | Server frames | Client frames | Result |
|---|---|---|---|
| One `Set` a frame each for 5 s (60 a second, a drag) | p99 23.1 ms, max 29.0 ms | p99 22.1-27.0 ms, max 27.3-30.9 ms | 899 edits sent, 899 landed, none refused, every client holding the others' last values |
| One 1,000-set transaction each, together | one frame of 78-82 ms as the commits land | one frame of 47-52 ms as the others' edits arrive | each commit applied, 433-452 ms round trip; every client held the other 2,000 within 0.43-0.46 s |

The drag burst ran under a role with `Rate = 120`. The bulk burst ran under one
with a `Rate` high enough for 1,000 operations at once, since a transaction
spends one action per operation. Building a 1,000-set transaction takes the
client about 2 ms.

The long server frame is the three commits applying in the frame they arrive:
3,000 sets, each moving a part. The part writes alone take the engine 26-42 ms
in a quiet frame, and they are most of what a set costs. 3,000 `Set`s on the
properties took 28-41 ms against 70-78 ms on the code of 2026-10-23, when a
part was written by a listener on its own thread.

On 2026-11-01 the burst ran on today's code and on that of 2026-10-23, side by
side in the same place. The longest server frame was 56-182 ms today and
49-123 ms on the older code: the same within Studio's noise, and neither came
near the 29 ms recorded on 2026-10-23, so that figure came from different
conditions, not from code since changed. A long stall did not repeat without
the edits.

Studio caps a server at 60 frames a second, so these say whether a frame went
long, not how much headroom was left. They are Studio's frame times, on one
machine running the server and three clients together.
