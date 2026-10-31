# Local space

Every copy has a local space, and its **origin** is where that space sits in the
world. Values stay relative to the copy. Only a link marked `SceneSpace` writes
the world position to its target:

```luau
-- server
local Crate = Prism.Objects:Register({
    Name = "Crate",
    Properties = {Spot, Bulk},
    Instance = ReplicatedStorage.CrateTemplate,
    Links = {
        {Property = Spot, Type = "Property", Name = "CFrame", SceneSpace = true},
        {Property = Bulk, Type = "Property", Name = "Size"},
    },
})

local a = Rooms:Load(workspace)
local b = Rooms:Load(workspace, {Origin = CFrame.new(5000, 0, 0)})
```

An object with `Spot` at `(10, 0, 0)` holds that value in both copies. Its part
sits at `(10, 0, 0)` in `a` and `(5010, 0, 0)` in `b`.

```luau
b:SetOrigin(CFrame.new(9000, 0, 0))   -- the whole copy, in one packet
b:GetOrigin()
```

Moving a copy changes no value. It isn't an edit, so it records no history, and
a commit doesn't save it, so a moved room committed is the same room. The default
origin leaves everything where its value says, so a level that never uses this
behaves and saves exactly as it did. Copies set aside take a new origin when they
come back.

## What `SceneSpace` means

It says the link's target wants a world value, so Prism writes `Origin * value`
to it. It lives on the link because that is a fact about the target: one property
can drive a part's `CFrame` on one type and an attachment's on another.

| Target | `SceneSpace` | |
|---|---|---|
| `Part.CFrame`, `Part.Position` | yes | World space |
| An attribute a script reads as a world position | yes | The script gets the world value |
| `Attachment.CFrame`, `Weld.C0` | no | Already relative, so it would be moved twice |
| `Part.Size` | no | Not a position |

The property has to be a `CFrame` or a `Vector`, and a `Vector` is taken as a
point. Anything else warns at registration and loses the flag, and so does a
link to `Orientation` or `Rotation`: those are angles, and a rotated origin can't
be applied to them by multiplying. Keep position and rotation in one `CFrame`
property. A `Vector` target other than those two can't be told from a position,
so marking a `Size` is yours to avoid.

A link with no flag is untouched by the origin, so a part it drives stays put
while the rest of its copy moves.

## Working in the world

`Get`, `Set` and a save are all relative to the copy. Anything that thinks in the
world, like a drag gizmo, crosses over first:

```luau
-- server, or a copy a client owns
copy:ToWorld(crate:Get(Spot))
crate:Set(Spot, copy:ToLocal(worldCFrame))

-- client, by copy id
Prism.Scenes:ToWorld(crate.InstanceId, crate:Get(Spot))
crate:Set(Spot, Prism.Scenes:ToLocal(crate.InstanceId, pointer), true)
```

A `Scene:Load` option, `SetOrigin` and the three conversions work the same on a
copy a client owns. A client can't move a copy the server owns.

Pivoting a `Model` of your own moves the parts but not the values, so the next
`Set` writes a part back to where its value says. Use an origin to move a copy
whose objects can change.

## Placing somewhere

`Place` reads a pack at the local positions it was saved with. `At` moves what it
places, through each `SceneSpace` link's value:

```luau
room:Place(prefab, CFrame.new(100, 0, 0))
Prism.Transactions.new():Place(prefab, room.Id, CFrame.new(100, 0, 0)):Commit()
```

Unlike an origin, this does change the values, because the placed objects are
part of the copy from then on.
