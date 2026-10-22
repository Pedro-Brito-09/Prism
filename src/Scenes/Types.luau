--!strict
const ObjectTypes = require("../Objects/Types")
const PermissionTypes = require("../Permissions/Types")
const Handles = require("../Handles")

export type SceneIdentifier = Handles.SceneIdentifier
export type PersistentId = Handles.PersistentId

export type SceneConfig = {
    Name: string,

    -- Server only. Whether the scene is anybody's to see. Public unless this
    -- says otherwise, and it has to be said here rather than after the fact:
    -- registering a scene has already told everyone present its name.
    Private: boolean?,

    -- Server only. Who the scene admits from the moment it exists, by Player or
    -- user id. Only means anything on a private scene -- a public one is
    -- everybody's, and a list on it is inert.
    Admitted: {Player | number}?,

    -- Server only. Rights over the scene from the moment it exists: Player or
    -- user id to the name of the role to grant. The collaborator list a game
    -- already keeps, handed over once, so an owner holds their rights the
    -- moment they arrive rather than after a PlayerAdded hook remembers them.
    Rights: {[any]: string}?,
}

export type SceneRegistry = {
    Id: SceneIdentifier,
    Name: string,
}

-- How a pack is read into a new copy.
export type LoadOptions = {
    -- Seconds of each frame the read may spend building objects before it
    -- waits for the next frame. 1/120 unless given: the server keeps running
    -- while a large level loads, and the load takes about twice as long as the
    -- building does. A game that can afford a stall -- a level loading behind a
    -- loading screen -- can give more, and math.huge builds everything without
    -- waiting at all.
    Budget: number?,
}

-- One live copy of a scene. Load makes them and every one is equal: there is no
-- canonical copy, because a scene is the document and a copy is a reading of
-- it. Objects live here rather than on the scene, which is also the only place
-- they could live -- ask a scene loaded twice for "the object with local id 4"
-- and there is no answer.
export type SceneInstance = {
    Id: ObjectTypes.SceneInstanceId,
    Scene: SceneIdentifier,

    -- The scene this reads. Loose for the same reason Registry is: naming Scene
    -- here would be circular with the field below.
    Owner: any,

    -- Where this copy's objects live. A folder Prism makes and names for the
    -- copy, parented wherever Load was told to put it -- or under
    -- workspace.__prism.__scene_N when it was told nothing. Parent it into a
    -- Model of your own to pivot a whole copy, into PlayerGui for a scene made
    -- of interfaces, anywhere a Folder can go.
    --
    -- Nil for a copy the server opened: it builds no parts, so there is nothing
    -- for a folder of its to hold. Each client drawing the copy keeps its own.
    Folder: Folder?,

    -- True for a copy the server opened rather than loaded. The server owns
    -- its data exactly as it owns a loaded copy's, but clones no templates;
    -- every admitted client draws the copy itself.
    Opened: boolean,

    Objects: {[ObjectTypes.RuntimeId]: ObjectTypes.Object},

    -- Withdrawn from the world but kept whole, and holding the objects it took
    -- with it: out of the registries, folder out of the tree, every object in
    -- it suspended. What a player asking for a copy to go gets, as against
    -- Unload, which is final -- a copy cannot be rebuilt from its scene the way
    -- it was, because loading reads what the scene last committed rather than
    -- what was on screen.
    Suspended: {ObjectTypes.Object}?,

    -- Where the folder was parented while it was live, so a copy a game loaded
    -- into PlayerGui or into a Model of its own goes back there.
    Parent: Instance?,

    -- The one crossing between the two identities, and deliberately scoped to a
    -- copy: a persistent id names an object here, but names one in every other
    -- live copy of the same scene too.
    ByLocal: {[Handles.LocalId]: ObjectTypes.Object},

    -- Objects in the pack whose type this build does not have, as decoded
    -- records. Not objects: nothing finds, draws or replicates them. They are
    -- here so Serialize and Commit write them back where they were rather than
    -- deleting them from the level.
    Unknown: {any},

    Create: (
        self: SceneInstance,
        Reference: ObjectTypes.ObjectRegistry | ObjectTypes.ObjectIdentifier,
        InitialValues: {[number]: any}?
    ) -> ObjectTypes.Object?,

    -- A pack read into this copy rather than into a copy of its own: pasting a
    -- prefab into a level being edited. Every object is made afresh under an id
    -- this copy's scene mints, and the references inside the pack are remapped
    -- onto them; a reference pointing at anything the pack did not carry is
    -- dropped, because the id it holds means nothing here. Returns what it made,
    -- or nil if the pack could not be read.
    Place: (self: SceneInstance, Pack: buffer) -> {ObjectTypes.Object}?,

    Find: (self: SceneInstance, Local: Handles.LocalId) -> ObjectTypes.Object?,
    GetObjects: (self: SceneInstance) -> {ObjectTypes.Object},

    -- What this copy holds right now, as a pack.
    Serialize: (self: SceneInstance) -> buffer,

    -- Writes that pack back into the scene, making this copy what the scene
    -- says it is. Explicit rather than a side effect of unloading, because with
    -- more than one copy live, "save on unload" has to pick one and cannot.
    Commit: (self: SceneInstance) -> (),

    Unload: (self: SceneInstance) -> (),

    -- Out of the world, kept, and back again. True when it went; false when it
    -- was already away, or when its scene has been unregistered since and there
    -- is nothing to come back to. Dispose is the end of a suspended copy: its
    -- objects for good, and the folder they were in.
    Suspend: (self: SceneInstance) -> boolean,
    Revive: (self: SceneInstance) -> boolean,
    Dispose: (self: SceneInstance) -> (),
}

export type Scene = {
    Id: SceneIdentifier,
    Name: string,

    -- Only ever climbs, and is written into the pack. Handing a local id back
    -- out after its object is gone would make any reference still holding it --
    -- an undo entry, another object pointing here -- silently name a different
    -- object, which is the same reason property ids are never recycled.
    --
    -- It belongs to the scene rather than to a copy: two copies both creating
    -- an object have to get different ids, or committing either one would be
    -- undefined.
    LastId: Handles.LocalId,

    -- The committed state. A scene is this and nothing else until it is loaded.
    Data: buffer?,

    Instances: {[ObjectTypes.SceneInstanceId]: SceneInstance},

    -- A new live copy. Called twice, it gives two, and they are equals -- which
    -- is what makes one saved room able to stand in the world five times. Nil
    -- only where the scene's pack could not be read.
    Load: (self: Scene, Parent: Instance?, Options: LoadOptions?) -> SceneInstance?,

    -- Every copy at once. A single copy unloads itself.
    Unload: (self: Scene) -> (),

    -- The committed pack, for the caller to store however it likes. This is
    -- what the scene says it is, not what any copy currently holds.
    Serialize: (self: Scene) -> buffer,

    GetInstances: (self: Scene) -> {SceneInstance},
    Destroy: (self: Scene) -> (),
}

-- A scene on the server also decides who hears about it. One that has admitted
-- nobody is public, which is what every scene was before admission existed;
-- one that has admitted anybody is told to them and to nobody else -- its name,
-- its copies and its objects alike.
export type ServerScene = Scene & {
    -- Writes the committed pack to a DataStore key, as the buffer itself.
    -- False when every attempt failed.
    Save: (self: ServerScene, Store: GlobalDataStore, Key: string) -> boolean,

    -- Whether the scene is anybody's to see. A private scene is told to the
    -- players it admits and to nobody else; a public one is everybody's, and
    -- its admitted list is inert.
    --
    -- A flag rather than something read off the list. Privacy used to mean "has
    -- admitted somebody", which made evicting the last player throw the scene
    -- open -- to everyone, including the player just evicted -- at exactly the
    -- moment somebody was locking it down. It also left no way to say the one
    -- thing a level editor most wants at the start: closed, and nobody in it
    -- yet.
    Private: boolean,

    -- User ids. The scene's rather than anyone's session, so it outlives
    -- whoever is connected.
    Admitted: {[number]: true},

    -- A live copy the server holds the data of and builds no parts for. Every
    -- admitted client draws it, and nobody else is told it exists: Roblox has
    -- no per-player workspace, so a part in the world is a part for everybody,
    -- and this is the only way to keep a scene out of sight.
    Open: (self: ServerScene, Options: LoadOptions?) -> SceneInstance?,

    Admit: (self: ServerScene, Who: Player | number) -> (),
    Evict: (self: ServerScene, Who: Player | number) -> (),

    -- True for anyone at all while the scene is public.
    Admits: (self: ServerScene, Who: Player | number) -> boolean,
    GetAdmitted: (self: ServerScene) -> {number},
    IsPublic: (self: ServerScene) -> boolean,

    -- Closing a scene or opening it, after it has been registered. Closing
    -- takes it away from everyone it does not admit; opening hands it to
    -- everybody.
    SetPrivate: (self: ServerScene, Private: boolean) -> (),

    -- Rights over this scene, by user id. Not admission: admission decides
    -- what a player is sent, and these decide what they may change. Session
    -- state that goes with the scene; nothing writes them into a pack.
    Rights: {[number]: PermissionTypes.SceneRights},

    -- Clears what the player held here and copies the role's scene half in.
    Grant: (self: ServerScene, Who: Player | number, Role: string) -> boolean,
    Revoke: (self: ServerScene, Who: Player | number) -> (),
    GrantCapability: (self: ServerScene, Who: Player | number, Capability: string) -> (),
    RevokeCapability: (self: ServerScene, Who: Player | number, Capability: string) -> (),
    GetRights: (self: ServerScene, Who: Player | number) -> PermissionTypes.SceneRights?,
}

-- A scene the client owns outright: a prefab preview, a local sandbox, a room
-- being built before anyone else is shown it. The same document a server scene
-- is -- copies, packs, persistent ids, all of it -- except that nothing in it
-- replicates and nothing in it needs asking for. Its objects apply their own
-- edits, because there is nobody to ask.
--
-- Push is the one thing a server scene has no equivalent of: it hands the
-- committed pack to the server, which registers a scene of its own from it.
-- What comes back is that scene's id, and it is a different document from this
-- one -- pushing twice registers two.
export type LocalScene = Scene & {
    Push: (self: LocalScene, Name: string) -> (boolean, SceneIdentifier?),
}

return true
