# Scenes the client owns

A client can own a scene outright — a prefab preview, a sandbox, a room built
before anyone else sees it. It is the same document a server scene is, with one
difference: nothing in it replicates, so its objects apply their own edits
instead of asking for them. There is nobody to ask and nothing to roll back to.

```luau
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
`Serialize` and `Unload` a server scene has, and its copies have the same
`Create`, `Find`, `Commit`, `Place` and `Serialize`.
`Scenes:Get` still means the server's scene of that name and `Scenes:GetLocal`
means yours; local ids count down from the top of the id space while the
server's count up, so the two never collide.

Objects you own carry `Local = true`, which is how an editor tells an edit that
has already happened from one that can still be refused.

## Handing one to the server

```luau
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
