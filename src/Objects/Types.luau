--!strict
const PropertyTypes = require("../Properties/Types")

export type ObjectIdentifier = number
export type RuntimeId = number

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
    RuntimeId: RuntimeId,
    Parent: ObjectIdentifier,
    Name: string,
    Properties: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property<any>},

    -- Property name -> id, so a lookup by name costs what a lookup by id does.
    -- Built once from the registry's ordered property list.
    Names: {[string]: PropertyTypes.PropertyIdentifier},
    Destroyed: boolean,

    Instance: Instance?,
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
