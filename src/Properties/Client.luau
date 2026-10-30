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
-- Properties:Layout(Objects:GetRegistry(object.Registry).Properties).
function Properties:Layout(Ids: {PropertyIdentifier}, IncludeHidden: boolean?): {Types.Section}
    return Shared.Layout(Registered, Ids, IncludeHidden)
end

-- The server sends a CustomEnum constraint as the enum's name, because the enum
-- table carries methods and a remote cannot serialize a function. Resolve it
-- back into the local registry so IsValid can compare against it.
--
-- An enum this client has not registered yet is waited for rather than given
-- up on: a game may register its enums after requiring Prism, and the
-- registries can arrive first. Until then the constraint is a placeholder
-- carrying only the enum's name, which accepts the pending options the server's
-- values decode to -- name and id, no Value -- so the client holds what the
-- server holds rather than the default. A nil constraint used to stand in, and
-- refused them all. Property instances share their registry's Constraints
-- table, so resolving it later reaches every object already holding the
-- property, and Objects swaps the pending values for the real options.
const Waiting: {[string]: {any}} = {}

const function Placeholder(Name: string): any
    return {
        __type = "CustomEnum",
        Name = Name,
        Options = {},
        ById = {},
        Pending = true,

        GetById = function()
            return nil
        end,

        GetByValue = function()
            return nil
        end,
    }
end

const function Register(Payload: any)
    -- Where the enum's name sits: on the constraints of a CustomEnum, on the
    -- item constraints of a Table of them.
    local Constraints = Payload.Constraints
    if Payload.Type == "Table" and Constraints then
        Constraints = if Constraints.Of == "CustomEnum" then Constraints.Item else nil
    elseif Payload.Type ~= "CustomEnum" then
        Constraints = nil
    end

    -- Frozen on the server, but a remote hands over a copy, and every property
    -- built from this registry starts out holding this table.
    if Payload.Type == "Table" and type(Payload.DefaultValue) == "table" and not table.isfrozen(Payload.DefaultValue) then
        table.freeze(Payload.DefaultValue)
    end

    -- The Enum the server sent by name, back to the Enum itself. Without this
    -- the field is nil here and `EnumType ~= Constraints.Enum` is true of every
    -- value, so the client refused them all before anything was sent.
    const Own = Payload.Constraints
    if Payload.Type == "Enum" and Own and type(Own.Enum) == "string" then
        const Named = Own.Enum
        const Resolved = (Enum :: any)[Named]
        if Resolved then
            Own.Enum = Resolved
        else
            Logger:Warn(`Property {Payload.Id} constrains to Enum.{Named}, which this client does not know. Its values will be refused.`)
            Own.Enum = nil
        end
    end

    if Constraints and type(Constraints.CustomEnum) == "string" then
        const Name = Constraints.CustomEnum
        const Resolved = CustomEnum:GetEnum(Name)
        if not Resolved then
            Logger:Warn(`Property {Payload.Id} constrains to custom enum {Name}, which is not registered on this client yet. Its values read with no Value until it is.`)

            local List = Waiting[Name]
            if not List then
                List = {}
                Waiting[Name] = List
            end

            table.insert(List, Constraints)
        end

        Constraints.CustomEnum = Resolved or Placeholder(Name)
    end

    Registered[Payload.Id] = Payload
end

CustomEnum:OnRegistered(function(Enum)
    const List = Waiting[Enum.Name]
    if not List then
        return
    end

    Waiting[Enum.Name] = nil
    for _, Constraints in List do
        Constraints.CustomEnum = Enum
    end
end)

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
