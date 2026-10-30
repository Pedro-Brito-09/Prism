# Performance

Everything here was measured, on one real level, and each table says how. The
same level is used throughout: 34,918 objects from a building game.

## How fast a load goes

A load builds objects for at most 1/120 of a second each frame, then waits for
the next, so the server keeps running while a large level loads. That makes
the load take about three times as long as the building does.

`Budget` changes that per load, in seconds a frame. A game that loads behind a
loading screen can afford more, and `math.huge` builds everything without
waiting at all, which stalls the server for the whole build. Measured on a
real 34,918 object level:

| Budget | Load takes | Frames | Longest frame |
|---|---|---|---|
| 1/120 (default) | 13.7 s | 791 | 0.29 s |
| 1/30 | 5.2 s | 129 | 0.33 s |
| `math.huge` | 4.1 s | 1 | 4.1 s |

The same level was timed again on 2026-10-28, in the game's own place on a
Studio server with one player connected, which is slower than wherever the
table above was measured -- so the two are side by side here, today's code
against the code from before that day's work on links and objects, in the
same session:

| Budget | Load takes now | Before | Frames now | Longest frame now |
|---|---|---|---|---|
| 1/120 (default) | 18.8-19.4 s | 21.4-22.4 s | 1,011-1,062 | 0.32-0.41 s |
| 1/30 | 7.2 s | 8.7 s | 134-137 | 0.54-0.61 s |
| `math.huge` | 4.2-4.4 s | 5.1-5.5 s | 1 | 4.2-4.4 s |

About 15-20% less at every budget, most of it likely what a link used to
build, which was about a fifth of a load's own work. Most of what is left is the engine's: cloning, parenting and writing
each part.

The longest frame is never shorter than reading the pack, which happens in one
go before any building starts: about a third of a second for that level.

A budget that isn't a number above zero warns and falls back to 1/120. The
budget covers telling connected players about the objects as well as building
them: they go out in chunks of 50, as many chunks a frame as the budget allows,
so `math.huge` sends them all in the same stall that built them.

## What a loaded level costs

Measured on 2026-10-22 and 2026-10-23 on the same 34,918-object level (20,287
blocks with parts, 14,631 attributes, 495,279 properties: 14.2 an object),
loaded with the default budget on a Studio server with up to three players.
Both columns were measured again on 2026-10-28, with one player, after a
client stopped keeping a value for every property that arrived, links stopped
being listeners, and objects and properties stopped carrying what their type
shares.

**Memory.** Lua heap, read with `gcinfo()` after allocating garbage until the
collector had run, since an idle VM barely collects:

| | Server | Each client |
|---|---|---|
| Prism required, nothing loaded | 3.4-4.4 MB | 7.4-9.9 MB |
| Level loaded | 114-115 MB | 131-137 MB |
| Per object | about 3.2 KB | about 3.6 KB |
| Per property | about 225 bytes | about 250 bytes |
| After unloading | 4.4-4.7 MB | 12.1-12.7 MB |

Most of it is properties. A property holds only its `Value`, and reads
everything else -- its name, type, constraints, default and methods --
through a table shared by every property of its registry; `SetDefault` gives
it a default of its own. It used to hold eleven fields of its own, and the
level took 535 MB on the server and 576-590 MB on a client: 1.1 KB a property.
A property an instance link drives also holds the instance, reads the type's
own link entry through a shared table of the same kind, and `Set` writes the
instance itself. Links used to be `OnChange` listeners -- a link table, two
functions and a listener array, about 430 bytes for each of the level's
330,259 linked properties -- and the level took 320 MB on the server and
309 MB on a client. Since a link is not a listener, a linked property's
`Listeners` stays nil until something else watches it.

An object reads its methods through a metatable, and shares its name map --
frozen, since every object of the type reads it -- with every object of its
type. With the methods as fields of every object and a name map built for
each, the level took 170 MB on the server and 200 MB on a client. A table's
slots come in powers of two, so
these pay twice: five method fields took an object past 16 keys to 32 slots,
and a property holding two values takes twice the room of one holding one.
The parts themselves are engine memory, not Lua heap: about 8 MB on a client
by the `Instances` memory tag.

Reading a shared field goes through `__index`: about 23 ns instead of 5,
which loading the level does not notice -- 3.8-4.1 s with `math.huge`
against 4.1-4.2 s before, timed side by side.

Building or loading the level allocates far more than it keeps: the server's
heap read 451 MB of garbage straight after the level was built, and fell to
4 MB once the collector ran.

An unload gives the server everything back, and a client all but about
2.5 MB of it. Every object, property and part of the level is collected on a
client once the collector has caught up. What stays is room in the client's
tables of objects by runtime id and of parts: a Luau table keeps that room
after its keys are gone, weak or not, and the next load reuses it, so a
second load and unload read the same. It used to keep about 20 MB, because
the value the server last confirmed was kept for every property as it
arrived: 495,279 entries and 16 MB of hash. It is kept now only for a
property this client edits, and `Objects:CountConfirmed()` says how many
that is. The server holds on to anything still in a player's undo
history: after the edit bursts below, 44 MB of edited objects stayed until
`History:Clear` let them go.

**Frames.** Prism runs nothing per frame, so a loaded level that nobody edits
costs nothing measurable: server frames averaged 16.64 ms against 16.62 with
nothing loaded (p99 18.6 against 18.2 ms, heartbeat work 0.09 ms against
0.10), and clients 16.64 against 16.61.

**Edits, three players at once:**

| Burst | Server frames | Client frames | Result |
|---|---|---|---|
| One `Set` a frame each for 5 s (60 a second, a drag) | p99 18.5 ms, max 19.5 ms | p99 18.5 ms, max 19.4 ms | 906 edits, none refused, every client holding all of them |
| One 1,000-set transaction each, together | p99 18.6 ms, max 29.4 ms | max 19-20 ms | each commit 380-400 ms round trip; every client held the other 2,000 within 0.65 s |

The drag burst ran under a role with `Rate = 120`. The bulk burst ran under
one with a `Rate` high enough for 1,000 operations at once, since a
transaction spends one action per operation.

Studio caps a server at 60 frames a second, so these say whether a frame went
long, not how much headroom was left. The frame times are Studio's, on one
machine running the server and three clients together.
