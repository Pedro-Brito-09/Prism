# Permissions

`Prism.Permissions`. See the [Permissions guide](/guides/permissions). Scene rights
are granted on the scene; see [a scene](/api/scenes#a-scene).

## Server

`who` is a Player or a user id.

| Call | Returns | |
|---|---|---|
| `Permissions:Register(name, config)` | role? | |
| `Permissions:GetRegistered()` | `{[name]: role}` | |
| `Permissions:Grant(who, role)` | `boolean` | The role's global half |
| `Permissions:Revoke(who)` | | |
| `Permissions:GrantCapability(who, name)` | | Global |
| `Permissions:RevokeCapability(who, name)` | | Global |
| `Permissions:Get(who)` | global rights | |
| `Permissions:GetOn(scene, who)` | scene rights? | |
| `Permissions:CanPush(player)` | `boolean` | |
| `Permissions:Can(player, action, target, property?)` | `boolean` | |
| `Permissions:Has(player, capability, sceneId?)` | `boolean` | |

## Client

| Call | Returns | |
|---|---|---|
| `Permissions:Get()` | global rights | This player's |
| `Permissions:GetOn(sceneId)` | scene rights? | This player's |
| `Permissions:Can(action, target, property?)` | `boolean` | To grey out tools. Also says no for an object someone else holds |
| `Permissions:Has(capability, sceneId?)` | `boolean` | |
| `Permissions:OnChange(fn)` | disconnect | `fn(sceneId?)` |

`action` is `"Create"`, `"Edit"` or `"Destroy"`. `target` is an object, or for a
create `{Scene = sceneId, Registry = typeId}`.

## Role config

| `Global` field | |
|---|---|
| `Rate` | Actions per second. 60 if left out |
| `CanPush` | Whether a client may push a scene |
| `Capabilities` | `{string}` |

| `Scene` field | |
|---|---|
| `CanCreate`, `CanEdit`, `CanDestroy` | The three verbs |
| `Objects` | `{Whitelist?, Blacklist?}` of object type ids |
| `Properties` | `{Whitelist?, Blacklist?}` of property ids, or `[property] = {objectType}` |
| `Capabilities` | `{string}` |
