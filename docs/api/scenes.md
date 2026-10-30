# Scenes

`Prism.Scenes`. See the guides on [scenes and copies](/guides/scenes),
[saving](/guides/saving), [who sees a scene](/guides/visibility) and
[scenes the client owns](/guides/client-scenes).

## Making and finding scenes

| Call | Side | Returns | |
|---|---|---|---|
| `Scenes.new(config)` | S C | scene? | On the client, a scene it owns |
| `Scenes.fromBuffer(config, pack)` | S C | scene? | A new scene, with a new Guid |
| `Scenes.fromDataStore(store, guid, config, source?)` | S | scene? | Registers under the saved Guid. `nil` with a warning if it cannot |
| `Scenes:Get(name)` | S C | scene? | On the client, the server's scene as `{Id, Name, Guid}` |
| `Scenes:GetById(id)` | S C | scene? | As above |
| `Scenes:GetByGuid(guid)` | S C | scene? | As above |
| `Scenes:GetRegistered()` | S C | `{[id]: scene}` | |
| `Scenes:GetDefault()` | S | scene | The implicit `Default` scene |
| `Scenes:SetPushRole(role?)` | S | | Granted to a player on a scene they push |
| `Scenes:GetLocal(name)` | C | local scene? | A scene this client owns |
| `Scenes:GetLocalById(id)` | C | local scene? | |
| `Scenes:GetOwned()` | C | `{[id]: local scene}` | |

| Config field | Side | |
|---|---|---|
| `Name` | S C | |
| `Private` | S | Say it here if the scene must never be public |
| `Admitted` | S | `{Player \| number}`. Only means anything on a private scene |
| `Rights` | S | `{[Player \| number] = roleName}` |

A `source` is `"Draft"` (the default), `"Published"`, `{Draft = version}`,
`{Published = version}` or `{Backup = id}`.

## Finding copies

| Call | Side | Returns | |
|---|---|---|---|
| `Scenes:GetInstances()` | S | `{copy}` | Every live copy of every scene |
| `Scenes:GetInstance(copyId)` | S | copy? | |
| `Scenes:GetInstances(sceneId)` | C | `{copyId}` | Live copies of a server scene |
| `Scenes:GetInstanceScene(copyId)` | C | `sceneId?` | |
| `Scenes:GetObjects(copyId)` | C | `{object}` | |
| `Scenes:GetFolder(copyId)` | C | `Folder?` | The folder this client drew an opened copy into |
| `Scenes:GetLocalCopy(copyId)` | C | copy? | A copy of a scene this client owns |
| `Scenes:OnCopyAdded(fn)` | C | disconnect | `fn(copyId, sceneId, folder?)`. Does not replay earlier copies |
| `Scenes:OnCopyRemoved(fn)` | C | disconnect | `fn(copyId, sceneId)` |

## Stored versions

| Call | Side | Returns | |
|---|---|---|---|
| `Scenes:ListVersions(store, guid, which, limit?)` | S | `{{Version, Time}}?` | `which` is `"Draft"` or `"Published"`. Newest first |
| `Scenes:ListBackups(store, guid, limit?)` | S | `{{Backup, Time}}?` | Newest first |

## A scene

| Member | Side | Returns | |
|---|---|---|---|
| `.Id`, `.Name` | S C | | `Id` is per server; don't store it |
| `.Guid` | S | `string` | What it is saved under |
| `:Load(parent?, options?)` | S C | copy? | `options` is `{Budget = seconds, Origin = cframe}` |
| `:Unload()` | S C | | Every copy |
| `:Serialize()` | S C | `buffer` | The committed pack, not what a copy holds |
| `:GetInstances()` | S C | `{copy}` | |
| `:Destroy()` | S C | | |
| `:Open(options?)` | S | copy? | Each admitted client draws it |
| `:Save(store)` | S | `boolean` | The draft |
| `:Publish(store)` | S | `boolean` | The scene as it is, not the stored draft |
| `:Backup(store)` | S | `id?` | |
| `:Admit(who)`, `:Evict(who)` | S | | A Player or a user id |
| `:Admits(who)` | S | `boolean` | True for anyone while public |
| `:GetAdmitted()` | S | `{userId}` | |
| `:IsPublic()` | S | `boolean` | |
| `:SetPrivate(private)` | S | | |
| `:Grant(who, role)` | S | `boolean` | The role's scene half |
| `:Revoke(who)` | S | | |
| `:GrantCapability(who, name)`, `:RevokeCapability(who, name)` | S | | |
| `:GetRights(who)` | S | rights? | |
| `:Push(name)` | C | `ok, sceneId?, reason?` | Hands the committed pack to the server |

A refused push's `reason` is `NoPushRight`, `TooLarge`, `TooManyObjects`, `BadName`,
`NameTaken`, `UnknownType`, `Unreadable`, `Budget`, `Failed` or `Unreachable`.

## A copy

| Member | Returns | |
|---|---|---|
| `.Id`, `.Scene`, `.Owner` | | Its id, its scene's id, and the scene itself |
| `.Folder` | `Folder?` | `nil` on the server for an opened copy |
| `.Opened` | `boolean` | |
| `.Unknown` | `{any}` | Objects of unregistered types, kept for saving |
| `:Create(type, values?)` | object? | |
| `:Place(pack, at?)` | `{object}?` | Into this copy, with new ids, moved by `at` |
| `:GetOrigin()` | `CFrame` | Where its [local space](/guides/local-space) sits |
| `:SetOrigin(cframe)` | `boolean` | Moves the whole copy; not an edit, not saved |
| `:ToWorld(value)`, `:ToLocal(value)` | any | A `CFrame` or position, between local and world |
| `:Find(localId)` | object? | The one crossing between [the two identities](/concepts/identity) |
| `:GetObjects()` | `{object}` | |
| `:Serialize()` | `buffer` | What this copy holds right now |
| `:Commit()` | | Writes this copy back into its scene |
| `:Unload()` | | Final |
| `:Suspend()`, `:Revive()` | `boolean` | Out of the world and back |
| `:Dispose()` | | The end of a suspended copy |
