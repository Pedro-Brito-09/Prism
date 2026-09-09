--!strict
const ObjectTypes = require("../Objects/Types")
const Handles = require("../Handles")

export type SceneIdentifier = Handles.SceneIdentifier
export type PersistentId = Handles.PersistentId

export type SceneConfig = {
    CustomId: SceneIdentifier?,
    Name: string,

    -- Where this scene's instances are parented while it is loaded. Falls back
    -- to the object registry's own Container, which is what a game with one
    -- scene has always used.
    Container: Instance?,
}

export type SceneRegistry = {
    Id: SceneIdentifier,
    Name: string,
}

-- One live copy of a scene's objects. Load makes the canonical one; Instance
-- makes extras, which share the pack's persistent ids and differ only in their
-- objects' runtime ids.
export type SceneInstance = {
    Id: ObjectTypes.SceneInstanceId,
    Scene: SceneIdentifier,

    -- The scene this came from, for the id counter. Loose for the same reason
    -- Registry is: naming Scene here would be circular with the field below.
    Owner: any,

    Container: Instance?,
    Canonical: boolean,
    Objects: {[ObjectTypes.RuntimeId]: ObjectTypes.Object},

    -- The one crossing between the two identities, and deliberately scoped to
    -- an instance: a persistent id names one object here, but names one in
    -- every other live copy of the same scene too.
    ByLocal: {[Handles.LocalId]: ObjectTypes.Object},

    Find: (self: SceneInstance, Local: Handles.LocalId) -> ObjectTypes.Object?,
    GetObjects: (self: SceneInstance) -> {ObjectTypes.Object},
    Destroy: (self: SceneInstance) -> (),
}

export type Scene = {
    Id: SceneIdentifier,
    Name: string,
    Container: Instance?,
    Loaded: boolean,

    -- Only ever climbs, and is written into the pack. Handing a local id back
    -- out after its object is gone would make any reference still holding it --
    -- an undo entry, another object pointing here -- silently name a different
    -- object, which is the same reason property ids are never recycled.
    LastId: Handles.LocalId,

    -- The canonical instance, the one Load makes and Serialize describes. Nil
    -- while the scene is unloaded.
    Main: SceneInstance?,

    -- Extra live copies, keyed by their instance id.
    Instances: {[ObjectTypes.SceneInstanceId]: SceneInstance},

    -- The scene while it is unloaded. Loading rebuilds the objects from this
    -- and clears it; unloading writes it and destroys them.
    Data: buffer?,

    Create: (
        self: Scene,
        Reference: ObjectTypes.ObjectRegistry | ObjectTypes.ObjectIdentifier,
        InitialValues: {[number]: any}?
    ) -> ObjectTypes.Object?,

    Load: (self: Scene) -> boolean,
    Unload: (self: Scene) -> boolean,

    -- An extra live copy, on top of whatever Load made. Every object in it
    -- carries the persistent id its pack was written with, so five instances of
    -- one room are five sets of objects that agree on what they are and
    -- disagree on which they are.
    Instance: (self: Scene, Container: Instance?) -> SceneInstance?,

    -- The pack, for the caller to store however it likes. Answers for a loaded
    -- scene too, by serializing what is live rather than refusing.
    Serialize: (self: Scene) -> buffer,
    GetObjects: (self: Scene) -> {ObjectTypes.Object},
    Destroy: (self: Scene) -> (),
}

return true
