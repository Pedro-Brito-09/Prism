this originally wasn't going to be vibe coded but it got too big and I lowkey didn't wanna spend much time debugging; a lot of stuff still made by hand by me :)

# Prism

Prism is a framework for building level editors in Roblox games. It handles the
parts every editor needs and nobody wants to write twice:

- **Typed, constrained properties** and object types built from them, with
  templates and links that drive the instances.
- **Scenes** — levels as documents you load, edit, save and load again, as many
  copies at once as you like, with references between objects that survive it.
- **Multiplayer editing** — replication, permissions per scene, locks and
  presence, and a rate limit the server enforces.
- **Transactions** that land whole or not at all, and **undo / redo** per
  player across the server's scenes and the client's own.
- **Storage** in a compact binary format that survives schema changes, and a
  sharded DataStore database for browsing and searching levels.

> **Status:** structurally complete, played through in Studio with up to
> three players, and stress tested under a poor network, with 5,000-object
> levels, with streaming, and with concurrent DataStore writes. Those passes
> found ten bugs, all fixed, and every suite in `tests/` runs green. It has
> not shipped in a live game yet — see `ROADMAP.md`.

## Contents

- [Getting started](#getting-started)
- [Properties](#properties)
- [Objects](#objects) — [basics](#basics), [locks](#locks),
  [dragging](#dragging-clientsided), [references](#references)
- [Scenes](#scenes)
- [Transactions](#transactions)
- [History](#history)
- [Selection](#selection)
- [Permissions](#permissions)
- [Database](#database)
- [Networking](#networking)
- [API at a glance](#api-at-a-glance)
- [Storage format](#storage-format)
- [Contributing](#contributing)
- [Tests](#tests)
- [Type checking](#type-checking)
- [License](#license)

## Getting started

### Requirements

Prism is written in current Luau: it uses `const` and string requires
(`require("@self/...")`). It needs a Roblox Studio recent enough to run both;
an older one fails to parse the modules rather than failing at runtime.

### Installing

Insert [`dist/Prism.rbxmx`](dist/Prism.rbxmx) into ReplicatedStorage: drag it
into Studio, or right-click ReplicatedStorage → **Insert from File**. It is one
ModuleScript called `Prism`, with nothing to move and nothing to set. Require it
from a server script and a client script; it resolves the server or client half
of each subsystem for you.

```lua
local Prism = require(ReplicatedStorage.Prism)
```

It can live anywhere **both sides can see**; ReplicatedStorage is the usual
place. To update, delete the old `Prism` and insert the new one.

The source is `src/` (`init.luau` is the module itself), and
`node scripts/build.js` rebuilds the models in `dist/` from it. CI fails a push
that changes the source without rebuilding them.

Require it on the server before any client does: the client waits for the
server to say it is ready, and warns if it never does.

### A first editor, end to end

Register what exists on the server, once. Registries replicate to every client,
including ones that join later.

```lua
-- server
local Tint = Prism.Properties:Register({Name = "Tint", Type = "Color", DefaultValue = Color3.new(1, 1, 1)})

local Crate = Prism.Objects:Register({
    Name = "Crate",
    Properties = {Tint},
    Instance = ReplicatedStorage.CrateTemplate,
    Links = {{Property = Tint, Type = "Property", Name = "Color"}},
})

Prism.Permissions:Register("Builder", {
    Global = {Rate = 120},
    Scene = {CanCreate = true, CanEdit = true, CanDestroy = true},
})

local Level = Prism.Scenes.new({Name = "Level 1"})
local room = Level:Load()

Players.PlayerAdded:Connect(function(player)
    Prism.Permissions:Grant(player, "Builder")
    Level:Grant(player, "Builder")
end)
```

Edit from the client. A create goes through a transaction; a set is applied
straight away and confirmed by the server afterwards.

```lua
-- client: registry ids are the server's, so look them up by name
local function idOf(registered, name)
    for id, registry in registered do
        if registry.Name == name then return id end
    end
end

local Crate = idOf(Prism.Objects:GetRegistered(), "Crate")
local Tint = idOf(Prism.Properties:GetRegistered(), "Tint")

local edit = Prism.Transactions.new()
edit:Create(Crate, {[Tint] = Color3.new(1, 0, 0)}, roomCopyId)
local ok, created = edit:Commit()

-- Commit answers with the new runtime ids; the object itself replicates just after.
local crate = Prism.Objects:Get(created[1])
while not crate do
    task.wait()
    crate = Prism.Objects:Get(created[1])
end

crate:Set(Tint, Color3.new(0, 1, 0))

Prism.History:Undo()   -- back to red
```

Save on the server when the player asks to.

```lua
-- server
room:Commit()
Level:Save(DataStore)     -- the draft, under Level.Guid
Level:Publish(DataStore)  -- what players get
```

`roomCopyId` is the id of the copy the server loaded. A client hears of a copy
through `Prism.Scenes:OnCopyAdded` as it arrives, and finds one that is already
here with `Prism.Scenes:GetInstances(Prism.Scenes:Get("Level 1").Id)`, which
lists the live copies of a server scene. `OnCopyAdded` does not replay copies
that arrived before it was connected. Registries arrive shortly after the client
requires Prism, so wait for them before looking ids up. The sections below go
through each piece.

## Properties

A property is a typed, constrained field. Register it once on the server; the
registry replicates to every client, including late joiners.

```lua
-- server
local Health = Prism.Properties:Register({
    Name = "Health",
    Type = "Number",
    DefaultValue = 100,
    Constraints = {MinValue = 0, MaxValue = 100, AllowDecimals = false},
})
```

| Type | Value | Constraints |
|---|---|---|
| `Text` | `string` | `MinLength` (rejects), `MaxLength` (truncates) |
| `Number` | `number` | `MinValue`, `MaxValue` (clamp), `AllowDecimals` (rounds when `false`), `Precision` (snaps to steps of it from `MinValue`) |
| `Bool` | `boolean` | — |
| `Color` | `Color3` | `R`, `G`, `B`, each a set of `Number` constraints on 0–255 |
| `Vector` | `Vector3` | `X`, `Y`, `Z`, each a set of `Number` constraints |
| `CFrame` | `CFrame` | — |
| `Enum` | an `EnumItem` | `Enum` (required: which enum), `Whitelist`, `Blacklist` (items or names) |
| `CustomEnum` | an option of a custom enum | `CustomEnum` (required), `Whitelist`, `Blacklist` (options or option ids) |
| `Object` | another object | `Types` (object type ids or names) |
| `Table` | a list of values of one other type | `Of` (required: the item type, any but `Table`), `Item` (that type's constraints, applied to every item), `MinItems` (rejects), `MaxItems` (truncates; at most 4096, which is also the default) |

A `Color` is held and saved at 8 bits per channel, the 0–255 its constraints
are written in: each channel is scaled to 0–255, rounded to the nearest and
clamped, so `Color3.new(0.5, 0, 0)` reads back with a red of 128/255, about
0.502, and a channel past 1 is stored as 255. A color made with
`Color3.fromRGB` comes back exactly, and so does any color that has been
through a set once. Compare colors after a set, not the value passed in.

A value that fails a rejecting constraint is refused — `Set` returns `false` —
and one outside a clamping constraint is brought into range.

`Object` is a reference to another object — a button's door, a path node's next
node. It's stored as a local id, so it's saved and duplicated like one; see
[References](#references) for what that buys you and what it rules out.

A `Table` is a list, every item one type and held to that type's constraints:

```lua
-- server
local Doors = Prism.Properties:Register({
    Name = "Doors",
    Type = "Table",
    DefaultValue = {},
    Constraints = {Of = "Object", MaxItems = 8},
})

lever:Set(Doors, {doorA, doorB})
lever:Get(Doors)    -- the objects it names, in order
```

A list is handed back frozen, and two lists holding the same items are the
same value, so setting an equal list is no change. A `Table` of `Object` reads
as the objects its items name; an item whose target isn't there is left out of
what `Get` returns but kept in the list, as a single reference keeps its id. A
`Table` cannot drive an instance member, so a `Links` entry naming one is
dropped at registration.

A custom enum is a named list of options with ids that are saved in place of the
values, so the values can be anything. Register it **on both sides** under the
same name — a client checks a `CustomEnum` constraint against its own copy. A
client may register it whenever it likes. Until it does, it warns once per
property and holds that property's values as **pending** options: the enum's
name and the option `Id`, `Pending = true`, and no `Value`. Registering the enum
swaps each one for the real option and fires `OnChange`. A save or a server
that meets an enum it has not registered keeps the option the same way, rather
than dropping which one it was.

```lua
-- server and client
local Material = Prism.CustomEnum:Register("Material", {Wood = 1, Stone = 2, Metal = 3})

-- server
local Surface = Prism.Properties:Register({
    Name = "Surface",
    Type = "CustomEnum",
    DefaultValue = Material:GetByValue("Wood"),
    Constraints = {CustomEnum = Material},
})

crate:Set(Surface, Material:GetById(2))   -- Stone
```

Option ids are whole numbers up to 65535 and, like property ids, should never be
reused for a different option: saved data holds the id.

`Display` says how a property presents itself in an editor, so a property panel
can be generated from the registry instead of written by hand for each property.
It replicates with the registry.

```lua
local Speed = Prism.Properties:Register({
    Name = "Speed",
    Type = "Number",
    DefaultValue = 1,
    Display = {Category = "Motion", Order = 2, Description = "Studs a second"},
})

-- Grouped by category, sorted by Order, hidden properties left out.
for _, section in Prism.Properties:Layout(Prism.Objects:GetRegistry(object.Registry).Properties) do
    panel:AddHeader(section.Category)
    for _, registry in section.Properties do
        panel:AddField(registry, registry.Display)
    end
end
```

Every field is optional. `Category` defaults to `"General"` and `Order` to 0;
properties with the same order keep the order the object type lists them in.
`Hidden` properties are left out of a layout unless you pass `true` as its
second argument. `ReadOnly` is presentation only: it greys a field out but
doesn't stop a write. To stop one, put the property in a role's
`Properties.Blacklist`. A field of the wrong type falls back to its default,
with a warning.

`Properties:Unregister(id)` drops a property on the server and on every client.
It's refused while an object type or a database is built on it. The id is never
handed out again, because saved data names it.

## Objects

An object type is a named set of properties, optionally backed by a template
instance. `Objects.new` clones that template per instance.

```lua
-- server
local Enemy = Prism.Objects:Register({
    Name = "Enemy",
    Properties = {Health},
    Instance = ReplicatedStorage.EnemyTemplate,
    Links = {
        {Property = Health, Type = "Attribute", Name = "Health"},
    },
})

local enemy = Prism.Objects.new(Enemy)
enemy:Set(Health, 50)
enemy:Get("Health")
enemy:Destroy()
```

A registry replicates whole, template and links included, so a client can build
the same objects the server does. The template travels as a reference and
resolves only on a client it replicates to: keep it in ReplicatedStorage if a
client will ever build these objects itself, or in ServerStorage if only the
server will. A client that needs a template it can't see warns once for that
type, the first time it tries to build one.

`Replicate` says who is sent an object's data: `"Everyone"`, the default, or
`"Admitted"`, meaning only the players its scene admits. Scenery that no client
script reads can be `"Admitted"`. Players still see its parts, which replicate
on their own, and only the people editing pay for its properties. Keep the
default for anything a client script reads, like a spinning part's speed. An
object's data goes whole or not at all. Any value other than those two strings
counts as `"Admitted"`, with a warning.

`Objects:Unregister(id)` drops an object type on the server and on every client.
It's refused while any object of the type is live, and it releases the
properties the type was holding. Like property ids, the id is never reused.
Saved objects of an unregistered type are kept as they were and written back —
see [Storage format](#what-this-build-cannot-read-is-kept).

`Objects:OnAdded` and `Objects:OnRemoved` fire on **both sides** for every
object that appears or goes, so neither a panel nor a server script has to poll
`GetWorkspace()` to notice one.

```lua
-- server or client
local stop = Prism.Objects:OnAdded(function(object, restored)
    outliner:Add(object)
end)
```

On the server that is every object created, restored by a scene load, revived
from a suspend, destroyed, suspended, or taken away with the copy that held it.
On the client it is every object replicated to it, built in a scene it owns, or
drawn for an opened copy.

An added object is already filed, so `Objects:Get` and `copy:Find` both answer
for it. A removed one is already torn down and reports `Destroyed`, but still
carries its ids. Both return a disconnect function.

`OnAdded` is also handed whether the object was **restored** — read back from a
pack under the id it was saved with, rather than created by anyone. Loading a
level is one of these per object and is not the same event as somebody placing
one; the history uses exactly this distinction to keep a level load out of the
undo stack.

The signals are not the packets. A scene load builds its objects silently and
sends them in one batch afterwards; `OnAdded` fires either way, because it is
about the object existing rather than about anybody being told.

### Basics

Every object carries two ids: `RuntimeId`, which names this live copy of it, and
`PersistentId`, which is saved with it and outlives a reload. See Scenes.

`object.Registry` is the id of the object's type, the one `Objects:Register`
returned; `Objects:GetRegistry(object.Registry)` gives the type itself.

A link mirrors a property onto the instance. `Type = "Property"` writes a real
instance property (the types must match), `Type = "Attribute"` writes an
attribute. `Descendant` targets a child instead of the root.

`Set`, `Get`, `OnChange` and `GetProperty` all take either the property id or
its name, and a name costs the same as an id to resolve.

`Objects:Duplicate(object, copy?)` makes a new object of the same type holding
the same values, in the original's copy unless you name another. It gets a new
local id and a part of its own. On the client this works for objects in scenes
the client owns; an object the server holds is duplicated with a transaction's
`Duplicate`, which checks create rights like any other create.

`Objects:DuplicateGroup(objects, copy?)` duplicates several as one thing, which
is not the same as calling `Duplicate` on each: references *between* the
originals are remapped onto the copies, and references pointing outside the
group are left alone. Duplicate a room and its buttons work its own doors;
duplicate one lever and it still works the door it always worked.

Watch a single property without paying for a signal on every property:

```lua
-- server or client
local disconnect = enemy:OnChange(Health, function(value)
    print("health is now", value)
end)

disconnect()
```

Watching a property the object does not carry warns and hands back a disconnect
that does nothing, so the caller never has to guard the release.

`GetProperty` returns the property instance itself, for what `Get` and `Set` do
not cover:

```lua
enemy:GetProperty("Health").Constraints.MaxValue
```

### Locks

A client takes a lock when it starts on an object. While it holds one, nobody
else may edit or destroy that object, so two people cannot drag one part at
once.

```lua
-- client
if Prism.Objects:Lock(selected) then   -- one object or a list: all or none
    -- drag
    Prism.Objects:Unlock(selected)
end

Prism.Objects:IsLocked(object)         -- held by anyone at all
Prism.Objects:GetLock(object)          -- the holder's user id, or nil
Prism.Objects:OnLockChanged(function(runtimeId, userId, held) ... end)
```

Taking a lock needs edit rights on the object, costs one action per object, and
fails if anyone else holds any of the objects named. Releasing needs no rights.
`IsLocked` and `GetLock` answer for your own holds as soon as `Lock`, `Unlock`
or a transaction holding them returns.

On a client, `Set` and `Destroy` on an object someone else holds are refused on
the spot — `false`, and nothing shown — rather than applied and taken back when
the server says no. On the client `Permissions:Can` says no to
an edit or a destroy of an object someone else holds, so a tool greyed out by
it is greyed out for held objects too. Listen to `Objects:OnLockChanged` to
refresh it when a hold comes or goes.
A transaction can take and release them too, in the same list as the edit they
are for — see Transactions.

**The server can hold a lock itself.** On the server, `Objects:Lock(list,
holder)` takes a Player, a user id, or any other value naming who holds it — a
string like `"DoorAnimator"`, a module, a table. That lets a system keep players
off an object while it works on it, such as animating a door open, with no
player involved:

```lua
-- server
Prism.Objects:Lock(door, "DoorAnimator")
-- animate the door; no player can edit it meanwhile
Prism.Objects:Unlock(door)
```

`GetHolder(object)` gives back whatever holds it. `GetLock(object)` gives only a
player's user id, and `nil` both when nothing holds the object and when the
holder isn't a player — so use `IsLocked(object)` to ask whether anything holds
it at all.

A lock is released when its object goes, or when its holder **leaves**, is
**evicted from the scene** or **loses edit rights on it** — any of those would
leave somebody holding objects they can no longer touch, and nobody else able to
touch them either.

The server's own edits ignore locks. The server can take locks on a player's
behalf with `Objects:Lock(list, player)`, which is refused the same way if
someone else holds any of them, and release anyone's with
`Objects:Unlock(list)`.

Who holds what is presence as well as a lock. It's told only to the players the
object's scene admits, because who is editing a private level is part of the
level. Objects in scenes a client owns are never locked; nobody else can touch
them.

### Dragging: `ClientSided`

On the client, `Set` takes a third argument. `true` shows the value on this
client and sends nothing; the next `Set` without it sends the value it lands on,
once. Pass it every frame of a drag and leave it off when the drag ends:

```lua
-- client, while the gizmo moves
crate:Set(Position, pointer, true)

-- on release
crate:Set(Position, pointer)
```

A plain `Set` per frame costs one action of the player's budget each, so a drag
at sixty frames a second sits exactly on the default `Rate` and starts being
refused, and a refusal snaps the value back mid-drag. With `ClientSided` the
drag costs one action and is one step of history however long the player
paused in it.

- **Nothing else sees the preview.** `OnChange` and links fire, so the part
  moves; `Objects:OnEdited` does not, because no edit has been made yet. The
  closing `Set` fires it once, with `Before` being the value from before the
  preview began. That holds for a part the server built too: a client drives
  its links on every part it can see, writing only its own view of the part,
  which the server's value replaces once the edit lands or is refused.
- **Cancelling** is ending the preview on the value it started from: that sends
  nothing and records nothing.
- **A refusal** of the closing `Set` rolls back to what the server holds, as any
  refused set does.
- **Someone else's edit** to the same property during a preview does not move
  it; it becomes the value a refusal or a cancel returns to.
- A preview left open on a server object is just a value shown on one client:
  the server and every other player never see it. In a scene the client owns
  the shown value is the value, so committing that scene saves it.

The argument is ignored on the server, where every set is already the real one.
It works the same on an object in a scene the client owns, where nothing is sent
either way but the history still records the drag as one step.

### References

An `Object` property points at another object.

```lua
-- server
local Target = Prism.Properties:Register({
    Name = "Target",
    Type = "Object",
    DefaultValue = 0,                       -- 0 is "points at nothing"
    Constraints = {Types = {Door}},         -- optional; ids or type names
})

button:Set("Target", door)                  -- takes the object
button:Get("Target")                        -- hands back the object, not a number
```

What's stored is the target's **local id** — the low half of its persistent id —
so a reference is saved exactly as the pack's own ids are, and survives a save
and a reload without anything having to rewrite it.

It resolves through the copy holding the object doing the pointing, which is the
whole point: load one room twice and each copy's button works that copy's own
door. That also fixes the boundary. **A reference only ever names an object in
the same copy.** Pointing at one in another copy is refused, and cross-scene
references are out of scope — the id would mean nothing once either scene was
loaded somewhere else.

`Get` answers `nil` in three cases it does not tell apart: nothing is pointed
at, the target was destroyed, and the target has not arrived yet — a copy builds
its objects one at a time, so a button exists before its door does, and on a
client either half can replicate first. The stored id is kept in all three, so
the link comes back on its own when the target does. To read the raw id, go
through the property: `button:GetProperty("Target").Value`.

`Objects:Resolve(copyId, localId)` answers the same question from a raw id, for
a caller holding one that did not come off a property — the crossing itself,
scoped to a copy because that is the only scope a local id answers in.

`Constraints.Types` says what the property may point at, by object type id or
registered name. It's checked when the target actually resolves; an id naming
nothing is always allowed, because refusing one would make a pack restorable
only in the order it happened to be written.

Two things worth knowing. A reference can't drive an instance member, so a
`Links` entry naming one is dropped at registration — a local id on a part would
mean nothing outside its copy. And a reference follows one object, not its
lookalikes: undoing a destroy brings back **that same object** under its own
local id, so every reference to it works again (see
[History](#a-destroy-is-deferred-not-undone)), but a duplicate or a placed copy
is a new object with a new id, and references to the original stay on the
original. `DuplicateGroup` and `Place` remap the references *inside* what they
copy.

Creating two objects already wired to each other takes one transaction, because
neither id exists until the server mints it:

```lua
-- client
local edit = Prism.Transactions.new()
edit:Create(Button, {}, room.Id)
    :Create(Door, {}, room.Id)

-- the button's Target points at whatever operation 2 creates
edit.Operations[1].References = {[Target] = 2}
edit:Commit()
```

`Transactions.new():DuplicateGroup(objects, copy?)` does this for you, and is
what a client uses to duplicate a selection with its references intact.

## Scenes

A scene is a document: a named set of objects, and the unit a level is saved and
loaded as. Registering one creates data and nothing else. `Load` reads it into a
live copy.

```lua
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

### Loading more than once

`Load` called twice gives two copies, equals in every way. There is no canonical
one.

```lua
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

### Where the instances live

Every copy owns a folder, and every object's instance is parented into the
folder of the copy holding it. `Load` says where that folder goes:

```lua
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

### How fast a load goes

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

The longest frame is never shorter than reading the pack, which happens in one
go before any building starts: about a third of a second for that level.

```lua
-- server or client
Level:Load(workspace, {Budget = 1 / 30})          -- faster, choppier
Level:Load(workspace, {Budget = math.huge})       -- one stall, as short as it gets
Draft:Open({Budget = 1 / 30})                     -- server, an opened copy
```

A budget that isn't a number above zero warns and falls back to 1/120. The
budget covers telling connected players about the objects as well as building
them: they go out in chunks of 50, as many chunks a frame as the budget allows,
so `math.huge` sends them all in the same stall that built them.

### What a loaded level costs

Measured on 2026-10-22 and 2026-10-23 on the same 34,918-object level (20,287
blocks with parts, 14,631 attributes, 495,279 properties: 14.2 an object),
loaded with the default budget on a Studio server with up to three players.

**Memory.** Lua heap, read with `gcinfo()` after allocating garbage until the
collector had run, since an idle VM barely collects:

| | Server | Each client |
|---|---|---|
| Prism required, nothing loaded | 3.4-4.4 MB | 7.4-8.1 MB |
| Level loaded | 320 MB | 342 MB |
| Per object | about 9.1 KB | about 9.6 KB |
| Per property | about 640 bytes | about 690 bytes |
| After unloading | 4.4 MB | 26-32 MB |

Most of it is properties. A property holds only its `Value` and its
`DefaultValue`, and reads everything else -- its name, type, constraints and
methods -- through a table shared by every property of its registry. It used
to hold eleven fields of its own, and the level took 535 MB on the server and
576-590 MB on a client: 1.1 KB a property. A property an instance link drives
also carries a `Listeners` table and the link's two functions. The parts
themselves are engine memory, not Lua heap: about 8 MB on a client by the
`Instances` memory tag.

Reading a shared field goes through `__index`: about 23 ns instead of 5,
which loading the level does not notice -- 3.8-4.1 s with `math.huge`
against 4.1-4.2 s before, timed side by side.

Building or loading the level allocates far more than it keeps: the server's
heap read 451 MB of garbage straight after the level was built, and fell to
4 MB once the collector ran.

An unload gives the server everything back. A client keeps about 20 MB of
Lua heap and the level's 8 MB of instances after the copy is gone, the same
after two loads and unloads as after one, so it does not grow. What holds it
has not been traced. The server holds on to anything still in a player's undo
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

### Placing a pack into a copy

Loading reads a pack as a whole new copy, every object under the id it was saved
with. Placing reads one **into a copy that already exists** — pasting a prefab
into a level somebody is editing:

```lua
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
copy — and if it happens to mean something, it means the wrong thing.

A client places through a transaction, which makes it one create per object and
so needs create rights and nothing more:

```lua
-- client
Prism.Transactions.new():Place(prefab, room.Id):Commit()
```

One transaction, so it lands whole or not at all and undoes as a single step.

Copies of scenes the client owns have `Place` too, straight on the copy. That
form creates the objects one at a time, so the history records one step each;
the transaction form works on a local copy as well, and is the one to reach for
when the placement should undo as a single step:

```lua
-- client, into a copy it owns
Prism.Transactions.new():Place(prefab, sandbox.Id):Commit()
```

### Setting a copy aside

A copy can leave the world without being unloaded:

```lua
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
suspend-and-offer that a player's destroy goes through. See History for what
holds them in between.

### Saving

`instance:Commit()` writes a copy back into its scene. Saving writes what the
scene last committed to a DataStore, under the scene's **Guid**.

```lua
-- server
room:Commit()
Rooms:Save(DataStore)                 -- the draft; false if every retry failed
Rooms:Publish(DataStore)              -- what players get
local id = Rooms:Backup(DataStore)    -- a copy nothing overwrites; nil on failure

local guid = Rooms.Guid               -- keep this wherever your game lists its levels

Prism.Scenes.fromDataStore(DataStore, guid, {Name = "Rooms"})                -- the draft
Prism.Scenes.fromDataStore(DataStore, guid, {Name = "Rooms"}, "Published")
```

Every server scene gets a Guid when it is registered: 22 characters, made by
Prism, never by the game. `Scene.Id` cannot do this job — it is claimed per
server in registration order, so it names a different scene on the next
server, and it is a u16 because it rides on the wire. `fromDataStore` registers
the scene under the Guid it was saved with, so saving it again writes the same
keys; `fromBuffer` and a client's push make a new scene with a new Guid,
because a pack carries none. Clients get the Guid with the scene's name, and
`Scenes:GetByGuid` finds one on either side.

| key | written by | history |
|---|---|---|
| `<Guid>:Draft` | `Save` | the DataStore's own versions, 30 days |
| `<Guid>:Published` | `Publish` | the DataStore's own versions, 30 days |
| `<Guid>:Backup:<id>` | `Backup` | kept until the game removes it |

`Publish` writes the scene as it is, not the stored draft, so a scene published
without saving goes live with its unsaved edits. When to back up is the game's
call — after a publish, once a day, before something risky. A backup's id is
the moment it was taken, in unix milliseconds. Prism never deletes one.

```lua
Prism.Scenes:ListVersions(DataStore, guid, "Draft", 20)    -- {{Version, Time}}, newest first
Prism.Scenes:ListBackups(DataStore, guid, 20)              -- {{Backup, Time}}, newest first

Prism.Scenes.fromDataStore(DataStore, guid, config, {Draft = version})
Prism.Scenes.fromDataStore(DataStore, guid, config, {Published = version})
Prism.Scenes.fromDataStore(DataStore, guid, config, {Backup = id})
```

A listing's entries are what `fromDataStore` takes back: `Version` goes in as
`{Draft = version}` or `{Published = version}`, and `Backup` as `{Backup = id}`.
Every call that reads a stored scene starts with the store and the Guid.

`fromDataStore` returns `nil`, with a warning, when the Guid is not one Prism
made, when the source names more or less than one pack, when a scene is
already registered under it, when the key couldn't be
read, or when nothing is stored there. A new level is `Scenes.new`; reading an
empty key as an empty scene would let any string shaped like a Guid become one.

`Scene:Serialize()` hands you the pack itself, to store wherever you like, and
`Scenes.fromBuffer(config, pack)` reads one. Store it as the **buffer**, never
`buffer.tostring` of it: a DataStore only takes strings that are valid UTF-8,
and a pack's bytes are not, so that write fails.

A DataStore counts a buffer at its base64 size, so one key holds a pack of
about **3 MiB**, not 4 MB: measured, 3,145,312 bytes stored and anything a few
hundred bytes past that was refused. A real 35,000 object level packs to
about 130 KB.

Committing is always explicit. Unloading never writes back on its own — with
more than one copy live it would have to pick one, and it cannot.

`Objects.new` with no scene lands in an implicit `Default` scene, loaded the
first time something needs it, so object creation works with no scene of your
own. Naming a scene that is loaded twice is refused rather than guessed.

### Two identities

Objects carry both, and each has one job:

| | `RuntimeId` | `PersistentId` (`Scene` + `LocalId`) |
|---|---|---|
| names | one live object | one object in a pack |
| unique | across the server, right now | within a scene, forever |
| saved | never | always |
| on the wire | always | never |

`RuntimeId` is the only thing that crosses the wire and the only key the
workspace uses — a client naming an object with a persistent id would be
ambiguous the moment a scene is instanced twice, and client input is the last
place that should be. `PersistentId` is the only thing a pack contains.

There is exactly one crossing, `instance:Find(localId)`, and it is scoped to a
copy on purpose: a persistent id names an object in *every* live copy of its
scene, so the question only has an answer once you say which copy.

```
PersistentId = SceneId * 2^32 + LocalId
```

48 bits, well inside the 53 a Luau number holds exactly, so a saved reference is
one plain number rather than a pair. `Objects:Split(id)` gives back the halves.

Only the low half is written to a pack. The scene stamps its own id on at load,
which is what keeps a pack portable: load the same prefab under two scenes and
you get two distinct persistent identities, with the references inside the pack
remapped together.

A local id is never handed out twice within a scene, for the same reason a
property id is never recycled — a reference still holding it would name a
different object. The scene's counter rides along in the pack.

The scene id in the high half is the session's, not the saved scene's: a pack
never holds it. What names a saved scene across servers is its Guid; see
Saving.

### Loading and unloading are one packet

A copy going away fires a single message naming it, and the client drops
everything it holds for it. Loading sends the objects down the same chunked path
a joining player receives. One packet per object would put a five thousand
object scene into the remote queue in a single frame, which is the flood the
join replay exists to avoid.

### Who hears about a scene

A scene is public unless you say otherwise. A **private** one tells only the
players it admits its name, and sends them alone the objects whose type has
`Replicate = "Admitted"`.

```lua
-- server
local Workshop = Prism.Scenes.new({
    Name = "Workshop",
    Private = true,
    Admitted = {ownerUserId},
})

Workshop:Admit(player)        -- a Player or a user id
Workshop:Evict(otherUserId)
Workshop:Admits(player)       -- true if admitted, or if the scene is public
Workshop:SetPrivate(false)    -- open it to everybody, or close it again
```

Privacy is a flag, not something read off the list. An admitted list on a public
scene does nothing and says so with a warning. Being able to state it outright
is what lets a scene be **closed with nobody in it yet** — the state a level
editor starts in — and it is what stops evicting the last person from throwing
the scene open to everyone, the evicted included.

Admitting someone sends them the scene's name and its admitted-only objects,
down the chunked path a joining player receives. Evicting someone takes those
away again. The list is keyed by user id and belongs to the scene, so it
outlives whoever is connected. Someone admitted while away is shown the scene
when they join.

Players who aren't admitted still get the scene's copies and every object whose
type replicates to everyone, which is the default. The client needs the copy to
file those objects under. What leaks is that a copy of scene N exists: a copy id
and a scene id, with no name and no admitted-only objects.

A scene that should never be public says `Private = true` in `Scenes.new`.
Closing it afterwards works, but it is too late for the moment it was
registered: that packet has already told everyone its name.

Evicting the last admitted player leaves the scene closed and admitting nobody,
which is a state it can sit in perfectly well.

A player who isn't admitted can't edit a scene either. Their edits are refused
as though its objects didn't exist.

Admission decides who gets an object's data, not who sees its part. A copy
loaded with `Load` is built on the server, and Roblox replicates its parts to
everybody.

### Opening instead of loading

`Load` builds every object's part on the server, so the parts replicate to
every player whether or not they're admitted. `Open` builds none. The server
still owns the copy and its data, but it clones no templates, and each admitted
client draws the copy itself from the template that came with the registry.

```lua
-- server
local Draft = Prism.Scenes.new({Name = "Draft", Admitted = {editorUserId}})
local copy = Draft:Open()
copy:Create(Crate, {[Tint] = Color3.new(1, 0, 0)})
```

Roblox has no per-player workspace, so this is the only way to keep a scene out
of sight. An opened copy and its objects go only to the players its scene
admits, whatever each type's `Replicate` says, because a player who isn't
admitted has no part to attach the data to. Players who aren't admitted aren't
told an opened copy exists.

Each client draws into a folder of its own, built where the server builds one
for a copy it loads. Reparent the folder to put the copy somewhere else:

```lua
-- client
Prism.Scenes:OnCopyAdded(function(copyId, sceneId, folder)
    if folder then
        folder.Parent = player.PlayerGui   -- a scene made of interfaces
    end
end)
```

`folder` is nil for a loaded copy, whose parts belong to the server.
`Scenes:GetFolder(copyId)` answers the same question later, and
`OnCopyRemoved` fires when a copy goes. Objects a client drew carry
`Drawn = true`. Their templates have to replicate, so keep them in
ReplicatedStorage.

### Scenes the client owns

A client can own a scene outright — a prefab preview, a sandbox, a room built
before anyone else sees it. It is the same document a server scene is, with one
difference: nothing in it replicates, so its objects apply their own edits
instead of asking for them. There is nobody to ask and nothing to roll back to.

```lua
-- client
local Sandbox = Prism.Scenes.new({Name = "Sandbox"})
local preview = Sandbox:Load()

local crate = preview:Create(Crate, {[Tint] = Color3.new(1, 0, 0)})
crate:Set(Tint, Color3.new(0, 1, 0))   -- applied here, and that is the end of it
preview:Commit()
```

Local objects clone and drive their type's template exactly as server side ones
do, from the registry that replicated with it. A type whose template lives in
ServerStorage still builds local objects, but with no instance.

`Prism.Scenes.new` on the client returns a scene you own, with the same `Load`,
`Create`, `Find`, `Commit`, `Serialize` and `Unload` a server scene has.
`Scenes:Get` still means the server's scene of that name and `Scenes:GetLocal`
means yours; local ids count down from the top of the id space while the
server's count up, so the two never collide.

Objects you own carry `Local = true`, which is how an editor tells an edit that
has already happened from one that can still be refused.

### Handing one to the server

```lua
-- client
preview:Commit()
local ok, sceneId, reason = Sandbox:Push("Room 4")
```

A refused push says why in `reason`: `NoPushRight`, `TooLarge`, `TooManyObjects`,
`BadName`, `NameTaken`, `UnknownType`, `Unreadable`, `Budget`, `Failed`, or
`Unreachable` when the request never got an answer. It is `nil` when the push
landed.

The pack crosses in one packet. The server refuses it unless the player holds
the global `CanPush` right and every object type in it is registered. It
re-encodes the pack so the one it keeps is the one it wrote, and registers it as
a scene of its own without loading it. Putting a room in the world is the
server's call; the client asked for a document to be stored, not spawned.

A pushed scene admits only the player who pushed it, because it was built where
nobody else could see it. `Scenes:SetPushRole(role)` also grants them that role
on it. With no push role set, they hold no rights there until the game grants
some.

`Push` sends what the scene says it is, so commit the copy you mean first. What
comes back is a different document from the one you pushed: the local scene
stays local, and pushing twice registers two scenes rather than updating one.

A commit costs one action rather than one per object, bounded by size instead —
512 KB and 4096 objects. A transaction charges per operation because each one
reaches into the world as it stands; a commit arrives whole, and what bounds it
is known before a byte of it is read.

## Transactions

A list of operations — create, set, destroy — validated and applied as a unit.
One packet up, one permission pass, and one thing for an editor's history to
record.

```lua
-- client (or server, on a player's behalf)
local edit = Prism.Transactions.new()

edit:Create(Crate, {[Health] = 50}, room.Id)
    :Duplicate(original)             -- a create holding original's values
    :DuplicateGroup(selection)       -- the same, references between them remapped
    :Place(prefab, room.Id)          -- a saved pack, one create per object in it
    :Lock(selection)                 -- one object or a list, all or none
    :Set(other, "Health", 20)
    :Destroy(stale)
    :Unlock(selection)
    :Load(sceneId)                   -- a copy of a scene into the world
    :Unload(copyId)                  -- and a live copy out of it

local applied, created = edit:Commit()
```

`Commit` answers whether the whole list landed, and the runtime ids of what it
created, in the order the creates were declared. `Create` takes the copy the
object belongs in, because a scene loaded twice has two equally good ones;
leave it out and the object lands where `Objects.new` would have put it.

Nothing is applied unless everything passes. A single refused operation ends the
transaction while the world has not moved yet, and an operation that could not
even be built — an unknown property, a target that is not an object — makes
`Commit` refuse rather than send what is left.

This is also the only way a client creates an object in a scene the server
owns: `Objects.new` is server side, and a transaction's `Create` is what a
role's `CanCreate` governs.

### Not only for talking to the server

A transaction whose objects are all in scenes the client owns **applies on the
spot**. Same builder, same operations; `Commit` sees what it is about and either
sends it or does the work, and a local commit does not yield because there is
nobody to ask.

That is how a local edit is batched: every set, create and destroy in it is
one apply and one undo step, so undoing a pasted prefab takes it away whole
rather than one object at a time.

```lua
-- A whole prefab into a copy this client owns: one edit, one undo step.
Prism.Transactions.new():Place(prefab, sandbox.Id):Commit()
```

A transaction is **all local or all the server's**, never both. The second kind
to arrive is refused by name when it is added. That one is forced: half of a
mixed transaction needs a round trip that can come back refused, and by then the
local half has already applied — there is no atomicity to be had across that
line, and a transaction that cannot be atomic is not one.

Everything else is the same on both paths: the three phases in the same order,
a rollback if it throws partway, and one entry in the history.

### Holds, and copies

`Lock` and `Unlock` put taking a hold in the same list as the edit that needs
it. Locking three objects and moving them is one packet that either gets all
three and moves them or does neither, rather than a lock that can come back
refused after the edit was already built. Locks are taken
before everything else in the transaction and released after — hold these, do
this, let go. Refused for objects in scenes the client owns, which are never
held: nobody else can touch them.

`Load` names a scene and `Unload` a live copy, and they are the only way a
client asks for either — there is no channel of their own. Loading needs the
**create** verb on that scene and unloading needs **destroy**, because that is
what they amount to: every object in it made, or every object in it taken away.
The verb alone: a pack holds whatever it holds, so there is no type to check the
object lists against, and those lists govern what a role builds by hand.

The copy a load makes is not in what `Commit` hands back. It arrives the way
created objects do, through the packet announcing it — `Scenes:OnCopyAdded`.

An unload **withdraws** the copy rather than unloading it: out of the
registries, its folder out of the tree, every object in it suspended, the whole
thing kept. That is what makes it undoable. Loading it again would read what the
scene last committed, which is not what was on screen unless somebody had just
saved; withdrawing it means an undo brings back exactly what was there. The copy
ends when the step holding it does, the same way a destroyed object does.
`copy:Unload()` from server code is still final — nobody asked for that one.

### Ordering

Operations apply locks first, then loads, then creates, then sets, then
destroys, then unloads, then the releases — whatever order they were declared
in. That is what makes a transaction atomic rather than merely
batched: a create can be taken back by destroying what it made, and a set by
writing back what it overwrote, but a destroy cannot be taken back at all — so
nothing irreversible happens until everything reversible has already succeeded.

Two sets on one property are one change by the time it lands, and an object
destroyed by the same transaction that changed it is announced once, as gone.

## History

Undo and redo, per player. The client drives it:

```lua
-- client
Prism.History:Undo()      -- yields while the server answers for its half
Prism.History:Redo()
Prism.History:CanUndo()
Prism.History:OnChange(function() toolbar:Refresh() end)
```

A step is one committed transaction, one create or destroy, or a run of
`Object:Set` calls to one property with no pause longer than a second, so a drag
undoes as one. A drag written with `ClientSided` is one step however long it
paused, because only its closing set is an edit. A copy loaded or unloaded by a
transaction is part of its step: undoing a load withdraws the copy it made, and
undoing an unload puts back the one it took, objects and values and ids intact. Holds are not recorded — a lock
is not a change to the world, and taking somebody's hold back is not an undo.

Each stack keeps the last 100 steps. That count is **per player and across every
scene** — editing two rooms does not give you two hundred steps, because what
you take back is one sequence of things you did rather than one per room. The
server's half and the client's half do count separately, though: only the client
can see both, and a client that has gone quiet must not be what decides how much
the server holds on to.

Steps are also capped by **what they hold**: at most 10,000 objects kept alive
between them on each half. A step holds one object per create or destroy, and
every object in a copy it loaded or unloaded, so a hundred unloads of a large
room cannot keep a hundred large rooms in memory. The oldest steps go until the
rest fit, except the newest, which is kept however much it holds.

Both limits can be changed on each side, and take effect at the next step
recorded. Setting them on the server applies to every player's stack; setting
them on a client applies to that client's own half:

```lua
-- server or client
Prism.History:SetLimits({Steps = 50, Objects = 2000})
Prism.History:GetLimits()     -- {Steps = 50, Objects = 2000}
```

### A destroy is deferred, not undone

Undoing a destroy does not build a replacement. The object is **suspended**:
withdrawn from the world by every measure — `Destroyed` reads true, it is gone
from the workspace and from its copy, its part is parented out of the world and
every client has been told — while the table, its property values, its runtime
id and its local id all survive. Undo revives that same object, with the part it
had rather than a fresh clone of the template, so whatever the game hung on that
part is still hanging there. The part is destroyed by `Clear`, with the rest.

That is what keeps references working. A reference stores a local id, a scene
never issues one twice, and an object that comes back under its own is pointed
at again by everything that was pointing at it. Rebuilding a lookalike would get
a fresh id and leave every reference to the original dangling.

Undoing a create is the same act in reverse: the object is suspended, not
destroyed, because redo has to bring back *that* object.

So something has to decide when a destroy is finally a destroy. That is
`Clear`, and it runs in exactly three places: when a new action forks the redo
stack a step was sitting on, when a step falls off the end of the stack past
either limit — the step count or the object count — and when the player leaves
(or `History:Clear()` is called). A step with nothing holding it lets go of
whatever it was keeping, and only then are the values gone. With **nothing
keeping it at all** — a game that never requires `Prism.History` — a destroy is
immediate.

### Where the steps live

Split by who owns the scene, because a step has to hold objects and objects live
on one side or the other.

| | recorded | applied |
|---|---|---|
| the server's scenes | server, per player | server, through the same rights, locks and budget as any edit |
| scenes the client owns | client | client, on the spot |

The client keeps the **order** — one list where each place is either a step of
its own or the id of one the server holds — so a single undo takes back the last
thing the player did whichever side recorded it. An undo of a server step names
the step it means; if that is not the one on top, the server says no and sends
back its stacks, which the client reconciles against. A new action on either
side forks the redo stack on both. That fork, and `Clear`, reach the server in
the order they happened among the player's edits, so an edit made straight
after `Clear` is recorded and one made straight before it is cleared. Neither
yields.

Recorded server side: every transaction a player commits, every `Object:Set`
through the single channel, and every lone `Object:Destroy`. Commit a transaction with `Untracked = true`
to keep it out. Recorded client side: creates, destroys and sets in scenes the
client owns. A copy reading its own pack back is not an action and is not
recorded.

If someone else has changed a property since, undo and redo leave that property
alone and apply the rest of the step. A refused undo — a lock, a missing right —
stays on the stack to be tried again. An object whose copy has been unloaded
cannot come back, and that entry is skipped.

On the server, `Prism.History` takes the player: `History:Undo(player)`,
`Redo`, `CanUndo`, `CanRedo`, `Clear(player)`.

### Actions of your own

Not everything an editor does is an object. Push a step of your own and it sits
in the same order, so one Ctrl+Z reaches it where it happened:

```lua
-- client; on the server, History:Push(player, {...})
Prism.History:Push({
    Undo = function() camera:GoTo(before) end,
    Redo = function() camera:GoTo(after) end,
})
```

The same three verbs every step has. `Clear` is optional and is the one to read
twice: it runs when the step can no longer be reached — forked off the redo
stack, pushed past either limit, or the player leaving — and is where an action
holding something of its own lets go of it, exactly as Prism's own steps
finally destroy the objects they were keeping.

```lua
-- client
local snapshot = Terrain:CopyRegion(region)

Prism.History:Push({
    Undo = function() Terrain:PasteRegion(snapshot, corner, true) end,
    Redo = function() Terrain:Clear(region) end,
    Clear = function() snapshot:Destroy() end,
})
```

A step is either yours or Prism's, never both — mixing them would mean deciding
where your verb runs among entries it knows nothing about, and two pushes say it
plainly. Pushing one forks the redo stack like any other new action. An `Undo`
or `Redo` that throws leaves the step on the stack to be tried again, and
nothing you do inside either one is recorded as a new action. That covers
what runs on the action's own thread -- not threads it spawns -- and nothing
else: an edit the player makes while an action yields is recorded as usual.

On the server it takes the player — `History:Push(player, action)` — and costs
one action of their budget to reverse, since nothing here can weigh what it
does. A client-side push covers the client's half of the order; there is no way
to hand the server a function, so an action that has to run there is pushed
there.

The history is built on signals you can use yourself: `Objects:OnEdited(fn)` on
the client for its own `Object:Set` calls, `Objects:OnPlayerEdited(fn)` on the
server for a player's, `Transactions:OnCommitted(fn)` on the client and
`Transactions:OnApplied(fn)` on the server, and `Objects.OnRetired(fn)` on both
— which is the one that decides whether a destroyed object is kept.

### On the client

`Commit` yields until the server answers, and applies nothing early. A single
`Set` is optimistic because it has a local object to write to and a value to
roll back to; a create has neither, and no id at all until the server mints one.

The result comes back as one broadcast rather than one per operation: created
objects arrive down the same chunked path a scene load uses, and changes and
removals have bulk channels beside the single ones.

### Budget

Undo and redo spend one action each, whatever the step holds: a transaction is
one thing to take back however many operations it carried, and charging by the
entry would leave a player who committed an edit at their ceiling unable to undo
it. Loading a scene is one action for the same reason.

A transaction spends one action per operation rather than one per packet, so a
role with `Rate = 60` may commit sixty operations a second however they are
grouped. Charging per call would let one packet carrying ten thousand
operations walk straight past the limiter. A single transaction carries at most
1024 operations.

## Selection

Client side, and purely local: the server never hears about it. Entries are
pruned on read, so an object destroyed by someone else drops out on its own.

```lua
-- client
Prism.Selection:Set({objectA, objectB})
Prism.Selection:Add(runtimeId)
Prism.Selection:Contains(objectA)

local disconnect = Prism.Selection:OnChange(function(selected)
    panel:Render(selected)
end)
```

`Get` returns the selected objects in the order they were added, which is the
order an editor reads as "the active one is last". `Query(fn)` filters that
list.

## Permissions

Rights come in two kinds. Global rights are about the session: the action
budget, whether a client may push a scene, and any capabilities your game
defines. Scene rights are about one scene: the three verbs, which object types
and properties they reach, and that scene's capabilities. A player with no
rights on a scene can do nothing there.

```lua
-- server
Prism.Permissions:Register("Builder", {
    Global = {Rate = 120, CanPush = true},  -- actions per second, per operation
    Scene = {
        CanCreate = true,
        CanEdit = true,
        CanDestroy = true,
        Objects = {Blacklist = {Enemy}},                -- may not touch this type
        Properties = {Blacklist = {[Tint] = {Crate}}},  -- nor tint a crate
        Capabilities = {"Invite"},
    },
})

Prism.Permissions:Grant(player, "Builder")      -- the global half
level:Grant(ownerUserId, "Builder")             -- the scene half, on this scene
level:GrantCapability(player, "Publish")
level:RevokeCapability(player, "Publish")
```

A role is a template. Granting one clears what the player held there and
copies the role in. After that the player's own set is the whole truth, so
editing a role later doesn't reach anyone who already holds it.

Grants are keyed by user id, and passing a Player uses theirs. A grant can name
someone who hasn't joined yet, and it still applies when they rejoin. Scene
rights last as long as their scene; global rights last as long as the server.
Nothing is saved: who owns a level is your game's own record, so hand it over
when the scene is made.

```lua
-- server
local level = Prism.Scenes.new({Name = "Level 4", Rights = {[ownerUserId] = "Builder"}})
```

Object and property lists each take a whitelist and a blacklist. A present
whitelist is exhaustive; an absent one constrains nothing. Property lists take
ids like object lists do, or `[Property] = {ObjectType}` to limit an entry to
those types. They govern writing only, never what a client is sent.

Capabilities are plain strings that exist by appearing in a role or a grant.
Prism enforces only its three verbs and just answers for capabilities. Asking
for one that nothing grants warns once.

```lua
Prism.Permissions:Has(player, "Invite", level.Id)   -- server
Prism.Permissions:Has("Publish")                    -- client, global
Prism.Permissions:Can("Edit", object, Tint)         -- client, to grey out tools
```

A player without a global grant gets a budget of 60 actions a second and can't
push. The server re-checks every request, whatever the client thinks.

## Database

Sharded metadata storage. Records live in `{Key}:1..N`; ids come from a
monotonic counter, so when the tail shard reaches its limit its boundary
freezes and a new tail opens. Records never move between shards, and edits to
different shards do not contend with each other.

A shard is stored as the same packed format as a scene (see
[Storage format](#scene-packs)). On 20,000 typical level records (title,
creator, plays, likes, date, public flag, thumbnail) that came to 14 bytes a
record, down from 61. MemoryStore pages are packed the same way, so a 31 KB
page holds about 1,300 records.

The limit (`ShardLimit`, 1 MB by default) is measured **before** compression,
because it is a CPU budget rather than a storage one: every create decodes and
re-encodes the whole tail shard inside an `UpdateAsync` transform, which cannot
yield. 1 MB is about 30,000 records and about a second per create. What a shard
actually stores is a quarter to a third of that. Keep `ShardLimit` under 3 MB:
a DataStore counts a stored buffer at its base64 size, so no key holds much more
than 3 MiB of one.

```lua
-- server
local db = Prism.Database.new({
    Key = "Levels",
    InitialMetadata = {Prism.Properties.new(Title), Prism.Properties.new(Plays)},
})

local ok, id = db:Create()
db:Edit(id, {[Title] = "My Level"})
db:GetById(id)
db:Delete(id)
```

### Browsing

A cache declares its order. `IdOrdered` says the order matches shard order,
which lets a page stop as soon as it is full — page 1 of a newest-first browse
reads one shard however many exist.

```lua
-- server
db:RegisterCache("Newest", {IdOrdered = "Desc", PageSize = 50})

local page = db:Get("Newest", 1)
print(page.Records, page.HasMore)
```

Any other order needs `Sort`, and correctness requires reading every shard: a
record in the last shard can rank first, so stopping early would return "the
most played level among the oldest 50,000" and look plausible while being wrong.

```lua
-- server
db:RegisterCache("Popular", {
    Sort = function(a, b) return a[2].Value > b[2].Value end,
    PageSize = 50,
})
```

### Searching

`Find` filters without a global ordering, so it stops as soon as it has enough.
Search by name and list by creator both go through it.

```lua
-- server
db:Find(function(record)
    return string.find(string.lower(record[1].Value), query, 1, true) ~= nil
end, 50)
```

### Caching

Three tiers: in-process, then a MemoryStore page cache shared across servers,
then the DataStore. Both cache tiers expire after 90 seconds (`Expiration`), so
a write from another server becomes visible within that window — there is no
cross-server invalidation. The writing server bypasses the shared tier for the
same window so it always reads its own writes.

Pages rather than shards are cached in MemoryStore because a MemoryStore value
caps at 32 KB while a shard is measured in megabytes.

## Networking

Channels are declared in `src/Channels.luau` with a codec per parameter, so a
packet is one byte of channel id plus exactly the bytes the values need. Ids come
from the manifest order, so they match on both sides.

```lua
{
    Name = "MyFeature.Move",
    Args = {Codecs.u32, Codecs.Vector},
    Returns = {Codecs.Bool},
}
```

```lua
-- server; a client fires and invokes the same channel object
local Move = Prism.Networking:Get("MyFeature.Move")
Move:Fire(player, runtimeId, Vector3.new(1, 2, 3))  -- server, targeted
Move:FireAll(runtimeId, Vector3.new(1, 2, 3))
Move.OnInvoke = function(player, runtimeId, position) return true end
```

Codecs: `u8`/`u16`/`u32`, `i8`/`i16`/`i32`, `f32`/`f64`, `Varint`,
`SignedVarint`, `Bool`, `String`, `LongString`, `Buffer`, `Vector`, `Color`,
`CFrame`, `Instance`, `Player`, `Any`, plus `Optional(codec)` and
`Array(codec)`.

Append new channels at the end of the manifest. Never reorder them, and never
reuse a removed channel's slot during a live rollout.

Invokes are client to server only. `InvokeClient` parks the calling server thread
until the client answers, and a client that never answers holds it forever.

## API at a glance

What each module offers, and on which side. **S** is server, **C** is client.
The sections above explain each one.

| Module | Call | Side |
|---|---|---|
| `Properties` | `:Register(config)`, `:Unregister(id)` | S |
| | `:GetRegistered()`, `:GetRegistry(id)`, `.new(id)`, `:Layout(ids, includeHidden?)` | S C |
| `CustomEnum` | `:Register(name, options)`, `:GetEnum(name)`, `:GetRegistered()`, `:OnRegistered(fn)` | S C |
| `Objects` | `.new(type, values?, copy?)`, `:Register(config)`, `:Unregister(id)` | S |
| | `:Get(runtimeId)`, `:GetWorkspace()`, `:GetRegistered()`, `:GetRegistry(id)`, `:Resolve(copy, localId)`, `:Split(persistentId)` | S C |
| | `:Duplicate(object, copy?)`, `:DuplicateGroup(objects, copy?)` | S C (client: scenes it owns) |
| | `:Lock(objects)`, `:Unlock(objects)`, `:GetLock(object)`, `:IsLocked(object)` | S C (server: `:Lock(objects, holder)`) |
| | `:GetHolder(object)`, `.OnPlayerEdited(fn)` | S |
| | `:OnLockChanged(fn)`, `:OnEdited(fn)`, `:FromInstance(instance)` | C |
| | `:OnAdded(fn)`, `:OnRemoved(fn)`, `.OnRetired(fn)` | S C |
| | `.Suspend(object)`, `.Revive(object)`, `.Dispose(object)`, `.Retire(...)` | S C |
| an object | `:Set(property, value, clientSided?)`, `:Get(property)`, `:GetProperty(property)`, `:OnChange(property, fn)`, `:Destroy()` | S C |
| `Scenes` | `.new(config)`, `.fromBuffer(config, pack)`, `:Get(name)`, `:GetById(id)`, `:GetByGuid(guid)`, `:GetRegistered()` | S C |
| | `.fromDataStore(store, guid, config, source?)`, `:ListVersions(store, guid, which, limit?)`, `:ListBackups(store, guid, limit?)`, `:SetPushRole(role)`, `:GetDefault()`, `:GetInstance(copyId)` | S |
| | `:GetLocal(name)`, `:GetOwned()`, `:GetFolder(copyId)`, `:GetInstances(sceneId)`, `:GetInstanceScene(copyId)`, `:GetObjects(copyId)`, `:OnCopyAdded(fn)`, `:OnCopyRemoved(fn)` | C |
| a scene | `:Load(parent?, options?)`, `:Unload()`, `:Serialize()`, `:GetInstances()`, `:Destroy()` | S C |
| | `.Guid`, `:Save(store)`, `:Publish(store)`, `:Backup(store)`, `:Open(options?)`, `:Admit(who)`, `:Evict(who)`, `:Admits(who)`, `:SetPrivate(private)`, `:IsPublic()`, `:Grant(who, role)`, `:Revoke(who)`, `:GrantCapability(who, name)`, `:RevokeCapability(who, name)` | S |
| | `:Push(name)` → `ok, sceneId, reason` | C |
| a copy | `:Create(type, values?)`, `:Place(pack)`, `:Find(localId)`, `:GetObjects()`, `:Serialize()`, `:Commit()`, `:Unload()`, `:Suspend()`, `:Revive()`, `:Dispose()` | S C |
| `Transactions` | `.new()`, then `:Create`, `:Duplicate`, `:DuplicateGroup`, `:Place`, `:Set`, `:Destroy`, `:Lock`, `:Unlock`, `:Load`, `:Unload`, `:Commit()` | S C |
| | `:OnCommitted(fn)` | C |
| | `.OnApplied(fn)` | S |
| `History` | `:Undo()`, `:Redo()`, `:CanUndo()`, `:CanRedo()`, `:Clear()`, `:Push(action)` | S C (server: the player first) |
| | `:SetLimits(limits)`, `:GetLimits()` | S C |
| | `:OnChange(fn)` | C |
| `Selection` | `:Set`, `:Add`, `:Remove`, `:Contains`, `:Clear`, `:Get`, `:Query(fn)`, `:OnChange(fn)` | C |
| `Permissions` | `:Register(name, role)`, `:Grant(who, role)`, `:Revoke(who)`, `:GrantCapability`, `:RevokeCapability`, `:Get(who)` | S |
| | `:Can(...)`, `:Has(...)` | S C (server: the player first) |
| | `:Get()`, `:GetOn(scene)`, `:OnChange(fn)` | C |
| `Database` | `.new(config)`, then `:Create`, `:Edit`, `:Delete`, `:GetById`, `:Get(cache, page)`, `:Find(fn, count)`, `:RegisterCache(name, config)` | S |
| `Networking` | `:Get(name)`, then `:Fire`, `:FireAll`, `:Invoke`, `.OnInvoke` | S C |

## Storage format

A buffer decodes with **zero reference to the registry**. The registry decides
how a decoded value is validated and applied, never how the bytes are read, so a
developer can change a constraint, change a type, or unregister a property and
existing data still decodes byte-exactly.

Every value carries a one-byte tag:

```
wwwttttt    w = wire shape (how to read it)
            t = semantic type (what it means)
```

The wire shape is what survives schema drift. A reader that has never heard of
semantic type 19 still knows it is length-prefixed, so it skips it precisely and
keeps reading the rest of the record. Shapes: varint, fixed 3/4/8/12/48, and
length-prefixed bytes.

Numbers pick their encoding from the **value**, not the schema — a whole number
becomes a varint, a fractional one that survives f32 becomes 4 bytes, anything
else 8. Exact to 2^53. That is why changing `AllowDecimals` cannot corrupt
anything, and why user ids and unix timestamps are not mangled by f32's 24-bit
mantissa. Setting `Precision` quantises values before they are encoded,
which makes them far more likely to fit the 4-byte form.

Ids, lengths and counts are LEB128 varints: one byte below 128, two below 16384.

### Scene packs

A scene's pack doesn't write its objects one record at a time. It groups them
by type and writes each type's properties once, as columns. Each column carries
a default: the value it holds most often **in that pack**. Each object then
spends one bit per column saying whether it holds something else, and writes
only those values.

The default belongs to the pack, not the registry. Changing a property's
`DefaultValue` later changes nothing about a level already saved: every object
reads back holding exactly what it was saved with, defaults included.

Each column is written whichever of these ways comes out smallest:

- **raw**: each value tagged, as above. Any column can fall back to it, and it
  keeps a pack readable with no registry.
- **bool**: nothing beyond the bit, which is the value.
- **palette**: the column's distinct values once, then an index per object.
  Materials, enums, mesh ids, colours.
- **grid**: a Vector as three small integers on a step such as half a stud.
  A Vector off the grid, `-0` included, is written as its twelve bytes instead.
  A value read back from the grid is always the same float, bit for bit.
- **delta**: the grid again, but each Vector as how far it moved from the one
  before it, every X step first, then every Y, then every Z. Blocks are placed
  near the last one, so the steps are smaller than the positions.
- **relative**: a reference as how far its target is from the object holding
  it. Something made right after the thing it points at -- an attribute after
  its block, a button after its door -- is one step back, every time.
- **list**: a `Table` of `Object` the same way, a count and then each item as
  how far its target is from the object holding the list. A wiring block made
  after the blocks it takes inputs from writes the same few small numbers on
  every row.

Everything is written column by column, bitmaps and values alike, so similar
bytes sit together. The pack is then compressed with zstd, at level 19 for
scenes and 9 for database shards, when that makes it smaller. A reader checks
how far a pack claims to unpack before unpacking it, and refuses anything past
64MB, because a client can push a pack.

Measured on a real building game's level of 20,287 blocks and 14,631 block
attributes (34,918 objects): 4.22MB written as one record per object, 353KB
in columns, and 129KB as stored after zstd. Writing references relative to
their object took 33KB off that, and position steps a little more. Positions
are most of what is left.

Reading that pack back takes about a third of a second. Loading it takes
longer, and not because of the pack: building 34,918 objects and 20,287 parts
takes about 4 seconds, which a load spreads over frames so the server keeps
running. See [How fast a load goes](#how-fast-a-load-goes).

Property ids are **never recycled**, because they are written into saved data —
reusing one for a different property would silently reinterpret every record
still carrying it. Object registry ids are not recycled either, for the same
reason: a registry id is written into every saved object as its type. Nor are
scene ids, which live in the high bits of every persistent id, or an object's
local id within its scene. Runtime ids are the exception, and only because they
are never written down at all.

### What this build cannot read is kept

Skipping a record precisely is only half of it: a save that dropped what it
skipped would delete it at the next commit. So a loaded copy keeps what it
cannot use and writes it back unchanged.

- **An object of a type that is not registered** is not built — nothing finds,
  draws or replicates it — but the copy keeps it (`copy.Unknown`), and
  `Serialize` and `Commit` put it back in its place by local id, every value
  exactly as it was read.
  Its local id stays spent, so a new object never takes it.
- **A value for a property the object's type no longer lists**, or for a
  property id nobody registered, is not the object's: `Get` does not see it. It
  is kept on the object (`object.Unknown`, tagged bytes by property id) and
  written back by a save. Put the property back on the type and the value is
  read again at the next load. A direct `Duplicate` carries these values.
- **Replication never sends them**, and a pack a client pushes to the server
  keeps nothing the server cannot read: the server writes its own packs, and it
  does not store bytes it cannot read on a client's say-so.

What is still dropped: a registered property whose **type** changed since the
save (the registry saying something new about it, and the object carrying it
under the new type), anything unknown in database metadata, and anything a
**placement** or a transaction's `Duplicate` would have to carry — those build
fresh objects of known types from known values.

Objects and packs carry a format version, and readers refuse anything newer
than they understand rather than misreading it. Individual metadata records do
not — the version lives on the pack that contains them.

## Contributing

Contributions are welcome: open a pull request against `main`.

- One change per pull request, on a branch named `feat/...`, `fix/...` or
  `docs/...`, with commits written as `type(scope): what changed`.
- Update this README in the same pull request as any change to the API.
- Run `scripts/analyze.sh`, `node scripts/check-channels.js` and
  `scripts/test-pure.sh` before opening it; CI runs the same three on every
  push.
- For anything bigger than a fix, open an issue first, or read `ROADMAP.md`,
  which lists what is planned and how the work is done.

By opening a pull request you agree that your contribution is released under the
same [MIT license](#license) as the rest of Prism.

## Tests

Part of the suite needs no Roblox at all:

```bash
scripts/test-pure.sh
```

`tests/Pure.luau` covers Varint, Handles, IdPool, the codecs, Try, CustomEnum,
permission resolution and property layout: everything that needs no DataModel.
Much of it is the floor the format stands on: every id, length and count in a
pack is a varint, every saved object is addressed by a persistent id, every
registry id comes out of a pool. It checks every byte length boundary this file
claims for varints, that `PersistentId` really is `Scene * 2^32 + Local` across
the 48 bits it uses, that every codec that does not need a Roblox type round
trips at its boundaries, that a blacklist beats a whitelist, and that a
non-recycling pool never hands out a released id twice. It fetches a Luau CLI
into `.tooling/`; CI runs it on every push.

The rest needs a DataModel, players and replication, so Studio is the only place
it runs.

The tests run the unit suite on the server and the replication, permissions,
optimistic-edit, transaction and lifecycle suite on one client. Insert
[`dist/PrismTests.rbxmx`](dist/PrismTests.rbxmx) into ReplicatedStorage in an
empty place. It brings its own copy of Prism:

```text
ReplicatedStorage
└── PrismTests
    ├── Prism                      <- src/
    ├── Harness                    <- tests/Harness.luau
    ├── Server                     <- tests/Server.server.luau (RunContext Server)
    └── Client                     <- tests/Client.client.luau (RunContext Client)
```

Both suites are Scripts with RunContext set, so they run from where they are,
and every require is relative to the model.

Then use **Test > Play** with one player. The server creates a set of
integration fixtures and intentionally keeps them alive so the client can
validate both live delivery and late-join replay. A failed test prints its group
and assertion, then fails the corresponding script.

> **Warning: the database tests write to real data stores.** They use the
> DataStore and MemoryStore keys `PrismSelfTest` and `PrismSelfTestBurst`, need
> Studio API access enabled, and are **on by default**: `RUN_DATABASE` near the
> top of `tests/Server.server.luau` switches them. They **wipe both keys** before
> they start and after they finish, so never point them at a key that holds
> anything you want. Set `RUN_DATABASE = false` in any place whose data stores
> you care about.

## Type checking

Every file is `--!strict`, and `scripts/analyze.sh` is what actually holds them
to it:

```bash
scripts/analyze.sh
```

It fetches a pinned `luau-lsp` and the Roblox API definitions into `.tooling/`
and runs the analyser over `src/` and `tests/`. Nothing has to be installed
first, and nothing is left behind that `.gitignore` does not already cover. CI
runs this script, `check-channels.js` and `test-pure.sh`, so a push is checked
exactly the way a local run is.

The tests are only lightly checked. The analyser reads files, not the model, so
it cannot resolve the suites' `require("./Prism")`, and everything the suites get from Prism
reads as `any`, and a mistake in how a test calls Prism shows up when the test
runs rather than here. `ROADMAP.md` has the reasoning for leaving it that way.

It fails when a file grows a diagnostic it did not have before, rather than
when any diagnostic exists at all. `.analyze-baseline.txt` records the count
per file, and `scripts/analyze.sh --update-baseline` rewrites it.

That is a ratchet rather than a clean bill of health, and deliberately. Most of
what is left is the default type solver reading code written for the new one:
`type function` and `read` fields are new-solver features, `for _, X in List or
{}` is a union the old solver will not iterate, and `pcall(fn)` binding two
results is flagged whenever `fn` returns nothing. None of those are runtime
faults, and the new solver reports far more problems than the default one, so
switching would cost more than it bought. Real bugs still get caught,
without the standing noise having to be cleared first.

`scripts/analyze.sh --raw` prints everything, baseline or not.

`node scripts/check-channels.js` is the other half, and it checks what the
analyser structurally cannot. `Fire`, `FireAll` and `Invoke` all take `...:
any`, so sending a channel the wrong number of arguments type checks cleanly
and then errors at runtime. The script finds every caller across all three
call forms, the `Audience.Fire` paths included, and checks each against the
count the channel declares.

This is the check the Studio pass cannot do cheaply. A wrong argument count on a
channel, a function that returns one value where two are read, a field that
moved — the analyser finds all of those across 20,000 lines in seconds, where
playing the game finds them one at a time, each costing a rebuild and a replay.
Run it before taking a build into Studio, not after.

## License

Prism is released under the [MIT License](LICENSE). Use it in any game, open or
closed source, free or paid; keep the copyright notice in the `LICENSE` file
with any copy of the code.
