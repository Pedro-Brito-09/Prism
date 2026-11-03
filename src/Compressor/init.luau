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
-- UpdateAsync transforms, an unreadable record bricks the key.
--
-- Numbers pick their encoding from the value, not from the schema. A whole
-- number becomes a varint, a fractional one that survives f32 becomes four
-- bytes, anything else becomes eight. That is why changing AllowDecimals cannot
-- corrupt anything: the bytes describe themselves. It also keeps integers out
-- of f32, whose 24 bit mantissa silently mangles any integer past 16,777,216 --
-- user ids and unix timestamps included.

const RunService = game:GetService("RunService")

const Properties = if RunService:IsClient()
    then require("./Properties/Client")
    else require("./Properties/Server")

const PropertyTypes = require("./Properties/Types")
const Handles = require("./Handles")
const DatabaseTypes = require("./Database/Types")
const ObjectTypes = require("./Objects/Types")
const TransactionTypes = require("./Transactions/Types")
const Varint = require("./Varint")
const Logger = require("./Logger")
const Format = require("@self/Format")
const Packs = require("@self/Packs")

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

export type RawObject = Format.RawObject
export type Insert = Packs.Insert
export type Inserts = Packs.Inserts
type Column = Packs.Column
type Group = Packs.Group

const OBJECT_HEADER = "/oh"

-- A packet rather than a record, and the only header here that never reaches
-- storage. See the Transactions section.
const TRANSACTION_HEADER = "/th"

const FORMAT_VERSION = Format.FORMAT_VERSION
const WriteProperty = Format.WriteProperty
const ReadProperty = Format.ReadProperty
const Concat = Format.Concat
const CheckVersion = Format.CheckVersion

const SCENE_COMPRESSION_LEVEL = Packs.SCENE_COMPRESSION_LEVEL
const METADATA_COMPRESSION_LEVEL = Packs.METADATA_COMPRESSION_LEVEL
const PACK_INSERTS = Packs.PACK_INSERTS
const NewWriter = Packs.NewWriter
const PutVarint = Packs.PutVarint
const PutBuffer = Packs.PutBuffer
const Finish = Packs.Finish
const PutInserts = Packs.PutInserts
const ReadInsertList = Packs.ReadInsertList
const WritePack = Packs.WritePack
const ReadPack = Packs.ReadPack
const Decoder = Packs.Decoder

const Compressor = {}

--=============================================================================
-- Values
--=============================================================================

-- A value as a self contained buffer: tag byte followed by the encoded value.
-- See Format for the encoding.
function Compressor:CompressValue(Type: PropertyTypes.PropertyType, Value: any?, Constraints: any?): buffer?
    return Format:CompressValue(Type, Value, Constraints)
end

function Compressor:DecompressValue(Buf: buffer, Offset: number?): (any?, number, PropertyTypes.PropertyType?, PropertyTypes.PropertyType?)
    return Format:DecompressValue(Buf, Offset)
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

        const Tagged = Format:CompressValue(Type, Value, Constraints)
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
            Fields[METADATA_SCENES] = Format:CompressValue("Table", Metadata.Scenes, SCENES_CONSTRAINTS) :: buffer
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

            const Tagged = Format:CompressValue(Prop.Type, Prop.Value, Prop.Constraints)
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
        const Scenes = if Linked then Format:DecompressValue(Linked, 0) else nil

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
-- A scene pack's header, up to where its payload starts.
const function ReadSceneHeader(Pack: buffer): (number, number, number, Inserts, number)
    const Version, VersionRead = Varint.Read(Pack, 0)
    CheckVersion(Version, "Scene pack")

    const Flags, FlagsRead = Varint.Read(Pack, VersionRead)
    const LastId, LastIdRead = Varint.Read(Pack, VersionRead + FlagsRead)
    const At = VersionRead + FlagsRead + LastIdRead

    if bit32.band(Flags, PACK_INSERTS) ~= 0 then
        const Inserts, After = ReadInsertList(Pack, At)
        return Version, Flags, LastId, Inserts, After
    end

    return Version, Flags, LastId, {Last = 0, List = {}}, At
end

-- The scenes inserted into a pack, read off its header without touching the
-- payload, so asking costs nothing on a level of any size.
function Compressor:ReadInserts(Pack: buffer?): Inserts
    if not Pack then
        return {Last = 0, List = {}}
    end

    const _, _, _, Inserts = ReadSceneHeader(Pack)
    return Inserts
end

-- The same pack with other inserts in its header. The payload is copied across
-- as it stands, compressed or not.
function Compressor:WithInserts(Pack: buffer, Inserts: Inserts): buffer
    const Version, Flags, LastId, _, Payload = ReadSceneHeader(Pack)

    const Carries = Inserts.Last > 0
    const Out = NewWriter()
    PutVarint(Out, Version)
    PutVarint(Out, if Carries then bit32.bor(Flags, PACK_INSERTS) else bit32.band(Flags, bit32.bnot(PACK_INSERTS)))
    PutVarint(Out, LastId)

    if Carries then
        PutInserts(Out, Inserts)
    end

    PutBuffer(Out, Pack, Payload, buffer.len(Pack) - Payload)
    return Finish(Out)
end

function Compressor:CompressScene(
    LastId: number,
    Objects: {ObjectTypes.Object | DecompressedObject | RawObject},
    Inserts: Inserts?
): buffer
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

    const Pack = WritePack(LastId, Groups, SCENE_COMPRESSION_LEVEL, Inserts)
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
            const Value, ValueRead, Type, ItemType = Format:DecompressValue(CompressedTransaction, Offset)
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
