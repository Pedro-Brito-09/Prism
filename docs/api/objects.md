# Objects

`Prism.Objects`. See the guides on [objects](/guides/objects),
[locks](/guides/locks), [dragging](/guides/dragging) and
[references](/guides/references).

## Registry

| Call | Side | Returns | |
|---|---|---|---|
| `Objects:Register(config)` | S | `id?` | |
| `Objects:Unregister(id)` | S | `boolean` | Refused while any object of the type is live. The id is never reused |
| `Objects:GetRegistered()` | S C | `{[id]: registry}` | |
| `Objects:GetRegistry(id)` | S C | `registry?` | |

| Config field | Type | |
|---|---|---|
| `Name` | `string` | |
| `Properties` | `{id}` | Property ids |
| `Instance` | `Instance?` | The template to clone |
| `Links` | `{link}?` | `{Property, Type = "Property" \| "Attribute", Name, Descendant?, SceneSpace?}`; see [Local space](/guides/local-space) |
| `Replicate` | `string?` | `"Everyone"` (default) or `"Admitted"` |

## Finding and making objects

| Call | Side | Returns | |
|---|---|---|---|
| `Objects.new(type, values?, copy?)` | S | object | With no copy, lands in the implicit `Default` scene |
| `Objects.new(type, values?, copy)` | C | object | In a copy this client owns; `copy` is required |
| `Objects:Get(runtimeId)` | S C | object? | |
| `Objects:GetWorkspace()` | S C | `{[runtimeId]: object}` | The live map. An unload can swap it, so read it again rather than keeping it |
| `Objects:Resolve(copyId, value)` | S C | object? | A local id, within a copy, or an address |
| `Objects:Split(persistentId)` | S C | `sceneId, localId` | |
| `Objects:FromInstance(instance)` | C | object? | |
| `Objects:Duplicate(object, copy?)` | S | object? | |
| `Objects:DuplicateGroup(objects, copy?)` | S | `{object}` | Remaps references between them |
| `Objects:Duplicate(object)` | C | object? | Scenes the client owns |
| `Objects:DuplicateGroup(objects)` | C | `{object}` | Scenes the client owns |
| `Objects:CountConfirmed()` | C | `number` | Properties holding a confirmed value |

## An object

| Field | |
|---|---|
| `RuntimeId` | This live object. See [two identities](/concepts/identity) |
| `PersistentId`, `Scene`, `LocalId` | The object in a pack, and its two halves |
| `InstanceId` | The id of the copy holding it |
| `Registry` | The id of its type |
| `Name` | Its type's name |
| `Instance` | Its part, if it has one |
| `Destroyed` | `true` once gone |
| `Suspended` | `true` while withdrawn but kept for undo |
| `Local` | Client: in a scene this client owns |
| `Drawn` | Client: this client built its part, because the copy was opened |

| Method | Returns | |
|---|---|---|
| `:Set(property, value, clientSided?)` | `boolean` | `property` is an id or a name. `clientSided` is client only; see [dragging](/guides/dragging) |
| `:Get(property)` | value? | An `Object` property hands back the object |
| `:GetProperty(property)` | [property](/api/properties#a-property)? | |
| `:OnChange(property, fn)` | disconnect | |
| `:Destroy()` | | |

## Locks

| Call | Side | Returns | |
|---|---|---|---|
| `Objects:Lock(objects)` | C | `boolean` | One object or a list, all or none |
| `Objects:Unlock(objects)` | C | `boolean` | One object or a list |
| `Objects:Lock(objects, holder)` | S | `boolean` | One object or a list, all or none. `holder` is a Player, user id or any other value |
| `Objects:Unlock(objects, holder?)` | S | `boolean` | One object or a list. With no holder, releases anyone's |
| `Objects:IsLocked(object)` | S C | `boolean` | Held by anything at all. The client also takes a runtime id |
| `Objects:GetLock(object)` | S C | `userId?` | `nil` if free or held by a non-player. The client also takes a runtime id |
| `Objects:GetHolder(object)` | S | any | Whatever holds it |
| `Objects:OnLockChanged(fn)` | C | disconnect | `fn(runtimeId, userId?, held)` |

## Signals

| Call | Side | Callback |
|---|---|---|
| `Objects:OnAdded(fn)` | S C | `fn(object, restored)` |
| `Objects:OnRemoved(fn)` | S C | `fn(object)` |
| `Objects:OnEdited(fn)` | C | `fn(object, propertyId, before, after)`, for this client's own sets |
| `Objects.OnPlayerEdited(fn)` | S | `fn(player, object, propertyId, before, after)`, for a player's sets |
| `Objects.OnRetired(fn)` | S | `fn(player?, object) -> boolean`; return `true` to keep it |
| `Objects.OnRetired(fn)` | C | `fn(object) -> boolean` |

## Setting objects aside

Plain functions. See [Setting a copy aside](/guides/scenes#setting-a-copy-aside).

| Call | Side | Returns | |
|---|---|---|---|
| `Objects.Suspend(object)` | S C | `boolean` | Out of the world, kept whole |
| `Objects.Revive(object)` | S C | `boolean` | Back as it was |
| `Objects.Dispose(object)` | S C | | The end of a suspended object |
| `Objects.Retire(player?, object)` | S | | Suspend, and offer it to whatever keeps destroyed objects |
| `Objects.Retire(object)` | C | | |
