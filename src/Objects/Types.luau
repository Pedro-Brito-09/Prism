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

-- How far an object's data goes, named for the two audiences a scene has:
-- every player, all of whom are shown the copies of every scene the server
-- built, and the players the scene admits.
export type Reach = "Everyone" | "Admitted"

export type InstanceLinkRegistry = {
    Property: PropertyTypes.PropertyIdentifier,
    Type: "Property" | "Attribute",
    Descendant: string?,
    Name: string,
}

export type ObjectRegistry = {
    Id: ObjectIdentifier,
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    -- Template only. Objects.new clones it and parents the clone into the copy
    -- the object belongs to, so put it somewhere that does not render on its
    -- own. ReplicatedStorage if a client will ever build these objects itself
    -- -- the registry replicates with this reference, and it resolves only on
    -- a client the instance replicates to -- or ServerStorage if only the
    -- server ever will.
    Instance: Instance?,
    Links: {InstanceLinkRegistry}?,

    -- Who is sent the data of this type's objects: every player, or only the
    -- ones the scene holding the object admits. Whole objects either way --
    -- nothing withholds some of an object's properties and sends the rest.
    -- The part is another matter: one the server built replicates to everybody
    -- whatever this says.
    Replicate: Reach,

    -- Client side only: whether the server's registry has a template, which
    -- tells a nil Instance above apart from one that did not replicate here.
    HasTemplate: boolean?,
}

export type ObjectConfig = {
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    Instance: Instance?,
    Links: {InstanceLinkRegistry}?,

    -- Everyone when left out.
    Replicate: Reach?,
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

    Registry: ObjectIdentifier,
    Name: string,

    -- Destroyed, but kept whole so the destroy can be taken back. Set while
    -- something -- a history step, on either side -- is holding the object
    -- against an undo. It is out of the world by every measure a caller can
    -- see: Destroyed is true, it is gone from the workspace and from its copy,
    -- its part is gone and every client has been told. What survives is the
    -- table, the property values and both ids, which is what lets it come back
    -- as itself rather than as a new object holding the same numbers.
    Suspended: boolean?,

    -- Client side only. True when the object belongs to a scene this client
    -- owns, which is what makes its edits apply on the spot: there is nobody to
    -- ask and nothing to roll back to. An editor reads it to know whether an
    -- edit it just made can still be refused.
    Local: boolean?,

    -- Client side only. True when this client built the object's instance
    -- itself because the server opened the copy holding it rather than loading
    -- it. The instance is this client's, then, and goes when the object does.
    Drawn: boolean?,

    Properties: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>},

    -- Values the object was saved with that its type no longer lists, or that
    -- this build cannot read, as their tagged bytes by property id. Never read
    -- or replicated; written back when the object is saved, so taking a
    -- property off a type and saving does not erase every value it held. See
    -- Compressor's DecompressedObject.
    Unknown: {[PropertyTypes.PropertyIdentifier]: buffer}?,

    -- Property name -> id, so a lookup by name costs what a lookup by id does.
    -- Built once from the registry's ordered property list.
    Names: {[string]: PropertyTypes.PropertyIdentifier},
    Destroyed: boolean,

    Instance: Instance?,

    -- Called by Destroy to drop the object from the scene copy holding it. A
    -- plain callback rather than a reference to the copy, because naming that
    -- type here would put Objects and Scenes in a require cycle.
    Release: (() -> ())?,

    -- The type's own links, when the object drives anything through them. Each
    -- linked property holds its instance and its entry; see BuildLinks.
    Links: {InstanceLinkRegistry}?,

    -- ClientSided is the client's, and ignored on the server: shown here, sent
    -- nowhere, until a set without it ends the preview. See Objects/Client.
    Set: (self: Object, Property: PropertyReference, Value: any?, ClientSided: boolean?) -> boolean,
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
