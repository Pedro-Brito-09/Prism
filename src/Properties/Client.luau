const Network = require("./Network")
const Types = require("./Types")

export type PropertyIdentifier = Types.PropertyIdentifier
export type PropertyRegistry = Types.PropertyRegistry

local Properties = {}
const Registered: {[PropertyIdentifier]: PropertyRegistry} = {}

function Properties:GetRegistered(): {[PropertyIdentifier]: PropertyRegistry}
    return Registered
end

function Properties:GetRegistry(Identifier: PropertyIdentifier): PropertyRegistry?
    return Registered[Identifier]
end

Network.PropertyRegistered:Connect(function(Prop)
    Properties[Prop.Id] = Prop
end)

return Properties