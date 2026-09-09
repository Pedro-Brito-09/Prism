--!strict
const PropertyTypes = require("../Properties/Types")
const Handles = require("../Handles")

export type ObjectIdentifier = number

-- The object's own identity, scene included. See Handles: it replaced a per
-- session counter, so a reference kept across an unload still names the same
-- object when the scene comes back.
export type Handle = Handles.Handle
export type SceneIdentifier = Handles.SceneIdentifier

-- Every lookup on an object takes either the property's id or its name.
export type PropertyReference = PropertyTypes.PropertyIdentifier | string

export type InstanceLinkRegistry = {
    Property: PropertyTypes.PropertyIdentifier,
    Type: "Property" | "Attribute",
    Descendant: string?,
    Name: string,
}

export type InstanceLink = InstanceLinkRegistry & {
    -- The disconnect function returned by Property:OnChange, not an
    -- RBXScriptConnection. The old code called :Destroy() on this, which is not
    -- a member of RBXScriptConnection and threw during cleanup.
    Disconnect: (() -> ())?,
}

export type ObjectRegistry = {
    Id: ObjectIdentifier,
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    -- Template only. Objects.new clones it and parents the clone to Container,
    -- so put it somewhere that does not replicate or render on its own --
    -- ServerStorage or ReplicatedStorage rather than Workspace.
    Instance: Instance?,
    Container: Instance?,
    Links: {InstanceLinkRegistry}?,
}

export type ObjectConfig = {
    CustomId: ObjectIdentifier?,
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    Instance: Instance?,
    Container: Instance?,
    Links: {InstanceLinkRegistry}?,
}

export type Object = {
    -- Id is the whole handle and the only thing anything else should pass
    -- around. Scene and LocalId are the two halves it is made of, kept here so
    -- reading one does not mean unpacking it, and so a printed handle -- which
    -- is a large opaque number -- can be made sense of.
    Id: Handle,
    Scene: SceneIdentifier,
    LocalId: number,

    Parent: ObjectIdentifier,
    Name: string,
    Properties: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>},

    -- Property name -> id, so a lookup by name costs what a lookup by id does.
    -- Built once from the registry's ordered property list.
    Names: {[string]: PropertyTypes.PropertyIdentifier},
    Destroyed: boolean,

    Instance: Instance?,

    -- Called by Destroy to drop the object from the scene holding it. A plain
    -- callback rather than a reference to the scene, because naming the scene
    -- type here would put Objects and Scenes in a require cycle.
    Release: (() -> ())?,

    -- Keyed by property id, not an array: a link is looked up by the property
    -- it mirrors.
    Links: {[PropertyTypes.PropertyIdentifier]: InstanceLink}?,

    Set: (self: Object, Property: PropertyReference, Value: any?) -> boolean,
    Get: (self: Object, Property: PropertyReference) -> any?,

    -- The property instance itself, for the parts of it Get and Set do not
    -- cover: SetDefault, Constraints, DefaultValue. Indexing Properties by hand
    -- works too, but only by id.
    GetProperty: (self: Object, Property: PropertyReference) -> PropertyTypes.Property<any>?,

    -- Returns the disconnect function from Property:OnChange. An unknown
    -- reference warns and returns a disconnect that does nothing.
    OnChange: (self: Object, Property: PropertyReference, Callback: (Value: any) -> ()) -> () -> (),
    Destroy: (self: Object) -> (),
}

return true
