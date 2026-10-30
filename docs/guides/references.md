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
