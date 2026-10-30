# A first editor

An editor end to end: a crate type, a role that may edit it, a level, a client
that creates and changes a crate, and a save. Every piece is covered properly in
the guides; this page is the shape of the whole thing.

Register what exists on the server, once. Registries replicate to every client,
including ones that join later.

```luau
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

```luau
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

```luau
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
requires Prism, so wait for them before looking ids up. Start with
[how Prism fits together](/concepts/overview) for the model behind this.
