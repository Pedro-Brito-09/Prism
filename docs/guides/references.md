# References

An `Object` property points at another object.

```luau
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
door.

`Get` answers `nil` in three cases it does not tell apart: nothing is pointed
at, the target was destroyed, and the target has not arrived yet — a copy builds
its objects one at a time, so a button exists before its door does, and on a
client either half can replicate first. The stored id is kept in all three, so
the link comes back on its own when the target does. To read the raw id, go
through the property: `button:GetProperty("Target").Value`.

`Objects:Resolve(copyId, localId)` answers the same question from a raw id, for
a caller holding one that did not come off a property — the crossing itself,
scoped to a copy because that is the only scope a local id answers in.

## Into another scene

The same property can point at an object in another scene. Hand it the object:

```luau
-- server
portal:Set("Target", lobbyDoor)     -- lobbyDoor is in another scene
portal:Get("Target")                -- lobbyDoor
portal:GetProperty("Target").Value  -- "<Guid>:<LocalId>"
```

A local id means nothing outside its copy, and a scene id means nothing on the
next server, so what's stored instead is an **address**: the target scene's
[Guid](/guides/saving) and the local id, as text. Set a target in the same copy
and the property goes back to holding a plain local id. Either kind can sit in a
`Table` of `Object`, side by side.

An address is looked up on every read, so it doesn't matter which scene loads
first. It answers when **the target scene has exactly one live copy**:

| The target scene | `Get` | `Set` with the object |
|---|---|---|
| is live once | the object | stores the address |
| is not loaded | `nil`, address kept | nothing to hand it |
| is live more than once | `nil`, address kept | refused |

A scene loaded twice has two objects under that address, and picking one would
wire a portal to whichever room loaded first — the same reason naming such a
scene in `Objects.new` is refused. That includes another copy of the holder's own
scene. When a game does want a particular copy, take the local id off the end of
the address and ask that copy: `copy:Find(tonumber(address:match("%d+$")))`.

A client resolves an address only for scenes it has been told about, so one into
a private scene the player isn't admitted to reads as `nil`. The value itself
still reaches that player, Guid included: the scene's name and objects don't, but
the Guid does. A client's own scene has no Guid and can't be pointed at from
another scene; its objects can point out at the server's scenes.

Inserted copies don't count as the scene's copy, because they're a part of another
scene. Reaching one takes the longer address on
[Inserting a scene](/guides/inserting#references).

Three limits follow from the address naming a saved scene:

- `fromBuffer` and a client's push make a new scene with a new Guid, so references
  to the original don't follow them. `fromDataStore` keeps the Guid, and so keeps
  them working.
- `Duplicate`, `DuplicateGroup` and `Place` leave an address as it is. It already
  means the same thing from anywhere, so a placed portal keeps its destination,
  where a local id the pack didn't carry is dropped.
- `OnChange` doesn't fire when a target appears, as with a local id. A value
  changing is what it reports, and the value hasn't.

## Constraints, links and wiring

`Constraints.Types` says what the property may point at, by object type id or
registered name. It's checked when the target actually resolves; an id naming
nothing is always allowed, because refusing one would make a pack restorable
only in the order it happened to be written.

Two things worth knowing. A reference can't drive an instance member, so a
`Links` entry naming one is dropped at registration — a local id on a part would
mean nothing outside its copy. And a reference follows one object, not its
lookalikes: undoing a destroy brings back **that same object** under its own
local id, so every reference to it works again (see
[History](/guides/history#a-destroy-is-deferred-not-undone)), but a duplicate or a placed copy
is a new object with a new id, and references to the original stay on the
original. `DuplicateGroup` and `Place` remap the references *inside* what they
copy.

Creating two objects already wired to each other takes one transaction, because
neither id exists until the server mints it:

```luau
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
