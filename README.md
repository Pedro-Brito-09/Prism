# Prism

Prism is a framework made to facilitate the creation of level editors for roblox games.

`src/` is a ModuleScript folder (`init.luau` is the module itself). Require it from
both sides; it resolves the server or client half of each subsystem for you.

```lua
local Prism = require(path.to.Prism)
```

## Properties

A property is a typed, constrained field. Register it once on the server; the
registry replicates to every client, including late joiners.

```lua
local Health = Prism.Properties:Register({
    Name = "Health",
    Type = "Number",
    DefaultValue = 100,
    Constraints = {MinValue = 0, MaxValue = 100, AllowDecimals = false},
})
```

Types: `Text`, `Number`, `Bool`, `Color`, `Vector`, `CFrame`, `Enum`, `CustomEnum`.

Constraints reject or clamp depending on the constraint: `MinLength` rejects an
invalid value, `MinValue`/`MaxValue`/`MaxLength` clamp it into range.

## Objects

An object type is a named set of properties, optionally backed by a template
instance. `Objects.new` clones that template per instance.

```lua
local Enemy = Prism.Objects:Register({
    Name = "Enemy",
    Properties = {Health},
    Instance = ServerStorage.EnemyTemplate,
    Links = {
        {Property = Health, Type = "Attribute", Name = "Health"},
    },
})

local enemy = Prism.Objects.new(Enemy)
enemy:Set(Health, 50)
enemy:Get("Health")
enemy:Destroy()
```

Every object carries two ids: `RuntimeId`, which names this live copy of it, and
`PersistentId`, which is saved with it and outlives a reload. See Scenes.

A link mirrors a property onto the instance. `Type = "Property"` writes a real
instance property (the types must match), `Type = "Attribute"` writes an
attribute. `Descendant` targets a child instead of the root.

`Set`, `Get`, `OnChange` and `GetProperty` all take either the property id or
its name, and a name costs the same as an id to resolve.

Watch a single property without paying for a signal on every property:

```lua
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

## Scenes

A scene is a document: a named set of objects, and the unit a level is saved and
loaded as. Registering one creates data and nothing else. `Load` reads it into a
live copy.

```lua
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

### Saving

`instance:Commit()` writes a copy back into its scene; `Scene:Serialize()` hands
you the committed pack to store wherever you like.

```lua
room:Commit()
DataStore:SetAsync(key, buffer.tostring(Rooms:Serialize()))

Prism.Scenes.fromBuffer({Name = "Rooms2"}, pack)   -- registered, nothing live
```

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

### Loading and unloading are one packet

A copy going away fires a single message naming it, and the client drops
everything it holds for it. Loading sends the objects down the same chunked path
a joining player receives. One packet per object would put a five thousand
object scene into the remote queue in a single frame, which is the flood the
join replay exists to avoid.

### Scenes the client owns

A client can own a scene outright — a prefab preview, a sandbox, a room built
before anyone else sees it. It is the same document a server scene is, with one
difference: nothing in it replicates, so its objects apply their own edits
instead of asking for them. There is nobody to ask and nothing to roll back to.

```lua
Prism.Objects:Localize(Crate, {
    Instance = ReplicatedStorage.CrateTemplate,
    Links = {{Property = Tint, Type = "Property", Name = "Color"}},
})

local Sandbox = Prism.Scenes.new({Name = "Sandbox"})
local preview = Sandbox:Load()

local crate = preview:Create(Crate, {[Tint] = Color3.new(1, 0, 0)})
crate:Set(Tint, Color3.new(0, 1, 0))   -- applied here, and that is the end of it
preview:Commit()
```

`Localize` hands over the half of a registry the wire cannot carry. A registry
replicates as an id, a name and a property list: the template instance is left
behind deliberately — it is an asset sitting in ServerStorage, and shipping one
per type to every client would be absurd — and so are its links, which mean
nothing without a template. Supply them once per object type and local objects
clone and drive an instance exactly as server side ones do.

`Prism.Scenes.new` on the client returns a scene you own, with the same `Load`,
`Create`, `Find`, `Commit`, `Serialize` and `Unload` a server scene has.
`Scenes:Get` still means the server's scene of that name and `Scenes:GetLocal`
means yours; local ids count down from the top of the id space while the
server's count up, so the two never collide.

Objects you own carry `Local = true`, which is how an editor tells an edit that
has already happened from one that can still be refused.

### Handing one to the server

```lua
preview:Commit()
local ok, sceneId = Sandbox:Push("Room 4")
```

The pack crosses in one packet. The server refuses it unless it may create every
object type in it, re-encodes it so the pack it keeps is the one it wrote, and
registers it as a scene of its own — it does not load it. Putting a room in the
world is the server's call; the client asked for a document to be stored, not
spawned.

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
local edit = Prism.Transactions.new()

edit:Create(Crate, {[Health] = 50}, room.Id)
    :Set(other, "Health", 20)
    :Destroy(stale)

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

This is also the only way a client creates an object. `Objects.new` is server
side, and until a channel asked for a create, `CanCreate` was a permission
nothing could reach.

### Ordering

Operations apply creates first, then sets, then destroys, whatever order they
were declared in. That is what makes a transaction atomic rather than merely
batched: a create can be taken back by destroying what it made, and a set by
writing back what it overwrote, but a destroy cannot be taken back at all — so
nothing irreversible happens until everything reversible has already succeeded.

Two sets on one property are one change by the time it lands, and an object
destroyed by the same transaction that changed it is announced once, as gone.

### On the client

`Commit` yields until the server answers, and applies nothing early. A single
`Set` is optimistic because it has a local object to write to and a value to
roll back to; a create has neither, and no id at all until the server mints one.

The result comes back as one broadcast rather than one per operation: created
objects arrive down the same chunked path a scene load uses, and changes and
removals have bulk channels beside the single ones.

### Budget

A transaction spends one action per operation rather than one per packet, so a
role with `Rate = 60` may commit sixty operations a second however they are
grouped. Charging per call would let one packet carrying ten thousand
operations walk straight past the limiter. A single transaction carries at most
1024 operations.

## Selection

Client side, and purely local: the server never hears about it. Entries are
pruned on read, so an object destroyed by someone else drops out on its own.

```lua
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

Client edits are denied unless a role allows them. Roles are named, not per
object, and can blacklist object types outright.

```lua
Prism.Permissions:Register("Builder", {
    Level = 10,
    CanCreate = true,
    CanEdit = true,
    CanDestroy = true,
    Rate = 120,           -- actions per second, counted per operation
    Blacklist = {Enemy},  -- may not touch this object type
})

Prism.Permissions:SetDefault("Viewer")
Prism.Permissions:Assign(player, "Builder")
```

The client can read its own role to grey out tools; the server re-checks every
request regardless.

```lua
if Prism.Permissions:Can("Edit", objectType) then ... end
```

## Database

Sharded metadata storage. Records live in `{Key}:1..N`; ids come from a
monotonic counter, so when the tail shard nears the 4 MB value limit its
boundary freezes and a new tail opens. Records never move between shards, and
edits to different shards do not contend with each other.

```lua
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
db:RegisterCache("Newest", {IdOrdered = "Desc", PageSize = 50})

local page = db:Get("Newest", 1)
print(page.Records, page.HasMore)
```

Any other order needs `Sort`, and correctness requires reading every shard: a
record in the last shard can rank first, so stopping early would return "the
most played level among the oldest 50,000" and look plausible while being wrong.

```lua
db:RegisterCache("Popular", {
    Sort = function(a, b) return a[2].Value > b[2].Value end,
    PageSize = 50,
})
```

### Searching

`Find` filters without a global ordering, so it stops as soon as it has enough.
Search by name and list by creator both go through it.

```lua
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
anything, and why user ids and unix timestamps are no longer mangled by f32's
24-bit mantissa. Setting `Precision` quantises values before they are encoded,
which makes them far more likely to fit the 4-byte form.

Ids, lengths and counts are LEB128 varints: one byte below 128, two below 16384.

Property ids are **never recycled**, because they are written into saved data —
reusing one for a different property would silently reinterpret every record
still carrying it. Object registry ids are not recycled either, for the same
reason: a registry id is written into every saved object as its type. Nor are
scene ids, which live in the high bits of every persistent id, or an object's
local id within its scene. Runtime ids are the exception, and only because they
are never written down at all.

Objects and packs carry a format version, and readers refuse anything newer
than they understand rather than misreading it. Individual metadata records do
not — the version lives on the pack that contains them.

## Tests

The tests run the unit suite on the server and the replication, permissions,
optimistic-edit, transaction and lifecycle suite on one client. Sync the files into Studio
with Roblox Script Sync using this layout:

```text
ReplicatedStorage
└── Prism                          <- the repo root, so src/ sits inside it
ServerScriptService
├── Server                         <- tests/Server.server.luau
└── Harness                        <- tests/Harness.luau (ModuleScript)
StarterPlayer
└── StarterPlayerScripts
    ├── Client                     <- tests/Client.client.luau
    └── Harness                    <- tests/Harness.luau (ModuleScript)
```

Both suites reach the harness with `require("./Harness")`, so it has to be a
sibling of each one rather than living in a shared folder.

Then use **Test > Play** with one player. The server creates three integration
fixtures and intentionally keeps them alive so the client can validate both
live delivery and late-join replay. A failed test prints its group and
assertion, then fails the corresponding script.

The database tests write to real DataStore and MemoryStore keys, so they need
Studio API access enabled. They are currently switched on by `RUN_DATABASE` near
the top of `tests/Server.server.luau`; set it to `false` to skip them. The suite
uses the `PrismSelfTest` key, and its cleanup step is commented out, so records
accumulate across runs and ids keep climbing rather than restarting at 1.
