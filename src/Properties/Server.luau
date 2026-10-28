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

-- A CustomEnum constraint holds the enum table itself, and that table carries
-- GetById and GetByValue as function fields. A remote cannot serialize a
-- function, so firing the registry raw threw for every CustomEnum property and
-- no client ever received it. Only the enum's name crosses the wire; the client
-- resolves it against its own registry, which is why custom enums have to be
-- registered from shared code rather than server-only code.
--
-- A Table of CustomEnum carries the same enum one level down, in its item
-- constraints, and crosses the same way.
const function ToRegistryPayload(Registry: PropertyRegistry<any>): any
    const Constraints = (Registry :: any).Constraints
    if not Constraints then
        return Registry
    end

    local Copy

    if Registry.Type == "CustomEnum" then
        Copy = table.clone(Constraints)
        Copy.CustomEnum = if Constraints.CustomEnum then Constraints.CustomEnum.Name else nil
    elseif Registry.Type == "Table" and Constraints.Of == "CustomEnum" and Constraints.Item then
        const Item: any = table.clone(Constraints.Item)
        Item.CustomEnum = if Item.CustomEnum then Item.CustomEnum.Name else nil

        Copy = table.clone(Constraints)
        Copy.Item = Item
    else
        return Registry
    end

    return {
        __type = "PropertyRegistry",
        Id = Registry.Id,
        Name = Registry.Name,
        Type = Registry.Type,
        Constraints = Copy,
        DefaultValue = Registry.DefaultValue,
        Display = Registry.Display,
    }
end

-- Never recycled: property ids are written into saved metadata, and reusing one
-- for a different property silently reinterprets every record still holding it.
const Ids = IdPool.new(nil, false)

-- How many things are built on each property: object types that carry it and
-- databases whose metadata holds it. Counted here rather than asked of them,
-- because Properties cannot require either without a cycle.
const Holders: {[PropertyIdentifier]: number} = {}

function Properties.Retain(Identifier: PropertyIdentifier)
    Holders[Identifier] = (Holders[Identifier] or 0) + 1
end

function Properties.Unretain(Identifier: PropertyIdentifier)
    const Count = (Holders[Identifier] or 0) - 1
    Holders[Identifier] = if Count > 0 then Count else nil
end

-- Fills in what the constraints derive, in place. A Table's item constraints
-- are a property's constraints one level down, so they get the same treatment.
const function Prepare(Type: any, Constraints: any)
    if Type == "Number" and Constraints.Precision then
        local Scale = 1
        while math.abs(Constraints.Precision * Scale - math.round(Constraints.Precision * Scale)) > 1e-9 do
            Scale *= 10
        end

        Constraints.Scale = Scale
    end

    if Type == "Text" and Constraints.MaxLength then
        Constraints.MaxLength = math.min(Constraints.MaxLength, MAX_TEXT_LENGTH)
    end

    if Type == "Table" then
        Constraints.MaxItems = math.min(Constraints.MaxItems or Types.MAX_TABLE_ITEMS, Types.MAX_TABLE_ITEMS)

        if Constraints.Item then
            Prepare(Constraints.Of, Constraints.Item)
        end
    end
end

function Properties:Register<T>(Config: PropertyConfig<T>): PropertyIdentifier?
    const Constraints = Config.Constraints :: any
    local Default: any = Config.DefaultValue

    -- Settled before an id is claimed, because ids are never handed out twice
    -- and a refused registration would burn one.
    if Config.Type == "Table" then
        if not Constraints or not Types.IsItemType(Constraints.Of) then
            Logger:Warn(`Property {Config.Name} is a Table, which needs Constraints.Of naming the type of its items -- any property type but Table.`)
            return nil
        end

        if Constraints.Item ~= nil and type(Constraints.Item) ~= "table" then
            Logger:Warn(`Property {Config.Name} has Constraints.Item of type {type(Constraints.Item)}, not a table.`)
            return nil
        end

        Prepare(Config.Type, Constraints)

        -- Fixed and frozen like any value it will hold, because every property
        -- built from the registry starts out holding this very table.
        Default = Types:FixValue("Table", Default or {}, Constraints)
        if Default == nil then
            Logger:Warn(`Property {Config.Name} has a DefaultValue that is not a list its constraints accept.`)
            return nil
        end
    elseif Constraints then
        Prepare(Config.Type, Constraints)
    end

    const Identifier = Ids:Claim()
    if not Identifier then
        Logger:Warn("The property id pool is exhausted.")
        return nil
    end

    const Prop = {}
    Prop.__type = "PropertyRegistry"
    Prop.Id = Identifier
    Prop.Name = Config.Name
    Prop.Type = Config.Type
    Prop.Constraints = Constraints
    Prop.DefaultValue = Default

    -- On the registry, which already replicates, so a client builds the same
    -- panel from the same metadata without being told anything extra.
    Prop.Display = Shared.Display(Config.Display, Config.Name)

    Registered[Identifier] = Prop :: any
    Network.PropertyRegistered:FireAll(ToRegistryPayload(Prop :: any))
    return Identifier
end

-- Refused while anything is built on the property. An object type carrying it
-- would name a property nobody could build, on the server or on the client
-- rebuilding one of its objects; a database would fail to read its own records.
-- Unregister those first.
function Properties:Unregister(Identifier: PropertyIdentifier): boolean
    const Registry = Registered[Identifier]
    if not Registry then
        return false
    end

    const Held = Holders[Identifier]
    if Held then
        Logger:Warn(`Cannot unregister property {Registry.Name}: {Held} object type(s) or database(s) are built on it.`)
        return false
    end

    Registered[Identifier] = nil
    Ids:Release(Identifier)

    -- Told to every client, which used to keep serving the registry it had for
    -- the rest of the session.
    Network.PropertyUnregistered:FireAll(Identifier)
    return true
end

function Properties:GetRegistered(): {[PropertyIdentifier]: PropertyRegistry<any>}
    return Registered
end

function Properties:GetRegistry(Identifier: PropertyIdentifier): PropertyRegistry<any>?
    return Registered[Identifier]
end

-- What Replication sends to a joining player. Same shape Register broadcasts.
function Properties:GetRegistryPayload(Identifier: PropertyIdentifier): any
    const Registry = Registered[Identifier]
    return if Registry then ToRegistryPayload(Registry) else nil
end

function Properties.new(Reference: PropertyRegistry<any> | PropertyIdentifier): Property<any>
    return Shared.new(Registered, Reference)
end

-- Some properties as a panel lays them out. See Shared.Layout.
function Properties:Layout(Ids: {PropertyIdentifier}, IncludeHidden: boolean?): {Types.Section}
    return Shared.Layout(Registered, Ids, IncludeHidden)
end

return Properties
