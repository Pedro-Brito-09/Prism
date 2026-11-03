--!strict
-- Packs: the columnar layout a scene's objects and a database shard's records
-- are stored as. Built on the tagged values in Format.

const EncodingService = game:GetService("EncodingService")

const PropertyTypes = require("../Properties/Types")
const Varint = require("../Varint")
const Logger = require("../Logger")
const Format = require("./Format")

type RawObject = Format.RawObject

const FORMAT_VERSION = Format.FORMAT_VERSION
const WIRE_VARINT = Format.WIRE_VARINT
const WIRE_FIXED12 = Format.WIRE_FIXED12
const WIRE_BYTES = Format.WIRE_BYTES
const Probe = Format.Probe
const MakeTag = Format.MakeTag
const ReadTagged = Format.ReadTagged
const Slice = Format.Slice
const TaggedLength = Format.TaggedLength

const Packs = {}

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

-- The header carries the scenes inserted into this one. A flag and not a version,
-- so a pack with none is byte for byte what it was, and a build from before them
-- refuses one that has them with a message, by the unknown flag check in ReadPack.
const PACK_INSERTS = 2
const PACK_FLAGS = PACK_COMPRESSED + PACK_INSERTS

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

const BOOL_FALSE = Format:CompressValue("Bool", false) :: buffer
const BOOL_TRUE = Format:CompressValue("Bool", true) :: buffer
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

export type Column = {
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
export type Group = {Key: number, Rows: {RawObject}, Order: {number}}

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
-- The scenes inserted into a scene: the source's Guid, where it sits in this
-- scene's local space, and an id. Last only climbs and is saved, because an
-- address names an insert by id, so an id handed out twice would point an old
-- reference at a new insert, as a local id would.
--
-- In the header, outside the compressed payload, so inserting a scene into a
-- level rewrites a few bytes rather than decompressing and packing it again.
export type Insert = {Id: number, Guid: string, Origin: CFrame}
export type Inserts = {Last: number, List: {Insert}}

--   [varint last][varint count]([varint id][varint length][guid][12 f32 origin])...
const function PutInserts(W: Writer, Inserts: Inserts)
    PutVarint(W, Inserts.Last)
    PutVarint(W, #Inserts.List)

    for _, Entry in Inserts.List do
        PutVarint(W, Entry.Id)
        PutVarint(W, #Entry.Guid)
        PutBuffer(W, buffer.fromstring(Entry.Guid))

        const Origin = buffer.create(48)
        for Index, Component in {Entry.Origin:GetComponents()} do
            buffer.writef32(Origin, (Index - 1) * 4, Component)
        end

        PutBuffer(W, Origin)
    end
end

const function ReadInsertList(Buf: buffer, Offset: number): (Inserts, number)
    local At = Offset

    const Last, LastRead = Varint.Read(Buf, At)
    At += LastRead

    const Count, CountRead = Varint.Read(Buf, At)
    At += CountRead

    const List: {Insert} = {}
    for _ = 1, Count do
        const Id, IdRead = Varint.Read(Buf, At)
        At += IdRead

        const Length, LengthRead = Varint.Read(Buf, At)
        At += LengthRead

        const Guid = buffer.readstring(Buf, At, Length)
        At += Length

        const C = table.create(12) :: {number}
        for Index = 1, 12 do
            C[Index] = buffer.readf32(Buf, At + (Index - 1) * 4)
        end
        At += 48

        table.insert(List, {
            Id = Id,
            Guid = Guid,
            Origin = CFrame.new(C[1], C[2], C[3], C[4], C[5], C[6], C[7], C[8], C[9], C[10], C[11], C[12]),
        })
    end

    return {Last = Last, List = List}, At
end

const function WritePack(LastId: number, Groups: {Group}, Level: number, Inserts: Inserts?): (buffer, number)
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

    -- Last as well as the list: an emptied scene still has to remember which
    -- ids it has spent.
    const Carries = Inserts ~= nil and Inserts.Last > 0
    if Carries then
        Flags += PACK_INSERTS
    end

    const Out = NewWriter()
    PutVarint(Out, FORMAT_VERSION)
    PutVarint(Out, Flags)
    PutVarint(Out, LastId)

    if Carries then
        PutInserts(Out, Inserts :: Inserts)
    end

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

    if bit32.band(Flags, PACK_INSERTS) ~= 0 then
        const _, After = ReadInsertList(Pack, At)
        At = After
    end

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

Packs.SCENE_COMPRESSION_LEVEL = SCENE_COMPRESSION_LEVEL
Packs.METADATA_COMPRESSION_LEVEL = METADATA_COMPRESSION_LEVEL
Packs.PACK_INSERTS = PACK_INSERTS
Packs.NewWriter = NewWriter
Packs.PutVarint = PutVarint
Packs.PutBuffer = PutBuffer
Packs.Finish = Finish
Packs.PutInserts = PutInserts
Packs.ReadInsertList = ReadInsertList
Packs.WritePack = WritePack
Packs.ReadPack = ReadPack
Packs.Decoder = Decoder

return Packs
