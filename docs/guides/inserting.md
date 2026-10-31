# Inserting a scene

Inserting puts one scene inside another, as many times as you like, each at its
own place. Think of Roblox packages: the source stays one document, and each
insert is a copy of it that keeps its own position.

```luau
-- server
local Hallway = Prism.Scenes.new({Name = "Hallway"})
local Rooms = Prism.Scenes.new({Name = "Rooms"})

local near = Rooms:Insert(Hallway, CFrame.new(0, 0, 0))
local far = Rooms:Insert(Hallway, CFrame.new(5000, 0, 0))

local room = Rooms:Load()
room.Inserted[far]             -- the far hallway, an ordinary copy
```

Loading `Rooms` loads a copy of `Hallway` for each insert, in that copy's folder.
Unloading or setting aside the room takes them with it. Load `Rooms` five times
and each copy has its own two hallways.

An insert's origin is in the local space of the scene it's in, so moving the room
moves them too. This depends on [local space](/guides/local-space): only links
marked `SceneSpace` follow an origin, so a hallway's parts need that flag to land
in two places.

```luau
Rooms:MoveInsert(far, CFrame.new(9000, 0, 0))
Rooms:RemoveInsert(near)
Rooms:GetInserts()            -- {{Id, Guid, Origin}}
```

These change every live copy of `Rooms` at once. Inserts belong to the scene, not
a copy, so they go straight into its pack with no commit. Save the scene to keep
them. An id is never handed out twice, and inserting that would put a scene inside
itself, directly or through another, is refused.

## Updating

Committing the source updates every insert of it, like publishing a package:

```luau
local edit = Hallway:Load()
edit:Find(doorId):Set(Color, red)
edit:Commit()                         -- every hallway in every live room is red
```

Each inserted copy is compared with the source by local id, because the same id
is always the same object. A changed value is set, an object the source gained is
built, and one it lost is destroyed. Objects that didn't change aren't touched,
their parts aren't rebuilt, and references to them hold. An insert's origin is the
room's, so an update never moves one away from where you put it.

- **Only inserts follow.** A copy of the scene loaded on its own is left alone,
  because it may hold somebody's work.
- **It happens inside the commit**, all at once, so no insert is ever half
  updated. A large source updated in many places takes that long, in one frame.
- **Other servers** read the latest source the next time they load the level,
  once it has been saved. An update doesn't reach a server that's already running.
- **A room set aside** catches up when it comes back.
- If a reference pointed at an object the source removed, `Get` answers `nil` and
  the address stays, as with any destroyed target.

## Read only

An inserted copy is its source's to change. Setting or destroying anything in it,
creating or placing into it, committing it and moving it are all refused, so
nothing inside can be lost to an update. Edit the source scene instead.

A client's edit to an object in an inserted copy shows and then rolls back when
the server refuses it. Scenes a client owns can't be inserted or insert others,
and a push from a client drops any inserts in its pack.

## Finding the source

A source has to be registered when the level loads. If it isn't, that insert warns
and is skipped, and the rest of the level loads. Handing `Load` a store fetches
what's missing, registered under its Guid:

```luau
Rooms:Load(workspace, {Store = DataStore})                    -- what was published
Rooms:Load(workspace, {Store = DataStore, Source = "Draft"})
```

Register sources yourself first if they need a `Private` flag or a name.

## References

An object in an inserted copy has the same Guid as every other copy of its
source, so an address to one goes through the scene it's inserted in and says
which insert: `<Guid>/<InsertId>:<LocalId>`. Hand `Set` the object and Prism writes
that for you.

```luau
button:Set("Target", room.Inserted[far]:Find(doorId))
```

| From | To | |
|---|---|---|
| A room | A door in one of its own inserts | Works, and each copy of the room finds its own |
| A room | A door in another room's insert | Refused: it would read as its own room's |
| Another scene | A door in an insert | Works while the room has one live copy of its own |
| Another scene | `Hallway`, by its plain address | Only a standalone copy; inserted ones don't count |
| Inside an insert | The room around it | Not possible: inserts are read only, and the source doesn't know where it's used |

So references go inward. The room points at its hallways, and a hallway can't
point out at the room.
