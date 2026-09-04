--!strict
--[[
    Loom test suite -- server half.

    Put this in ServerScriptService, put Harness.luau at
    ReplicatedStorage/LoomTests/Harness, and point LOOM below at wherever you
    synced src/. Run it alongside LoomTest.client.luau with one test player.

    The Database section is off by default: it writes to real DataStore and
    MemoryStore keys and needs Studio API access enabled. Turn RUN_DATABASE on
    when you want it. It uses its own throwaway key and removes it afterwards.
]]

const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerStorage = game:GetService("ServerStorage")

const LOOM = ReplicatedStorage:WaitForChild("Loom")
const RUN_DATABASE = false
const DATABASE_KEY = "LoomSelfTest"

const Loom = require(LOOM)
const Harness = require(ReplicatedStorage:WaitForChild("LoomTests"):WaitForChild("Harness"))

const Networking = Loom.Networking
const Properties = Loom.Properties
const PropertyTypes = require(LOOM.Properties.Types)
const Compressor = Loom.Compressor
const Permissions = Loom.Permissions
const CustomEnum = Loom.CustomEnum
const Encoding = Loom.Encoding
const Objects = Loom.Objects
const IdPool = Loom.IdPool
const Codecs = Loom.Codecs
const Varint = Loom.Varint
const Try = Loom.Try

const T = Harness.new()

--=============================================================================
-- Varint
--=============================================================================

T:Describe("Varint")

T:Test("round trips across byte boundaries", function()
    const Cases = {0, 1, 127, 128, 129, 16383, 16384, 2097151, 2097152, 1e9, Varint.MAX_SAFE}
    const Buf = buffer.create(16)

    for _, Value in Cases do
        const Written = Varint.Write(Buf, 0, Value)
        const Read, Consumed = Varint.Read(Buf, 0)

        T:Eq(Read, Value, `value {Value}`)
        T:Eq(Consumed, Written, `consumed for {Value}`)
        T:Eq(Written, Varint.Measure(Value), `measure agrees for {Value}`)
    end
end)

T:Test("uses the expected widths", function()
    T:Eq(Varint.Measure(0), 1, "zero")
    T:Eq(Varint.Measure(127), 1, "127")
    T:Eq(Varint.Measure(128), 2, "128")
    T:Eq(Varint.Measure(16383), 2, "16383")
    T:Eq(Varint.Measure(16384), 3, "16384")
end)

T:Test("zigzag keeps small negatives small", function()
    T:Eq(Varint.Zigzag(0), 0, "0")
    T:Eq(Varint.Zigzag(-1), 1, "-1")
    T:Eq(Varint.Zigzag(1), 2, "1")
    T:Eq(Varint.Zigzag(-2), 3, "-2")
    T:Eq(Varint.MeasureSigned(-1), 1, "-1 is one byte")

    const Buf = buffer.create(16)
    for _, Value in {0, -1, 1, -63, 63, -1e6, 1e6, Varint.MAX_SIGNED, -Varint.MAX_SIGNED - 1} do
        const Written = Varint.WriteSigned(Buf, 0, Value)
        const Read, Consumed = Varint.ReadSigned(Buf, 0)
        T:Eq(Read, Value, `signed {Value}`)
        T:Eq(Consumed, Written, `signed consumed {Value}`)
    end
end)

T:Test("rejects what it cannot represent", function()
    const Buf = buffer.create(16)
    T:Throws(function() Varint.Write(Buf, 0, -1) end, "negative")
    T:Throws(function() Varint.Write(Buf, 0, 1.5) end, "fractional")
    T:Throws(function() Varint.Write(Buf, 0, Varint.MAX_SAFE * 4) end, "past 2^53")
end)

T:Test("refuses a runaway varint", function()
    const Buf = buffer.create(16)
    for Index = 0, 15 do
        buffer.writeu8(Buf, Index, 255) -- continuation bit set forever
    end

    T:Throws(function() Varint.Read(Buf, 0) end, "no terminator")
end)

--=============================================================================
-- Codecs
--=============================================================================

T:Describe("Codecs")

const function RoundTrip(Codec, Value, What: string)
    const Extras = {}
    const Size = Codec.Measure(Value)
    const Buf = buffer.create(math.max(Size, 1))

    const Written = Codec.Write(Buf, 0, Value, Extras)
    T:Eq(Written, Size, `{What}: measure agrees with write`)

    const Read, Consumed = Codec.Read(Buf, 0, Extras)
    T:Eq(Consumed, Written, `{What}: consumed agrees`)
    return Read
end

T:Test("fixed width codecs round trip", function()
    T:Eq(RoundTrip(Codecs.u8, 200, "u8"), 200)
    T:Eq(RoundTrip(Codecs.u16, 65535, "u16"), 65535)
    T:Eq(RoundTrip(Codecs.u32, 4294967295, "u32"), 4294967295)
    T:Eq(RoundTrip(Codecs.i16, -300, "i16"), -300)
    T:Eq(RoundTrip(Codecs.f64, 0.1, "f64"), 0.1)
    T:Eq(RoundTrip(Codecs.Bool, true, "bool true"), true)
    T:Eq(RoundTrip(Codecs.Bool, false, "bool false"), false)
end)

T:Test("variable width codecs round trip", function()
    T:Eq(RoundTrip(Codecs.Varint, 300, "varint"), 300)
    T:Eq(RoundTrip(Codecs.SignedVarint, -300, "signed varint"), -300)
    T:Eq(RoundTrip(Codecs.String, "hello", "string"), "hello")
    T:Eq(RoundTrip(Codecs.String, "", "empty string"), "")
    T:Eq(RoundTrip(Codecs.LongString, string.rep("x", 70000), "long string"):len(), 70000)
end)

T:Test("roblox datatype codecs round trip", function()
    T:Eq(RoundTrip(Codecs.Vector, Vector3.new(1, 2, 3), "vector"), Vector3.new(1, 2, 3))
    T:Eq(RoundTrip(Codecs.Color, Color3.fromRGB(10, 20, 30), "color"), Color3.fromRGB(10, 20, 30))

    const Frame = CFrame.new(1, 2, 3)
    const Back = RoundTrip(Codecs.CFrame, Frame, "cframe")
    T:Ok((Back.Position - Frame.Position).Magnitude < 1e-4, "cframe position")
end)

T:Test("buffer codec preserves bytes", function()
    const Source = buffer.create(4)
    buffer.writeu32(Source, 0, 123456)

    const Back = RoundTrip(Codecs.Buffer, Source, "buffer")
    T:Eq(buffer.len(Back), 4, "length")
    T:Eq(buffer.readu32(Back, 0), 123456, "contents")
end)

T:Test("Any rides the side channel and survives nil", function()
    const Part = Instance.new("Part")

    const Extras = {}
    const Buf = buffer.create(4)
    const A = Codecs.Any.Write(Buf, 0, Part, Extras)
    const B = Codecs.Any.Write(Buf, A, nil, Extras)

    T:Eq(#Extras, 1, "nil does not take a slot")
    T:Eq((Codecs.Any.Read(Buf, 0, Extras)), Part, "instance")
    T:Eq((Codecs.Any.Read(Buf, A, Extras)), nil, "nil")
    T:Eq(A + B, 4, "two bytes each")

    Part:Destroy()
end)

T:Test("Optional distinguishes nil from a value", function()
    const Inner = Codecs.Optional(Codecs.u16)
    T:Eq(RoundTrip(Inner, 500, "optional present"), 500)
    T:Eq(RoundTrip(Inner, nil, "optional absent"), nil)
    T:Eq(Inner.Measure(nil), 1, "absent costs one byte")
end)

T:Test("Array round trips including empty", function()
    const Inner = Codecs.Array(Codecs.Varint)
    const Back = RoundTrip(Inner, {1, 128, 70000}, "array")
    T:Eq(#Back, 3, "count")
    T:Eq(Back[2], 128, "second")
    T:Eq(Back[3], 70000, "third")
    T:Eq(#RoundTrip(Inner, {}, "empty array"), 0, "empty")
end)

--=============================================================================
-- Networking manifest
--=============================================================================

T:Describe("Networking")

T:Test("channel lookups are stable", function()
    const First = Networking:Get("Loom.Ready")
    const Second = Networking:Get("Loom.Ready")
    T:Eq(First, Second, "same manifest entry")
    T:Eq(First.Name, "Loom.Ready", "channel name")
    T:Ok(First.Id > 0 and First.Id <= 255, "channel id fits the packet header")
end)

T:Test("unknown channels are rejected", function()
    T:Throws(function()
        Networking:Get("Tests.DoesNotExist")
    end, "unknown channel")
end)

T:Test("schema arity is checked before transport", function()
    const Removed = Networking:Get("Objects.ObjectRemoved")
    T:Throws(function()
        Removed:FireAll(1, 2)
    end, "too many arguments")
end)

T:Test("server-to-client invokes are rejected", function()
    T:Throws(function()
        Networking:Get("Loom.Ready"):Invoke()
    end, "server invoke")
end)

T:Test("connections disconnect idempotently", function()
    const Ready = Networking:Get("Loom.Ready")
    const Before = #Ready.Connections
    const Disconnect = Ready:Connect(function() end)

    T:Eq(#Ready.Connections, Before + 1, "connected")
    Disconnect()
    Disconnect()
    T:Eq(#Ready.Connections, Before, "disconnected once")
end)

--=============================================================================
-- IdPool
--=============================================================================

T:Describe("IdPool")

T:Test("hands out sequential ids", function()
    const Pool = IdPool.new()
    T:Eq(Pool:Claim(), 1, "first")
    T:Eq(Pool:Claim(), 2, "second")
    T:Eq(Pool:Claim(), 3, "third")
end)

T:Test("reuses a released id when recycling", function()
    const Pool = IdPool.new(nil, true)
    Pool:Claim()
    Pool:Claim()
    Pool:Release(1)

    T:Ok(not Pool:IsUsed(1), "released")
    T:Eq(Pool:Claim(), 1, "reused")
end)

T:Test("never reuses when recycling is off", function()
    const Pool = IdPool.new(nil, false)
    Pool:Claim()
    Pool:Claim()
    Pool:Release(1)

    T:Eq(Pool:Claim(), 3, "moved past the hole")
end)

T:Test("honours a custom id and refuses a duplicate", function()
    const Pool = IdPool.new()
    T:Eq(Pool:Claim(50), 50, "custom")
    T:Eq(Pool:Claim(50), nil, "duplicate refused")
    T:Eq(Pool:Claim(), 51, "counter moved past it")
end)

T:Test("Normalize rejects what the wire cannot carry", function()
    T:Eq(IdPool.Normalize(5, "test"), 5, "valid")
    T:Eq(IdPool.Normalize("7", "test"), 7, "numeric string")
    T:Eq(IdPool.Normalize(5.7, "test"), 5, "floored")
    T:Eq(IdPool.Normalize(-5, "test"), nil, "negative")
    T:Eq(IdPool.Normalize(0, "test"), nil, "zero")
    T:Eq(IdPool.Normalize(70000, "test"), nil, "past u16")
    T:Eq(IdPool.Normalize("abc", "test"), nil, "not a number")
end)

T:Test("errors when exhausted", function()
    const Pool = IdPool.new(2)
    Pool:Claim()
    Pool:Claim()
    T:Throws(function() Pool:Claim() end, "exhausted")
end)

--=============================================================================
-- CustomEnum
--=============================================================================

T:Describe("CustomEnum")

const Shapes = CustomEnum:Register("TestShapes", {Circle = 1, Square = 2, Triangle = 3})

T:Test("registers and looks up", function()
    T:Ok(Shapes, "registered")
    T:Eq(#Shapes.Options, 3, "option count")
    T:Eq(Shapes:GetById(2).Value, "Square", "by id")
    T:Eq(Shapes:GetByValue("Triangle").Id, 3, "by value")
    T:Eq(Shapes:GetById(99), nil, "missing id")
end)

T:Test("options are ordered deterministically", function()
    T:Eq(Shapes.Options[1].Id, 1, "first")
    T:Eq(Shapes.Options[2].Id, 2, "second")
    T:Eq(Shapes.Options[3].Id, 3, "third")
end)

T:Test("refuses duplicate registration", function()
    T:Eq(CustomEnum:Register("TestShapes", {A = 1}), nil, "duplicate name")
end)

T:Test("skips invalid options rather than failing", function()
    const Mixed = CustomEnum:Register("TestMixed", {Good = 1, AlsoGood = 2, Bad = 1})
    T:Eq(#Mixed.Options, 2, "duplicate id dropped")
end)

T:Test("UNKNOWN exists for unresolvable options", function()
    T:Ok(CustomEnum.UNKNOWN, "present")
    T:Eq(CustomEnum.UNKNOWN.Parent, "Unknown", "parent")
end)

--=============================================================================
-- Property types and validation
--=============================================================================

T:Describe("Property validation")

T:Test("type ids are stable and reversible", function()
    for Name, Id in PropertyTypes.Ids do
        T:Eq(PropertyTypes:GetTypeFromId(Id), Name, `id {Id}`)
        T:Ok(Id < 32, `{Name} fits five bits`)
    end
end)

T:Test("IsValid checks the underlying type", function()
    T:Ok(PropertyTypes:IsValid("Number", 5), "number")
    T:Ok(not PropertyTypes:IsValid("Number", "5"), "string is not a number")
    T:Ok(PropertyTypes:IsValid("Text", "hi"), "text")
    T:Ok(not PropertyTypes:IsValid("Text", 5), "number is not text")
    T:Ok(PropertyTypes:IsValid("Vector", Vector3.new()), "vector")
    T:Ok(not PropertyTypes:IsValid("Number", nil), "nil")
end)

T:Test("FixValue clamps numbers into range", function()
    const Constraints = {MinValue = 0, MaxValue = 10}
    T:Eq(PropertyTypes:FixValue("Number", 20, Constraints), 10, "over")
    T:Eq(PropertyTypes:FixValue("Number", -5, Constraints), 0, "under")
    T:Eq(PropertyTypes:FixValue("Number", 5, Constraints), 5, "inside")
end)

T:Test("FixValue truncates text and applies AllowDecimals", function()
    T:Eq(PropertyTypes:FixValue("Text", "abcdef", {MaxLength = 3}), "abc", "truncated")
    T:Eq(PropertyTypes:FixValue("Number", 5.7, {AllowDecimals = false}), 6, "rounded")
end)

T:Test("Table is gone from the type system", function()
    T:Eq(PropertyTypes.Ids.Table, nil, "no id")
    T:Eq(PropertyTypes.Map.Table, nil, "no map entry")
end)

--=============================================================================
-- Compressor: values
--=============================================================================

T:Describe("Compressor values")

const function ValueRoundTrip(Type: string, Value: any, What: string): any
    const Buf = Compressor:CompressValue(Type, Value)
    T:Ok(Buf, `{What}: compressed`)
    if not Buf then
        return nil
    end

    const Back, Consumed, ReadType = Compressor:DecompressValue(Buf, 0)
    T:Eq(Consumed, buffer.len(Buf), `{What}: consumed the whole buffer`)
    T:Eq(ReadType, Type, `{What}: type survived`)
    return Back
end

T:Test("text round trips including empty and long", function()
    T:Eq(ValueRoundTrip("Text", "hello", "text"), "hello")
    T:Eq(ValueRoundTrip("Text", "", "empty text"), "")
    T:Eq(ValueRoundTrip("Text", string.rep("a", 70000), "long text"):len(), 70000)
end)

T:Test("whole numbers survive exactly", function()
    for _, Value in {0, 1, -1, 42, -42, 1000000} do
        T:Eq(ValueRoundTrip("Number", Value, `number {Value}`), Value)
    end
end)

T:Test("REGRESSION: integers past f32 are not mangled", function()
    -- f32 has a 24 bit mantissa, so it snaps anything past 16,777,216 onto a
    -- grid. Timestamps and user ids both live well past that.
    const Timestamp = 1767000000
    const UserId = 8000000000

    T:Eq(ValueRoundTrip("Number", 16777217, "just past f32"), 16777217)
    T:Eq(ValueRoundTrip("Number", Timestamp, "unix timestamp"), Timestamp)
    T:Eq(ValueRoundTrip("Number", UserId, "user id"), UserId)
    T:Eq(ValueRoundTrip("Number", 4503599627370495, "2^52 - 1"), 4503599627370495)
end)

T:Test("fractional numbers pick a width that round trips", function()
    T:Eq(ValueRoundTrip("Number", 0.5, "f32 exact"), 0.5)
    T:Eq(ValueRoundTrip("Number", 1.5, "f32 exact"), 1.5)
    T:Eq(ValueRoundTrip("Number", 0.1, "needs f64"), 0.1)
    T:Eq(ValueRoundTrip("Number", -0.3, "needs f64"), -0.3)
end)

T:Test("number encoding is chosen by value, not schema", function()
    T:Eq(buffer.len(Compressor:CompressValue("Number", 42)), 2, "small int: tag + 1")
    T:Eq(buffer.len(Compressor:CompressValue("Number", 0.5)), 5, "f32: tag + 4")
    T:Eq(buffer.len(Compressor:CompressValue("Number", 0.1)), 9, "f64: tag + 8")
end)

T:Test("other value types round trip", function()
    T:Eq(ValueRoundTrip("Bool", true, "true"), true)
    T:Eq(ValueRoundTrip("Bool", false, "false"), false)
    T:Eq(ValueRoundTrip("Color", Color3.fromRGB(10, 20, 30), "color"), Color3.fromRGB(10, 20, 30))
    T:Eq(ValueRoundTrip("Vector", Vector3.new(1, 2, 3), "vector"), Vector3.new(1, 2, 3))
    T:Eq(ValueRoundTrip("Enum", Enum.Material.Plastic, "enum"), Enum.Material.Plastic)
    T:Eq(ValueRoundTrip("CustomEnum", Shapes:GetById(2), "custom enum"), Shapes:GetById(2))
end)

T:Test("nil compresses to nothing", function()
    T:Eq(Compressor:CompressValue("Number", nil), nil, "nil value")
end)

T:Test("SCHEMA DRIFT: an unknown semantic type is skipped, not fatal", function()
    -- Rewrite the tag's type bits to a semantic type this build has no name
    -- for, keeping the wire shape. A reader must still know how far to move.
    const Buf = Compressor:CompressValue("Text", "hello") :: buffer
    const Original = buffer.readu8(Buf, 0)
    const Wire = Original // 32

    buffer.writeu8(Buf, 0, Wire * 32 + 20) -- semantic type 20 does not exist

    const Value, Consumed, Type = Compressor:DecompressValue(Buf, 0)
    T:Eq(Value, nil, "value dropped")
    T:Eq(Type, nil, "type unknown")
    T:Eq(Consumed, buffer.len(Buf), "skipped exactly the whole value")
end)

--=============================================================================
-- Compressor: packing
--=============================================================================

T:Describe("Compressor packing")

T:Test("packs and unpacks buffers in order", function()
    const Parts = {}
    for Index = 1, 5 do
        const Part = buffer.create(Index)
        buffer.writeu8(Part, 0, Index * 10)
        table.insert(Parts, Part)
    end

    const Unpacked = Compressor:UnpackBuffers(Compressor:PackBuffers(Parts))
    T:Eq(#Unpacked, 5, "count")

    for Index = 1, 5 do
        T:Eq(buffer.len(Unpacked[Index]), Index, `part {Index} length`)
        T:Eq(buffer.readu8(Unpacked[Index], 0), Index * 10, `part {Index} contents`)
    end
end)

T:Test("handles an empty pack", function()
    T:Eq(#Compressor:UnpackBuffers(Compressor:PackBuffers({})), 0, "empty")
end)

T:Test("rejects a buffer that is not a pack", function()
    T:Throws(function()
        Compressor:UnpackBuffers(buffer.create(16))
    end, "bad header")
end)

--=============================================================================
-- Properties
--=============================================================================

T:Describe("Properties")

const TitleId = Properties:Register({
    Name = "TestTitle",
    Type = "Text",
    DefaultValue = "Untitled",
    Constraints = {MaxLength = 20},
}) :: number

const HealthId = Properties:Register({
    Name = "TestHealth",
    Type = "Number",
    DefaultValue = 100,
    Constraints = {MinValue = 0, MaxValue = 100, AllowDecimals = false},
}) :: number

const PlaysId = Properties:Register({
    Name = "TestPlays",
    Type = "Number",
    DefaultValue = 0,
}) :: number

const TintId = Properties:Register({
    Name = "TestTint",
    Type = "Color",
    DefaultValue = Color3.new(1, 1, 1),
}) :: number

T:Test("registration returns usable ids", function()
    T:Ok(TitleId, "title")
    T:Ok(HealthId, "health")
    T:Eq(Properties:GetRegistry(TitleId).Name, "TestTitle", "registry name")
    T:Eq(Properties:GetRegistry(TitleId).Type, "Text", "registry type")
end)

T:Test("refuses a duplicate custom id", function()
    const Taken = Properties:Register({
        Name = "TestDuplicate",
        Type = "Bool",
        DefaultValue = false,
        CustomId = TitleId,
    })

    T:Eq(Taken, nil, "duplicate refused")
end)

T:Test("instances start at the registry default", function()
    const Prop = Properties.new(TitleId)
    T:Eq(Prop.Value, "Untitled", "value")
    T:Eq(Prop.DefaultValue, "Untitled", "default")
    T:Eq(Prop.Parent, TitleId, "parent")
end)

T:Test("Set reports accepted and changed separately", function()
    const Prop = Properties.new(HealthId)

    const Accepted, Changed = Prop:Set(50)
    T:Ok(Accepted, "accepted")
    T:Ok(Changed, "changed")

    const AcceptedAgain, ChangedAgain = Prop:Set(50)
    T:Ok(AcceptedAgain, "same value still accepted")
    T:Ok(not ChangedAgain, "same value is not a change")

    const Rejected = Prop:Set("not a number")
    T:Ok(not Rejected, "wrong type rejected")
    T:Eq(Prop.Value, 50, "value untouched after rejection")
end)

T:Test("constraints clamp on the way in", function()
    const Prop = Properties.new(HealthId)
    Prop:Set(500)
    T:Eq(Prop.Value, 100, "clamped to max")

    Prop:Set(-20)
    T:Eq(Prop.Value, 0, "clamped to min")

    Prop:Set(5.7)
    T:Eq(Prop.Value, 6, "rounded by AllowDecimals")
end)

T:Test("text is truncated to MaxLength", function()
    const Prop = Properties.new(TitleId)
    Prop:Set(string.rep("x", 50))
    T:Eq(#Prop.Value, 20, "truncated")
end)

T:Test("OnChange allocates only when used", function()
    const Prop = Properties.new(HealthId)
    T:Eq(Prop.Listeners, nil, "no listeners before OnChange")

    local Seen: any = nil
    const Disconnect = Prop:OnChange(function(Value)
        Seen = Value
    end)

    T:Ok(Prop.Listeners, "allocated on connect")

    Prop:Set(42)
    task.wait()
    T:Eq(Seen, 42, "listener fired")

    Disconnect()
    T:Eq(Prop.Listeners, nil, "freed when the last listener leaves")

    Prop:Set(43)
    task.wait()
    T:Eq(Seen, 42, "no longer firing")
end)

T:Test("OnChange does not fire for an unchanged value", function()
    const Prop = Properties.new(HealthId)
    Prop:Set(10)

    local Count = 0
    Prop:OnChange(function()
        Count += 1
    end)

    Prop:Set(10)
    task.wait()
    T:Eq(Count, 0, "no fire")

    Prop:Set(11)
    task.wait()
    T:Eq(Count, 1, "fired once")
end)

T:Test("disconnecting twice is harmless", function()
    const Prop = Properties.new(HealthId)
    const Disconnect = Prop:OnChange(function() end)
    Disconnect()
    Disconnect()
    T:Eq(Prop.Listeners, nil, "still clean")
end)

--=============================================================================
-- Compressor: objects and metadata
--=============================================================================

T:Describe("Compressor records")

T:Test("metadata round trips", function()
    const Title = Properties.new(TitleId)
    Title:Set("My Level")

    const Plays = Properties.new(PlaysId)
    Plays:Set(1767000000) -- past f32, the regression case

    const Record = {
        Id = 7,
        SavedVersion = 2,
        PublishedVersion = 1,
        Title,
        Plays,
    }

    const Back = Compressor:DecompressMetadata(Compressor:CompressMetadata(Record :: any))
    T:Eq(Back.Id, 7, "id")
    T:Eq(Back.SavedVersion, 2, "saved version")
    T:Eq(Back.PublishedVersion, 1, "published version")
    T:Eq(#Back, 2, "property count")

    for _, Prop in Back do
        if Prop.Parent == TitleId then
            T:Eq(Prop.Value, "My Level", "title")
        elseif Prop.Parent == PlaysId then
            T:Eq(Prop.Value, 1767000000, "plays exact")
        end
    end
end)

T:Test("metadata packs round trip and preserve LastId", function()
    const function Build(Id: number, Name: string)
        const Title = Properties.new(TitleId)
        Title:Set(Name)
        return {Id = Id, SavedVersion = 0, PublishedVersion = 0, Title}
    end

    const Records = {Build(1, "One"), Build(2, "Two"), Build(3, "Three")}
    const LastId, Back = Compressor:DecompressMetadatas(Compressor:CompressMetadatas(42, Records :: any))

    T:Eq(LastId, 42, "last id")
    T:Eq(#Back, 3, "count")
    T:Eq(Back[1].Id, 1, "order preserved")
    T:Eq(Back[3][1].Value, "Three", "third record value")
end)

T:Test("rejects a buffer that is not metadata", function()
    T:Throws(function()
        Compressor:DecompressMetadata(buffer.create(32))
    end, "bad header")
end)

--=============================================================================
-- Objects
--=============================================================================

T:Describe("Objects")

const Template = Instance.new("Part")
Template.Name = "LoomTestTemplate"
Template.Anchored = true
Template.Parent = ServerStorage

const Container = Instance.new("Folder")
Container.Name = "LoomTestContainer"
Container.Parent = workspace

const CrateId = Objects:Register({
    Name = "TestCrate",
    Properties = {TitleId, HealthId, TintId},
    Instance = Template,
    Container = Container,
    Links = {
        {Property = TintId, Type = "Property", Name = "Color"},
        {Property = HealthId, Type = "Attribute", Name = "Health"},
    },
}) :: number

const BareId = Objects:Register({
    Name = "TestBare",
    Properties = {TitleId},
}) :: number

T:Test("registration validates its property list", function()
    T:Ok(CrateId, "registered")
    T:Eq(Objects:GetRegistry(CrateId).Name, "TestCrate", "name")

    const Sparse = Objects:Register({
        Name = "TestSparse",
        Properties = {TitleId, 99999}, -- second is not registered
    }) :: number

    T:Eq(#Objects:GetRegistry(Sparse).Properties, 1, "unregistered property dropped")
end)

T:Test("instances get their own clone of the template", function()
    const A = Objects.new(CrateId)
    const B = Objects.new(CrateId)

    T:Ok(A.Instance, "A has an instance")
    T:Ok(B.Instance, "B has an instance")
    T:Ok(A.Instance ~= B.Instance, "instances are distinct")
    T:Ok(A.Instance ~= Template, "not the template itself")
    T:Eq(A.Instance.Parent, Container, "parented to the container")

    A:Destroy()
    T:Ok(B.Instance and B.Instance.Parent == Container, "destroying A leaves B alone")
    B:Destroy()
end)

T:Test("get and set work by id and by name", function()
    const Obj = Objects.new(CrateId)

    T:Eq(Obj:Get(TitleId), "Untitled", "default by id")
    T:Eq(Obj:Get("TestTitle"), "Untitled", "default by name")

    T:Ok(Obj:Set(TitleId, "Renamed"), "set accepted")
    T:Eq(Obj:Get(TitleId), "Renamed", "set applied")
    T:Eq(Obj:Get("TestTitle"), "Renamed", "visible by name")

    T:Ok(not Obj:Set(99999, "x"), "unknown property refused")
    T:Ok(not Obj:Set(HealthId, "not a number"), "wrong type refused")

    Obj:Destroy()
end)

T:Test("links mirror properties onto the instance", function()
    const Obj = Objects.new(CrateId)
    T:Ok(Obj.Links, "links built")

    Obj:Set(TintId, Color3.fromRGB(255, 0, 0))
    task.wait()
    T:Eq(Obj.Instance.Color, Color3.fromRGB(255, 0, 0), "property link followed")

    Obj:Set(HealthId, 55)
    task.wait()
    T:Eq(Obj.Instance:GetAttribute("Health"), 55, "attribute link followed")

    Obj:Destroy()
end)

T:Test("an object with no instance still works", function()
    const Obj = Objects.new(BareId)
    T:Eq(Obj.Instance, nil, "no instance")
    T:Eq(Obj.Links, nil, "no links")
    T:Ok(Obj:Set(TitleId, "Bare"), "set still works")
    Obj:Destroy()
end)

T:Test("destroy is idempotent and answers instead of throwing", function()
    const Obj = Objects.new(CrateId)
    const Inst = Obj.Instance
    const RuntimeId = Obj.RuntimeId

    Obj:Destroy()
    T:Ok(Obj.Destroyed, "flagged")
    T:Eq(Obj.RuntimeId, RuntimeId, "identity readable after destroy")
    T:Eq(Inst.Parent, nil, "instance destroyed")
    T:Eq(Objects:GetWorkspace()[RuntimeId], nil, "removed from workspace")

    -- None of these may throw.
    Obj:Destroy()
    T:Eq(Obj:Get(TitleId), nil, "get answers nil")
    T:Eq(Obj:Set(TitleId, "x"), false, "set answers false")
end)

T:Test("links are disconnected on destroy", function()
    const Obj = Objects.new(CrateId)
    const Prop = Obj.Properties[TintId]

    T:Ok(Prop.Listeners, "listener attached while alive")
    Obj:Destroy()
    T:Eq(Prop.Listeners, nil, "listener released")
end)

T:Test("round trips through compression", function()
    const Obj = Objects.new(CrateId)
    Obj:Set(TitleId, "Compressed")
    Obj:Set(HealthId, 33)

    const Copy = Objects.fromCompression(Compressor:CompressObject(Obj :: any))
    T:Ok(Copy, "rebuilt")

    if Copy then
        T:Eq(Copy.Parent, CrateId, "same registry")
        T:Eq(Copy:Get(TitleId), "Compressed", "title carried")
        T:Eq(Copy:Get(HealthId), 33, "health carried")
        T:Ok(Copy.RuntimeId ~= Obj.RuntimeId, "distinct runtime id")
        Copy:Destroy()
    end

    Obj:Destroy()
end)

T:Test("runtime ids are unique", function()
    const Seen = {}
    const Made = {}

    for _ = 1, 20 do
        const Obj = Objects.new(BareId)
        T:Ok(not Seen[Obj.RuntimeId], `runtime id {Obj.RuntimeId} is fresh`)
        Seen[Obj.RuntimeId] = true
        table.insert(Made, Obj)
    end

    for _, Obj in Made do
        Obj:Destroy()
    end
end)

--=============================================================================
-- Permissions
--=============================================================================

T:Describe("Permissions")

Permissions:Register("TestViewer", {Level = 1})
Permissions:Register("TestBuilder", {
    Level = 10,
    CanCreate = true,
    CanEdit = true,
    CanDestroy = true,
    Rate = 5,
    Blacklist = {CrateId},
})

T:Test("roles register once", function()
    T:Ok(Permissions:GetRegistered().TestBuilder, "registered")
    T:Eq(Permissions:Register("TestBuilder", {Level = 1}), nil, "duplicate refused")
end)

T:Test("unassigned players are denied everything", function()
    const Ghost = {} :: any -- stands in for a Player; only used as a table key
    T:Eq(Permissions:Get(Ghost).Name, "None", "fallback role")
    T:Ok(not Permissions:Can(Ghost, "Edit"), "cannot edit")
    T:Ok(not Permissions:Can(Ghost, "Create"), "cannot create")
    T:Ok(not Permissions:Can(Ghost, "Destroy"), "cannot destroy")
end)

T:Test("a default role grants its verbs", function()
    const Ghost = {} :: any
    Permissions:SetDefault("TestBuilder")

    T:Eq(Permissions:Get(Ghost).Name, "TestBuilder", "defaulted")
    T:Ok(Permissions:Can(Ghost, "Edit"), "can edit")
    T:Ok(Permissions:Can(Ghost, "Edit", BareId), "can edit a permitted type")

    Permissions:SetDefault(nil)
end)

T:Test("the blacklist blocks a specific object type", function()
    const Ghost = {} :: any
    Permissions:SetDefault("TestBuilder")

    T:Ok(not Permissions:Can(Ghost, "Edit", CrateId), "blacklisted type refused")
    T:Ok(Permissions:Can(Ghost, "Edit", BareId), "other types still allowed")

    Permissions:SetDefault(nil)
end)

T:Test("a viewer role grants nothing without verbs", function()
    const Ghost = {} :: any
    Permissions:SetDefault("TestViewer")
    T:Ok(not Permissions:Can(Ghost, "Edit"), "no edit verb")

    Permissions:SetDefault(nil)
end)

T:Test("Assign accepts a real player", function()
    const Plr = Players:GetPlayers()[1]
    if not Plr then
        T:Skip("no player is connected; run a one-client play test")
        return
    end

    T:Ok(Permissions:Assign(Plr, "TestBuilder"), "assignment accepted")
    T:Eq(Permissions:Get(Plr).Name, "TestBuilder", "assigned role")
    T:Ok(Permissions:Assign(Plr, nil), "assignment cleared")
end)

T:Test("REGRESSION: the payload blacklist is a sequential array", function()
    -- Sent as a map, non-sequential numeric keys are not guaranteed to survive
    -- remote serialization, and the client silently allowed blacklisted types.
    const Ghost = {} :: any
    Permissions:SetDefault("TestBuilder")

    const Payload = Permissions:GetPayload(Ghost)
    T:Eq(#Payload.Blacklist, 1, "one entry, reachable by length")
    T:Eq(Payload.Blacklist[1], CrateId, "entry is the object id")
    T:Eq(Payload.Name, "TestBuilder", "role name carried")

    Permissions:SetDefault(nil)
end)

T:Test("rate limiting cuts off past the role budget", function()
    const Ghost = {} :: any
    Permissions:SetDefault("TestBuilder") -- Rate = 5

    local Allowed = 0
    for _ = 1, 20 do
        if Permissions:Consume(Ghost) then
            Allowed += 1
        end
    end

    T:Eq(Allowed, 5, "exactly the budget")
    Permissions:SetDefault(nil)
end)

T:Test("a zero rate role cannot act at all", function()
    const Ghost = {} :: any
    T:Ok(not Permissions:Consume(Ghost), "fallback has no budget")
end)

--=============================================================================
-- Client integration fixtures
--=============================================================================

T:Describe("Client integration fixtures")

-- The builder may edit and destroy bare objects, but TestCrate is blacklisted.
-- Keeping all three objects alive lets the client verify both authorization
-- paths as well as object removal without coupling those checks together.
const DeniedFixture = Objects.new(CrateId)
DeniedFixture:Set(TitleId, "FixtureDenied")

const EditableFixture = Objects.new(BareId)
EditableFixture:Set(TitleId, "FixtureEditable")

const DestroyFixture = Objects.new(BareId)
DestroyFixture:Set(TitleId, "FixtureDestroy")

const function AssignBuilder(Plr: Player)
    Permissions:Assign(Plr, "TestBuilder")
end

for _, Plr in Players:GetPlayers() do
    AssignBuilder(Plr)
end
Players.PlayerAdded:Connect(AssignBuilder)

-- A client writes this marker while its Permissions.OnChange listener is
-- attached. The server briefly changes the role, then restores the builder so
-- the remaining accepted-edit and destroy tests can proceed deterministically.
EditableFixture.Properties[TitleId]:OnChange(function(Value)
    if Value ~= "PermissionPulse" then
        return
    end

    for _, Plr in Players:GetPlayers() do
        Permissions:Assign(Plr, "TestViewer")
        task.delay(0.2, function()
            if Plr.Parent then
                Permissions:Assign(Plr, "TestBuilder")
            end
        end)
    end
end)

T:Test("fixtures are live and carry distinct markers", function()
    T:Eq(DeniedFixture:Get(TitleId), "FixtureDenied", "denied fixture")
    T:Eq(EditableFixture:Get(TitleId), "FixtureEditable", "editable fixture")
    T:Eq(DestroyFixture:Get(TitleId), "FixtureDestroy", "destroy fixture")
    T:Ok(DeniedFixture.Instance, "instance-backed fixture")
end)

--=============================================================================
-- Try and Encoding
--=============================================================================

T:Describe("Try")

T:Test("returns the value on first success", function()
    const Ok, Value = Try(3, function()
        return "done"
    end)

    T:Ok(Ok, "succeeded")
    T:Eq(Value, "done", "value")
end)

T:Test("retries until it succeeds", function()
    local Calls = 0
    const Ok = Try(5, function()
        Calls += 1
        if Calls < 3 then
            error("not yet")
        end
        return true
    end)

    T:Ok(Ok, "eventually succeeded")
    T:Eq(Calls, 3, "stopped as soon as it worked")
end)

T:Test("gives up and reports failure", function()
    local Calls = 0
    const Ok = Try(3, function()
        Calls += 1
        error("always")
    end)

    T:Ok(not Ok, "failed")
    T:Eq(Calls, 3, "used every attempt")
end)

T:Test("forwards arguments and preserves trailing nils", function()
    const Ok, A, B, C = Try(1, function(X, Y)
        return X, Y, nil
    end, "first", "second")

    T:Ok(Ok, "succeeded")
    T:Eq(A, "first", "first argument")
    T:Eq(B, "second", "second argument")
    T:Eq(C, nil, "trailing nil")
end)

T:Describe("Encoding")

T:Test("base64 round trips through EncodingService", function()
    -- If this fails, the EncodingService signature in src/Encoding.luau needs
    -- correcting; it is the only place that touches the service.
    const Source = buffer.create(8)
    for Index = 0, 7 do
        buffer.writeu8(Source, Index, Index * 31 % 256)
    end

    const Back = Encoding.Decode(Encoding.Encode(Source))
    T:Eq(buffer.len(Back), 8, "length")

    for Index = 0, 7 do
        T:Eq(buffer.readu8(Back, Index), Index * 31 % 256, `byte {Index}`)
    end
end)

T:Test("survives a compressed record", function()
    const Title = Properties.new(TitleId)
    Title:Set("Encoded")

    const Packed = Compressor:CompressMetadatas(1, {
        {Id = 1, SavedVersion = 0, PublishedVersion = 0, Title} :: any,
    })

    const _, Back = Compressor:DecompressMetadatas(Encoding.Decode(Encoding.Encode(Packed)))
    T:Eq(#Back, 1, "record count")
    T:Eq(Back[1][1].Value, "Encoded", "value")
end)

--=============================================================================
-- Database (opt in: writes real DataStore and MemoryStore keys)
--=============================================================================

if RUN_DATABASE then
    T:Describe("Database")

    const Title = Properties.new(TitleId)
    Title:Set("New Level")

    const Plays = Properties.new(PlaysId)
    Plays:Set(0)

    -- ShardLimit is deliberately tiny so the seal path runs after a handful of
    -- records instead of needing three megabytes of them.
    const db = Loom.Database.new({
        Key = DATABASE_KEY,
        InitialMetadata = {Title, Plays},
        ShardLimit = 400,
        Expiration = 1,
    })

    db:RegisterCache("Newest", {IdOrdered = "Desc", PageSize = 3})
    db:RegisterCache("Oldest", {IdOrdered = "Asc", PageSize = 3})
    db:RegisterCache("Popular", {
        PageSize = 3,
        Sort = function(A, B)
            const Left = A[2] and A[2].Value or 0
            const Right = B[2] and B[2].Value or 0
            return Left > Right
        end,
    })

    const Created = {}

    T:Test("creates records with increasing ids", function()
        for Index = 1, 8 do
            const Ok, Id = db:Create()
            T:Ok(Ok, `create {Index}`)

            if Id then
                table.insert(Created, Id)
                db:Edit(Id, {[TitleId] = `Level {Index}`, [PlaysId] = Index * 10})
            end
        end

        T:Eq(#Created, 8, "all created")
        T:Ok(Created[8] > Created[1], "ids increase")
    end)

    T:Test("reads a record back by id", function()
        db:Refresh()
        const Record = db:GetById(Created[1])
        T:Ok(Record, "found")

        if Record then
            T:Eq(Record.Id, Created[1], "id matches")
            for _, Prop in Record do
                if Prop.Parent == TitleId then
                    T:Eq(Prop.Value, "Level 1", "title")
                end
            end
        end
    end)

    T:Test("sharding sealed at least once", function()
        db:Refresh()
        const Page = db:Get("Oldest", 1)
        T:Ok(#Page.Records > 0, "records readable across shards")

        -- Every created id must still be reachable, which only holds if the
        -- boundary lookup and the multi shard walk agree.
        for _, Id in Created do
            T:Ok(db:GetById(Id) ~= nil, `id {Id} still reachable`)
        end
    end)

    T:Test("id ordered paging walks in both directions", function()
        db:Refresh()

        const Newest = db:Get("Newest", 1)
        T:Eq(#Newest.Records, 3, "page size respected")
        T:Ok(Newest.HasMore, "more pages exist")
        T:Eq(Newest.Records[1].Id, Created[8], "newest first")

        const Oldest = db:Get("Oldest", 1)
        T:Eq(Oldest.Records[1].Id, Created[1], "oldest first")
    end)

    T:Test("paging reaches the end cleanly", function()
        db:Refresh()

        const Seen = {}
        local Page = 1

        while Page < 20 do
            const Result = db:Get("Oldest", Page)
            for _, Record in Result.Records do
                T:Ok(not Seen[Record.Id], `id {Record.Id} appears once`)
                Seen[Record.Id] = true
            end

            if not Result.HasMore then
                break
            end

            Page += 1
        end

        local Count = 0
        for _ in Seen do
            Count += 1
        end

        T:Eq(Count, 8, "every record paged exactly once")
        T:Eq(#db:Get("Oldest", 99).Records, 0, "past the end is empty")
    end)

    T:Test("sorted caches order by the comparator", function()
        db:Refresh()
        const Page = db:Get("Popular", 1)
        T:Eq(#Page.Records, 3, "page size")

        const Top = Page.Records[1]
        for _, Prop in Top do
            if Prop.Parent == PlaysId then
                T:Eq(Prop.Value, 80, "highest plays first")
            end
        end
    end)

    T:Test("Find filters and honours its limit", function()
        db:Refresh()

        const Matches = db:Find(function(Record)
            for _, Prop in Record do
                if Prop.Parent == TitleId and type(Prop.Value) == "string" then
                    return string.find(Prop.Value, "Level", 1, true) ~= nil
                end
            end
            return false
        end, 4)

        T:Eq(#Matches, 4, "stopped at the limit")

        const None = db:Find(function()
            return false
        end)

        T:Eq(#None, 0, "no matches")
    end)

    T:Test("REGRESSION: returned records are frozen", function()
        db:Refresh()
        const Record = db:GetById(Created[1])
        T:Ok(Record, "found")

        if Record then
            -- Must be a valid value that differs from the current one, or Set
            -- returns early without ever attempting to mutate.
            T:Throws(function()
                Record[1]:Set("mutated from outside")
            end, "mutating a cached record")
        end
    end)

    T:Test("edits persist and deletes remove", function()
        T:Ok(db:Edit(Created[2], {[TitleId] = "Edited"}), "edit accepted")
        db:Refresh()

        const Record = db:GetById(Created[2])
        if Record then
            for _, Prop in Record do
                if Prop.Parent == TitleId then
                    T:Eq(Prop.Value, "Edited", "edit visible")
                end
            end
        end

        T:Ok(not db:Edit(999999, {[TitleId] = "x"}), "editing a missing id fails")
        T:Ok(not db:Edit(Created[2], {[99999] = "x"}), "unregistered property fails")

        T:Ok(db:Delete(Created[3]), "delete accepted")
        db:Refresh()
        T:Eq(db:GetById(Created[3]), nil, "gone")
        T:Ok(not db:Delete(Created[3]), "second delete fails")
    end)

    T:Test("a deleted id is never handed out again", function()
        const Ok, NewId = db:Create()
        T:Ok(Ok, "created")
        T:Ok(NewId and NewId > Created[8], "counter did not reuse the deleted id")

        if NewId then
            db:Delete(NewId)
        end
    end)

    T:Describe("Database cleanup")

    T:Test("removes its test keys", function()
        for _, Id in Created do
            db:Delete(Id)
        end

        const Store = db.DataStore
        for Index = 1, 10 do
            pcall(function()
                Store:RemoveAsync(`{DATABASE_KEY}:{Index}`)
            end)
        end

        pcall(function()
            Store:RemoveAsync("Manifest")
        end)

        T:Ok(true, "cleanup ran")
    end)
end

--=============================================================================

-- Template, Container, and the three fixtures deliberately remain alive until
-- the play session ends so a late-starting client can receive them via replay.

const Passed = T:Report()
if not Passed then
    error("[ LOOM TEST ] Server suite failed; see the failures above.", 0)
end

if not RUN_DATABASE then
    print("[ LOOM TEST ] Database suite skipped. Set RUN_DATABASE = true to run it.")
end

print("[ LOOM TEST ] Client fixtures are ready; LoomTest.client.luau runs separately.")
