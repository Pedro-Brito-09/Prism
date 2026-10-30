--!strict
-- Binary serialization for objects and database metadata.
--
-- The governing rule: a buffer is decodable with zero reference to the registry.
-- The registry decides how a decoded value is validated and applied, never how
-- the bytes are read. A developer can change a constraint, change a type, or
-- unregister a property entirely, and existing data still decodes byte exactly.
--
-- Every value carries a one byte tag:
--
--   wwwttttt   w = wire shape (how to read it), t = semantic type (what it means)
--
-- The wire shape is what makes the format survive change. A reader that has
-- never heard of semantic type 19 still knows type 19 is length prefixed, so it
-- skips it precisely and keeps reading. Without that, one unknown property makes
-- the rest of the record unreadable -- and since decoding runs inside DataStore
-- UpdateAsync transforms, an unreadable record used to brick the key.
--
-- Numbers pick their encoding from the value, not from the schema. A whole
-- number becomes a varint, a fractional one that survives f32 becomes four
-- bytes, anything else becomes eight. That is why changing AllowDecimals cannot
-- corrupt anything: the bytes describe themselves. It also ends the old bug
-- where every number went through f32, whose 24 bit mantissa silently mangles
-- any integer past 16,777,216 -- user ids and unix timestamps included.

const RunService = game:GetService("RunService")
const EncodingService = game:GetService("EncodingService")

const Properties = if RunService:IsClient()
    then require("./Properties/Client")
    else require("./Properties/Server")

const PropertyTypes = require("./Properties/Types")
const Handles = require("./Handles")
const DatabaseTypes = require("./Database/Types")
const ObjectTypes = require("./Objects/Types")
const TransactionTypes = require("./Transactions/Types")
const CustomEnum = require("./CustomEnum")
const Varint = require("./Varint")
const Codecs = require("./Codecs")
const Logger = require("./Logger")

export type DecompressedObject = {
    __type: "DecompressedObject",

    -- The object's id within its scene, not the whole persistent id: the scene
    -- half is stamped on at load, which is what lets the same pack be loaded
    -- under two different scenes without the two colliding.
    LocalId: Handles.LocalId,

    Registry: ObjectTypes.ObjectIdentifier,
    Properties: {[PropertyTypes.PropertyIdentifier]: any},

    -- Property records this build could not place -- an id nobody registered,
    -- or a semantic type it has never heard of -- kept as their tagged bytes so
    -- writing the object back puts them back exactly as they were read. The
    -- wire shape exists so a reader can step over what it does not know and
    -- keep the rest; dropping the record anyway at the next save undid that.
    Unknown: {[PropertyTypes.PropertyIdentifier]: buffer}?,

    -- The tagged values this object was read from a pack as, whole. A scene
    -- keeps them for an object whose type is not registered, and writes them
    -- back untouched.
    Source: RawObject?,
}

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

const OBJECT_HEADER = "/oh"

-- A packet rather than a record, and the only header here that never reaches
-- storage. See the Transactions section.
const TRANSACTION_HEADER = "/th"

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

const Compressor = {}

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
function Compressor:CompressValue(Type: PropertyTypes.PropertyType, Value: any?, Constraints: any?): buffer?
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
            const Tagged = Compressor:CompressValue(Of, Item, Constraints.Item)
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
function Compressor:DecompressValue(Buf: buffer, Offset: number?): (any?, number, PropertyTypes.PropertyType?, PropertyTypes.PropertyType?)
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

            const Item, ItemRead, Written = Compressor:DecompressValue(Buf, Cursor)
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
    const Tagged = Compressor:CompressValue(Type, Value, Constraints)
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
    const Value, Consumed, Type, ItemType = Compressor:DecompressValue(Buf, Offset)

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

--=============================================================================
-- Objects
--=============================================================================

-- [/oh][varint version][varint registry id][varint local id][varint count][properties...]
--
-- The local id is the object's identity within its scene and is what makes a
-- saved reference outlive the save. The scene half is not written -- the scene
-- knows which one it is, and leaving it out is what keeps a pack portable. The
-- runtime id is not written either, and never is: it names a live copy, and a
-- pack describes the thing rather than any copy of it.
--
-- WithUnknown writes the records the object is keeping without understanding
-- them (see DecompressedObject.Unknown). A save wants them; replication does
-- not -- a client has no more use for them than the server did.
const function SortedKeys(Map: {[number]: any}): {number}
    const Keys = {}
    for Key in Map do
        table.insert(Keys, Key)
    end

    table.sort(Keys)
    return Keys
end

-- An object's values as tagged bytes, by property id.
const function ToRaw(Obj: ObjectTypes.Object | DecompressedObject, WithUnknown: boolean?): RawObject
    const Fields = {}
    const IsDecompressed = (Obj :: any).__type == "DecompressedObject"
    const Unknown: {[number]: buffer}? = if WithUnknown then (Obj :: any).Unknown else nil

    -- A value the object carries wins over one it is keeping for the same id:
    -- the property has come back since, and what it holds now is the answer.
    if Unknown then
        for Key, Raw in Unknown do
            if (Obj :: any).Properties[Key] == nil then
                Fields[Key] = Raw
            end
        end
    end

    for Key, Entry in (Obj :: any).Properties do
        local Id, Type, Value, Constraints

        if IsDecompressed then
            const Registry = Properties:GetRegistry(Key :: PropertyTypes.PropertyIdentifier)
            if not Registry then
                Logger:Warn(`Tried compressing an object with unregistered property id {Key}. Skipping.`)
                continue
            end

            Id, Type, Value, Constraints = Key, Registry.Type, Entry, Registry.Constraints
        else
            Id, Type, Value, Constraints = Entry.Parent, Entry.Type, Entry.Value, Entry.Constraints
        end

        const Tagged = Compressor:CompressValue(Type, Value, Constraints)
        if Tagged then
            Fields[Id] = Tagged
        end
    end

    return {
        __type = "RawObject",
        LocalId = if IsDecompressed
            then (Obj :: DecompressedObject).LocalId
            else (Obj :: ObjectTypes.Object).LocalId,
        Registry = Obj.Registry,
        Fields = Fields,
    }
end

const function WriteRecord(Raw: RawObject): buffer
    local Size = 0
    local Count = 0
    const Buffers = {}

    -- Walked in id order rather than hash order, so the same object always
    -- produces the same bytes. Hash order meant two identical objects serialized
    -- differently, which rules out hashing, diffing or deduplicating saves.
    for _, Key in SortedKeys(Raw.Fields) do
        const Tagged = Raw.Fields[Key]
        const IdSize = Varint.Measure(Key)
        const Header = buffer.create(IdSize)
        Varint.Write(Header, 0, Key)

        table.insert(Buffers, Header)
        table.insert(Buffers, Tagged)
        Size += IdSize + buffer.len(Tagged)
        Count += 1
    end

    const PrefixSize = Varint.Measure(FORMAT_VERSION)
        + Varint.Measure(Raw.Registry)
        + Varint.Measure(Raw.LocalId)
        + Varint.Measure(Count)

    const Prefix = buffer.create(PrefixSize)

    local At = Varint.Write(Prefix, 0, FORMAT_VERSION)
    At += Varint.Write(Prefix, At, Raw.Registry)
    At += Varint.Write(Prefix, At, Raw.LocalId)
    Varint.Write(Prefix, At, Count)

    return Concat(OBJECT_HEADER, Prefix, Buffers, Size)
end

function Compressor:CompressObject(Obj: ObjectTypes.Object | DecompressedObject, WithUnknown: boolean?): buffer
    return WriteRecord(ToRaw(Obj, WithUnknown))
end

function Compressor:DecompressObject(CompressedObj: buffer): DecompressedObject
    if buffer.readstring(CompressedObj, 0, #OBJECT_HEADER) ~= OBJECT_HEADER then
        Logger:Error("Tried to decompress invalid object buffer.")
    end

    local Offset = #OBJECT_HEADER

    const Version, VersionRead = Varint.Read(CompressedObj, Offset)
    CheckVersion(Version, "Object")
    Offset += VersionRead

    const TypeId, TypeIdRead = Varint.Read(CompressedObj, Offset)
    Offset += TypeIdRead

    const LocalId, LocalIdRead = Varint.Read(CompressedObj, Offset)
    Offset += LocalIdRead

    const Count, CountRead = Varint.Read(CompressedObj, Offset)
    Offset += CountRead

    const Obj: DecompressedObject = {
        __type = "DecompressedObject",
        LocalId = LocalId,
        Registry = TypeId,
        Properties = {},
    }

    for _ = 1, Count do
        const Id, Value, Consumed, Raw = ReadProperty(CompressedObj, Offset)
        Offset += Consumed

        if Raw and Id then
            local Unknown = Obj.Unknown
            if not Unknown then
                Unknown = {}
                Obj.Unknown = Unknown
            end

            (Unknown :: {[number]: buffer})[Id] = Raw
        elseif Id then
            Obj.Properties[Id] = Value
        end
    end

    return Obj
end

--=============================================================================
-- Packs
--=============================================================================

-- [varint version][varint flags][varint last id][body]
--
-- Both packs that are stored -- a scene's objects and a database shard's
-- records -- are written as this. LastId is what stops a scene reopening a
-- local id after the object holding it is gone, and a database reusing a
-- record id: without it, unload and load would restart the counter and the
-- second object ever created would answer to the name the first one was saved
-- under.
--
-- Written as one record per row -- every value beside its property id, and
-- every value a row held, defaults included, since a property starts out
-- holding its default -- a level of 20,000 blocks came to 4.5MB, past what one
-- DataStore key holds. A pack writes the same values and drops the repetition:
--
--   body     [varint group count][group...]
--   group    [varint key][varint column count][column...]
--            [varint row count][u8 partial]
--            [varint id step...]                       one per row
--            [present bitmap...]                       one per column, if partial
--            [written bitmap...]                       one per column
--            [values...]                               column by column
--   column   [varint id][u8 encoding][tagged default][encoding's own]
--
-- Rows are grouped -- objects by type, records by the properties they carry --
-- and a group's properties are written once as columns rather than once per
-- row. A column says, one bit a row, which rows hold something other than the
-- column's default, and writes only those. A partial group has rows missing
-- some of its columns -- an object read from a save made before a property was
-- added -- and says, one bit a row, which rows have each column.
--
-- Everything is column by column, the bitmaps and the values alike, rather than
-- row by row. The bytes a pack is made of then come in long runs of the same
-- kind -- every position, then every material -- which is what zstd finds
-- repetition in.
--
-- The default is the pack's own, not the registry's: whatever value the column
-- holds most often in this pack, written into the pack. A developer changing a
-- property's default afterwards changes nothing about what is already saved,
-- because nothing about the pack ever pointed at the registry. Every row reads
-- back holding exactly the values it was written with.
--
-- A column writes its values in whichever of these is smallest for it:
--
--   raw      each value tagged, exactly as a record would hold it. What every
--            column can fall back to, and what keeps a pack readable with no
--            registry: a column of a type this build has never heard of is
--            still a list of tagged values it can step over.
--   bool     nothing: the written bit is the value. Only for a column holding
--            Bools and nothing else.
--   palette  [varint count][tagged value...] after the default, then one
--            varint index per value. Materials, enums, mesh ids, colours: the
--            columns a level repeats a handful of values across.
--   grid     [varint scale] after the default, then each Vector as three signed
--            varints of its components times the scale. Building games snap to
--            a grid, so a position or a size is usually a few small integers
--            rather than twelve bytes of float. A Vector off the grid escapes to
--            its twelve bytes, so the column never refuses a value.
--   delta    [varint scale] after the default, then the grid again, written as
--            how far each Vector moved from the one before it: a bitmap of
--            which values are off the grid, every X step, every Y step, every
--            Z step, then the twelve bytes of each value off the grid. Blocks
--            are placed one after another near each other, so the steps are
--            smaller than the positions, and one axis at a time is what zstd
--            finds the most repetition in.
--   relative each reference as a signed varint of how far the object it names
--            is from the row's own id. An attribute made right after its block
--            names the object one before it, every time; written as the id
--            itself, that was a different number on every row.
--   list     a Table of references the same way: a varint count, then each
--            item as how far the object it names is from the row's own id.
--            Wiring blocks keep their inputs in such lists, and the blocks
--            they name are placed near them.
--
-- Whole, the body is then compressed with zstd when that comes out smaller,
-- which flag 1 records. Most of what is left is a level repeating itself in
-- ways no column can see, and zstd does see them.

const PACK_COMPRESSED = 1
const PACK_FLAGS = PACK_COMPRESSED

-- How far a pack may unpack. A client can push a pack, and a few bytes of zstd
-- can claim a gigabyte.
const MAX_UNPACKED_SIZE = 64 * 1024 * 1024

-- A scene is written when somebody saves, and its body is small by the time
-- zstd sees it: 19 took 70ms over 11ms for 9 on a 35,000 object level, and came
-- out 8% smaller. A shard is rewritten whole on every record created in it,
-- inside an UpdateAsync transform, where 19 cost 680ms a write.
const SCENE_COMPRESSION_LEVEL = 19
const METADATA_COMPRESSION_LEVEL = 9

const COLUMN_RAW = 0
const COLUMN_BOOL = 1
const COLUMN_PALETTE = 2
const COLUMN_GRID = 3
const COLUMN_RELATIVE = 4
const COLUMN_GRID_DELTA = 5
const COLUMN_RELATIVE_LIST = 6

-- Steps a grid column may snap to, smallest first so that a tie goes to the
-- smaller integers.
const GRID_SCALES = {1, 2, 4, 5, 8, 10, 16, 20, 100, 1000}

-- Past this a component is not a grid position in any sense that matters, and
-- times a scale it would leave the varint's range.
const GRID_LIMIT = 2 ^ 40

const BOOL_FALSE = Compressor:CompressValue("Bool", false) :: buffer
const BOOL_TRUE = Compressor:CompressValue("Bool", true) :: buffer
const BOOL_FALSE_KEY = buffer.tostring(BOOL_FALSE)
const BOOL_TRUE_KEY = buffer.tostring(BOOL_TRUE)
const VECTOR_TAG = MakeTag(WIRE_FIXED12, PropertyTypes:GetTypeId("Vector") :: number)
const OBJECT_TAG = MakeTag(WIRE_VARINT, PropertyTypes:GetTypeId("Object") :: number)
const TABLE_TAG = MakeTag(WIRE_BYTES, PropertyTypes:GetTypeId("Table") :: number)

-- A buffer that grows as it is written, so a pack is built in one place rather
-- than as thousands of pieces glued together at the end.
type Writer = {Buf: buffer, At: number}

const function NewWriter(): Writer
    return {Buf = buffer.create(256), At = 0}
end

const function Reserve(W: Writer, Size: number)
    const Need = W.At + Size
    const Length = buffer.len(W.Buf)
    if Need <= Length then
        return
    end

    const Grown = buffer.create(math.max(Length * 2, Need))
    buffer.copy(Grown, 0, W.Buf, 0, W.At)
    W.Buf = Grown
end

const function PutU8(W: Writer, Value: number)
    Reserve(W, 1)
    buffer.writeu8(W.Buf, W.At, Value)
    W.At += 1
end

const function PutVarint(W: Writer, Value: number)
    Reserve(W, Varint.Measure(Value))
    W.At += Varint.Write(W.Buf, W.At, Value)
end

const function PutSigned(W: Writer, Value: number)
    Reserve(W, Varint.MeasureSigned(Value))
    W.At += Varint.WriteSigned(W.Buf, W.At, Value)
end

const function PutBuffer(W: Writer, Part: buffer, Offset: number?, Length: number?)
    const From = Offset or 0
    const Size = Length or (buffer.len(Part) - From)
    Reserve(W, Size)
    buffer.copy(W.Buf, W.At, Part, From, Size)
    W.At += Size
end

const function Finish(W: Writer): buffer
    const Out = buffer.create(W.At)
    buffer.copy(Out, 0, W.Buf, 0, W.At)
    return Out
end

-- Whether a Vector's components all land on the grid. Exact or nothing, to the
-- bit: a component read back from the grid has to be the same float the record
-- held, or a save would move things by a rounding error every time. A -0 is
-- off the grid for that reason, since the integer it scales to has no sign.
const function FitsGrid(Tagged: buffer, Scale: number): boolean
    for Index = 0, 2 do
        const Component = buffer.readf32(Tagged, 1 + Index * 4)
        const Scaled = math.round(Component * Scale)
        if math.abs(Scaled) > GRID_LIMIT then
            return false
        end

        buffer.writef32(Probe, 0, Scaled / Scale)
        if buffer.readu32(Probe, 0) ~= buffer.readu32(Tagged, 1 + Index * 4) then
            return false
        end
    end

    return true
end

const function GridSize(Tagged: buffer, Scale: number): number
    if not FitsGrid(Tagged, Scale) then
        return 1 + 12
    end

    local Size = 0
    for Index = 0, 2 do
        const Scaled = math.round(buffer.readf32(Tagged, 1 + Index * 4) * Scale)
        Size += if Index == 0
            then Varint.Measure(Varint.Zigzag(Scaled) * 2)
            else Varint.MeasureSigned(Scaled)
    end

    return Size
end

-- The first component carries the escape: an even varint is the component
-- zigzagged and doubled, and a 1 means the twelve raw bytes follow instead.
const function PutGrid(W: Writer, Tagged: buffer, Scale: number)
    if not FitsGrid(Tagged, Scale) then
        PutVarint(W, 1)
        PutBuffer(W, Tagged, 1, 12)
        return
    end

    for Index = 0, 2 do
        const Scaled = math.round(buffer.readf32(Tagged, 1 + Index * 4) * Scale)
        if Index == 0 then
            PutVarint(W, Varint.Zigzag(Scaled) * 2)
        else
            PutSigned(W, Scaled)
        end
    end
end

-- The grid integers a Vector lands on at Scale, or nil when it is off the grid.
const function GridInts(Tagged: buffer, Scale: number): {number}?
    if not FitsGrid(Tagged, Scale) then
        return nil
    end

    return {
        math.round(buffer.readf32(Tagged, 1) * Scale),
        math.round(buffer.readf32(Tagged, 5) * Scale),
        math.round(buffer.readf32(Tagged, 9) * Scale),
    }
end

-- The local id a tagged reference holds, or nil when the value is not exactly
-- one: a column holding anything else cannot be written relative to its rows.
const function TargetOf(Key: string): number?
    if string.byte(Key, 1) ~= OBJECT_TAG then
        return nil
    end

    const Buf = buffer.fromstring(Key)
    const Ok, Target, Read = pcall(Varint.Read, Buf, 1)
    if not Ok or 1 + Read ~= #Key then
        return nil
    end

    return Target
end

-- A Table of references, tagged exactly as CompressValue writes one. The one
-- place both sides build it, so what the reader rebuilds is what the writer
-- checked it would.
const function ReferenceList(Targets: {number}): buffer
    local Inner = Varint.Measure(#Targets)
    for _, Target in Targets do
        Inner += 1 + Varint.Measure(Target)
    end

    const Out = buffer.create(1 + Varint.Measure(Inner) + Inner)
    buffer.writeu8(Out, 0, TABLE_TAG)
    local At = 1 + Varint.Write(Out, 1, Inner)
    At += Varint.Write(Out, At, #Targets)
    for _, Target in Targets do
        buffer.writeu8(Out, At, OBJECT_TAG)
        At += 1 + Varint.Write(Out, At + 1, Target)
    end

    return Out
end

-- The local ids a tagged Table of references holds, or nil when the value is
-- anything else -- or is one but would not be rebuilt byte for byte from its
-- ids, which a column written relative to its rows could not give back.
const function TargetsOf(Key: string): {number}?
    if string.byte(Key, 1) ~= TABLE_TAG then
        return nil
    end

    const Buf = buffer.fromstring(Key)
    const Ok, Targets = pcall(function(): {number}?
        const _, LengthRead = Varint.Read(Buf, 1)
        const Count, CountRead = Varint.Read(Buf, 1 + LengthRead)
        if Count > #Key then
            return nil
        end

        local At = 1 + LengthRead + CountRead
        const List = table.create(Count) :: {number}
        for Index = 1, Count do
            if buffer.readu8(Buf, At) ~= OBJECT_TAG then
                return nil
            end

            const Target, Read = Varint.Read(Buf, At + 1)
            List[Index] = Target
            At += 1 + Read
        end

        return List
    end)

    if not Ok or not Targets or buffer.tostring(ReferenceList(Targets)) ~= Key then
        return nil
    end

    return Targets
end

type Column = {
    Id: number,
    Encoding: number,
    Default: string,
    Palette: {[string]: number}?,
    Scale: number?,
}

-- Decides how one column is written, from every value it holds in this pack.
-- Values is by row, nil where a row does not carry the column; LocalIds is
-- each row's id, which a reference is written relative to.
const function PlanColumn(Id: number, Values: {[number]: string}, Rows: number, LocalIds: {number}): Column
    const Counts: {[string]: number} = {}
    for Row = 1, Rows do
        const Key = Values[Row]
        if Key then
            Counts[Key] = (Counts[Key] or 0) + 1
        end
    end

    -- Most common first, then by the bytes themselves, so the same column
    -- always plans the same way and the same rows write the same pack.
    const Distinct = {}
    for Key in Counts do
        table.insert(Distinct, Key)
    end

    table.sort(Distinct, function(A, B)
        if Counts[A] ~= Counts[B] then
            return Counts[A] > Counts[B]
        end

        return A < B
    end)

    const Default = Distinct[1]

    local IsBool = true
    for _, Key in Distinct do
        if Key ~= BOOL_FALSE_KEY and Key ~= BOOL_TRUE_KEY then
            IsBool = false
            break
        end
    end

    if IsBool then
        return {Id = Id, Encoding = COLUMN_BOOL, Default = Default}
    end

    -- What each encoding would cost for the values that are not the default.
    local Raw = 0
    local Palette = Varint.Measure(#Distinct - 1)
    const Index: {[string]: number} = {}

    for Position = 2, #Distinct do
        const Key = Distinct[Position]
        Index[Key] = Position - 1
        Palette += #Key
        Raw += #Key * Counts[Key]
        Palette += Varint.Measure(Position - 1) * Counts[Key]
    end

    local Grid = math.huge
    local Scale = nil

    local IsVector = true
    for Position = 2, #Distinct do
        if string.byte(Distinct[Position], 1) ~= VECTOR_TAG or #Distinct[Position] ~= 13 then
            IsVector = false
            break
        end
    end

    if IsVector and #Distinct > 1 then
        for _, Candidate in GRID_SCALES do
            local Size = Varint.Measure(Candidate)
            for Position = 2, #Distinct do
                const Key = Distinct[Position]
                Size += GridSize(buffer.fromstring(Key), Candidate) * Counts[Key]
            end

            if Size < Grid then
                Grid, Scale = Size, Candidate
            end
        end
    end

    -- The values that are written, in the order they are written: a delta and
    -- a relative reference both depend on where in the column a value falls.
    const Written: {string} = {}
    const WrittenRows: {number} = {}
    for Row = 1, Rows do
        const Key = Values[Row]
        if Key ~= nil and Key ~= Default then
            table.insert(Written, Key)
            table.insert(WrittenRows, Row)
        end
    end

    local Delta = math.huge
    local DeltaScale = nil

    if IsVector and #Distinct > 1 then
        for _, Candidate in GRID_SCALES do
            -- Nil for a value off the grid at this scale.
            const Ints: {[string]: {number}?} = {}
            for Position = 2, #Distinct do
                const Key = Distinct[Position]
                Ints[Key] = GridInts(buffer.fromstring(Key), Candidate)
            end

            local Size = Varint.Measure(Candidate) + (#Written + 7) // 8
            local X, Y, Z = 0, 0, 0
            for _, Key in Written do
                const Step = Ints[Key]
                if Step then
                    Size += Varint.MeasureSigned(Step[1] - X)
                        + Varint.MeasureSigned(Step[2] - Y)
                        + Varint.MeasureSigned(Step[3] - Z)
                    X, Y, Z = Step[1], Step[2], Step[3]
                else
                    Size += 12
                end
            end

            if Size < Delta then
                Delta, DeltaScale = Size, Candidate
            end
        end
    end

    local Relative = math.huge
    if #Distinct > 1 then
        const Targets: {[string]: number} = {}
        local Fits = true
        for Position = 2, #Distinct do
            const Target = TargetOf(Distinct[Position])
            if not Target then
                Fits = false
                break
            end

            Targets[Distinct[Position]] = Target
        end

        if Fits then
            Relative = 0
            for Position, Key in Written do
                Relative += Varint.MeasureSigned(Targets[Key] - LocalIds[WrittenRows[Position]])
            end
        end
    end

    local List = math.huge
    if #Distinct > 1 then
        const Lists: {[string]: {number}} = {}
        local Fits = true
        for Position = 2, #Distinct do
            const Targets = TargetsOf(Distinct[Position])
            if not Targets then
                Fits = false
                break
            end

            Lists[Distinct[Position]] = Targets
        end

        if Fits then
            List = 0
            for Position, Key in Written do
                const Row = LocalIds[WrittenRows[Position]]
                List += Varint.Measure(#Lists[Key])
                for _, Target in Lists[Key] do
                    List += Varint.MeasureSigned(Target - Row)
                end
            end
        end
    end

    -- The smallest wins, and a tie goes to the simpler encoding.
    local Best, Encoding = Raw, COLUMN_RAW
    if Palette < Best then
        Best, Encoding = Palette, COLUMN_PALETTE
    end

    if Grid < Best then
        Best, Encoding = Grid, COLUMN_GRID
    end

    if Delta < Best then
        Best, Encoding = Delta, COLUMN_GRID_DELTA
    end

    if Relative < Best then
        Best, Encoding = Relative, COLUMN_RELATIVE
    end

    if List < Best then
        Best, Encoding = List, COLUMN_RELATIVE_LIST
    end

    return {
        Id = Id,
        Encoding = Encoding,
        Default = Default,
        Palette = if Encoding == COLUMN_PALETTE then Index else nil,
        Scale = if Encoding == COLUMN_GRID then Scale elseif Encoding == COLUMN_GRID_DELTA then DeltaScale else nil,
    }
end

const function WriteColumn(W: Writer, Plan: Column)
    PutVarint(W, Plan.Id)
    PutU8(W, Plan.Encoding)
    PutBuffer(W, buffer.fromstring(Plan.Default))

    if Plan.Encoding == COLUMN_PALETTE then
        const Palette = Plan.Palette :: {[string]: number}
        const Ordered = {}
        for Key, Position in Palette do
            Ordered[Position] = Key
        end

        PutVarint(W, #Ordered)
        for _, Key in Ordered do
            PutBuffer(W, buffer.fromstring(Key))
        end
    elseif Plan.Encoding == COLUMN_GRID or Plan.Encoding == COLUMN_GRID_DELTA then
        PutVarint(W, Plan.Scale :: number)
    end
end

const function PutBitmap(W: Writer, Bits: {boolean}, Count: number)
    for Start = 1, Count, 8 do
        local Byte = 0
        for Bit = 0, math.min(7, Count - Start) do
            if Bits[Start + Bit] then
                Byte = bit32.bor(Byte, bit32.lshift(1, Bit))
            end
        end

        PutU8(W, Byte)
    end
end

-- Every value a column writes, in row order. A whole column at a time rather
-- than a value at a time, because a delta is from the value before it and its
-- axes are written one after another.
const function PutColumnValues(W: Writer, Plan: Column, Values: {[number]: string}, Rows: number, LocalIds: {number})
    const Written: {string} = {}
    const WrittenRows: {number} = {}
    for Row = 1, Rows do
        const Key = Values[Row]
        if Key ~= nil and Key ~= Plan.Default then
            table.insert(Written, Key)
            table.insert(WrittenRows, Row)
        end
    end

    if Plan.Encoding == COLUMN_GRID_DELTA then
        const Scale = Plan.Scale :: number
        const Ints = table.create(#Written) :: {{number}?}
        const Escaped = table.create(#Written) :: {boolean}
        for Index, Key in Written do
            const Step = GridInts(buffer.fromstring(Key), Scale)
            Ints[Index] = Step
            Escaped[Index] = Step == nil
        end

        PutBitmap(W, Escaped, #Written)

        for Axis = 1, 3 do
            local Previous = 0
            for Index = 1, #Written do
                const Step = Ints[Index]
                if Step then
                    PutSigned(W, Step[Axis] - Previous)
                    Previous = Step[Axis]
                end
            end
        end

        for Index, Key in Written do
            if Escaped[Index] then
                PutBuffer(W, buffer.fromstring(Key), 1, 12)
            end
        end

        return
    end

    for Index, Key in Written do
        if Plan.Encoding == COLUMN_RAW then
            PutBuffer(W, buffer.fromstring(Key))
        elseif Plan.Encoding == COLUMN_PALETTE then
            PutVarint(W, (Plan.Palette :: {[string]: number})[Key])
        elseif Plan.Encoding == COLUMN_GRID then
            PutGrid(W, buffer.fromstring(Key), Plan.Scale :: number)
        elseif Plan.Encoding == COLUMN_RELATIVE then
            PutSigned(W, (TargetOf(Key) :: number) - LocalIds[WrittenRows[Index]])
        elseif Plan.Encoding == COLUMN_RELATIVE_LIST then
            const Targets = TargetsOf(Key) :: {number}
            PutVarint(W, #Targets)
            for _, Target in Targets do
                PutSigned(W, Target - LocalIds[WrittenRows[Index]])
            end
        end

        -- A bool column writes nothing: the written bit already said it.
    end
end

-- One group: its rows, and the column ids to write them under in that order.
type Group = {Key: number, Rows: {RawObject}, Order: {number}}

const function WriteGroup(W: Writer, Group: Group)
    const Rows = Group.Rows
    const Order = Group.Order

    table.sort(Rows, function(A: RawObject, B: RawObject)
        return A.LocalId < B.LocalId
    end)

    const Plans = table.create(#Order) :: {Column}
    const Keys = table.create(#Order) :: {{[number]: string}}
    local Partial = false

    const LocalIds = table.create(#Rows) :: {number}
    for Row, Raw in Rows do
        LocalIds[Row] = Raw.LocalId
    end

    for Index, Id in Order do
        const Values = {}
        for Row, Raw in Rows do
            const Tagged = Raw.Fields[Id]
            if Tagged then
                Values[Row] = buffer.tostring(Tagged)
            else
                Partial = true
            end
        end

        Keys[Index] = Values
        Plans[Index] = PlanColumn(Id, Values, #Rows, LocalIds)
    end

    PutVarint(W, Group.Key)
    PutVarint(W, #Order)
    for _, Plan in Plans do
        WriteColumn(W, Plan)
    end

    PutVarint(W, #Rows)
    PutU8(W, if Partial then 1 else 0)

    local Previous = 0
    for _, Raw in Rows do
        PutVarint(W, Raw.LocalId - Previous)
        Previous = Raw.LocalId
    end

    const Bits = table.create(#Rows) :: {boolean}

    if Partial then
        for Index in Order do
            for Row = 1, #Rows do
                Bits[Row] = Keys[Index][Row] ~= nil
            end

            PutBitmap(W, Bits, #Rows)
        end
    end

    for Index, Plan in Plans do
        for Row = 1, #Rows do
            const Key = Keys[Index][Row]
            Bits[Row] = Key ~= nil and Key ~= Plan.Default
        end

        PutBitmap(W, Bits, #Rows)
    end

    for Index, Plan in Plans do
        PutColumnValues(W, Plan, Keys[Index], #Rows, LocalIds)
    end
end

-- The header, then the body -- compressed when that makes it smaller. Kept only
-- when it is: a pack of a few rows comes out larger under zstd than without
-- it, and a build that cannot compress at all still writes a pack every build
-- can read.
const function WritePack(LastId: number, Groups: {Group}, Level: number): (buffer, number)
    const Body = NewWriter()
    PutVarint(Body, #Groups)
    for _, Group in Groups do
        WriteGroup(Body, Group)
    end

    local Payload = Finish(Body)
    const Size = buffer.len(Payload)
    local Flags = 0

    const Ok, Compressed = pcall(function()
        return EncodingService:CompressBuffer(Payload, Enum.CompressionAlgorithm.Zstd, Level)
    end)

    if Ok and buffer.len(Compressed) < Size then
        Payload = Compressed
        Flags += PACK_COMPRESSED
    end

    const Out = NewWriter()
    PutVarint(Out, FORMAT_VERSION)
    PutVarint(Out, Flags)
    PutVarint(Out, LastId)
    PutBuffer(Out, Payload)
    return Finish(Out), Size
end

const function ReadBitmap(Buf: buffer, Offset: number, Count: number, Into: {boolean}): number
    for Index = 1, Count do
        const Byte = buffer.readu8(Buf, Offset + (Index - 1) // 8)
        Into[Index] = bit32.extract(Byte, (Index - 1) % 8) == 1
    end

    return (Count + 7) // 8
end

-- A count read from the pack, refused when it claims more entries than there
-- are bytes left for. Every entry takes at least one, and a count past that is
-- a lie a table would otherwise be allocated for.
const function ReadCount(Buf: buffer, Offset: number): (number, number)
    const Count, Read = Varint.Read(Buf, Offset)
    if Count > buffer.len(Buf) - Offset - Read then
        Logger:Error(`A pack claims {Count} entries at offset {Offset} with fewer bytes left.`)
    end

    return Count, Read
end

type ReadColumn = {
    Id: number,
    Encoding: number,
    Default: buffer,
    Other: buffer?,
    Palette: {buffer}?,
    Scale: number?,
}

-- Shared is every buffer the column hands to more than one row -- its default,
-- its palette -- which the caller decodes once rather than once per row.
const function ReadColumnHeader(Buf: buffer, Offset: number, Shared: {[buffer]: true}): (ReadColumn, number)
    local At = Offset

    const Id, IdRead = Varint.Read(Buf, At)
    At += IdRead

    const Encoding = buffer.readu8(Buf, At)
    At += 1

    const DefaultLength = TaggedLength(Buf, At)
    const Default = Slice(Buf, At, DefaultLength)
    At += DefaultLength

    const Column: ReadColumn = {Id = Id, Encoding = Encoding, Default = Default}
    Shared[Default] = true

    if Encoding == COLUMN_BOOL then
        const Key = buffer.tostring(Default)
        if Key ~= BOOL_FALSE_KEY and Key ~= BOOL_TRUE_KEY then
            Logger:Error(`Bool column {Id} has a default that is not a Bool.`)
        end

        const Other = buffer.fromstring(if Key == BOOL_FALSE_KEY then BOOL_TRUE_KEY else BOOL_FALSE_KEY)
        Column.Other = Other
        Shared[Other] = true
    elseif Encoding == COLUMN_PALETTE then
        const Count, CountRead = ReadCount(Buf, At)
        At += CountRead

        const Palette = table.create(Count) :: {buffer}
        for Index = 1, Count do
            const Length = TaggedLength(Buf, At)
            Palette[Index] = Slice(Buf, At, Length)
            Shared[Palette[Index]] = true
            At += Length
        end

        Column.Palette = Palette
    elseif Encoding == COLUMN_GRID or Encoding == COLUMN_GRID_DELTA then
        const Scale, ScaleRead = Varint.Read(Buf, At)
        At += ScaleRead

        if Scale == 0 then
            Logger:Error(`Grid column {Id} has a scale of 0.`)
        end

        Column.Scale = Scale
    elseif Encoding ~= COLUMN_RAW and Encoding ~= COLUMN_RELATIVE and Encoding ~= COLUMN_RELATIVE_LIST then
        Logger:Error(`Column {Id} is written in encoding {Encoding}, which this build does not know.`)
    end

    return Column, At - Offset
end

const function ReadGrid(Buf: buffer, Offset: number, Scale: number): (buffer, number)
    const Tagged = buffer.create(13)
    buffer.writeu8(Tagged, 0, VECTOR_TAG)

    const First, FirstRead = Varint.Read(Buf, Offset)
    if First == 1 then
        buffer.copy(Tagged, 1, Buf, Offset + FirstRead, 12)
        return Tagged, FirstRead + 12
    end

    if First % 2 == 1 then
        Logger:Error(`Malformed grid value at offset {Offset}.`)
    end

    local At = Offset + FirstRead
    buffer.writef32(Tagged, 1, Varint.Unzigzag(First // 2) / Scale)

    for Index = 1, 2 do
        const Scaled, Read = Varint.ReadSigned(Buf, At)
        At += Read
        buffer.writef32(Tagged, 1 + Index * 4, Scaled / Scale)
    end

    return Tagged, At - Offset
end

-- A Vector rebuilt from its grid integers, which the writer only used when they
-- give back the same floats exactly.
const function GridVector(X: number, Y: number, Z: number, Scale: number): buffer
    const Tagged = buffer.create(13)
    buffer.writeu8(Tagged, 0, VECTOR_TAG)
    buffer.writef32(Tagged, 1, X / Scale)
    buffer.writef32(Tagged, 5, Y / Scale)
    buffer.writef32(Tagged, 9, Z / Scale)
    return Tagged
end

-- Every value a column wrote, into the rows that wrote one. Returns how many
-- bytes they took.
const function ReadColumnValues(
    Buf: buffer,
    Offset: number,
    Column: ReadColumn,
    WrittenRows: {number},
    Ids: {number},
    Rows: {{[number]: buffer}}
): number
    local At = Offset
    const Count = #WrittenRows

    if Column.Encoding == COLUMN_GRID_DELTA then
        const Scale = Column.Scale :: number
        const Escaped = table.create(Count) :: {boolean}
        At += ReadBitmap(Buf, At, Count, Escaped)

        const Axes: {{number}} = {table.create(Count) :: {number}, table.create(Count) :: {number}, table.create(Count) :: {number}}
        for Axis = 1, 3 do
            const Values = Axes[Axis]
            local Previous = 0
            for Index = 1, Count do
                if not Escaped[Index] then
                    const Step, Read = Varint.ReadSigned(Buf, At)
                    At += Read
                    Previous += Step
                    Values[Index] = Previous
                end
            end
        end

        for Index, Row in WrittenRows do
            local Tagged: buffer
            if Escaped[Index] then
                Tagged = buffer.create(13)
                buffer.writeu8(Tagged, 0, VECTOR_TAG)
                buffer.copy(Tagged, 1, Buf, At, 12)
                At += 12
            else
                Tagged = GridVector(Axes[1][Index], Axes[2][Index], Axes[3][Index], Scale)
            end

            Rows[Row][Column.Id] = Tagged
        end

        return At - Offset
    end

    for _, Row in WrittenRows do
        local Tagged: buffer

        if Column.Encoding == COLUMN_BOOL then
            Tagged = Column.Other :: buffer
        elseif Column.Encoding == COLUMN_PALETTE then
            const Position, Read = Varint.Read(Buf, At)
            At += Read

            const Entry = (Column.Palette :: {buffer})[Position]
            if not Entry then
                Logger:Error(`Column {Column.Id} names palette entry {Position}, which it does not have.`)
            end

            Tagged = Entry :: buffer
        elseif Column.Encoding == COLUMN_GRID then
            const Value, Read = ReadGrid(Buf, At, Column.Scale :: number)
            At += Read
            Tagged = Value
        elseif Column.Encoding == COLUMN_RELATIVE then
            const Distance, Read = Varint.ReadSigned(Buf, At)
            At += Read

            const Target = Ids[Row] + Distance
            if Target < 0 then
                Logger:Error(`Column {Column.Id} points row {Ids[Row]} at {Target}, which is not an id.`)
            end

            Tagged = buffer.create(1 + Varint.Measure(Target))
            buffer.writeu8(Tagged, 0, OBJECT_TAG)
            Varint.Write(Tagged, 1, Target)
        elseif Column.Encoding == COLUMN_RELATIVE_LIST then
            const ItemCount, CountRead = ReadCount(Buf, At)
            At += CountRead

            const Targets = table.create(ItemCount) :: {number}
            for Item = 1, ItemCount do
                const Distance, Read = Varint.ReadSigned(Buf, At)
                At += Read

                const Target = Ids[Row] + Distance
                if Target < 0 then
                    Logger:Error(`Column {Column.Id} points row {Ids[Row]} at {Target}, which is not an id.`)
                end

                Targets[Item] = Target
            end

            Tagged = ReferenceList(Targets)
        else
            const Length = TaggedLength(Buf, At)
            Tagged = Slice(Buf, At, Length)
            At += Length
        end

        Rows[Row][Column.Id] = Tagged
    end

    return At - Offset
end

-- A row as the pack holds it: the group's key, its id, its tagged values by
-- column id, and the column ids in the order the group wrote them.
type OnRow = (Key: number, LocalId: number, Fields: {[number]: buffer}, Order: {number}, Shared: {[buffer]: true}) -> ()

-- Reads a pack's header and body, handing each row to OnRow. Returns
-- the pack's LastId.
const function ReadPack(Pack: buffer, Offset: number, Each: OnRow): number
    local At = Offset

    const Flags, FlagsRead = Varint.Read(Pack, At)
    At += FlagsRead

    if Flags ~= bit32.band(Flags, PACK_FLAGS) then
        Logger:Error(`Pack carries flags {Flags}, some of which this build does not know.`)
    end

    const LastId, LastIdRead = Varint.Read(Pack, At)
    At += LastIdRead

    local Buf = Slice(Pack, At, buffer.len(Pack) - At)
    if bit32.band(Flags, PACK_COMPRESSED) ~= 0 then
        -- Asked before unpacking rather than after. The size is in the zstd
        -- frame, and unpacking refuses a frame that does not have one.
        const Size = EncodingService:GetDecompressedBufferSize(Buf, Enum.CompressionAlgorithm.Zstd)
        if not Size or Size > MAX_UNPACKED_SIZE then
            Logger:Error(`Pack unpacks to {tostring(Size)} bytes; at most {MAX_UNPACKED_SIZE} are read.`)
        end

        Buf = EncodingService:DecompressBuffer(Buf, Enum.CompressionAlgorithm.Zstd)
    end

    At = 0
    const Shared: {[buffer]: true} = {}

    const GroupCount, GroupCountRead = ReadCount(Buf, At)
    At += GroupCountRead

    for _ = 1, GroupCount do
        const Key, KeyRead = Varint.Read(Buf, At)
        At += KeyRead

        const ColumnCount, ColumnCountRead = ReadCount(Buf, At)
        At += ColumnCountRead

        const Columns = table.create(ColumnCount) :: {ReadColumn}
        const Order = table.create(ColumnCount) :: {number}
        for Index = 1, ColumnCount do
            const Column, Read = ReadColumnHeader(Buf, At, Shared)
            Columns[Index] = Column
            Order[Index] = Column.Id
            At += Read
        end

        const RowCount, RowCountRead = ReadCount(Buf, At)
        At += RowCountRead

        const Partial = buffer.readu8(Buf, At) == 1
        At += 1

        const Ids = table.create(RowCount) :: {number}
        const Rows = table.create(RowCount) :: {{[number]: buffer}}
        local Previous = 0
        for Row = 1, RowCount do
            const Step, StepRead = Varint.Read(Buf, At)
            At += StepRead

            Previous += Step
            Ids[Row] = Previous
            Rows[Row] = {}
        end

        -- Left empty when no row is missing a column, which is nearly always.
        const Present: {{boolean}} = {}
        if Partial then
            for Index = 1, ColumnCount do
                const Bits = table.create(RowCount) :: {boolean}
                At += ReadBitmap(Buf, At, RowCount, Bits)
                Present[Index] = Bits
            end
        end

        const Written = table.create(ColumnCount) :: {{boolean}}
        for Index = 1, ColumnCount do
            const Bits = table.create(RowCount) :: {boolean}
            At += ReadBitmap(Buf, At, RowCount, Bits)
            Written[Index] = Bits
        end

        for Index, Column in Columns do
            const Has, Wrote = Present[Index], Written[Index]
            const WrittenRows: {number} = {}

            for Row = 1, RowCount do
                if Has and not Has[Row] then
                    continue
                end

                if Wrote[Row] then
                    table.insert(WrittenRows, Row)
                else
                    Rows[Row][Column.Id] = Column.Default
                end
            end

            At += ReadColumnValues(Buf, At, Column, WrittenRows, Ids, Rows)
        end

        for Row = 1, RowCount do
            Each(Key, Ids[Row], Rows[Row], Order, Shared)
        end
    end

    return LastId
end

-- A value read for the property it belongs to, decoded once when many rows
-- share the same buffer.
type Placed = {any}

const function Decoder(): (PropertyTypes.PropertyIdentifier, buffer, {[buffer]: true}) -> (PropertyTypes.PropertyIdentifier?, any?, buffer?)
    const Decoded: {[buffer]: Placed} = {}

    return function(Id: PropertyTypes.PropertyIdentifier, Tagged: buffer, Shared: {[buffer]: true})
        local Result = if Shared[Tagged] then Decoded[Tagged] else nil
        if not Result then
            const PropertyId, Value, _, Raw = ReadTagged(Id, Tagged, 0)
            Result = {PropertyId, Value, Raw}
            if Shared[Tagged] then
                Decoded[Tagged] = Result
            end
        end

        const Read = Result :: Placed
        return Read[1], Read[2], Read[3]
    end
end

--=============================================================================
-- Metadata packs
--=============================================================================

-- A record's properties ride as columns numbered by property id, and the Guids
-- of the scenes it links as column 0, a Table of Text -- no property can be
-- taken for it, because property ids start at 1. A group is every record
-- carrying the same columns in the same order: a record's properties are read
-- back by position as well as by id, and the order is the one a record was
-- built in.
const METADATA_SCENES = 0
-- Text, the name Prism gives a string. It read "String", which is no type, so
-- every record linking a scene threw when its shard was written.
const SCENES_CONSTRAINTS = {Of = "Text"}

-- Returns the pack and the size of its body before compression, which is what a
-- caller measures a shard by: rewriting it decodes and encodes all of that.
function Compressor:CompressMetadatas(LastId: number, Metadatas: {DatabaseTypes.Metadata}): (buffer, number)
    const Groups: {Group} = {}
    const ByLayout: {[string]: Group} = {}

    for _, Metadata in Metadatas do
        const Fields: {[number]: buffer} = {}
        const Order: {number} = {}

        -- Nothing written for a record linking no scene, which is most of them.
        if #Metadata.Scenes > 0 then
            Fields[METADATA_SCENES] = Compressor:CompressValue("Table", Metadata.Scenes, SCENES_CONSTRAINTS) :: buffer
            table.insert(Order, METADATA_SCENES)
        end

        for Index, Prop in Metadata do
            if type(Index) ~= "number" then
                continue
            end

            const Column = Prop.Parent
            if Fields[Column] then
                Logger:Warn(`Record {Metadata.Id} carries property {Prop.Parent} twice. The second is not saved.`)
                continue
            end

            const Tagged = Compressor:CompressValue(Prop.Type, Prop.Value, Prop.Constraints)
            if Tagged then
                Fields[Column] = Tagged
                table.insert(Order, Column)
            end
        end

        const Layout = table.concat(Order, ",")
        local Group = ByLayout[Layout]
        if not Group then
            const Made: Group = {Key = #Groups + 1, Rows = {}, Order = Order}
            ByLayout[Layout] = Made
            table.insert(Groups, Made)
            Group = Made
        end

        const Row: RawObject = {
            __type = "RawObject",
            LocalId = Metadata.Id,
            Registry = 0,
            Fields = Fields,
        }

        table.insert(Group.Rows, Row)
    end

    return WritePack(LastId, Groups, METADATA_COMPRESSION_LEVEL)
end

function Compressor:DecompressMetadatas(CompressedMetadatas: buffer): (number, {DatabaseTypes.Metadata})
    const Version, VersionRead = Varint.Read(CompressedMetadatas, 0)
    CheckVersion(Version, "Metadata pack")

    const Metadatas: {DatabaseTypes.Metadata} = {}
    const Decode = Decoder()

    const LastId = ReadPack(CompressedMetadatas, VersionRead, function(_, Id, Fields, Order, Shared)
        const Linked = Fields[METADATA_SCENES]
        const Scenes = if Linked then Compressor:DecompressValue(Linked, 0) else nil

        const Metadata: any = {
            Id = Id,
            -- Copied rather than kept: a decoded Table is frozen, and Link and
            -- Unlink change this list on a record decoded for the purpose.
            Scenes = if type(Scenes) == "table" then table.clone(Scenes) else {},
        }

        -- Metadata does not keep what it cannot place. It is a database's own
        -- bookkeeping rather than anybody's level, and has nowhere to hold it.
        for _, Column in Order do
            const Tagged = Fields[Column]
            if Column == METADATA_SCENES or not Tagged then
                continue
            end

            const PropertyId, Value, Raw = Decode(Column, Tagged, Shared)
            if PropertyId and not Raw then
                -- Through any: Properties is the client's or the server's, and
                -- the analyser will not call a union of the two.
                const Prop = (Properties :: any).new(PropertyId)
                Prop:Set(Value)
                table.insert(Metadata, Prop)
            end
        end

        table.insert(Metadatas, Metadata)
    end)

    -- In id order across groups: the order records were created in, which is
    -- the order paging a shard relies on.
    table.sort(Metadatas, function(A: DatabaseTypes.Metadata, B: DatabaseTypes.Metadata)
        return A.Id < B.Id
    end)

    return LastId, Metadatas
end

--=============================================================================
-- Scene packs
--=============================================================================

-- Objects are grouped by type, the type's id the group's key, its columns in
-- property id order.
--
-- A RawObject is an object kept whole -- one whose type this build does not
-- have -- and goes back in exactly as it was read.
function Compressor:CompressScene(LastId: number, Objects: {ObjectTypes.Object | DecompressedObject | RawObject}): buffer
    const ByType: {[number]: {RawObject}} = {}
    for _, Obj in Objects do
        const Raw = if (Obj :: any).__type == "RawObject"
            then Obj :: RawObject
            else ToRaw(Obj :: any, true)

        local Rows = ByType[Raw.Registry]
        if not Rows then
            Rows = {}
            ByType[Raw.Registry] = Rows
        end

        table.insert(Rows :: {RawObject}, Raw)
    end

    const Groups: {Group} = {}
    for _, Registry in SortedKeys(ByType) do
        const Rows = ByType[Registry]
        const Ids: {[number]: true} = {}
        for _, Raw in Rows do
            for Id in Raw.Fields do
                Ids[Id] = true
            end
        end

        table.insert(Groups, {Key = Registry, Rows = Rows, Order = SortedKeys(Ids)})
    end

    const Pack = WritePack(LastId, Groups, SCENE_COMPRESSION_LEVEL)
    return Pack
end

function Compressor:DecompressScene(CompressedScene: buffer): (number, {DecompressedObject})
    const Version, VersionRead = Varint.Read(CompressedScene, 0)
    CheckVersion(Version, "Scene pack")

    const Objects: {DecompressedObject} = {}
    const Decode = Decoder()

    const LastId = ReadPack(CompressedScene, VersionRead, function(Registry, LocalId, Fields, Order, Shared)
        const Obj: DecompressedObject = {
            __type = "DecompressedObject",
            LocalId = LocalId,
            Registry = Registry,
            Properties = {},
            Source = {
                __type = "RawObject",
                LocalId = LocalId,
                Registry = Registry,
                Fields = Fields,
            },
        }

        for _, Id in Order do
            const Tagged = Fields[Id]
            if not Tagged then
                continue
            end

            const PropertyId, Value, Raw = Decode(Id, Tagged, Shared)
            if Raw and PropertyId then
                local Unknown = Obj.Unknown
                if not Unknown then
                    Unknown = {}
                    Obj.Unknown = Unknown
                end

                (Unknown :: {[number]: buffer})[PropertyId] = Raw
            elseif PropertyId then
                Obj.Properties[PropertyId] = Value
            end
        end

        table.insert(Objects, Obj)
    end)

    -- In local id order across types, which is the order a copy serializes
    -- them in and the order a load builds them in.
    table.sort(Objects, function(A: DecompressedObject, B: DecompressedObject)
        return A.LocalId < B.LocalId
    end)

    return LastId, Objects
end

--=============================================================================
-- Transactions
--=============================================================================

-- [/th][varint version][varint count][operations...]
--
--   create   [1][varint object type][varint scene copy][varint count][properties...]
--                [varint count][varint property id][varint operation]...
--   set      [2][varint runtime id][varint property id][tag][value]
--   destroy  [3][varint runtime id]
--   lock     [4][varint runtime id]
--   unlock   [5][varint runtime id]
--   load     [6][varint scene id]
--   unload   [7][varint scene copy]
--
-- A create's second list is its references: Object properties pointing at
-- something this same transaction creates, which cannot be written as values
-- because the ids they will hold are minted at the far end. Each entry names
-- the property and the operation whose new object it points at. Empty for
-- almost every create ever written, and one byte when it is.
--
-- The only format here that is never written to disk. It lives beside the ones
-- that are because it is the same problem -- tagged values authored by a peer
-- running a different build -- and because sharing the property writer is what
-- makes a value mean the same thing in a packet as it does in a save.
--
-- An operation of an unknown kind is refused rather than skipped. A value can be
-- stepped over knowing only its wire shape, which is what keeps an old reader
-- reading a new record; an operation cannot, and a transaction that quietly
-- drops the part it did not understand is no longer applied as a unit.
const function WriteValues(Buffers: {buffer}, Values: {[PropertyTypes.PropertyIdentifier]: any}): (number, number)
    local Size = 0
    local Count = 0

    -- Id order, like an object's properties, so the same edit always produces
    -- the same bytes -- which is what lets one history entry be compared
    -- against another rather than only replayed.
    const Keys = {}
    for Key in Values do
        table.insert(Keys, Key)
    end

    table.sort(Keys)

    -- Refused rather than skipped, unlike an object being saved. A record that
    -- drops a value it could not write is a record missing a field; a
    -- transaction that does it is a different transaction from the one the
    -- caller built, applied in full at the far end and reported as a success.
    for _, Key in Keys do
        const Registry = Properties:GetRegistry(Key)
            or Logger:Error(`Cannot write an operation carrying unregistered property id {Key}.`)

        const Written = WriteProperty(Buffers, Key, Registry.Type, Values[Key], Registry.Constraints)
        if Written == 0 then
            Logger:Error(`Cannot write {Registry.Name} as a {Registry.Type}: the value it was given cannot be encoded.`)
        end

        Size += Written
        Count += 1
    end

    return Size, Count
end

-- Throws rather than dropping, for the same reason. The caller is the author of
-- the list, not a peer, so an operation that cannot be written is a mistake to
-- be shown rather than a difference to be tolerated -- and the one thing this
-- must never do is quietly send four of five operations.
const function WriteOperation(Operation: TransactionTypes.Operation): buffer
    if Operation.Kind == "Create" then
        const Buffers = {}
        const Size, Count = WriteValues(Buffers, Operation.Properties)

        -- Sorted, like the values above and for the same reason: the same
        -- transaction has to produce the same bytes every time it is written.
        const Referenced = {}
        if Operation.References then
            for PropertyId in Operation.References do
                table.insert(Referenced, PropertyId)
            end

            table.sort(Referenced)
        end

        -- One operation index for an Object property. A Table of them writes a
        -- zero first, which no operation index can be, then one entry per item:
        -- the operation making that item's target, or zero for an item the
        -- value already holds.
        local ReferenceSize = Varint.Measure(#Referenced)
        for _, PropertyId in Referenced do
            const Names = (Operation.References :: any)[PropertyId]
            ReferenceSize += Varint.Measure(PropertyId)

            if type(Names) == "table" then
                ReferenceSize += 1 + Varint.Measure(#Names)
                for _, Entry in Names do
                    ReferenceSize += Varint.Measure(Entry)
                end
            else
                ReferenceSize += Varint.Measure(Names)
            end
        end

        const PrefixSize = 1
            + Varint.Measure(Operation.Object)
            + Varint.Measure(Operation.Instance)
            + Varint.Measure(Count)

        const Prefix = buffer.create(PrefixSize)
        buffer.writeu8(Prefix, 0, TransactionTypes.Kinds.Create)

        local At = 1 + Varint.Write(Prefix, 1, Operation.Object)
        At += Varint.Write(Prefix, At, Operation.Instance)
        Varint.Write(Prefix, At, Count)

        -- After the values rather than in the prefix, so a reader walks the
        -- properties with the count it already has and finds this where the
        -- record ends.
        const Tail = buffer.create(ReferenceSize)
        local Cursor = Varint.Write(Tail, 0, #Referenced)
        for _, PropertyId in Referenced do
            const Names = (Operation.References :: any)[PropertyId]
            Cursor += Varint.Write(Tail, Cursor, PropertyId)

            if type(Names) == "table" then
                Cursor += Varint.Write(Tail, Cursor, 0)
                Cursor += Varint.Write(Tail, Cursor, #Names)
                for _, Entry in Names do
                    Cursor += Varint.Write(Tail, Cursor, Entry)
                end
            else
                Cursor += Varint.Write(Tail, Cursor, Names)
            end
        end

        table.insert(Buffers, Tail)
        return Concat("", Prefix, Buffers, Size + ReferenceSize)
    elseif Operation.Kind == "Set" then
        const Registry = Properties:GetRegistry(Operation.Property)
            or Logger:Error(`Cannot write a set for unregistered property id {Operation.Property}.`)

        const Buffers = {}
        const Size = WriteProperty(Buffers, Operation.Property, Registry.Type, Operation.Value, Registry.Constraints)
        if Size == 0 then
            Logger:Error(`Cannot write a set of {Registry.Name}: the value it was given cannot be encoded.`)
        end

        const Prefix = buffer.create(1 + Varint.Measure(Operation.Target))
        buffer.writeu8(Prefix, 0, TransactionTypes.Kinds.Set)
        Varint.Write(Prefix, 1, Operation.Target)

        return Concat("", Prefix, Buffers, Size)
    elseif Operation.Kind == "Destroy" then
        const Encoded = buffer.create(1 + Varint.Measure(Operation.Target))
        buffer.writeu8(Encoded, 0, TransactionTypes.Kinds.Destroy)
        Varint.Write(Encoded, 1, Operation.Target)

        return Encoded
    elseif Operation.Kind == "Lock" or Operation.Kind == "Unlock" then
        const Encoded = buffer.create(1 + Varint.Measure(Operation.Target))
        buffer.writeu8(Encoded, 0, if Operation.Kind == "Lock"
            then TransactionTypes.Kinds.Lock
            else TransactionTypes.Kinds.Unlock)
        Varint.Write(Encoded, 1, Operation.Target)

        return Encoded
    elseif Operation.Kind == "Load" then
        const Encoded = buffer.create(1 + Varint.Measure(Operation.Scene))
        buffer.writeu8(Encoded, 0, TransactionTypes.Kinds.Load)
        Varint.Write(Encoded, 1, Operation.Scene)

        return Encoded
    elseif Operation.Kind == "Unload" then
        const Encoded = buffer.create(1 + Varint.Measure(Operation.Instance))
        buffer.writeu8(Encoded, 0, TransactionTypes.Kinds.Unload)
        Varint.Write(Encoded, 1, Operation.Instance)

        return Encoded
    end

    return Logger:Error(`Cannot write an operation of unknown kind {tostring((Operation :: any).Kind)}.`)
end

function Compressor:CompressTransaction(Operations: {TransactionTypes.Operation}): buffer
    const Buffers = {}
    local Size = 0
    local Count = 0

    for _, Operation in Operations do
        const Encoded = WriteOperation(Operation)

        table.insert(Buffers, Encoded)
        Size += buffer.len(Encoded)
        Count += 1
    end

    const PrefixSize = Varint.Measure(FORMAT_VERSION) + Varint.Measure(Count)
    const Prefix = buffer.create(PrefixSize)

    const At = Varint.Write(Prefix, 0, FORMAT_VERSION)
    Varint.Write(Prefix, At, Count)

    return Concat(TRANSACTION_HEADER, Prefix, Buffers, Size)
end

-- Everything below is reading bytes a client authored, so it is written to throw
-- rather than to cope: the caller runs it inside a pcall and drops the packet. A
-- truncated buffer throws out of Varint or out of buffer itself, which is the
-- same answer by a different route.
function Compressor:DecompressTransaction(CompressedTransaction: buffer): {TransactionTypes.Operation}
    if buffer.readstring(CompressedTransaction, 0, #TRANSACTION_HEADER) ~= TRANSACTION_HEADER then
        Logger:Error("Tried to decompress invalid transaction buffer.")
    end

    local Offset = #TRANSACTION_HEADER

    const Version, VersionRead = Varint.Read(CompressedTransaction, Offset)
    CheckVersion(Version, "Transaction")
    Offset += VersionRead

    const Count, CountRead = Varint.Read(CompressedTransaction, Offset)
    Offset += CountRead

    const Operations = {}

    for _ = 1, Count do
        const Kind = buffer.readu8(CompressedTransaction, Offset)
        Offset += 1

        if Kind == TransactionTypes.Kinds.Create then
            const Object, ObjectRead = Varint.Read(CompressedTransaction, Offset)
            Offset += ObjectRead

            const Live, LiveRead = Varint.Read(CompressedTransaction, Offset)
            Offset += LiveRead

            const Total, TotalRead = Varint.Read(CompressedTransaction, Offset)
            Offset += TotalRead

            const Values = {}
            for _ = 1, Total do
                -- Skipped and warned about, like restoring a saved object: a
                -- value for a property this build has never heard of is not a
                -- reason to refuse the object that carried it.
                const Id, Value, Consumed = ReadProperty(CompressedTransaction, Offset)
                Offset += Consumed

                if Id then
                    Values[Id] = Value
                end
            end

            const Referenced, ReferencedRead = Varint.Read(CompressedTransaction, Offset)
            Offset += ReferencedRead

            local References: {[PropertyTypes.PropertyIdentifier]: number | {number}}? = nil
            for _ = 1, Referenced do
                const PropertyId, PropertyRead = Varint.Read(CompressedTransaction, Offset)
                Offset += PropertyRead

                local Operation: number | {number}, OperationRead = Varint.Read(CompressedTransaction, Offset)
                Offset += OperationRead

                -- A Table of references. Every entry takes at least a byte, so
                -- a length past the bytes left is a lie, refused before a
                -- list that long is allocated for it.
                if Operation == 0 then
                    const Length, LengthRead = Varint.Read(CompressedTransaction, Offset)
                    Offset += LengthRead

                    if Length > buffer.len(CompressedTransaction) - Offset then
                        Logger:Error("A list of references claims more entries than the packet holds.")
                    end

                    const Entries = table.create(Length) :: {number}
                    for Index = 1, Length do
                        const Entry, EntryRead = Varint.Read(CompressedTransaction, Offset)
                        Offset += EntryRead
                        Entries[Index] = Entry
                    end

                    Operation = Entries
                end

                -- Kept whatever the property turns out to be. Unlike a value,
                -- which can be dropped and leave a readable record behind, a
                -- reference is a claim about another operation in this same
                -- transaction: the receiver checks it against the list it
                -- decoded and refuses the transaction if it does not hold.
                if not References then
                    References = {}
                end

                (References :: any)[PropertyId] = Operation
            end

            table.insert(Operations, {
                Kind = "Create" :: "Create",
                Object = Object,
                Instance = Live,
                Properties = Values,
                References = References,
            })
        elseif Kind == TransactionTypes.Kinds.Set then
            const Target, TargetRead = Varint.Read(CompressedTransaction, Offset)
            Offset += TargetRead

            const Property, PropertyRead = Varint.Read(CompressedTransaction, Offset)
            Offset += PropertyRead

            -- Read raw rather than through ReadProperty, which drops a value
            -- whose type has drifted and warns. Here the drift is the thing the
            -- receiver has to be told about: it decides whether the type the
            -- author wrote matches the property being set, and refuses the whole
            -- transaction when it does not.
            const Value, ValueRead, Type, ItemType = Compressor:DecompressValue(CompressedTransaction, Offset)
            Offset += ValueRead

            table.insert(Operations, {
                Kind = "Set" :: "Set",
                Target = Target,
                Property = Property,
                Value = Value,
                Type = Type,
                ItemType = ItemType,
            })
        elseif Kind == TransactionTypes.Kinds.Destroy then
            const Target, TargetRead = Varint.Read(CompressedTransaction, Offset)
            Offset += TargetRead

            table.insert(Operations, {
                Kind = "Destroy" :: "Destroy",
                Target = Target,
            })
        elseif Kind == TransactionTypes.Kinds.Lock or Kind == TransactionTypes.Kinds.Unlock then
            const Target, TargetRead = Varint.Read(CompressedTransaction, Offset)
            Offset += TargetRead

            -- Two literals rather than one with a union Kind: the solver will not
            -- match {Kind: "Lock" | "Unlock"} against either operation alone.
            table.insert(Operations, if Kind == TransactionTypes.Kinds.Lock
                then {Kind = "Lock" :: "Lock", Target = Target}
                else {Kind = "Unlock" :: "Unlock", Target = Target})
        elseif Kind == TransactionTypes.Kinds.Load then
            const Scene, SceneRead = Varint.Read(CompressedTransaction, Offset)
            Offset += SceneRead

            table.insert(Operations, {
                Kind = "Load" :: "Load",
                Scene = Scene,
            })
        elseif Kind == TransactionTypes.Kinds.Unload then
            const Instance_, InstanceRead = Varint.Read(CompressedTransaction, Offset)
            Offset += InstanceRead

            table.insert(Operations, {
                Kind = "Unload" :: "Unload",
                Instance = Instance_,
            })
        else
            Logger:Error(`Transaction carries an operation of unknown kind {Kind}.`)
        end
    end

    return Operations
end

return Compressor
