--!strict
const PropertyTypes = require("../Properties/Types")
const Handles = require("../Handles")

export type ObjectIdentifier = number

-- Names one live object for this session only, and the only identity that ever
-- crosses the wire. Unique across the server while it exists; never saved.
export type RuntimeId = number

-- Names an object inside a pack, and survives the session. Deliberately not
-- unique among live objects: instancing a scene twice gives every copy the ids
-- its pack was written with. See Handles.
export type PersistentId = Handles.PersistentId
export type SceneIdentifier = Handles.SceneIdentifier

-- One live copy of a scene, for this session only.
export type SceneInstanceId = number

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

    -- Template only. Objects.new clones it and parents the clone into the copy
    -- the object belongs to, so put it somewhere that does not replicate or
    -- render on its own -- ServerStorage or ReplicatedStorage rather than
    -- Workspace.
    Instance: Instance?,
    Links: {InstanceLinkRegistry}?,
}

-- The half of a registry that cannot cross the wire, handed to a client that
-- owns scenes of its own.
--
-- A registry replicates as an id, a name and a property list. The template
-- instance is deliberately left behind -- it is an asset sitting in
-- ServerStorage, and shipping one per type to every client would be absurd --
-- and so are the links, which only mean anything beside a template. A client
-- building its own objects supplies both itself, once per object type.
export type LocalRegistry = {
    Instance: Instance?,
    Links: {InstanceLinkRegistry}?,
}

export type ObjectConfig = {
    CustomId: ObjectIdentifier?,
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    Instance: Instance?,
    Links: {InstanceLinkRegistry}?,
}

export type Object = {
    -- What to hold, look up and send. Two objects are the same object when
    -- their runtime ids match.
    RuntimeId: RuntimeId,

    -- What to write down. Scene and LocalId are the halves PersistentId is made
    -- of, kept alongside so reading one does not mean unpacking it, and so a
    -- printed persistent id -- a large opaque number -- can be made sense of.
    PersistentId: PersistentId,
    Scene: SceneIdentifier,
    LocalId: number,

    -- The live copy of the scene this object belongs to. Two objects can share
    -- a persistent id and differ here; that is what instancing a scene means.
    InstanceId: SceneInstanceId,

    Parent: ObjectIdentifier,
    Name: string,

    -- Client side only. True when the object belongs to a scene this client
    -- owns, which is what makes its edits apply on the spot: there is nobody to
    -- ask and nothing to roll back to. An editor reads it to know whether an
    -- edit it just made can still be refused.
    Local: boolean?,

    Properties: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>},

    -- Property name -> id, so a lookup by name costs what a lookup by id does.
    -- Built once from the registry's ordered property list.
    Names: {[string]: PropertyTypes.PropertyIdentifier},
    Destroyed: boolean,

    Instance: Instance?,

    -- Called by Destroy to drop the object from the scene copy holding it. A
    -- plain callback rather than a reference to the copy, because naming that
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
