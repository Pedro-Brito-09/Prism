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

-- Writes a value onto the instance a property drives. A link used to be an
-- OnChange listener: a link table, two closures and a listener array a
-- property, 431 bytes, and 330,259 of the 495,279 properties of a real
-- 34,918-object level drive a part -- about 140 MB of a client's 309. Two
-- fields on the property, the instance and the type's own link, do the same.
const function Drive(Link: Types.Drive, Inst: Instance, Value: any)
    if Link.Type == "Attribute" then
        Inst:SetAttribute(Link.Name, Value)
    else
        (Inst :: any)[Link.Name] = Value
    end
end

Shared.Drive = Drive

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

    -- First, so a listener reading the instance sees the value it was told of.
    -- Protected rather than spawned like a listener: a link was checked against
    -- the template when its type was registered, so this throwing is rare, and
    -- a thread a set is no price to pay for the case where it does not.
    const Drives = self.Drives
    if Drives then
        const Link = self.Link :: Types.Drive
        if not pcall(Drive, Link, Drives, Val) then
            Logger:Warn(`Failed to drive {self.Name} onto {Link.Name} of {Drives:GetFullName()}.`)
        end
    end

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

-- What every property of one registry has in common, read through __index:
-- its identity, its constraints, its default and the four methods. These were
-- fields on every property, eleven keys a table, and a real 34,918-object level
-- holds 495,279 properties -- 535 MB of Lua heap on the server, nearly all of
-- it property tables. Constraints is the registry's own table, which the client
-- fills in place when a custom enum it names is registered, so sharing it
-- shares that too.
--
-- The default is the registry's, which never changes once it is registered; a
-- property's own SetDefault writes a field of its own over it. It was a field
-- on every property, and a table's slots come in powers of two: a property
-- holding only its Value takes one slot, one holding two takes two.
--
-- Keyed by the registry table, weakly: a client replaces its registries
-- wholesale when they are replayed, and a type unregistered and registered
-- again under the same id is a different registry.
const Shapes: {[any]: any} = setmetatable({}, {__mode = "k"}) :: any

local __destroy: <T>(self: Property<T>) -> ()

const function ShapeOf(Ref: PropertyRegistry<any>): any
    local Shape = Shapes[Ref]
    if not Shape then
        Shape = {
            __index = {
                __type = "Property",
                Parent = Ref.Id,
                Name = Ref.Name,
                Type = Ref.Type,
                Constraints = Ref.Constraints,
                DefaultValue = Ref.DefaultValue,
                Set = __setter,
                SetDefault = __default_setter,
                OnChange = __on_change,
                Destroy = __destroy,
            },

            -- Shapes of this one with a link on top, by link. See Drive.
            Linked = setmetatable({}, {__mode = "k"}),
        }

        Shapes[Ref] = Shape
    end

    return Shape
end

-- A property driving an instance reads its link through its shape as well,
-- the base shape's fields with the link beside them, so the property itself
-- holds only its Value and the instance: two slots rather than the four that
-- Value, DefaultValue, Drives and Link took. One shape a registry and a link,
-- and a link is an object type's own entry, shared by every object of it.
const function LinkedShapeOf(Base: any, Link: Types.Drive): any
    local Shape = Base.Linked[Link]
    if not Shape then
        const Index = table.clone(Base.__index)
        Index.Link = Link
        Shape = {__index = Index, Base = Base}
        Base.Linked[Link] = Shape
    end

    return Shape
end

-- Has the property write every value it is set to onto Inst, through Link.
function Shared.Link(Prop: any, Link: Types.Drive, Inst: Instance)
    const Current = getmetatable(Prop)
    Prop.Drives = Inst
    setmetatable(Prop, LinkedShapeOf(Current.Base or Current, Link))
end

-- Stops it. Safe on a property that drives nothing.
function Shared.Unlink(Prop: any)
    Prop.Drives = nil

    const Base = getmetatable(Prop).Base
    if Base then
        setmetatable(Prop, Base)
    end
end

__destroy = function<T>(self: Property<T>)
    self.Listeners = nil
    Shared.Unlink(self)
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

    -- Only what can differ between two properties of one registry lives on the
    -- property.
    return setmetatable({
        Value = Ref.DefaultValue,
    }, ShapeOf(Ref)) :: any
end

return Shared
