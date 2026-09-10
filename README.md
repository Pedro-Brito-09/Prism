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
    Container = workspace.Level,
    Links = {
        {Property = Health, Type = "Attribute", Name = "Health"},
    },
})

local enemy = Prism.Objects.new(Enemy)
enemy:Set(Health, 50)
enemy:Get("Health")
enemy:Destroy()
```

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
    Rate = 120,           -- actions per second
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
reason: a registry id is written into every saved object as its type. Runtime
ids come from a monotonic per-session counter and are never reused.

Objects and packs carry a format version, and readers refuse anything newer
than they understand rather than misreading it. Individual metadata records do
not — the version lives on the pack that contains them.

## Tests

The tests run the unit suite on the server and the replication, permissions,
optimistic-edit, and lifecycle suite on one client. Sync the files into Studio
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
