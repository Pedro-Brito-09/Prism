const Network = require("./Network")
const Logger = require("../Logger")
const Types = require("./Types")

export type PropertyType = Types.PropertyType
export type PropertyIdentifier = Types.PropertyIdentifier
export type PropertyRegistry<T> = Types.PropertyRegistry<T>
export type PropertyConfig<T> = Types.PropertyConfig<T>
export type Property<T> = Types.Property<T>

const Properties = {}
const Registered: {[PropertyIdentifier]: PropertyRegistry<any>} = {}

const function GetNextFreeId(): number
    local MinNextFree;
    for i, v in Registered do
        if (not MinNextFree or i < MinNextFree) and not Registered[i + 1] then
            MinNextFree = i
        end
    end

    return MinNextFree + 1 or 1
end

const function __setter<T>(self: Property<T>, Value: Types.ValueFor<T>?): boolean
    const Val = Types:FixValue(self.Type, Value, self.Constraints)
    if Val == nil then
        return false
    end

    self.Value = Val
    return true
end

const function __default_setter<T>(self: Property<T>, Value: Types.ValueFor<T>?): boolean
    const Val = Types:FixValue(self.Type, Value, self.Constraints)
    if Val == nil then
        return false
    end

    self.DefaultValue = Val
    return true
end

function Properties:Register<T>(Config: PropertyConfig<T>): PropertyIdentifier?
    if Config.CustomId then
        local Number = tonumber(Config.CustomId)
        if not Number then
            warn(`[CREATE UTILS] Custom property id needs to be an integer, got {Config.CustomId}. Will be using the next free id instead.`)
            Config.CustomId = nil
        elseif Number ~= math.floor(Number) then
            warn(`[CREATE UTILS] Custom property id needs to be an integer, got {Config.CustomId}. Will be using {math.floor(Number)} instead.`)
            Config.CustomId = math.floor(Number)
        end
    end

    const Identifier = Config.CustomId or GetNextFreeId()
    if Registered[Identifier] then
        warn(`[CREATE UTILS] There's already a property registered with id {Identifier}.`)
        return
    end

    const Constraints = Config.Constraints
    if Config.Type == "Number" and Constraints and Constraints.Precision then
        local Scale = 1
        while math.abs(Constraints.Precision * Scale - math.round(Constraints.Precision * Scale)) > 1e-9 do
            Scale *= 10
        end
        Constraints.Scale = Scale
    end

    const Prop = {}
    Prop.__type = "PropertyRegistry"
    Prop.Id = Identifier
    Prop.Name = Config.Name
    Prop.Type = Config.Type
    Prop.Constraints = Constraints
    Prop.DefaultValue = Config.DefaultValue

    Registered[Identifier] = Prop
    Network.PropertyRegistered:FireAll(Prop)
    return Identifier
end

function Properties:GetRegistered(): {[PropertyIdentifier]: PropertyRegistry<any>}
    return Registered
end

function Properties:GetRegistry(Identifier: PropertyIdentifier): PropertyRegistry<any>?
    return Registered[Identifier]
end

function Properties.new(Reference: PropertyRegistry<any> | PropertyIdentifier): Property<any>
    const TypeOf = typeof(Reference)
    local Ref: PropertyRegistry<any>
    if TypeOf == "number" then
        if not Registered[Reference :: PropertyIdentifier] then
            Logger:Error(`Invalid property reference.`)
        end

        Ref = Registered[Reference :: PropertyIdentifier]
    elseif TypeOf == "table" then
        Ref = Reference :: PropertyRegistry<any>
    else
        Logger:Error(`Invalid property reference.`)
    end

    if not Ref or not Ref.Id or not Registered[Ref.Id] then
        Logger:Error(`Invalid property reference.`)
    end

    const Prop = {}
    Prop.__type = "Property"
    Prop.Parent = Ref.Id
    Prop.Name = Ref.Name
    Prop.Type = Ref.Type
    Prop.DefaultValue = Ref.DefaultValue
    Prop.Value = Ref.DefaultValue
    Prop.Set = __setter
    Prop.SetDefault = __default_setter
    return Prop
end

return Properties