--!strict
-- The tagged value format: wire shapes, single values and property records.
-- What every record, pack and packet in the compressor is built from; see
-- Compressor/init.luau for the rules the format follows.

const RunService = game:GetService("RunService")

const Properties = if RunService:IsClient()
    then require("../Properties/Client")
    else require("../Properties/Server")

const PropertyTypes = require("../Properties/Types")
const Handles = require("../Handles")
const ObjectTypes = require("../Objects/Types")
const CustomEnum = require("../CustomEnum")
const Varint = require("../Varint")
const Codecs = require("../Codecs")
const Logger = require("../Logger")

-- An object as its tagged values and nothing decoded: each property's tag and
-- payload exactly as a record holds them, by property id. Every object a pack
-- is written from becomes one of these first, which is what lets one pack hold
-- live objects, objects read from a pack, and objects kept whole because their
-- type is not registered, and write all three the same way.
export type RawObject = {
    __type: "RawObject",
    LocalId: Handles.LocalId,
    Registry: ObjectTypes.ObjectIdentifier,
    Fields: {[PropertyTypes.PropertyIdentifier]: buffer},
}

-- Bump when the layout changes. Readers refuse anything newer than they know
-- rather than misreading it.
const FORMAT_VERSION = 1

--=============================================================================
-- Wire shapes
--=============================================================================

const WIRE_VARINT = 0
const WIRE_FIXED3 = 1
const WIRE_FIXED4 = 2
const WIRE_FIXED8 = 3
const WIRE_FIXED12 = 4
const WIRE_FIXED48 = 5
const WIRE_BYTES = 6

const FIXED_SIZES = {
    [WIRE_FIXED3] = 3,
    [WIRE_FIXED4] = 4,
    [WIRE_FIXED8] = 8,
    [WIRE_FIXED12] = 12,
    [WIRE_FIXED48] = 48,
}

const Format = {}

-- Reused for the f32 round trip test, so choosing a number encoding allocates
-- nothing.
const Probe = buffer.create(8)

const function MakeTag(Wire: number, Type: number): number
    return Wire * 32 + Type
end

const function SplitTag(Tag: number): (number, number)
    return Tag // 32, Tag % 32
end

-- Advances past a value knowing only its wire shape. This is what lets an old
-- reader skip a semantic type added after it shipped.
const function SkipValue(Buf: buffer, Offset: number, Wire: number): number
    if Wire == WIRE_VARINT then
        const _, Read = Varint.Read(Buf, Offset)
        return Read
    elseif Wire == WIRE_BYTES then
        const Length, Read = Varint.Read(Buf, Offset)
        return Read + Length
    end

    const Size = FIXED_SIZES[Wire]
    if not Size then
        Logger:Error(`Unknown wire shape {Wire} at offset {Offset}.`)
    end

    return Size
end

const function NumberWire(Value: number): number
    if Value % 1 == 0 and math.abs(Value) <= Varint.MAX_SIGNED then
        return WIRE_VARINT
    end

    buffer.writef32(Probe, 0, Value)
    if buffer.readf32(Probe, 0) == Value then
        return WIRE_FIXED4
    end

    return WIRE_FIXED8
end

-- Length prefixed payload used by Text, Enum and CustomEnum. Enum and
-- CustomEnum pack a name and a number inside; keeping that behind one length
-- means their internal layout can change without breaking skippability.
const function BytesBuffer(Inner: buffer): buffer
    const Length = buffer.len(Inner)
    const Prefix = Varint.Measure(Length)
    const Out = buffer.create(Prefix + Length)
    Varint.Write(Out, 0, Length)
    buffer.copy(Out, Prefix, Inner, 0)
    return Out
end

const function NamedNumber(Name: string, Value: number): buffer
    const NameLength = Varint.Measure(#Name)
    const ValueLength = Varint.Measure(Value)
    const Inner = buffer.create(NameLength + #Name + ValueLength)

    Varint.Write(Inner, 0, #Name)
    buffer.writestring(Inner, NameLength, Name)
    Varint.Write(Inner, NameLength + #Name, Value)
    return BytesBuffer(Inner)
end

const function ReadNamedNumber(Buf: buffer, Offset: number): (string, number)
    const NameLength, NameRead = Varint.Read(Buf, Offset)
    const Name = buffer.readstring(Buf, Offset + NameRead, NameLength)
    const Value = Varint.Read(Buf, Offset + NameRead + NameLength)
    return Name, Value
end

--=============================================================================
-- Values
--=============================================================================

-- Returns a self contained buffer: tag byte followed by the encoded value. The
-- receiver needs nothing else to read it back, which is why network payloads can
-- use this directly.
--
-- Constraints matter to one type only: a Table is written item by item as its
-- item type, and Of is where that type is named. Every other type ignores them.
function Format:CompressValue(Type: PropertyTypes.PropertyType, Value: any?, Constraints: any?): buffer?
    if Value == nil then
        return nil
    end

    const TypeId = PropertyTypes:GetTypeId(Type)
        or Logger:Error(`Tried compressing unsupported value type: {Type}`)

    local Wire: number
    local Payload: buffer

    if Type == "Text" then
        const Text = Value :: string
        const Inner = buffer.create(#Text)
        buffer.writestring(Inner, 0, Text)
        Wire, Payload = WIRE_BYTES, BytesBuffer(Inner)
    elseif Type == "Number" then
        const Number = Value :: number
        Wire = NumberWire(Number)

        if Wire == WIRE_VARINT then
            const Size = Varint.MeasureSigned(Number)
            Payload = buffer.create(Size)
            Varint.WriteSigned(Payload, 0, Number)
        elseif Wire == WIRE_FIXED4 then
            Payload = buffer.create(4)
            buffer.writef32(Payload, 0, Number)
        else
            Payload = buffer.create(8)
            buffer.writef64(Payload, 0, Number)
        end
    elseif Type == "Bool" then
        Wire = WIRE_VARINT
        Payload = buffer.create(1)
        buffer.writeu8(Payload, 0, Value and 1 or 0)
    elseif Type == "Color" then
        Wire = WIRE_FIXED3
        Payload = buffer.create(3)
        buffer.writeu8(Payload, 0, Codecs.ColorByte(Value.R))
        buffer.writeu8(Payload, 1, Codecs.ColorByte(Value.G))
        buffer.writeu8(Payload, 2, Codecs.ColorByte(Value.B))
    elseif Type == "Vector" then
        Wire = WIRE_FIXED12
        Payload = buffer.create(12)
        buffer.writef32(Payload, 0, Value.X)
        buffer.writef32(Payload, 4, Value.Y)
        buffer.writef32(Payload, 8, Value.Z)
    elseif Type == "CFrame" then
        Wire = WIRE_FIXED48
        Payload = buffer.create(48)
        for Index, Component in {(Value :: CFrame):GetComponents()} do
            buffer.writef32(Payload, (Index - 1) * 4, Component)
        end
    elseif Type == "Enum" then
        Wire = WIRE_BYTES
        Payload = NamedNumber(tostring(Value.EnumType), Value.Value)
    elseif Type == "CustomEnum" then
        Wire = WIRE_BYTES
        Payload = NamedNumber(Value.Parent, Value.Id)
    elseif Type == "Object" then
        -- The target's local id and nothing else. Unsigned, because a local id
        -- is, and a varint so the ids a hand built scene actually uses cost one
        -- byte. Nothing is resolved on the way in or out: a pack is read with
        -- no world to resolve against, and a reference means whatever the copy
        -- reading it says it means -- which is exactly what lets two copies of
        -- one room each point at their own door.
        --
        -- An address, for a target in another scene, is the same type in a
        -- different wire shape. The tag is what tells them apart on the way
        -- back, and a local id's bytes are untouched by it.
        if type(Value) == "string" then
            const Address = Value :: string
            const Inner = buffer.create(#Address)
            buffer.writestring(Inner, 0, Address)
            Wire, Payload = WIRE_BYTES, BytesBuffer(Inner)
        else
            Wire = WIRE_VARINT
            const Target = Value :: number
            const Size = Varint.Measure(Target)
            Payload = buffer.create(Size)
            Varint.Write(Payload, 0, Target)
        end
    elseif Type == "Table" then
        -- [varint count][tagged item]... inside one length prefix. Each item
        -- carries its own tag, exactly as a property of its type would be
        -- written, so the list reads back with no registry -- and a Number
        -- written as a varint and one written as a float sit in the same list.
        const Of = Constraints and Constraints.Of
        if not PropertyTypes.IsItemType(Of) then
            Logger:Error("Tried compressing a Table without the item type its constraints name in Of.")
        end

        const List = Value :: {any}
        const Items = table.create(#List) :: {buffer}
        local Size = Varint.Measure(#List)

        for Index, Item in List do
            const Tagged = Format:CompressValue(Of, Item, Constraints.Item)
            if not Tagged then
                Logger:Error(`Tried compressing a Table whose item {Index} cannot be written as a {Of}.`)
            end

            Items[Index] = Tagged :: buffer
            Size += buffer.len(Tagged :: buffer)
        end

        const Inner = buffer.create(Size)
        local At = Varint.Write(Inner, 0, #List)
        for _, Tagged in Items do
            buffer.copy(Inner, At, Tagged, 0)
            At += buffer.len(Tagged)
        end

        Wire, Payload = WIRE_BYTES, BytesBuffer(Inner)
    else
        return Logger:Error(`Tried compressing unsupported value type: {Type}`)
    end

    -- Every branch above assigns it or returns, but the solver still reads a
    -- local declared without a value as possibly nil.
    const Body = Payload :: buffer
    const Length = buffer.len(Body)
    const Out = buffer.create(1 + Length)
    buffer.writeu8(Out, 0, MakeTag(Wire, TypeId))
    buffer.copy(Out, 1, Body, 0)
    return Out
end

-- Reads the tag itself, so the caller does not have to know what it is reading.
-- Returns the value, how many bytes it consumed, and the semantic type the
-- writer recorded, which the caller can compare against what it expected.
--
-- A Table also returns the type its items were written as, nil for an empty
-- list, because a list of Numbers and a list of Object references are the same
-- Luau values and only the tags tell them apart.
function Format:DecompressValue(Buf: buffer, Offset: number?): (any?, number, PropertyTypes.PropertyType?, PropertyTypes.PropertyType?)
    const At = Offset or 0
    const Wire, TypeId = SplitTag(buffer.readu8(Buf, At))
    const Type = PropertyTypes:GetTypeFromId(TypeId)

    if not Type then
        -- Unknown semantic type: the wire shape still says how far to move, so
        -- the rest of the record stays readable.
        return nil, 1 + SkipValue(Buf, At + 1, Wire), nil
    end

    const Body = At + 1

    if Type == "Text" then
        const Length, Read = Varint.Read(Buf, Body)
        return buffer.readstring(Buf, Body + Read, Length), 1 + Read + Length, Type
    elseif Type == "Number" then
        if Wire == WIRE_VARINT then
            const Value, Read = Varint.ReadSigned(Buf, Body)
            return Value, 1 + Read, Type
        elseif Wire == WIRE_FIXED4 then
            return buffer.readf32(Buf, Body), 5, Type
        elseif Wire == WIRE_FIXED8 then
            return buffer.readf64(Buf, Body), 9, Type
        end

        return nil, 1 + SkipValue(Buf, Body, Wire), Type
    elseif Type == "Bool" then
        const Value, Read = Varint.Read(Buf, Body)
        return Value == 1, 1 + Read, Type
    elseif Type == "Color" then
        return Color3.fromRGB(
            buffer.readu8(Buf, Body),
            buffer.readu8(Buf, Body + 1),
            buffer.readu8(Buf, Body + 2)
        ), 4, Type
    elseif Type == "Vector" then
        return Vector3.new(
            buffer.readf32(Buf, Body),
            buffer.readf32(Buf, Body + 4),
            buffer.readf32(Buf, Body + 8)
        ), 13, Type
    elseif Type == "CFrame" then
        const Components = table.create(12) :: {number}
        for Index = 1, 12 do
            Components[Index] = buffer.readf32(Buf, Body + (Index - 1) * 4)
        end

        const C = Components
        return CFrame.new(C[1], C[2], C[3], C[4], C[5], C[6], C[7], C[8], C[9], C[10], C[11], C[12]), 49, Type
    elseif Type == "Enum" then
        const Length, Read = Varint.Read(Buf, Body)
        const Consumed = 1 + Read + Length
        const Name, Value = ReadNamedNumber(Buf, Body + Read)

        -- A saved enum can outlive the Roblox enum it names.
        const Found = (Enum :: any)[Name]
        if not Found then
            Logger:Warn(`Unknown enum {Name} while decompressing. Value dropped.`)
            return nil, Consumed, Type
        end

        const Ok, Item = pcall(function()
            return Found:FromValue(Value)
        end)

        if not Ok or not Item then
            Logger:Warn(`Unknown value {Value} for enum {Name}. Value dropped.`)
            return nil, Consumed, Type
        end

        return Item, Consumed, Type
    elseif Type == "CustomEnum" then
        const Length, Read = Varint.Read(Buf, Body)
        const Consumed = 1 + Read + Length
        const Name, Id = ReadNamedNumber(Buf, Body + Read)

        -- An enum this side has not registered is not the same as an option
        -- that no longer exists. Collapsing both to UNKNOWN threw away which
        -- option it was, and a client that registers its enums after the first
        -- values arrive showed every one of them as the property's default for
        -- the rest of the session. A pending option keeps the name and the id,
        -- encodes back to exactly what it was read from, and is swapped for the
        -- real option once the enum is registered. Its Value is nil until then.
        const Registered = CustomEnum:GetEnum(Name)
        if not Registered then
            return CustomEnum.Pending(Name, Id), Consumed, Type
        end

        return Registered:GetById(Id) or CustomEnum.UNKNOWN, Consumed, Type
    elseif Type == "Object" then
        if Wire == WIRE_BYTES then
            const Length, Read = Varint.Read(Buf, Body)
            return buffer.readstring(Buf, Body + Read, Length), 1 + Read + Length, Type
        end

        const Value, Read = Varint.Read(Buf, Body)
        return Value, 1 + Read, Type
    elseif Type == "Table" then
        const Length, Read = Varint.Read(Buf, Body)
        const Consumed = 1 + Read + Length
        const End = Body + Read + Length

        const Count, CountRead = Varint.Read(Buf, Body + Read)
        local Cursor = Body + Read + CountRead

        const List = {}
        local ItemType: PropertyTypes.PropertyType? = nil
        local Malformed = false

        for _ = 1, Count do
            -- Never past the length prefix: a count that claims more items
            -- than the bytes hold is malformed, and reading on would take the
            -- next record's bytes for items.
            if Cursor >= End then
                Malformed = true
                break
            end

            -- A nested Table is refused rather than followed. None can be
            -- written, and following one is recursion a peer gets to choose
            -- the depth of.
            const _, ItemTypeId = SplitTag(buffer.readu8(Buf, Cursor))
            if PropertyTypes:GetTypeFromId(ItemTypeId) == "Table" then
                Malformed = true
                break
            end

            const Item, ItemRead, Written = Format:DecompressValue(Buf, Cursor)
            Cursor += ItemRead

            -- One list, one item type.
            if Written and ItemType and Written ~= ItemType then
                Malformed = true
                break
            end

            if not ItemType then
                ItemType = Written :: PropertyTypes.PropertyType?
            end

            -- An item that cannot be read back -- an enum gone since the save,
            -- a type this build has never heard of -- is left out, and the
            -- rest of the list kept.
            if Item ~= nil then
                table.insert(List, Item)
            end
        end

        if Malformed or Cursor > End then
            Logger:Warn("A Table was saved with items it cannot hold. Value dropped.")
            return nil, Consumed, Type
        end

        return table.freeze(List), Consumed, Type, ItemType
    end

    return nil, 1 + SkipValue(Buf, Body, Wire), Type
end

--=============================================================================
-- Properties
--=============================================================================

-- [varint property id][tag][value]
const function WriteProperty(
    Buffers: {buffer},
    Id: PropertyTypes.PropertyIdentifier,
    Type: PropertyTypes.PropertyType,
    Value: any?,
    Constraints: any?
): number
    const Tagged = Format:CompressValue(Type, Value, Constraints)
    if not Tagged then
        return 0
    end

    const IdSize = Varint.Measure(Id)
    const Header = buffer.create(IdSize)
    Varint.Write(Header, 0, Id)

    table.insert(Buffers, Header)
    table.insert(Buffers, Tagged)
    return IdSize + buffer.len(Tagged)
end

-- The tagged value exactly as it sits in the buffer, for a record this build
-- cannot place but must not lose.
const function Slice(Buf: buffer, Offset: number, Length: number): buffer
    const Copy = buffer.create(Length)
    buffer.copy(Copy, 0, Buf, Offset, Length)
    return Copy
end

-- The fourth return is set instead of the value when the record is one this
-- build cannot place: the raw tagged bytes, for the caller to keep under the id.
-- A registered property whose type changed since the save is still dropped --
-- that is the registry deliberately saying something new about the property,
-- and the object carries the property under its new type either way.
-- The tagged value at Offset, read for the property it was saved under. Split
-- from ReadProperty because a pack does not write the id beside each value.
const function ReadTagged(
    PropertyId: PropertyTypes.PropertyIdentifier,
    Buf: buffer,
    Offset: number
): (PropertyTypes.PropertyIdentifier?, any?, number, buffer?)
    const Value, Consumed, Type, ItemType = Format:DecompressValue(Buf, Offset)

    const Registry = Properties:GetRegistry(PropertyId)
    if not Registry then
        Logger:Warn(`Property id {PropertyId} is not registered. Kept as saved, and written back unchanged.`)
        return PropertyId, nil, Consumed, Slice(Buf, Offset, Consumed)
    end

    if not Type then
        Logger:Warn(`Property {PropertyId} was saved with a type this build does not know. Kept as saved, and written back unchanged.`)
        return PropertyId, nil, Consumed, Slice(Buf, Offset, Consumed)
    end

    -- The registry changed type since the save. The bytes were still read
    -- correctly, so the record continues; only this value is dropped.
    if Registry.Type ~= Type then
        Logger:Warn(`Property {PropertyId} was saved as {Type} but is registered as {Registry.Type}. Skipping.`)
        return nil, nil, Consumed
    end

    -- The same, one level down: a Table whose items were written as a type
    -- other than the one it holds now. An empty list has no item type and
    -- fits any.
    if Type == "Table" and ItemType then
        const Of = (Registry :: any).Constraints and (Registry :: any).Constraints.Of
        if ItemType ~= Of then
            Logger:Warn(`Property {PropertyId} was saved as a Table of {ItemType} but holds {tostring(Of)} now. Skipping.`)
            return nil, nil, Consumed
        end
    end

    return PropertyId, Value, Consumed
end

const function ReadProperty(Buf: buffer, Offset: number): (PropertyTypes.PropertyIdentifier?, any?, number, buffer?)
    const PropertyId, IdRead = Varint.Read(Buf, Offset)
    const Id, Value, ValueRead, Raw = ReadTagged(PropertyId, Buf, Offset + IdRead)
    return Id, Value, IdRead + ValueRead, Raw
end

-- How many bytes the tagged value at Offset takes, tag included, read from its
-- wire shape alone.
const function TaggedLength(Buf: buffer, Offset: number): number
    const Wire = SplitTag(buffer.readu8(Buf, Offset))
    return 1 + SkipValue(Buf, Offset + 1, Wire)
end

const function Concat(Header: string, Prefix: buffer, Buffers: {buffer}, Size: number): buffer
    const Compressed = buffer.create(#Header + buffer.len(Prefix) + Size)
    buffer.writestring(Compressed, 0, Header)
    buffer.copy(Compressed, #Header, Prefix, 0)

    local Offset = #Header + buffer.len(Prefix)
    for _, Part in Buffers do
        buffer.copy(Compressed, Offset, Part, 0)
        Offset += buffer.len(Part)
    end

    return Compressed
end

const function CheckVersion(Version: number, What: string)
    if Version > FORMAT_VERSION then
        Logger:Error(`{What} was written in format version {Version}; this build reads up to {FORMAT_VERSION}.`)
    end
end

Format.FORMAT_VERSION = FORMAT_VERSION
Format.WIRE_VARINT = WIRE_VARINT
Format.WIRE_FIXED12 = WIRE_FIXED12
Format.WIRE_BYTES = WIRE_BYTES
Format.Probe = Probe
Format.MakeTag = MakeTag
Format.WriteProperty = WriteProperty
Format.ReadProperty = ReadProperty
Format.ReadTagged = ReadTagged
Format.Slice = Slice
Format.TaggedLength = TaggedLength
Format.Concat = Concat
Format.CheckVersion = CheckVersion

return Format
