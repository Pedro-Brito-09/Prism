--!strict
const ObjectTypes = require("../Objects/Types")
const Handles = require("../Handles")

export type SceneIdentifier = Handles.SceneIdentifier
export type PersistentId = Handles.PersistentId

export type SceneConfig = {
    CustomId: SceneIdentifier?,
    Name: string,

    -- Where a copy of this scene parents its instances, unless the copy names
    -- its own. Falls back to the object registry's Container, which is what a
    -- game with one scene has always used.
    Container: Instance?,
}

export type SceneRegistry = {
    Id: SceneIdentifier,
    Name: string,
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

    Container: Instance?,
    Objects: {[ObjectTypes.RuntimeId]: ObjectTypes.Object},

    -- The one crossing between the two identities, and deliberately scoped to a
    -- copy: a persistent id names an object here, but names one in every other
    -- live copy of the same scene too.
    ByLocal: {[Handles.LocalId]: ObjectTypes.Object},

    Create: (
        self: SceneInstance,
        Reference: ObjectTypes.ObjectRegistry | ObjectTypes.ObjectIdentifier,
        InitialValues: {[number]: any}?
    ) -> ObjectTypes.Object?,

    Find: (self: SceneInstance, Local: Handles.LocalId) -> ObjectTypes.Object?,
    GetObjects: (self: SceneInstance) -> {ObjectTypes.Object},

    -- What this copy holds right now, as a pack.
    Serialize: (self: SceneInstance) -> buffer,

    -- Writes that pack back into the scene, making this copy what the scene
    -- says it is. Explicit rather than a side effect of unloading, because with
    -- more than one copy live, "save on unload" has to pick one and cannot.
    Commit: (self: SceneInstance) -> (),

    Unload: (self: SceneInstance) -> (),
}

export type Scene = {
    Id: SceneIdentifier,
    Name: string,
    Container: Instance?,

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
    Load: (self: Scene, Container: Instance?) -> SceneInstance?,

    -- Every copy at once. A single copy unloads itself.
    Unload: (self: Scene) -> (),

    -- The committed pack, for the caller to store however it likes. This is
    -- what the scene says it is, not what any copy currently holds.
    Serialize: (self: Scene) -> buffer,

    GetInstances: (self: Scene) -> {SceneInstance},
    Destroy: (self: Scene) -> (),
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
