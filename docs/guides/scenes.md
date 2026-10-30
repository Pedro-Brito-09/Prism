# Scenes and copies

A scene is a document: a named set of objects, and the unit a level is saved and
loaded as. Registering one creates data and nothing else. `Load` reads it into a
live copy.

```luau
-- server
local Rooms = Prism.Scenes.new({Name = "Rooms"})

local room = Rooms:Load()              -- one live copy
room:Create(Crate, {[Health] = 50})
room:Commit()                          -- write this copy back into the scene
room:Unload()                          -- take it out of the world
```

Objects live on the copy, not on the scene, and that is the only place they
could live: ask a scene loaded twice for "the object with local id 4" and there
is no answer — ask a copy and there is.

## Loading more than once

`Load` called twice gives two copies, equals in every way. There is no canonical
one.

```luau
-- server
local a = Rooms:Load(workspace.SlotA)   -- where this copy's folder goes
local b = Rooms:Load(workspace.SlotB)

a:Find(localId)   -- this copy's object
b:Find(localId)   -- the other copy's
a:Unload()        -- takes its own objects, leaves b alone
Rooms:Unload()    -- takes every copy
```

Every copy carries the persistent ids the pack was written with, so five
identical rooms agree on *what* each object is and disagree on *which* one it
is.

## Where the instances live

Every copy owns a folder, and every object's instance is parented into the
folder of the copy holding it. `Load` says where that folder goes:

```luau
-- server
local room = Rooms:Load(workspace.SlotA)
room.Folder                              -- the copy's own folder
```

Name no parent and it lands in the tree Prism keeps for the purpose:

```
workspace
└── __prism
    └── __scene_4
        ├── __copy_11
        └── __copy_12
```

Keyed by the copy rather than the scene, because a scene loaded five times is
five copies and they cannot share a folder.

It is a `Folder`, and that is deliberate: a folder can be parented anywhere, so
a scene made of `ScreenGui` objects loads into `PlayerGui`, a scene of
atmospheres into `Lighting`, and a scene you want to move as a unit into a
`Model` of your own that you pivot. Prism never needs to know what class your
objects are or where that class belongs.

Unloading a copy destroys its folder and everything in it. A default scene
folder goes with the last of its copies; a parent you supplied is yours and is
left alone.

## How fast a load goes

A load builds objects for at most 1/120 of a second each frame, then waits for
the next, so the server keeps running while a large level loads. That makes
the load take about four times as long as the building does.

`Budget` changes that per load, in seconds a frame. A game that loads behind a
loading screen can afford more, and `math.huge` builds everything without
waiting at all, which stalls the server for the whole build. Measured on a

```luau
-- server or client
Level:Load(workspace, {Budget = 1 / 30})          -- faster, choppier
Level:Load(workspace, {Budget = math.huge})       -- one stall, as short as it gets
Draft:Open({Budget = 1 / 30})                     -- server, an opened copy
```

A budget that isn't a number above zero warns and falls back to 1/120. The
budget covers telling connected players about the objects as well as building
them: they go out in chunks of 50, as many chunks a frame as the budget allows,
so `math.huge` sends them all in the same stall that built them.

The measured numbers, on a real 34,918-object level, are under
[Performance](/internals/performance#loading).

## Placing a pack into a copy

Loading reads a pack as a whole new copy, every object under the id it was saved
with. Placing reads one **into a copy that already exists** — pasting a prefab
into a level somebody is editing:

```luau
-- server
local prefab = doorway:Serialize()          -- any pack: a copy's or a scene's

local made = room:Place(prefab)             -- server side, returns the new objects
```

Every object is created afresh under an id the target copy's scene mints, so the
pack's own ids — and its `LastId` — are ignored; they belong to the scene it was
written in. Place the same prefab five times and you get five independent sets.

References inside the pack follow it: a door and the button that works it come
out wired to each other. A reference to anything the pack *didn't* carry is
dropped rather than carried over, because that id means nothing in the target
copy — and if it happens to mean something, it means the wrong thing. A
[reference into another scene](/guides/references#into-another-scene) is the
exception: it means the same thing from anywhere, so it stays.

A client places through a transaction, which makes it one create per object and
so needs create rights and nothing more:

```luau
-- client
Prism.Transactions.new():Place(prefab, room.Id):Commit()
```

One transaction, so it lands whole or not at all and undoes as a single step.

Copies of scenes the client owns have `Place` too, straight on the copy. That
form creates the objects one at a time, so the history records one step each;
the transaction form works on a local copy as well, and is the one to reach for
when the placement should undo as a single step:

```luau
-- client, into a copy it owns
Prism.Transactions.new():Place(prefab, sandbox.Id):Commit()
```

## Setting a copy aside

A copy can leave the world without being unloaded:

```luau
-- server, or a client on a copy it owns
room:Suspend()     -- out of the registries, folder out of the tree, objects held
room:Revive()      -- back exactly as it was
room:Dispose()     -- the end of a suspended copy: its objects, and its folder
```

This is what an unload in a transaction does, and why undoing one can bring the
copy back with what was in it rather than what its scene last committed. A game
can use it directly for the same reason — a room set aside and brought back is
the room that left, down to the values on its objects and anything parented to
its folder. `Unload` stays the final one.

Objects have the same three: `Objects.Suspend(object)`, `Objects.Revive(object)`
and `Objects.Dispose(object)`, with `Objects.Retire(player, object)` for the
suspend-and-offer that a player's destroy goes through. See [History](/guides/history) for what
holds them in between.
