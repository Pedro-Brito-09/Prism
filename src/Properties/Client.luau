--!strict
const Network = require("./Network")
const Shared = require("./Shared")
const Types = require("./Types")

export type PropertyType = Types.PropertyType
export type PropertyIdentifier = Types.PropertyIdentifier
export type PropertyRegistry<T> = Types.PropertyRegistry<T>
export type Property<T> = Types.Property<T>

const Properties = {}
const Registered: {[PropertyIdentifier]: PropertyRegistry<any>} = {}

function Properties:GetRegistered(): {[PropertyIdentifier]: PropertyRegistry<any>}
    return Registered
end

function Properties:GetRegistry(Identifier: PropertyIdentifier): PropertyRegistry<any>?
    return Registered[Identifier]
end

-- The client builds property instances too: the compressor needs them when it
-- decompresses metadata, and Objects/Client needs them to rebuild an object
-- from the buffer the server sends.
function Properties.new(Reference: PropertyRegistry<any> | PropertyIdentifier): Property<any>
    return Shared.new(Registered, Reference)
end

Network.PropertyRegistered:Connect(function(Prop: PropertyRegistry<any>)
    Registered[Prop.Id] = Prop
end)

return Properties
