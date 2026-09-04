--!strict
const PropertyTypes = require("../Properties/Types")

export type ObjectIdentifier = number
export type RuntimeId = number

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

    -- Template only. Objects.new clones it; it must not live under game.
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
    Destroyed: boolean,

    Instance: Instance?,
    -- Keyed by property id, not an array: a link is looked up by the property
    -- it mirrors.
    Links: {[PropertyTypes.PropertyIdentifier]: InstanceLink}?,

    Set: (self: Object, Property: PropertyTypes.PropertyIdentifier | string, Value: any?) -> boolean,
    Get: (self: Object, Property: PropertyTypes.PropertyIdentifier | string) -> any?,
    Destroy: (self: Object) -> (),
}

return true
