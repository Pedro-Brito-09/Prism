--!strict
const CustomEnum = require("../CustomEnum")
const Network = require("./Network")
const Shared = require("./Shared")
const Logger = require("../Logger")
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

-- Some properties as a panel lays them out, from the Display that came with
-- each registry. Usually an object type's list:
-- Properties:Layout(Objects:GetRegistry(object.Parent).Properties).
function Properties:Layout(Ids: {PropertyIdentifier}, IncludeHidden: boolean?): {Types.Section}
    return Shared.Layout(Registered, Ids, IncludeHidden)
end

-- The server sends a CustomEnum constraint as the enum's name, because the enum
-- table carries methods and a remote cannot serialize a function. Resolve it
-- back into the local registry so IsValid can compare against it.
const function Register(Payload: any)
    const Constraints = Payload.Constraints
    if Payload.Type == "CustomEnum" and Constraints and type(Constraints.CustomEnum) == "string" then
        const Resolved = CustomEnum:GetEnum(Constraints.CustomEnum)
        if not Resolved then
            Logger:Warn(`Property {Payload.Id} constrains to custom enum {Constraints.CustomEnum}, which is not registered on this client.`)
        end

        Constraints.CustomEnum = Resolved
    end

    Registered[Payload.Id] = Payload
end

Network.PropertyRegistered:Connect(Register)

Network.RegistriesReplayed:Connect(function(Payloads: {any})
    for _, Payload in Payloads do
        Register(Payload)
    end
end)

-- Gone on the server, which refuses while anything is built on it. Nothing
-- replicated here carries it, so dropping the registry is all there is to do.
Network.PropertyUnregistered:Connect(function(Identifier: PropertyIdentifier)
    Registered[Identifier] = nil
end)

return Properties
