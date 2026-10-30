# Objects

An object type is a named set of properties, optionally backed by a template
instance. `Objects.new` clones that template per instance.

```luau
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
see [Storage format](/internals/storage-format#what-this-build-cannot-read-is-kept).

`Objects:OnAdded` and `Objects:OnRemoved` fire on **both sides** for every
object that appears or goes, so neither a panel nor a server script has to poll
`GetWorkspace()` to notice one.

```luau
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

## Basics

Every object carries two ids: `RuntimeId`, which names this live copy of it, and
`PersistentId`, which is saved with it and outlives a reload. See [Two identities](/concepts/identity).

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
the client owns, and takes no `copy`: the duplicate lands beside the original. An object the server holds is duplicated with a transaction's
`Duplicate`, which checks create rights like any other create.

`Objects:DuplicateGroup(objects, copy?)` duplicates several as one thing (no
`copy` on the client here either), which
is not the same as calling `Duplicate` on each: references *between* the
originals are remapped onto the copies, and references pointing outside the
group are left alone. Duplicate a room and its buttons work its own doors;
duplicate one lever and it still works the door it always worked.

Watch a single property without paying for a signal on every property:

```luau
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

```luau
enemy:GetProperty("Health").Constraints.MaxValue
```
