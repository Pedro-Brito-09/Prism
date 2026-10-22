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

    -- By value, not identity: a Table set to an equal list is no change, and
    -- keeps the list it already held.
    if Types:Equals(self.Type :: any, Val, self.Value) then
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

    if Types:Equals(self.Type :: any, Val, self.DefaultValue) then
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

--=============================================================================
-- Display
--=============================================================================

const DEFAULT_DISPLAY: Types.Display = {
    Category = "General",
    Order = 0,
    Description = nil,
    Hidden = false,
    ReadOnly = false,
}

-- Every field filled in, and a field of the wrong type dropped to its default
-- with a warning rather than handed to a panel that would draw it wrong.
function Shared.Display(Config: any, Name: string): Types.Display
    if Config ~= nil and type(Config) ~= "table" then
        Logger:Warn(`Property {Name} has a Display that is a {type(Config)}, not a table. Ignored.`)
        Config = nil
    end

    const Given = Config or {}

    const function Field(Key: string, Kind: string, Default: any): any
        const Value = Given[Key]
        if Value == nil then
            return Default
        end

        if type(Value) ~= Kind then
            Logger:Warn(`Property {Name} has Display.{Key} of type {type(Value)}, expected {Kind}. Ignored.`)
            return Default
        end

        return Value
    end

    return {
        Category = Field("Category", "string", DEFAULT_DISPLAY.Category),
        Order = Field("Order", "number", DEFAULT_DISPLAY.Order),
        Description = Field("Description", "string", nil),
        Hidden = Field("Hidden", "boolean", DEFAULT_DISPLAY.Hidden),
        ReadOnly = Field("ReadOnly", "boolean", DEFAULT_DISPLAY.ReadOnly),
    }
end

-- Some properties -- usually an object type's list -- as a panel lays them
-- out: grouped by category, each group sorted by Order, ties kept in the order
-- they were named. Categories come in the order their first property does, so
-- the lowest Order anywhere in a category puts it first. Hidden properties are
-- left out unless asked for, and ids nothing is registered under are skipped.
function Shared.Layout(
    Registry: {[PropertyIdentifier]: PropertyRegistry<any>},
    Ids: {PropertyIdentifier},
    IncludeHidden: boolean?
): {Types.Section}
    const Entries: {{Ref: PropertyRegistry<any>, Display: Types.Display, Index: number}} = {}

    for Index, Id in Ids do
        const Ref = Registry[Id]
        if not Ref then
            continue
        end

        const Display = Ref.Display or DEFAULT_DISPLAY
        if Display.Hidden and not IncludeHidden then
            continue
        end

        table.insert(Entries, {Ref = Ref, Display = Display, Index = Index})
    end

    table.sort(Entries, function(A, B)
        if A.Display.Order ~= B.Display.Order then
            return A.Display.Order < B.Display.Order
        end

        return A.Index < B.Index
    end)

    const Sections: {Types.Section} = {}
    const ByCategory: {[string]: Types.Section} = {}

    for _, Entry in Entries do
        const Category = Entry.Display.Category
        local Section = ByCategory[Category]
        if not Section then
            Section = {Category = Category, Properties = {}}
            ByCategory[Category] = Section
            table.insert(Sections, Section)
        end

        table.insert(Section.Properties, Entry.Ref)
    end

    return Sections
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
