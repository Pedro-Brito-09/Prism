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
const Logger = require("./Logger")

export type DecompressedObject = {
    __type: "DecompressedObject",

    -- The object's id within its scene, not the whole persistent id: the scene
    -- half is stamped on at load, which is what lets the same pack be loaded
    -- under two different scenes without the two colliding.
    LocalId: Handles.LocalId,

    Parent: ObjectTypes.ObjectIdentifier,
    Properties: {[PropertyTypes.PropertyIdentifier]: any},
}

const OBJECT_HEADER = "/oh"
const METADATA_HEADER = "/mh"
const PACK_HEADER = "/ph"

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
function Compressor:CompressValue(Type: PropertyTypes.PropertyType, Value: any?): buffer?
    if Value == nil then
        return nil
    end

    const TypeId = PropertyTypes:GetTypeId(Type)
    if not TypeId then
        Logger:Error(`Tried compressing unsupported value type: {Type}`)
    end

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
        buffer.writeu8(Payload, 0, math.floor(Value.R * 255))
        buffer.writeu8(Payload, 1, math.floor(Value.G * 255))
        buffer.writeu8(Payload, 2, math.floor(Value.B * 255))
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
    else
        Logger:Error(`Tried compressing unsupported value type: {Type}`)
    end

    const Length = buffer.len(Payload)
    const Out = buffer.create(1 + Length)
    buffer.writeu8(Out, 0, MakeTag(Wire, TypeId))
    buffer.copy(Out, 1, Payload, 0)
    return Out
end

-- Reads the tag itself, so the caller does not have to know what it is reading.
-- Returns the value, how many bytes it consumed, and the semantic type the
-- writer recorded, which the caller can compare against what it expected.
function Compressor:DecompressValue(Buf: buffer, Offset: number?): (any?, number, PropertyTypes.PropertyType?)
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
        const Components = table.create(12)
        for Index = 1, 12 do
            Components[Index] = buffer.readf32(Buf, Body + (Index - 1) * 4)
        end

        return CFrame.new(table.unpack(Components, 1, 12)), 49, Type
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

        const Registered = CustomEnum:GetEnum(Name)
        if not Registered then
            return CustomEnum.UNKNOWN, Consumed, Type
        end

        return Registered:GetById(Id) or CustomEnum.UNKNOWN, Consumed, Type
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
    Value: any?
): number
    const Tagged = Compressor:CompressValue(Type, Value)
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

const function ReadProperty(Buf: buffer, Offset: number): (PropertyTypes.PropertyIdentifier?, any?, number)
    const PropertyId, IdRead = Varint.Read(Buf, Offset)
    const Value, ValueRead, Type = Compressor:DecompressValue(Buf, Offset + IdRead)
    const Consumed = IdRead + ValueRead

    const Registry = Properties:GetRegistry(PropertyId)
    if not Registry then
        Logger:Warn(`Skipping unregistered property id {PropertyId}.`)
        return nil, nil, Consumed
    end

    if not Type then
        Logger:Warn(`Property {PropertyId} was saved with a type this build does not know. Skipping.`)
        return nil, nil, Consumed
    end

    -- The registry changed type since the save. The bytes were still read
    -- correctly, so the record continues; only this value is dropped.
    if Registry.Type ~= Type then
        Logger:Warn(`Property {PropertyId} was saved as {Type} but is registered as {Registry.Type}. Skipping.`)
        return nil, nil, Consumed
    end

    return PropertyId, Value, Consumed
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
function Compressor:CompressObject(Obj: ObjectTypes.Object | DecompressedObject): buffer
    local Size = 0
    local Count = 0
    const Buffers = {}
    const IsDecompressed = (Obj :: any).__type == "DecompressedObject"

    -- Walked in id order rather than hash order, so the same object always
    -- produces the same bytes. Hash order meant two identical objects serialized
    -- differently, which rules out hashing, diffing or deduplicating saves.
    const Keys = {}
    for Key in (Obj :: any).Properties do
        table.insert(Keys, Key)
    end

    table.sort(Keys)

    for _, Key in Keys do
        const Entry = (Obj :: any).Properties[Key]
        local Id, Type, Value

        if IsDecompressed then
            const Registry = Properties:GetRegistry(Key)
            if not Registry then
                Logger:Warn(`Tried compressing an object with unregistered property id {Key}. Skipping.`)
                continue
            end

            Id, Type, Value = Key, Registry.Type, Entry
        else
            Id, Type, Value = Entry.Parent, Entry.Type, Entry.Value
        end

        const Written = WriteProperty(Buffers, Id, Type, Value)
        if Written > 0 then
            Size += Written
            Count += 1
        end
    end

    const LocalId = if IsDecompressed
        then (Obj :: DecompressedObject).LocalId
        else (Obj :: ObjectTypes.Object).LocalId

    const PrefixSize = Varint.Measure(FORMAT_VERSION)
        + Varint.Measure(Obj.Parent)
        + Varint.Measure(LocalId)
        + Varint.Measure(Count)

    const Prefix = buffer.create(PrefixSize)

    local At = Varint.Write(Prefix, 0, FORMAT_VERSION)
    At += Varint.Write(Prefix, At, Obj.Parent)
    At += Varint.Write(Prefix, At, LocalId)
    Varint.Write(Prefix, At, Count)

    return Concat(OBJECT_HEADER, Prefix, Buffers, Size)
end

function Compressor:DecompressObject(CompressedObj: buffer): DecompressedObject
    if buffer.readstring(CompressedObj, 0, #OBJECT_HEADER) ~= OBJECT_HEADER then
        Logger:Error("Tried to decompress invalid object buffer.")
    end

    local Offset = #OBJECT_HEADER

    const Version, VersionRead = Varint.Read(CompressedObj, Offset)
    CheckVersion(Version, "Object")
    Offset += VersionRead

    const Parent, ParentRead = Varint.Read(CompressedObj, Offset)
    Offset += ParentRead

    const LocalId, LocalIdRead = Varint.Read(CompressedObj, Offset)
    Offset += LocalIdRead

    const Count, CountRead = Varint.Read(CompressedObj, Offset)
    Offset += CountRead

    const Obj: DecompressedObject = {
        __type = "DecompressedObject",
        LocalId = LocalId,
        Parent = Parent,
        Properties = {},
    }

    for _ = 1, Count do
        const Id, Value, Consumed = ReadProperty(CompressedObj, Offset)
        Offset += Consumed

        if Id then
            Obj.Properties[Id] = Value
        end
    end

    return Obj
end

--=============================================================================
-- Metadata
--=============================================================================

-- [/mh][varint id][varint saved][varint published][varint count][properties...]
-- The format version lives on the containing pack rather than on every record.
function Compressor:CompressMetadata(Metadata: DatabaseTypes.Metadata): buffer
    local Size = 0
    local Count = 0
    const Buffers = {}

    for Index, Prop in Metadata do
        if type(Index) ~= "number" then
            continue
        end

        const Written = WriteProperty(Buffers, Prop.Parent, Prop.Type, Prop.Value)
        if Written > 0 then
            Size += Written
            Count += 1
        end
    end

    const PrefixSize = Varint.Measure(Metadata.Id)
        + Varint.Measure(Metadata.SavedVersion)
        + Varint.Measure(Metadata.PublishedVersion)
        + Varint.Measure(Count)

    const Prefix = buffer.create(PrefixSize)
    local At = Varint.Write(Prefix, 0, Metadata.Id)
    At += Varint.Write(Prefix, At, Metadata.SavedVersion)
    At += Varint.Write(Prefix, At, Metadata.PublishedVersion)
    Varint.Write(Prefix, At, Count)

    return Concat(METADATA_HEADER, Prefix, Buffers, Size)
end

function Compressor:DecompressMetadata(CompressedMetadata: buffer): DatabaseTypes.Metadata
    if buffer.readstring(CompressedMetadata, 0, #METADATA_HEADER) ~= METADATA_HEADER then
        Logger:Error("Tried to decompress invalid metadata buffer.")
    end

    local Offset = #METADATA_HEADER

    const Id, IdRead = Varint.Read(CompressedMetadata, Offset)
    Offset += IdRead

    const Saved, SavedRead = Varint.Read(CompressedMetadata, Offset)
    Offset += SavedRead

    const Published, PublishedRead = Varint.Read(CompressedMetadata, Offset)
    Offset += PublishedRead

    const Count, CountRead = Varint.Read(CompressedMetadata, Offset)
    Offset += CountRead

    const Metadata = {
        Id = Id,
        SavedVersion = Saved,
        PublishedVersion = Published,
    }

    for _ = 1, Count do
        const PropertyId, Value, Consumed = ReadProperty(CompressedMetadata, Offset)
        Offset += Consumed

        if PropertyId then
            const Prop = Properties.new(PropertyId)
            Prop:Set(Value)
            table.insert(Metadata, Prop)
        end
    end

    return Metadata :: any
end

--=============================================================================
-- Packing
--=============================================================================

-- [/ph][varint count][[varint length][bytes]...]
function Compressor:PackBuffers(Buffers: {buffer}): buffer
    local Size = 0
    for _, Part in Buffers do
        const Length = buffer.len(Part)
        Size += Varint.Measure(Length) + Length
    end

    const CountSize = Varint.Measure(#Buffers)
    const Pack = buffer.create(#PACK_HEADER + CountSize + Size)
    buffer.writestring(Pack, 0, PACK_HEADER)
    Varint.Write(Pack, #PACK_HEADER, #Buffers)

    local Offset = #PACK_HEADER + CountSize
    for _, Part in Buffers do
        const Length = buffer.len(Part)
        Offset += Varint.Write(Pack, Offset, Length)
        buffer.copy(Pack, Offset, Part, 0)
        Offset += Length
    end

    return Pack
end

function Compressor:UnpackBuffers(PackedBuffers: buffer, Offset: number?): {buffer}
    local At = Offset or 0
    if buffer.readstring(PackedBuffers, At, #PACK_HEADER) ~= PACK_HEADER then
        Logger:Error("Tried to unpack invalid buffer pack.")
    end

    At += #PACK_HEADER

    const Count, CountRead = Varint.Read(PackedBuffers, At)
    At += CountRead

    const Unpacked = table.create(Count)
    for Index = 1, Count do
        const Length, LengthRead = Varint.Read(PackedBuffers, At)
        At += LengthRead

        const Slice = buffer.create(Length)
        buffer.copy(Slice, 0, PackedBuffers, At, Length)
        Unpacked[Index] = Slice
        At += Length
    end

    return Unpacked
end

-- [varint version][varint last id][pack of metadata buffers]
function Compressor:CompressMetadatas(LastId: number, Metadatas: {DatabaseTypes.Metadata}): buffer
    const Compressed = table.create(#Metadatas)
    for Index, Metadata in Metadatas do
        Compressed[Index] = Compressor:CompressMetadata(Metadata)
    end

    const Packed = Compressor:PackBuffers(Compressed)
    const PrefixSize = Varint.Measure(FORMAT_VERSION) + Varint.Measure(LastId)

    const Result = buffer.create(PrefixSize + buffer.len(Packed))
    const At = Varint.Write(Result, 0, FORMAT_VERSION)
    Varint.Write(Result, At, LastId)
    buffer.copy(Result, PrefixSize, Packed, 0)
    return Result
end

function Compressor:DecompressMetadatas(CompressedMetadatas: buffer): (number, {DatabaseTypes.Metadata})
    const Version, VersionRead = Varint.Read(CompressedMetadatas, 0)
    CheckVersion(Version, "Metadata pack")

    const LastId, LastIdRead = Varint.Read(CompressedMetadatas, VersionRead)
    const Metadatas = {}

    for _, Compressed in Compressor:UnpackBuffers(CompressedMetadatas, VersionRead + LastIdRead) do
        table.insert(Metadatas, Compressor:DecompressMetadata(Compressed))
    end

    return LastId, Metadatas
end

--=============================================================================
-- Scenes
--=============================================================================

-- [varint version][varint last id][pack of object buffers]
--
-- The same shape as a metadata pack, and for the same reason: LastId is what
-- stops a scene reopening a local id after the object holding it is gone.
-- Without it, unload and load would restart the counter and the second object
-- ever created would answer to the name the first one was saved under.
function Compressor:CompressScene(LastId: number, Objects: {ObjectTypes.Object | DecompressedObject}): buffer
    const Compressed = table.create(#Objects)
    for Index, Obj in Objects do
        Compressed[Index] = Compressor:CompressObject(Obj)
    end

    const Packed = Compressor:PackBuffers(Compressed)
    const PrefixSize = Varint.Measure(FORMAT_VERSION) + Varint.Measure(LastId)

    const Result = buffer.create(PrefixSize + buffer.len(Packed))
    const At = Varint.Write(Result, 0, FORMAT_VERSION)
    Varint.Write(Result, At, LastId)
    buffer.copy(Result, PrefixSize, Packed, 0)
    return Result
end

function Compressor:DecompressScene(CompressedScene: buffer): (number, {DecompressedObject})
    const Version, VersionRead = Varint.Read(CompressedScene, 0)
    CheckVersion(Version, "Scene pack")

    const LastId, LastIdRead = Varint.Read(CompressedScene, VersionRead)
    const Objects = {}

    for _, Compressed in Compressor:UnpackBuffers(CompressedScene, VersionRead + LastIdRead) do
        table.insert(Objects, Compressor:DecompressObject(Compressed))
    end

    return LastId, Objects
end

--=============================================================================
-- Transactions
--=============================================================================

-- [/th][varint version][varint count][operations...]
--
--   create   [1][varint object type][varint scene copy][varint count][properties...]
--   set      [2][varint runtime id][varint property id][tag][value]
--   destroy  [3][varint runtime id]
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
        if not Registry then
            Logger:Error(`Cannot write an operation carrying unregistered property id {Key}.`)
        end

        const Written = WriteProperty(Buffers, Key, Registry.Type, Values[Key])
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

        const PrefixSize = 1
            + Varint.Measure(Operation.Object)
            + Varint.Measure(Operation.Instance)
            + Varint.Measure(Count)

        const Prefix = buffer.create(PrefixSize)
        buffer.writeu8(Prefix, 0, TransactionTypes.Kinds.Create)

        local At = 1 + Varint.Write(Prefix, 1, Operation.Object)
        At += Varint.Write(Prefix, At, Operation.Instance)
        Varint.Write(Prefix, At, Count)

        return Concat("", Prefix, Buffers, Size)
    elseif Operation.Kind == "Set" then
        const Registry = Properties:GetRegistry(Operation.Property)
        if not Registry then
            Logger:Error(`Cannot write a set for unregistered property id {Operation.Property}.`)
        end

        const Buffers = {}
        const Size = WriteProperty(Buffers, Operation.Property, Registry.Type, Operation.Value)
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
    end

    Logger:Error(`Cannot write an operation of unknown kind {tostring((Operation :: any).Kind)}.`)
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

            table.insert(Operations, {
                Kind = "Create" :: "Create",
                Object = Object,
                Instance = Live,
                Properties = Values,
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
            const Value, ValueRead, Type = Compressor:DecompressValue(CompressedTransaction, Offset)
            Offset += ValueRead

            table.insert(Operations, {
                Kind = "Set" :: "Set",
                Target = Target,
                Property = Property,
                Value = Value,
                Type = Type,
            })
        elseif Kind == TransactionTypes.Kinds.Destroy then
            const Target, TargetRead = Varint.Read(CompressedTransaction, Offset)
            Offset += TargetRead

            table.insert(Operations, {
                Kind = "Destroy" :: "Destroy",
                Target = Target,
            })
        else
            Logger:Error(`Transaction carries an operation of unknown kind {Kind}.`)
        end
    end

    return Operations
end

return Compressor
