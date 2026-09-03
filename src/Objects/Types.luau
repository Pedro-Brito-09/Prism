const PropertyTypes = require("../Properties/Types")

export type ObjectIdentifier = number

export type InstanceLinkRegistry = {
    Property: PropertyTypes.PropertyIdentifier,
    Type: "Property" | "Attribute",
    Descendant: Instance?,
    Name: string,
}

export type InstanceLink = InstanceLinkRegistry & {
    OnChange: RBXScriptConnection?,
}

export type ObjectRegistry = {
    Id: ObjectIdentifier,
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    Instance: Instance?,
    Links: {InstanceLinkRegistry}?,
}

export type ObjectConfig = {
    CustomId: ObjectIdentifier?,
    Name: string,
    Properties: {PropertyTypes.PropertyIdentifier},

    Instance: Instance?,
    Links: {InstanceLink}?,
}

export type Object = {
    RuntimeId: number,
    Parent: ObjectIdentifier,
    Name: string,
    Properties: {[PropertyTypes.PropertyIdentifier]: PropertyTypes.Property},

    Instance: Instance?,
    Links: {InstanceLink}?,

    Set: (self: Object, Property: PropertyTypes.PropertyIdentifier | string, Value: any?) -> boolean,
    Get: (self: Object, Property: PropertyTypes.PropertyIdentifier | string) -> any?,
    Destroy: (self: Object) -> (),
}

return true