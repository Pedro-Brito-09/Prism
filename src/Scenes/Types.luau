--!strict
const ObjectTypes = require("../Objects/Types")
const Handles = require("../Handles")

export type SceneIdentifier = Handles.SceneIdentifier
export type Handle = Handles.Handle

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

    Objects: {[Handle]: ObjectTypes.Object},

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

    -- The pack, for the caller to store however it likes. Answers for a loaded
    -- scene too, by serializing what is live rather than refusing.
    Serialize: (self: Scene) -> buffer,
    GetObjects: (self: Scene) -> {ObjectTypes.Object},
    Destroy: (self: Scene) -> (),
}

return true
