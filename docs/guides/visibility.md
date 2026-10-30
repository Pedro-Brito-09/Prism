# Who sees a scene

A scene is public unless you say otherwise. A **private** one tells only the
players it admits its name, and sends them alone the objects whose type has
`Replicate = "Admitted"`.

```luau
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

## Opening instead of loading

`Load` builds every object's part on the server, so the parts replicate to
every player whether or not they're admitted. `Open` builds none. The server
still owns the copy and its data, but it clones no templates, and each admitted
client draws the copy itself from the template that came with the registry.

```luau
-- server
local Draft = Prism.Scenes.new({Name = "Draft", Private = true, Admitted = {editorUserId}})
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

```luau
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
