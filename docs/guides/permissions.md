# Permissions

Rights come in two kinds. Global rights are about the session: the action
budget, whether a client may push a scene, and any capabilities your game
defines. Scene rights are about one scene: the three verbs, which object types
and properties they reach, and that scene's capabilities. A player with no
rights on a scene can do nothing there.

```luau
-- server
Prism.Permissions:Register("Builder", {
    Global = {Rate = 120, CanPush = true},  -- actions per second, per operation
    Scene = {
        CanCreate = true,
        CanEdit = true,
        CanDestroy = true,
        Objects = {Blacklist = {Enemy}},                -- may not touch this type
        Properties = {Blacklist = {[Tint] = {Crate}}},  -- nor tint a crate
        Capabilities = {"Invite"},
    },
})

Prism.Permissions:Grant(player, "Builder")      -- the global half
level:Grant(ownerUserId, "Builder")             -- the scene half, on this scene
level:GrantCapability(player, "Publish")
level:RevokeCapability(player, "Publish")
```

A role is a template. Granting one clears what the player held there and
copies the role in. After that the player's own set is the whole truth, so
editing a role later doesn't reach anyone who already holds it.

Grants are keyed by user id, and passing a Player uses theirs. A grant can name
someone who hasn't joined yet, and it still applies when they rejoin. Scene
rights last as long as their scene; global rights last as long as the server.
Nothing is saved: who owns a level is your game's own record, so hand it over
when the scene is made.

```luau
-- server
local level = Prism.Scenes.new({Name = "Level 4", Rights = {[ownerUserId] = "Builder"}})
```

Object and property lists each take a whitelist and a blacklist. A present
whitelist is exhaustive; an absent one constrains nothing. Property lists take
ids like object lists do, or `[Property] = {ObjectType}` to limit an entry to
those types. They govern writing only, never what a client is sent.

Capabilities are plain strings that exist by appearing in a role or a grant.
Prism enforces only its three verbs and just answers for capabilities. Asking
for one that nothing grants warns once.

```luau
Prism.Permissions:Has(player, "Invite", level.Id)   -- server
Prism.Permissions:Has("Publish")                    -- client, global
Prism.Permissions:Can("Edit", object, Tint)         -- client, to grey out tools
```

A player without a global grant gets a budget of 60 actions a second and can't
push. The server re-checks every request, whatever the client thinks.
