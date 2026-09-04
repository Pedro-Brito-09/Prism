--!strict
const Network = require("./Network")
const Shared = require("./Shared")
const IdPool = require("../IdPool")
const Logger = require("../Logger")
const Types = require("./Types")

export type PropertyType = Types.PropertyType
export type PropertyIdentifier = Types.PropertyIdentifier
export type PropertyRegistry<T> = Types.PropertyRegistry<T>
export type PropertyConfig<T> = Types.PropertyConfig<T>
export type Property<T> = Types.Property<T>

-- Text lengths are varints now, so there is no format ceiling worth naming.
-- What actually binds is the DataStore value limit, and a single 1MB string
-- would swallow a third of a shard, so this caps it well below that.
const MAX_TEXT_LENGTH = 1048576

const Properties = {}
const Registered: {[PropertyIdentifier]: PropertyRegistry<any>} = {}
-- Never recycled: property ids are written into saved metadata, and reusing one
-- for a different property silently reinterprets every record still holding it.
const Ids = IdPool.new(nil, false)

function Properties:Register<T>(Config: PropertyConfig<T>): PropertyIdentifier?
    const Requested = if Config.CustomId ~= nil
        then IdPool.Normalize(Config.CustomId, "property")
        else nil

    const Identifier = Ids:Claim(Requested)
    if not Identifier then
        Logger:Warn(`There's already a property registered with id {Requested}.`)
        return
    end

    const Constraints = Config.Constraints
    if Constraints then
        if Config.Type == "Number" and Constraints.Precision then
            local Scale = 1
            while math.abs(Constraints.Precision * Scale - math.round(Constraints.Precision * Scale)) > 1e-9 do
                Scale *= 10
            end

            Constraints.Scale = Scale
        end

        if Config.Type == "Text" and Constraints.MaxLength then
            Constraints.MaxLength = math.min(Constraints.MaxLength, MAX_TEXT_LENGTH)
        end
    end

    const Prop = {}
    Prop.__type = "PropertyRegistry"
    Prop.Id = Identifier
    Prop.Name = Config.Name
    Prop.Type = Config.Type
    Prop.Constraints = Constraints
    Prop.DefaultValue = Config.DefaultValue

    Registered[Identifier] = Prop :: any
    Network.PropertyRegistered:FireAll(Prop)
    return Identifier
end

function Properties:Unregister(Identifier: PropertyIdentifier): boolean
    if not Registered[Identifier] then
        return false
    end

    Registered[Identifier] = nil
    Ids:Release(Identifier)
    return true
end

function Properties:GetRegistered(): {[PropertyIdentifier]: PropertyRegistry<any>}
    return Registered
end

function Properties:GetRegistry(Identifier: PropertyIdentifier): PropertyRegistry<any>?
    return Registered[Identifier]
end

function Properties.new(Reference: PropertyRegistry<any> | PropertyIdentifier): Property<any>
    return Shared.new(Registered, Reference)
end

return Properties
