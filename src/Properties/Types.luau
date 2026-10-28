const CustomEnum = require("../CustomEnum")
const Handles = require("../Handles")
const Codecs = require("../Codecs")

export type PropertyType = "Text" | "Number" | "Bool" | "Color" | "Vector" | "CFrame" | "Enum" | "CustomEnum" | "Object" | "Table"
export type PropertyIdentifier = number

export type TextConstraints = {
    MinLength: number?,
    MaxLength: number?
}

export type NumberConstraints = {
    MinValue: number?,
    MaxValue: number?,
    Precision: number?,
    Scale: number?,
    AllowDecimals: boolean?,
}

export type ColorConstraints = {
    R: NumberConstraints?,
    G: NumberConstraints?,
    B: NumberConstraints?
}

export type VectorConstraints = {
    X: NumberConstraints?,
    Y: NumberConstraints?,
    Z: NumberConstraints?
}

-- The list is optional, not its entries. Declaring {EnumItem? | string?} made
-- the list itself mandatory, so constraining an enum to nothing more than its
-- type did not typecheck -- and supplying an empty list to satisfy that rejects
-- every value, because IsValid treats a present whitelist as exhaustive.
export type EnumConstraints = {
    Enum: Enum,
    Whitelist: {EnumItem | string}?,
    Blacklist: {EnumItem | string}?,
}

export type CustomEnumConstraints = {
    CustomEnum: CustomEnum.CustomEnum<any>,
    Whitelist: {CustomEnum.RegisteredOption<any> | CustomEnum.OptionId}?,
    Blacklist: {CustomEnum.RegisteredOption<any> | CustomEnum.OptionId}?,
}

-- What an Object property may point at, by object type id or registered name.
-- Unlike every other constraint here, this one cannot be checked from the value
-- alone: the value is a local id, and what it names depends on which copy is
-- asking. Objects/Shared.Reference is where it is enforced, against the copy
-- holding the object being written. IsValid checks the number and nothing more.
export type ObjectConstraints = {
    Types: {number | string}?,
}

-- A list of values that are all one other property type: Of names it, and Item
-- holds that type's constraints, which every item is checked against exactly as
-- a property of that type would be. Not nestable -- a Table of Tables has no
-- item constraint that could say what it means.
--
-- Mandatory, unlike every other constraint here: without Of there is nothing to
-- check an item against and nothing to tell a Number from an Object reference,
-- both of which are Luau numbers.
--
-- MinItems refuses a shorter list, as MinLength refuses shorter text; MaxItems
-- cuts a longer one, as MaxLength does. Registration caps MaxItems, and sets it
-- when left out, so no list is unbounded.
export type TableConstraints = {
    Of: PropertyType,
    Item: any?,
    MinItems: number?,
    MaxItems: number?,
}

type PropertyValues = {
    Text: string,
    Number: number,
    Bool: boolean,
    Color: Color3,
    Vector: Vector3,
    CFrame: CFrame,
    Enum: EnumItem,
    CustomEnum: CustomEnum.RegisteredOption<any>,

    -- The target's local id, not the object. See Objects/Shared.
    Object: number,

    -- Frozen. A list changed in place would never pass through Set, so nothing
    -- -- undo, replication, listeners -- would hear that it had changed.
    Table: {any},
}

type PropertyConstraints = {
    Text: TextConstraints,
    Number: NumberConstraints,
    Bool: nil,
    Color: ColorConstraints,
    Vector: VectorConstraints,
    CFrame: nil,
    Enum: EnumConstraints,
    CustomEnum: CustomEnumConstraints,
    Object: ObjectConstraints,
    Table: TableConstraints,
}

type function GetFromMap(Map, Key)
    if not Map:is("table") or not Key:is("singleton") then
        return types.never
    end

    local Property = Map:readproperty(Key)
    if Property then
        return Property
    end

    return types.never
end

export type ValueFor<T> = GetFromMap<PropertyValues, T>
export type ConstraintsFor<T> = GetFromMap<PropertyConstraints, T>

-- How a property presents itself in an editor: enough for a property panel to
-- be generated from the registry rather than written per property. Presentation
-- only. ReadOnly greys a field out; it does not stop a write, which is what a
-- property blacklist in Permissions is for.
export type DisplayConfig = {
    Category: string?,
    Order: number?,
    Description: string?,
    Hidden: boolean?,
    ReadOnly: boolean?,
}

-- The same, with every default filled in at registration.
export type Display = {
    -- "General" when left out.
    Category: string,

    -- Lower comes first; ties keep the order the object type lists them in.
    Order: number,

    Description: string?,
    Hidden: boolean,
    ReadOnly: boolean,
}

export type PropertyRegistry<T = PropertyType> = {
    Id: PropertyIdentifier,
    Name: string,
    Type: T,
    Constraints: ConstraintsFor<T>,
    DefaultValue: ValueFor<T>,
    Display: Display,
}

export type PropertyConfig<T = PropertyType> = {
    Name: string,
    Type: T,
    Constraints: ConstraintsFor<T>?,
    DefaultValue: ValueFor<T>,
    Display: DisplayConfig?,
}

-- One category of a laid out panel, its properties in display order.
export type Section = {
    Category: string,
    Properties: {PropertyRegistry<any>},
}

-- Value, DefaultValue and Listeners are the property's own. Everything else is
-- read through a metatable shared by every property of the same registry, so it
-- reads the same but is not there to iterate, clone or send over a remote.
-- What a property needs of an instance link to drive its instance. An object
-- type's link entry is one; Properties cannot name that type without requiring
-- Objects.
export type Drive = {
    Type: "Property" | "Attribute",
    Name: string,
}

export type Property<T = PropertyType> = {
    Parent: PropertyIdentifier,
    Name: string,
    Type: T,
    Constraints: ConstraintsFor<T>,
    DefaultValue: ValueFor<T>,
    Value: ValueFor<T>,

    -- Allocated on the first OnChange call and dropped again when the last
    -- listener disconnects, so a property nobody watches costs one nil field.
    Listeners: {(Value: ValueFor<T>) -> ()}?,

    -- The instance this property drives and the link it drives it through, the
    -- object type's own entry, shared by every object of the type. Set by the
    -- object that wires it, and written straight from Set rather than through
    -- a listener; see Properties/Shared.
    Drives: Instance?,
    Link: Drive?,

    -- Returns (Accepted, Changed). Accepted is false when the value failed
    -- validation; Changed is false when it was accepted but equal to the
    -- current one, which lets callers skip a pointless replication broadcast.
    Set: (self: Property<T>, Value: ValueFor<T>?) -> (boolean, boolean),
    SetDefault: (self: Property<T>, Value: ValueFor<T>?) -> (boolean, boolean),
    OnChange: (self: Property<T>, Callback: (Value: ValueFor<T>) -> ()) -> () -> (),
    Destroy: (self: Property<T>) -> (),
}

const Types = {}
Types.Map = {
    Text = "string",
    Number = "number",
    Bool = "boolean",
    Color = "Color3",
    Vector = "Vector3",
    CFrame = "CFrame",
    Enum = "EnumItem",
    CustomEnum = "table",
    Object = "number",
    Table = "table",
}

Types.Ids = {
    Text = 0,
    Number = 1,
    Bool = 2,
    Color = 3,
    Vector = 4,
    CFrame = 5,
    Enum = 6,
    CustomEnum = 7,
    Object = 8,
    Table = 9,
}

-- Hard ceiling on a list, and what MaxItems becomes when left out. Every item is
-- validated on every set and sent whole on every change, so this is about the
-- cost of one packet rather than what the format can write.
Types.MAX_TABLE_ITEMS = 4096

const F32_MAX = 3.4028235e+38

-- An array and nothing else: every key a whole number from 1 to its length, so
-- no holes and no fields. A dictionary passed as a list would be written in an
-- order nobody chose and read back as something else.
const function IsList(Value: {[any]: any}): boolean
    const Length = #Value
    local Keys = 0

    for Key in Value do
        if type(Key) ~= "number" or Key < 1 or Key > Length or Key % 1 ~= 0 then
            return false
        end

        Keys += 1
    end

    return Keys == Length
end

-- What a Table may hold: any type but itself.
function Types.IsItemType(Of: any): boolean
    return type(Of) == "string" and Of ~= "Table" and (Types.Ids :: any)[Of] ~= nil
end

-- Whether a property holds references, alone or as a list of them. Takes a
-- property or a registry: both carry Type and Constraints.
function Types.HoldsReferences(Prop: any): boolean
    if Prop.Type == "Object" then
        return true
    end

    return Prop.Type == "Table" and Prop.Constraints ~= nil and Prop.Constraints.Of == "Object"
end

const function FixNumber(Value: ValueFor<"Number">, Constraints: ConstraintsFor<"Number">)
    if Constraints.Precision and Constraints.Scale then
        const IntMin = math.round((Constraints.MinValue or 0) * Constraints.Scale)
        const IntPrecision = math.round(Constraints.Precision * Constraints.Scale)
        const IntValue = math.round(Value * Constraints.Scale)
        const Steps = math.round((IntValue - IntMin) / IntPrecision)
        Value = (IntMin + Steps * IntPrecision) / Constraints.Scale
    end

    if Constraints.AllowDecimals == false then
        Value = math.round(Value)
    end

    if Constraints.MinValue then
        Value = math.max(Value, Constraints.MinValue)
    end

    if Constraints.MaxValue then
        Value = math.min(Value, Constraints.MaxValue)
    end

    return Value
end

function Types:IsValid<T>(Type: T, Value: ValueFor<T>?, Constraints: ConstraintsFor<T>?): boolean
    const TypeOf = typeof(Value)
    if TypeOf ~= Types.Map[Type] then
        return false
    end

    if Type == "CustomEnum" and (Value :: any).__type ~= "CustomEnumOption" then
        return false
    end

    -- A reference is a local id, so the same bounds a local id has. Whole,
    -- because it indexes a scene's object table; zero, because a reference
    -- pointing at nothing still has to be a number the format can write.
    --
    -- Whether the id names anything, and whether what it names is an allowed
    -- type, is not decided here: both need the copy holding the object, and a
    -- property does not know which object carries it. An id naming nothing is
    -- valid in any case -- a pack restores its objects one at a time, so a
    -- button is read back before the door it points at exists.
    if Type == "Object" then
        const TypedValue = (Value :: any) :: number
        return TypedValue >= 0
            and TypedValue <= Handles.MAX_LOCAL
            and TypedValue % 1 == 0
    end

    -- Every item as a property of the item type would be. Object items are
    -- held to the bounds an Object property is, and like one, whether each
    -- names anything is left to Objects/Shared.
    if Type == "Table" then
        const List = (Value :: any) :: {any}
        const TableConstraints = (Constraints :: any) :: TableConstraints?
        if not TableConstraints or not Types.IsItemType(TableConstraints.Of) then
            return false
        end

        if not IsList(List) or #List < (TableConstraints.MinItems or 0) then
            return false
        end

        for _, Item in List do
            if not Types:IsValid(TableConstraints.Of, Item, TableConstraints.Item) then
                return false
            end
        end

        return true
    end

    if Constraints then
        if Type == "Text" then
            const TypedValue = (Value :: any) :: string
            return #TypedValue >= (Constraints.MinLength or 0)
        elseif Type == "Enum" then
            const TypedValue = (Value :: any) :: EnumItem
            if TypedValue.EnumType ~= Constraints.Enum then
                return false
            end

            if Constraints.Whitelist and not (table.find(Constraints.Whitelist, TypedValue) or table.find(Constraints.Whitelist, TypedValue.Name)) then
                return false
            end

            if Constraints.Blacklist and (table.find(Constraints.Blacklist, TypedValue) or table.find(Constraints.Blacklist, TypedValue.Name)) then
                return false
            end
        elseif Type == "CustomEnum" then
            const TypedValue = (Value :: any) :: CustomEnum.RegisteredOption<any>

            -- The client resolves this constraint from the enum name the server
            -- sent, and gets nil when that enum was never registered locally.
            -- Nothing can be validated against an enum this peer does not know,
            -- so reject rather than indexing nil.
            if not Constraints.CustomEnum then
                return false
            end

            if TypedValue.Parent ~= Constraints.CustomEnum.Name then
                return false
            end

            if Constraints.Whitelist and not (table.find(Constraints.Whitelist, TypedValue) or table.find(Constraints.Whitelist, TypedValue.Id)) then
                return false
            end

            if Constraints.Blacklist and (table.find(Constraints.Blacklist, TypedValue) or table.find(Constraints.Blacklist, TypedValue.Id)) then
                return false
            end
        end
    end

    return true
end

function Types:FixValue<T>(Type: T, Value: ValueFor<T>?, Constraints: ConstraintsFor<T>?): ValueFor<T>?
    if not Types:IsValid(Type, Value, Constraints) then
        return nil
    end

    if not Constraints then
        return Value
    end
    
    if Type == "Text" then
        const TypedValue = (Value :: any) :: string
        return Constraints.MaxLength and string.sub(TypedValue, 1, Constraints.MaxLength) or TypedValue
    elseif Type == "Number" then
        return FixNumber(Value, Constraints)
    elseif Type == "Color" then
        local TypedValue = (Value :: any) :: Color3
        TypedValue = Color3.fromRGB(
            Types:FixValue("Number", Codecs.ColorByte(TypedValue.R), {
                MinValue = Constraints.R and Constraints.R.MinValue and math.clamp(Constraints.R.MinValue, 0, 255) or 0,
                MaxValue = Constraints.R and Constraints.R.MaxValue and math.clamp(Constraints.R.MaxValue, 0, 255) or 255,
                AllowDecimals = if Constraints.R then Constraints.R.AllowDecimals else true,
                Precision = if Constraints.R then Constraints.R.Precision else nil,
            }),

            Types:FixValue("Number", Codecs.ColorByte(TypedValue.G), {
                MinValue = Constraints.G and Constraints.G.MinValue and math.clamp(Constraints.G.MinValue, 0, 255) or 0,
                MaxValue = Constraints.G and Constraints.G.MaxValue and math.clamp(Constraints.G.MaxValue, 0, 255) or 255,
                AllowDecimals = if Constraints.G then Constraints.G.AllowDecimals else true,
                Precision = if Constraints.G then Constraints.G.Precision else nil,
            }),
            
            Types:FixValue("Number", Codecs.ColorByte(TypedValue.B), {
                MinValue = Constraints.B and Constraints.B.MinValue and math.clamp(Constraints.B.MinValue, 0, 255) or 0,
                MaxValue = Constraints.B and Constraints.B.MaxValue and math.clamp(Constraints.B.MaxValue, 0, 255) or 255,
                AllowDecimals = if Constraints.B then Constraints.B.AllowDecimals else true,
                Precision = if Constraints.B then Constraints.B.Precision else nil,
            })
        )

        return TypedValue
    elseif Type == "Vector" then
        local TypedValue = (Value :: any) :: Vector3
        TypedValue = Vector3.new(
            Types:FixValue("Number", TypedValue.X, {
                MinValue = Constraints.X and Constraints.X.MinValue and math.clamp(Constraints.X.MinValue, -F32_MAX, F32_MAX) or -F32_MAX,
                MaxValue = Constraints.X and Constraints.X.MaxValue and math.clamp(Constraints.X.MaxValue, -F32_MAX, F32_MAX) or F32_MAX,
                AllowDecimals = if Constraints.X then Constraints.X.AllowDecimals else true,
                Precision = if Constraints.X then Constraints.X.Precision else nil,
            }),

            Types:FixValue("Number", TypedValue.Y, {
                MinValue = Constraints.Y and Constraints.Y.MinValue and math.clamp(Constraints.Y.MinValue, -F32_MAX, F32_MAX) or -F32_MAX,
                MaxValue = Constraints.Y and Constraints.Y.MaxValue and math.clamp(Constraints.Y.MaxValue, -F32_MAX, F32_MAX) or F32_MAX,
                AllowDecimals = if Constraints.Y then Constraints.Y.AllowDecimals else true,
                Precision = if Constraints.Y then Constraints.Y.Precision else nil,
            }),
            
            Types:FixValue("Number", TypedValue.Z, {
                MinValue = Constraints.Z and Constraints.Z.MinValue and math.clamp(Constraints.Z.MinValue, -F32_MAX, F32_MAX) or -F32_MAX,
                MaxValue = Constraints.Z and Constraints.Z.MaxValue and math.clamp(Constraints.Z.MaxValue, -F32_MAX, F32_MAX) or F32_MAX,
                AllowDecimals = if Constraints.Z then Constraints.Z.AllowDecimals else true,
                Precision = if Constraints.Z then Constraints.Z.Precision else nil,
            })
        )

        return TypedValue
    elseif Type == "Table" then
        const List = (Value :: any) :: {any}
        const TableConstraints = (Constraints :: any) :: TableConstraints
        const Length = math.min(#List, TableConstraints.MaxItems or Types.MAX_TABLE_ITEMS)

        const Fixed = table.create(Length)
        local Same = Length == #List

        for Index = 1, Length do
            const Item = Types:FixValue(TableConstraints.Of, List[Index], TableConstraints.Item)
            Fixed[Index] = Item
            if Item ~= List[Index] then
                Same = false
            end
        end

        -- A frozen list nothing had to change is handed back as it is, so a
        -- value read out of a property goes back in as the same table.
        if Same and table.isfrozen(List) then
            return List :: any
        end

        return table.freeze(Fixed) :: any
    end

    return Value
end

-- Whether two values of one type are the same value. Plain equality for every
-- type but Table, whose values would otherwise compare by identity: two lists
-- holding the same items read as a change, and a step of history holding one
-- list never matched the property holding another.
function Types:Equals(Type: PropertyType, Left: any, Right: any): boolean
    if Left == Right then
        return true
    end

    if Type ~= "Table" or type(Left) ~= "table" or type(Right) ~= "table" then
        return false
    end

    if #Left ~= #Right then
        return false
    end

    for Index = 1, #Left do
        if Left[Index] ~= Right[Index] then
            return false
        end
    end

    return true
end

local ReverseIds;
function Types:GetTypeFromId(Id: number): PropertyType?
    if not ReverseIds then
        const Ids = {}
        for i, v in Types.Ids do
            Ids[v] = i
        end
        ReverseIds = Ids
    end

    return ReverseIds[Id]
end

function Types:GetTypeId(Type: PropertyType): number?
    return Types.Ids[Type]
end

-- Lossy, and more so since Object joined: a reference is a Luau number exactly
-- as a Number is, so this cannot tell them apart and never could -- the
-- difference is what the registry says the property is, not what the value
-- looks like. Ordered by type id so the ambiguity resolves the same way every
-- run, to the older and broader of the two. Iterating Types.Map directly left
-- it to hash order, which meant a plain 5 answered Number or Object depending
-- on nothing at all.
local ReverseMap;
function Types:GetTypeFromValue(Value: any): PropertyType?
    const TypeOf = typeof(Value)
    if not ReverseMap then
        const Names = {}
        for Name in Types.Map do
            table.insert(Names, Name)
        end

        table.sort(Names, function(Left: string, Right: string): boolean
            return Types.Ids[Left] < Types.Ids[Right]
        end)

        const Map = {}
        for _, Name in Names do
            const Luau = Types.Map[Name]
            if Map[Luau] == nil then
                Map[Luau] = Name
            end
        end

        ReverseMap = Map
    end

    return ReverseMap[TypeOf]
end

return Types