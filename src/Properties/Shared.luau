--!strict
-- Property instances, shared by the server and the client.
--
-- This used to live in Server.luau, which meant the client had no Properties.new
-- at all -- and the compressor calls it while decompressing metadata, so any
-- client side decompression died on a nil call.
--
-- Change notification is deliberately not a signal object. Most properties in an
-- editor are never watched, and allocating a signal table plus a handler list for
-- every property on every object costs more than the feature is worth. Instead a
-- property carries a nil Listeners field until something actually calls OnChange,
-- and drops it again when the last listener disconnects.

const Logger = require("../Logger")
const Types = require("./Types")

export type PropertyIdentifier = Types.PropertyIdentifier
export type PropertyRegistry<T> = Types.PropertyRegistry<T>
export type Property<T> = Types.Property<T>

const Shared = {}

const function __setter<T>(self: Property<T>, Value: Types.ValueFor<T>?): (boolean, boolean)
    const Val = Types:FixValue(self.Type, Value, self.Constraints)
    if Val == nil then
        return false, false
    end

    if Val == self.Value then
        return true, false
    end

    self.Value = Val

    const Listeners = self.Listeners
    if Listeners then
        for _, Callback in table.clone(Listeners) do
            task.spawn(Callback, Val)
        end
    end

    return true, true
end

const function __default_setter<T>(self: Property<T>, Value: Types.ValueFor<T>?): (boolean, boolean)
    const Val = Types:FixValue(self.Type, Value, self.Constraints)
    if Val == nil then
        return false, false
    end

    if Val == self.DefaultValue then
        return true, false
    end

    self.DefaultValue = Val
    return true, true
end

const function __on_change<T>(self: Property<T>, Callback: (Value: Types.ValueFor<T>) -> ()): () -> ()
    if typeof(Callback) ~= "function" then
        Logger:Error(`Invalid callback. Tried watching {self.Name} with a {typeof(Callback)}.`)
    end

    local Listeners = self.Listeners
    if not Listeners then
        Listeners = {}
        self.Listeners = Listeners
    end

    table.insert(Listeners :: {any}, Callback)

    local Disconnected = false
    return function()
        if Disconnected then
            return
        end

        Disconnected = true

        const Current = self.Listeners
        if not Current then
            return
        end

        const Position = table.find(Current, Callback)
        if Position then
            table.remove(Current, Position)
        end

        if #Current == 0 then
            self.Listeners = nil
        end
    end
end

const function __destroy<T>(self: Property<T>)
    self.Listeners = nil
end

function Shared.new(
    Registry: {[PropertyIdentifier]: PropertyRegistry<any>},
    Reference: PropertyRegistry<any> | PropertyIdentifier
): Property<any>
    const TypeOf = typeof(Reference)
    local Ref: PropertyRegistry<any>

    if TypeOf == "number" then
        Ref = Registry[Reference :: PropertyIdentifier]
        if not Ref then
            Logger:Error(`Invalid property reference. No property registered with id {Reference}.`)
        end
    elseif TypeOf == "table" then
        Ref = Reference :: PropertyRegistry<any>
    else
        Logger:Error(`Invalid property reference. Expected a registry or an id, got {TypeOf}.`)
    end

    if not Ref or not Ref.Id or not Registry[Ref.Id] then
        Logger:Error("Invalid property reference. The registry it points at is not registered.")
    end

    const Prop = {}
    Prop.__type = "Property"
    Prop.Parent = Ref.Id
    Prop.Name = Ref.Name
    Prop.Type = Ref.Type
    Prop.Constraints = Ref.Constraints
    Prop.DefaultValue = Ref.DefaultValue
    Prop.Value = Ref.DefaultValue

    Prop.Set = __setter
    Prop.SetDefault = __default_setter
    Prop.OnChange = __on_change
    Prop.Destroy = __destroy
    return Prop :: any
end

return Shared
