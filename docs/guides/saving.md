# Saving

`instance:Commit()` writes a copy back into its scene. Saving writes what the
scene last committed to a DataStore, under the scene's **Guid**.

```luau
-- server
room:Commit()
Rooms:Save(DataStore)                 -- the draft; false if every retry failed
Rooms:Publish(DataStore)              -- what players get
local id = Rooms:Backup(DataStore)    -- a copy nothing overwrites; nil on failure

local guid = Rooms.Guid               -- keep this wherever your game lists its levels

Prism.Scenes.fromDataStore(DataStore, guid, {Name = "Rooms"})                -- the draft
Prism.Scenes.fromDataStore(DataStore, guid, {Name = "Rooms"}, "Published")
```

Every server scene gets a Guid when it is registered: 22 characters, made by
Prism, never by the game. `Scene.Id` cannot do this job — it is claimed per
server in registration order, so it names a different scene on the next
server, and it is a u16 because it rides on the wire. `fromDataStore` registers
the scene under the Guid it was saved with, so saving it again writes the same
keys; `fromBuffer` and a client's push make a new scene with a new Guid,
because a pack carries none. Clients get the Guid with the scene's name, and
`Scenes:GetByGuid` finds one on either side.

| key | written by | history |
|---|---|---|
| `<Guid>:Draft` | `Save` | the DataStore's own versions, 30 days |
| `<Guid>:Published` | `Publish` | the DataStore's own versions, 30 days |
| `<Guid>:Backup:<id>` | `Backup` | kept until the game removes it |

`Publish` writes the scene as it is, not the stored draft, so a scene published
without saving goes live with its unsaved edits. When to back up is the game's
call — after a publish, once a day, before something risky. A backup's id is
the moment it was taken, in unix milliseconds. Prism never deletes one.

```luau
Prism.Scenes:ListVersions(DataStore, guid, "Draft", 20)    -- {{Version, Time}}, newest first
Prism.Scenes:ListBackups(DataStore, guid, 20)              -- {{Backup, Time}}, newest first

Prism.Scenes.fromDataStore(DataStore, guid, config, {Draft = version})
Prism.Scenes.fromDataStore(DataStore, guid, config, {Published = version})
Prism.Scenes.fromDataStore(DataStore, guid, config, {Backup = id})
```

A listing's entries are what `fromDataStore` takes back: `Version` goes in as
`{Draft = version}` or `{Published = version}`, and `Backup` as `{Backup = id}`.
Every call that reads a stored scene starts with the store and the Guid.

`fromDataStore` returns `nil`, with a warning, when the Guid is not one Prism
made, when the source names more or less than one pack, when a scene is
already registered under it, when the key couldn't be
read, or when nothing is stored there. A new level is `Scenes.new`; reading an
empty key as an empty scene would let any string shaped like a Guid become one.

`Scene:Serialize()` hands you the pack itself, to store wherever you like, and
`Scenes.fromBuffer(config, pack)` reads one. Store it as the **buffer**, never
`buffer.tostring` of it: a DataStore only takes strings that are valid UTF-8,
and a pack's bytes are not, so that write fails.

A DataStore counts a buffer at its base64 size, so one key holds a pack of
about **3 MiB**, not 4 MB: measured, 3,145,312 bytes stored and anything a few
hundred bytes past that was refused. A real 35,000 object level packs to
about 130 KB.

Committing is always explicit. Unloading never writes back on its own — with
more than one copy live it would have to pick one, and it cannot.

`Objects.new` with no scene lands in an implicit `Default` scene, loaded the
first time something needs it, so object creation works with no scene of your
own. Naming a scene that is loaded twice is refused rather than guessed.
