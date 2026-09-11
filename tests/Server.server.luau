--!strict
--[[
    Prism test suite -- server half.

    Put this in ServerScriptService with Harness.luau beside it, and point PRISM
    below at wherever you synced the repo. Run it alongside Client.client.luau
    with one test player.

    The Database section is on: it writes to real DataStore and MemoryStore keys
    and needs Studio API access enabled. Set RUN_DATABASE to false to skip it.
    Its cleanup step is commented out, so the PrismSelfTest key survives a run.
]]

const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerStorage = game:GetService("ServerStorage")

const PRISM = ReplicatedStorage:WaitForChild("Prism").src
const RUN_DATABASE = true
const DATABASE_KEY = "PrismSelfTest"

const Prism = require(PRISM)
const Harness = require("./Harness")

const Networking = Prism.Networking
const Properties = Prism.Properties
const PropertyTypes = require(PRISM.Properties.Types)
const Compressor = Prism.Compressor
const Permissions = Prism.Permissions
const CustomEnum = Prism.CustomEnum
const Encoding = Prism.Encoding
const Objects = Prism.Objects
const Handles = Prism.Handles
const Scenes = Prism.Scenes
const World = Prism.World
const IdPool = Prism.IdPool
const Codecs = Prism.Codecs
const Varint = Prism.Varint
const Try = Prism.Try

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
    const First = Networking:Get("Prism.Ready")
    const Second = Networking:Get("Prism.Ready")
    T:Eq(First, Second, "same manifest entry")
    T:Eq(First.Name, "Prism.Ready", "channel name")
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
        Networking:Get("Prism.Ready"):Invoke()
    end, "server invoke")
end)

T:Test("connections disconnect idempotently", function()
    const Ready = Networking:Get("Prism.Ready")
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

T:Test("a reference is valid as an id and nothing else", function()
    T:Ok(PropertyTypes:IsValid("Object", 0), "zero is no target")
    T:Ok(PropertyTypes:IsValid("Object", 12), "a local id")
    T:Ok(PropertyTypes:IsValid("Object", Handles.MAX_LOCAL), "the largest one")
    T:Ok(not PropertyTypes:IsValid("Object", -1), "not negative")
    T:Ok(not PropertyTypes:IsValid("Object", 1.5), "not fractional")
    T:Ok(not PropertyTypes:IsValid("Object", Handles.MAX_LOCAL + 1), "not past the id space")
    T:Ok(not PropertyTypes:IsValid("Object", "4"), "not a string")

    -- What an id names, and whether that is something the property may point
    -- at, is not a question a value can answer on its own: it needs the copy
    -- doing the asking. Objects/Shared is where that is settled.
    T:Ok(PropertyTypes:IsValid("Object", 999999, {Types = {"Nothing"}}), "a dangling id passes here")
end)

T:Test("a plain number reads back as a Number, not an Object", function()
    -- Both are Luau numbers, so the reverse map has two candidates for one
    -- entry and used to pick whichever hash order reached first.
    T:Eq(PropertyTypes:GetTypeFromValue(5), "Number", "number")
    T:Eq(PropertyTypes:GetTypeFromValue("hi"), "Text", "and the unambiguous ones still answer")
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

T:Test("a reference round trips as the local id it stores", function()
    T:Eq(ValueRoundTrip("Object", 0, "no target"), 0)
    T:Eq(ValueRoundTrip("Object", 1, "first id"), 1)
    T:Eq(ValueRoundTrip("Object", 70000, "past two bytes"), 70000)
    T:Eq(ValueRoundTrip("Object", Handles.MAX_LOCAL, "the largest local id"), Handles.MAX_LOCAL)

    -- A varint, so an id a hand built scene actually uses costs one byte and
    -- a reference is no dearer than the number it is.
    T:Eq(buffer.len(Compressor:CompressValue("Object", 4)), 2, "tag + 1")
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

-- Registered at load like the rest, so the client receives them too and checks
-- the metadata came across.
const SpeedId = Properties:Register({
    Name = "TestSpeed",
    Type = "Number",
    DefaultValue = 1,
    Display = {Category = "Motion", Order = 2, Description = "Studs a second"},
}) :: number

const SpinId = Properties:Register({
    Name = "TestSpin",
    Type = "Number",
    DefaultValue = 0,
    Display = {Category = "Motion", Order = 1},
}) :: number

const SecretId = Properties:Register({
    Name = "TestSecret",
    Type = "Text",
    DefaultValue = "",
    Display = {Hidden = true},
}) :: number

const PlainId = Properties:Register({
    Name = "TestPlain",
    Type = "Bool",
    DefaultValue = false,
    Display = {Order = "first" :: any},
}) :: number

T:Test("display metadata is filled in at registration", function()
    const Display = Properties:GetRegistry(PlainId).Display

    T:Eq(Display.Category, "General", "a category by default")
    T:Eq(Display.Order, 0, "a malformed order falls back")
    T:Eq(Display.Hidden, false, "nothing hidden unless it says so")
    T:Eq(Display.ReadOnly, false, "nor read only")

    T:Eq(Properties:GetRegistry(SpeedId).Display.Description, "Studs a second", "what was given is kept")
    T:Eq(Properties:GetRegistryPayload(SpeedId).Display.Category, "Motion", "and goes out with the registry")
end)

T:Test("a panel is laid out from the metadata", function()
    const Layout = Properties:Layout({SpeedId, SecretId, PlainId, SpinId})

    T:Eq(#Layout, 2, "two categories, the hidden property left out")
    T:Eq(Layout[1].Category, "General", "the category holding the lowest order comes first")
    T:Eq(Layout[2].Category, "Motion", "then the next")
    T:Eq(Layout[2].Properties[1].Id, SpinId, "within one, lowest order first")
    T:Eq(Layout[2].Properties[2].Id, SpeedId, "then the next")

    T:Eq(#Properties:Layout({SecretId}), 0, "hidden on its own is nothing")
    T:Eq(#Properties:Layout({SecretId}, true), 1, "unless hidden ones are asked for")
    T:Eq(#Properties:Layout({99999}), 0, "an id nothing is registered under is skipped")
end)

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

const ShapeId = Properties:Register({
    Name = "TestShape",
    Type = "CustomEnum",
    DefaultValue = Shapes.Options[1],
    Constraints = {CustomEnum = Shapes},
}) :: number

T:Test("registration returns usable ids", function()
    T:Ok(TitleId, "title")
    T:Ok(HealthId, "health")
    T:Eq(Properties:GetRegistry(TitleId).Name, "TestTitle", "registry name")
    T:Eq(Properties:GetRegistry(TitleId).Type, "Text", "registry type")
end)

T:Test("REGRESSION: a CustomEnum registry crosses the wire without its methods", function()
    -- The enum table carries GetById and GetByValue, and a remote refuses to
    -- serialize a function, so broadcasting the registry raw threw for every
    -- CustomEnum property and no client ever received one.
    const Payload = Properties:GetRegistryPayload(ShapeId)
    T:Ok(Payload, "payload built")
    T:Eq(type(Payload.Constraints.CustomEnum), "string", "enum reduced to its name")
    T:Eq(Payload.Constraints.CustomEnum, "TestShapes", "the right name")

    for Key, Value in Payload.Constraints do
        T:Ok(type(Value) ~= "function", `constraint {Key} is not a function`)
    end

    -- The server's own registry keeps the real table.
    T:Eq(type(Properties:GetRegistry(ShapeId).Constraints.CustomEnum), "table", "server copy untouched")
end)

T:Test("a CustomEnum property validates and round trips", function()
    const Prop = Properties.new(ShapeId)
    T:Eq(Prop.Value.Id, 1, "starts at the default option")

    T:Ok((Prop:Set(Shapes:GetById(2))), "accepted a real option")
    T:Eq(Prop.Value.Value, "Square", "value applied")
    T:Ok(not (Prop:Set("Square")), "refused a bare string")

    const Buf = Compressor:CompressValue("CustomEnum", Prop.Value)
    T:Ok(Buf, "compressed")

    const Back, _, Type = Compressor:DecompressValue(Buf :: buffer, 0)
    T:Eq(Type, "CustomEnum", "tag preserved")
    T:Eq(Back.Id, 2, "option id preserved")
    T:Eq(Back.Parent, "TestShapes", "parent preserved")
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

    -- Indexed rather than iterated: the record carries Id, SavedVersion and
    -- PublishedVersion beside the array of properties, and a generic for walks
    -- those numbers too and then tries to index them.
    for Index = 1, #Back do
        const Prop = Back[Index]
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
Template.Name = "PrismTestTemplate"
Template.Anchored = true
Template.Parent = ServerStorage

const CrateId = Objects:Register({
    Name = "TestCrate",
    Properties = {TitleId, HealthId, TintId},
    Instance = Template,
    Links = {
        {Property = TintId, Type = "Property", Name = "Color"},
        {Property = HealthId, Type = "Attribute", Name = "Health"},
    },
}) :: number

const BareId = Objects:Register({
    Name = "TestBare",
    Properties = {TitleId},
}) :: number

-- A template clients can see, so its registry reaches them carrying a
-- reference that resolves -- which is what a client building its own objects
-- clones. TestCrate's sits in ServerStorage and reaches them as nil.
const ShownTemplate = Instance.new("Part")
ShownTemplate.Name = "PrismShownTemplate"
ShownTemplate.Anchored = true
ShownTemplate.Parent = ReplicatedStorage

const ShownId = Objects:Register({
    Name = "TestShown",
    Properties = {TitleId},
    Instance = ShownTemplate,
    Links = {{Property = TitleId, Type = "Attribute", Name = "TestTitle"}},
}) :: number

-- Data only for the players a scene admits. The client checks that a scene it
-- was not admitted to still sends it objects of every other type, and none of
-- these.
const PrivateId = Objects:Register({
    Name = "TestPrivate",
    Properties = {TitleId},
    Replicate = "Admitted",
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

T:Test("a registry payload carries its template and links", function()
    const Crate = Objects:GetRegistryPayload(CrateId)
    T:Eq(Crate.Instance, Template, "the template, as a reference")
    T:Eq(#Crate.Links, 2, "the validated links")

    const Shown = Objects:GetRegistryPayload(ShownId)
    T:Eq(Shown.Instance, ShownTemplate, "a replicated template too")
    T:Eq(Shown.Links[1].Name, "TestTitle", "with its link")

    const Bare = Objects:GetRegistryPayload(BareId)
    T:Eq(Bare.Instance, nil, "a type with no template sends none")
    T:Eq(Bare.Links, nil, "and no links")
end)

T:Test("an object type replicates to everyone unless it says otherwise", function()
    T:Eq(Objects:GetRegistry(BareId).Replicate, "Everyone", "everyone by default")
    T:Eq(Objects:GetRegistry(PrivateId).Replicate, "Admitted", "the admitted, when asked")
    T:Eq(Objects:GetRegistryPayload(PrivateId).Replicate, "Admitted", "and the client is told which")

    const Typo = Objects:Register({
        Name = "TestReplicateTypo",
        Properties = {TitleId},
        Replicate = "admitted" :: any,
    }) :: number

    T:Eq(Objects:GetRegistry(Typo).Replicate, "Admitted", "a value that is neither keeps it back")
end)

T:Test("a property cannot be unregistered while anything is built on it", function()
    T:Ok(not Properties:Unregister(TitleId), "refused: object types carry it")
    T:Ok(Properties:GetRegistry(TitleId), "and still registered")

    const Loose = Properties:Register({Name = "TestLoose", Type = "Text", DefaultValue = ""}) :: number
    T:Ok(Properties:Unregister(Loose), "one nothing carries goes")
    T:Eq(Properties:GetRegistry(Loose), nil, "gone")

    const Next = Properties:Register({Name = "TestLooseAfter", Type = "Text", DefaultValue = ""}) :: number
    T:Ok(Next ~= Loose, "and its id is not handed out again")
end)

T:Test("an object type cannot be unregistered while objects of it are live", function()
    const Carried = Properties:Register({Name = "TestCarried", Type = "Text", DefaultValue = ""}) :: number
    const Doomed = Objects:Register({Name = "TestDoomed", Properties = {Carried}}) :: number
    const Obj = Objects.new(Doomed)

    T:Ok(not Objects:Unregister(Doomed), "refused while one is live")
    T:Ok(not Properties:Unregister(Carried), "and its property is held by it")

    Obj:Destroy()
    T:Ok(Objects:Unregister(Doomed), "goes once none are")
    T:Eq(Objects:GetRegistry(Doomed), nil, "gone")
    T:Ok(Properties:Unregister(Carried), "and lets go of its property")

    T:Throws(function()
        Objects.new(Doomed)
    end, "nothing can be made of it")
end)

T:Test("instances get their own clone of the template", function()
    const A = Objects.new(CrateId)
    const B = Objects.new(CrateId)

    T:Ok(A.Instance, "A has an instance")
    T:Ok(B.Instance, "B has an instance")
    T:Ok(A.Instance ~= B.Instance, "instances are distinct")
    T:Ok(A.Instance ~= Template, "not the template itself")

    -- Both landed in the default scene, so both are in that copy's folder.
    const Copy = A.Instance.Parent
    T:Ok(Copy and Copy:IsA("Folder"), "parented into a copy's folder")
    T:Eq(B.Instance.Parent, Copy, "and both into the same one")
    T:Eq(Copy.Parent.Parent.Name, World.RootName, "which hangs under the prism root")

    A:Destroy()
    T:Ok(B.Instance and B.Instance.Parent == Copy, "destroying A leaves B alone")
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

T:Test("OnChange watches by id and by name", function()
    const Obj = Objects.new(CrateId)

    local ById: any = nil
    local ByName: any = nil

    const StopId = Obj:OnChange(HealthId, function(Value)
        ById = Value
    end)

    const StopName = Obj:OnChange("TestTitle", function(Value)
        ByName = Value
    end)

    Obj:Set(HealthId, 42)
    Obj:Set("TestTitle", "Watched")
    task.wait()

    T:Eq(ById, 42, "id listener fired")
    T:Eq(ByName, "Watched", "name listener fired")

    StopId()
    StopName()

    Obj:Set(HealthId, 7)
    task.wait()
    T:Eq(ById, 42, "disconnected listener stays quiet")

    Obj:Destroy()
end)

T:Test("watching what the object does not carry still returns a disconnect", function()
    const Obj = Objects.new(CrateId)

    -- Neither of these may throw, here or when released: a caller that stores
    -- the disconnect and calls it later cannot be asked to check first.
    const Unknown = Obj:OnChange("NotAProperty", function() end)
    T:Eq(typeof(Unknown), "function", "unknown name answers a disconnect")
    Unknown()

    Obj:Destroy()

    const Destroyed = Obj:OnChange(TitleId, function() end)
    T:Eq(typeof(Destroyed), "function", "destroyed object answers a disconnect")
    Destroyed()
end)

T:Test("GetProperty resolves the same reference Get and Set take", function()
    const Obj = Objects.new(CrateId)

    T:Eq(Obj:GetProperty(TitleId), Obj.Properties[TitleId], "by id")
    T:Eq(Obj:GetProperty("TestTitle"), Obj.Properties[TitleId], "by name")
    T:Eq(Obj.Names["TestTitle"], TitleId, "name map points at the id")

    T:Eq(Obj:GetProperty(99999), nil, "unknown id")
    T:Eq(Obj:GetProperty("NotAProperty"), nil, "unknown name")

    -- What Get and Set do not expose.
    T:Eq(Obj:GetProperty("TestHealth").Constraints.MaxValue, 100, "reaches the constraints")

    Obj:Destroy()
    T:Eq(Obj:GetProperty(TitleId), nil, "destroyed answers nil")
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

T:Test("links that cannot work are refused at registration", function()
    -- Validated once against the template. These used to be checked inside
    -- Objects.new, so one malformed link warned again for every object made.
    const Bad = Objects:Register({
        Name = "TestBadLinks",
        Properties = {TitleId, HealthId, ShapeId},
        Instance = Template,
        Links = {
            -- SetAttribute throws on a table, which is what an option is.
            {Property = ShapeId, Type = "Attribute", Name = "Shape"},
            -- Readable, but assigning to it throws.
            {Property = TitleId, Type = "Property", Name = "ClassName"},
            -- Not a member at all.
            {Property = TitleId, Type = "Property", Name = "NotARealProperty"},
            -- Neither Property nor Attribute.
            {Property = HealthId, Type = "Nonsense" :: any, Name = "Health"},
        },
    }) :: number

    T:Eq(Objects:GetRegistry(Bad).Links, nil, "every bad link dropped")

    const Obj = Objects.new(Bad)
    T:Eq(Obj.Links, nil, "so nothing is wired onto the instance")
    Obj:Destroy()
end)

T:Test("a property linked twice keeps only the first link", function()
    const Dupe = Objects:Register({
        Name = "TestDuplicateLink",
        Properties = {TintId},
        Instance = Template,
        Links = {
            {Property = TintId, Type = "Property", Name = "Color"},
            {Property = TintId, Type = "Attribute", Name = "Tint"},
        },
    }) :: number

    const Links = Objects:GetRegistry(Dupe).Links
    T:Ok(Links, "a link survived")
    T:Eq(#(Links :: any), 1, "exactly one")
    T:Eq((Links :: any)[1].Type, "Property", "the first one wins")
end)

T:Test("initial values are applied before links and before the broadcast", function()
    const Tint = Color3.fromRGB(10, 20, 30)
    const Obj = Objects.new(CrateId, {[TitleId] = "Preloaded", [TintId] = Tint})

    T:Eq(Obj:Get(TitleId), "Preloaded", "text applied")
    T:Eq(Obj:Get(TintId), Tint, "colour applied")

    -- Wired after the values land, so the part carries the real colour rather
    -- than the registry default followed by a correction.
    T:Ok(Obj.Instance, "has an instance")
    if Obj.Instance then
        T:Eq((Obj.Instance :: any).Color, Tint, "link seeded from the initial value")
    end

    Obj:Destroy()
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
        -- A copy, not a restore: it gets its own persistent id rather than
        -- aliasing the original, which is still alive and still holds the
        -- saved one.
        T:Ok(Copy.PersistentId ~= Obj.PersistentId, "distinct persistent id")
        T:Ok(Copy.RuntimeId ~= Obj.RuntimeId, "and its own runtime id")
        T:Eq(Copy.Scene, Obj.Scene, "same scene")
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
-- Scenes
--=============================================================================

T:Describe("Scenes")

T:Test("a persistent id carries its scene and survives the round trip", function()
    const Persistent = Handles.Join(7, 1234)
    const Scene, Local = Handles.Split(Persistent)

    T:Eq(Scene, 7, "scene half")
    T:Eq(Local, 1234, "local half")
    T:Eq(Handles.Scene(Persistent), 7, "scene alone")
    T:Eq(Handles.Local(Persistent), 1234, "local alone")

    -- The largest id the scheme can produce still has to be an exact integer,
    -- or two different objects start comparing equal.
    const Biggest = Handles.Join(Handles.MAX_SCENE, Handles.MAX_LOCAL)
    T:Eq(Biggest % 1, 0, "still an integer")
    T:Ok(Biggest ~= Biggest - 1, "still distinguishable from its neighbour")
    T:Eq(Handles.Local(Biggest), Handles.MAX_LOCAL, "reads back at the top")
end)

T:Test("registering a scene puts nothing in the world", function()
    const Scene = Scenes.new({Name = "TestRegistered"})

    T:Eq(#Scene:GetInstances(), 0, "no copies")
    T:Eq(Scene.Data, nil, "and nothing committed")

    const Live = Scene:Load()
    T:Ok(Live, "loading makes one")
    T:Eq(#Scene:GetInstances(), 1, "listed by the scene")

    Scene:Destroy()
end)

T:Test("objects land in the default scene when none is named", function()
    const Obj = Objects.new(BareId)
    const Default = Scenes:GetDefault()
    const Live = Default:GetInstances()[1]

    T:Ok(Live, "the default scene loaded itself on first use")
    T:Eq(Obj.Scene, Default.Id, "scene recorded on the object")
    T:Eq(Handles.Scene(Obj.PersistentId), Default.Id, "and inside the persistent id")
    T:Eq(Live:Find(Obj.LocalId), Obj, "the copy holds it")

    Obj:Destroy()
    T:Eq(Live:Find(Obj.LocalId), nil, "and lets go on destroy")
end)

T:Test("refuses a duplicate name and a duplicate id", function()
    const First = Scenes.new({Name = "TestDuplicate"})
    T:Ok(First, "registered")

    T:Eq(Scenes.new({Name = "TestDuplicate"}), nil, "same name refused")

    const Fixed = Scenes.new({Name = "TestFixedId", CustomId = 4242})
    T:Eq(Fixed.Id, 4242, "custom id honoured")
    T:Eq(Scenes.new({Name = "TestFixedIdAgain", CustomId = 4242}), nil, "same id refused")

    First:Destroy()
    Fixed:Destroy()
end)

T:Test("local ids are per scene, so two scenes reuse the same numbers", function()
    const A = Scenes.new({Name = "TestSceneA"}):Load()
    const B = Scenes.new({Name = "TestSceneB"}):Load()

    const InA = A:Create(BareId)
    const InB = B:Create(BareId)

    T:Eq(InA.LocalId, 1, "first in A")
    T:Eq(InB.LocalId, 1, "first in B")
    T:Ok(InA.PersistentId ~= InB.PersistentId, "but the persistent ids differ")

    A.Owner:Destroy()
    B.Owner:Destroy()
end)

T:Test("commit then reload brings the same ids back", function()
    const Scene = Scenes.new({Name = "TestRoundTrip"})
    const Live = Scene:Load()

    const One = Live:Create(CrateId, {[TitleId] = "First"})
    const Two = Live:Create(CrateId, {[TitleId] = "Second"})
    const Saved = {One.LocalId, Two.LocalId}

    Live:Commit()
    T:Ok(Scene.Data, "the scene kept a pack")

    Scene:Unload()
    T:Ok(One.Destroyed and Two.Destroyed, "objects torn down")
    T:Eq(Objects:GetWorkspace()[One.RuntimeId], nil, "and out of the workspace")
    T:Eq(#Scene:GetInstances(), 0, "no copies left")

    const Again = Scene:Load()

    -- The whole point: an id written down before the unload still names the
    -- same object afterwards, even though its runtime id is new.
    const Back = Again:Find(Saved[1])
    T:Ok(Back, "the first saved id resolves again")
    T:Eq(Back:Get(TitleId), "First", "with its value")
    T:Ok(Back.RuntimeId ~= One.RuntimeId, "under a new runtime id")
    T:Eq(Again:Find(Saved[2]):Get(TitleId), "Second", "and so does the second")

    Scene:Destroy()
end)

T:Test("unloading does not save on its own", function()
    const Scene = Scenes.new({Name = "TestNoImplicitSave"})
    const Live = Scene:Load()

    Live:Create(CrateId, {[TitleId] = "Unsaved"})
    Scene:Unload()

    -- With more than one copy live, saving on unload would have to pick one and
    -- cannot, so it never saves and committing is always the caller's call.
    T:Eq(Scene.Data, nil, "nothing was written back")
    T:Eq(#Scene:Load():GetObjects(), 0, "so the scene reloads empty")

    Scene:Destroy()
end)

T:Test("a local id is never handed out twice, even across a reload", function()
    const Scene = Scenes.new({Name = "TestNoReuse"})
    const Live = Scene:Load()

    const First = Live:Create(BareId)
    const Taken = First.LocalId
    First:Destroy()

    Live:Commit()
    Scene:Unload()

    const Next = Scene:Load():Create(BareId)
    T:Ok(Next.LocalId > Taken, `{Next.LocalId} is past the id already spent`)

    Scene:Destroy()
end)

T:Test("a pack loads into a different scene without colliding", function()
    const Source = Scenes.new({Name = "TestSource"})
    const Live = Source:Load()
    Live:Create(CrateId, {[TitleId] = "Shared"})

    const Pack = Live:Serialize()

    -- Same bytes, two scenes. This is what per scene ids buy: a prefab is not
    -- tied to the scene that produced it.
    const Copy = Scenes.fromBuffer({Name = "TestCopy"}, Pack)
    T:Eq(#Copy:GetInstances(), 0, "registered with nothing live")

    const Original = Live:GetObjects()[1]
    const Restored = Copy:Load():GetObjects()[1]

    T:Eq(Restored:Get(TitleId), "Shared", "value carried")
    T:Eq(Restored.LocalId, Original.LocalId, "same id inside its scene")
    T:Ok(Restored.PersistentId ~= Original.PersistentId, "different persistent id, because a different scene")

    Source:Destroy()
    Copy:Destroy()
end)

T:Test("loading twice gives two equal copies", function()
    const Scene = Scenes.new({Name = "TestRoom"})
    const A = Scene:Load()
    A:Create(CrateId, {[TitleId] = "Room"})
    A:Commit()

    const B = Scene:Load()
    T:Eq(#Scene:GetInstances(), 2, "both live")

    const InA = A:GetObjects()[1]
    const InB = B:GetObjects()[1]
    T:Ok(InB, "the second copy has the object")

    -- Same thing, different one of it: that is the whole split between the two
    -- identities.
    T:Eq(InB.PersistentId, InA.PersistentId, "they agree on what it is")
    T:Ok(InB.RuntimeId ~= InA.RuntimeId, "and disagree on which it is")
    T:Eq(InB:Get(TitleId), "Room", "and it carries the value")

    -- Each copy answers for its own, so Find is never ambiguous.
    T:Eq(A:Find(InA.LocalId), InA, "A resolves to its own")
    T:Eq(B:Find(InA.LocalId), InB, "B resolves to its own")

    -- Editing one leaves the other alone.
    InA:Set(TitleId, "Edited")
    T:Eq(InB:Get(TitleId), "Room", "copies do not share state")

    Scene:Destroy()
end)

T:Test("a copy unloads itself, the scene unloads all of them", function()
    const Scene = Scenes.new({Name = "TestUnloadScope"})
    const A = Scene:Load()
    A:Create(BareId)
    A:Commit()

    const B = Scene:Load()
    const InA = A:GetObjects()[1]
    const InB = B:GetObjects()[1]

    B:Unload()
    T:Ok(InB.Destroyed, "the copy took its own objects")
    T:Ok(not InA.Destroyed, "and left the other alone")
    T:Eq(#Scene:GetInstances(), 1, "one copy left")

    Scene:Unload()
    T:Ok(InA.Destroyed, "the scene took the rest")
    T:Eq(#Scene:GetInstances(), 0, "none left")

    Scene:Destroy()
end)

T:Test("naming a scene loaded twice is refused rather than guessed", function()
    const Scene = Scenes.new({Name = "TestAmbiguous"})

    -- No copy at all: there is nowhere to put it.
    T:Throws(function()
        Objects.new(BareId, nil, Scene)
    end, "refused with no copy live")

    Scene:Load()
    T:Ok(Objects.new(BareId, nil, Scene), "accepted while there is one obvious answer")

    -- Two equally good copies, so picking one would put the object somewhere
    -- the caller did not choose.
    Scene:Load()
    T:Throws(function()
        Objects.new(BareId, nil, Scene)
    end, "refused once there are two")

    Scene:Destroy()
end)

T:Test("destroying a scene deregisters it", function()
    const Scene = Scenes.new({Name = "TestGone"})
    const Identifier = Scene.Id
    Scene:Load()

    T:Eq(Scenes:GetById(Identifier), Scene, "listed while it exists")
    T:Eq(Scenes:Get("TestGone"), Scene, "and findable by name")

    Scene:Destroy()
    T:Eq(Scenes:GetById(Identifier), nil, "gone by id")
    T:Eq(Scenes:Get("TestGone"), nil, "gone by name")

    -- The name is free again, but the id is not: a pack still naming the old
    -- scene must never decode as the new one.
    const Reused = Scenes.new({Name = "TestGone"})
    T:Ok(Reused, "the name can be registered again")
    T:Ok(Reused.Id ~= Identifier, "under a different id")

    Reused:Destroy()
end)

T:Test("the scene serializes what was committed, a copy what it holds", function()
    const Scene = Scenes.new({Name = "TestCommitted"})
    const Live = Scene:Load()

    Live:Create(CrateId, {[TitleId] = "Committed"})
    Live:Commit()

    Live:GetObjects()[1]:Set(TitleId, "Drifted")

    const _, Stored = Compressor:DecompressScene(Scene:Serialize())
    T:Eq(Stored[1].Properties[TitleId], "Committed", "the scene still says what it was told")

    const _, Current = Compressor:DecompressScene(Live:Serialize())
    T:Eq(Current[1].Properties[TitleId], "Drifted", "the copy says what it holds")

    Scene:Destroy()
end)

T:Test("a copy owns a folder, in the default tree when none is named", function()
    const Scene = Scenes.new({Name = "TestWorldTree"})
    const A = Scene:Load()
    const B = Scene:Load()

    T:Ok(A.Folder and A.Folder:IsA("Folder"), "a copy has a folder")
    T:Ok(A.Folder ~= B.Folder, "one each, because a copy is what gets placed")
    T:Eq(A.Folder.Name, `__copy_{A.Id}`, "named for the copy")

    const SceneFolder = A.Folder.Parent
    T:Eq(B.Folder.Parent, SceneFolder, "both under the scene's folder")
    T:Eq(SceneFolder.Name, `__scene_{Scene.Id}`, "named for the scene")
    T:Eq(SceneFolder.Parent.Name, World.RootName, "which hangs under the prism root")

    const Obj = A:Create(CrateId)
    T:Eq(Obj.Instance.Parent, A.Folder, "objects land in their own copy's folder")

    A:Unload()
    T:Eq(A.Folder.Parent, nil, "unloading takes the folder with it")
    T:Ok(SceneFolder.Parent, "the scene's folder stays while a copy remains")

    B:Unload()
    T:Eq(SceneFolder.Parent, nil, "and goes with the last of them")

    Scene:Destroy()
end)

T:Test("a copy goes wherever it is told, and takes its objects with it", function()
    -- A folder rather than a model precisely so this works: a scene of
    -- interfaces loads into PlayerGui, one of atmospheres into Lighting.
    const Elsewhere = Instance.new("Folder")
    Elsewhere.Name = "PrismTestElsewhere"
    Elsewhere.Parent = workspace

    const Scene = Scenes.new({Name = "TestNamedParent"})
    const Copy = Scene:Load(Elsewhere)

    T:Eq(Copy.Folder.Parent, Elsewhere, "parented where it was told")
    T:Eq(Copy:Create(CrateId).Instance.Parent, Copy.Folder, "and its objects with it")

    Copy:Unload()
    T:Eq(#Elsewhere:GetChildren(), 0, "unloading took the copy's folder")
    T:Ok(Elsewhere.Parent, "and left the parent alone, because it is not ours")

    Scene:Destroy()
    Elsewhere:Destroy()
end)

T:Test("an opened copy holds its objects and builds none of them", function()
    const Scene = Scenes.new({Name = "TestOpened"})
    const Copy = Scene:Open()

    T:Ok(Copy and Copy.Opened, "opened")
    T:Eq(Copy.Folder, nil, "with no folder on the server")

    const Obj = Copy:Create(CrateId, {[TitleId] = "Opened"})
    T:Eq(Obj.Instance, nil, "and no part: each admitted client draws its own")
    T:Eq(Obj:Get(TitleId), "Opened", "while the data is the server's as ever")
    T:Eq(Objects.ReachOf(Obj), "Admitted", "and kept for the admitted, whatever its type says")

    Copy:Commit()
    Copy:Unload()

    const Loaded = Scene:Load()
    T:Eq(#Loaded:GetObjects(), 1, "the same pack loads either way")
    T:Ok(Loaded:GetObjects()[1].Instance, "and loading builds the part")
    T:Eq(Objects.ReachOf(Loaded:GetObjects()[1]), "Everyone", "and follows its type again")

    Scene:Destroy()
end)

-- User ids 1 and 2 stand in for people who are not here. Nobody running this
-- suite is either of them.
T:Test("a scene that has admitted nobody is public", function()
    const Scene = Scenes.new({Name = "TestPublic"})

    T:Ok(Scene:IsPublic(), "public by default")
    T:Ok(Scene:Admits(1), "so it admits anyone")

    Scene:Admit(1)
    T:Ok(not Scene:IsPublic(), "one admission makes it private")
    T:Ok(Scene:Admits(1), "to the one admitted")
    T:Ok(not Scene:Admits(2), "and to nobody else")

    Scene:Evict(1)
    T:Ok(Scene:IsPublic(), "evicting the last makes it public again")

    Scene:Destroy()
end)

T:Test("admission takes a player or a user id, and belongs to the scene", function()
    const Scene = Scenes.new({Name = "TestAdmitted", Admitted = {1, 2}})
    T:Eq(#Scene:GetAdmitted(), 2, "admitted as it was registered")

    Scene:Admit(2)
    T:Eq(#Scene:GetAdmitted(), 2, "admitting twice is admitting once")

    Scene:Admit("somebody" :: any)
    T:Eq(#Scene:GetAdmitted(), 2, "something that is neither admits nobody")

    const Plr = Players:GetPlayers()[1]
    if Plr then
        Scene:Admit(Plr)
        T:Ok(Scene:Admits(Plr.UserId), "a player is kept by user id")

        Scene:Evict(Plr.UserId)
        T:Ok(not Scene:Admits(Plr), "and evicted by it")
        T:Ok(not Scene:IsPublic(), "leaving the rest of the list private")
    end

    Scene:Destroy()
end)

--=============================================================================
-- Permissions
--=============================================================================

T:Describe("Permissions")

Permissions:Register("TestViewer", {})
Permissions:Register("TestBuilder", {
    Global = {Rate = 5, CanPush = true, Capabilities = {"TestPublish"}},
    Scene = {
        CanCreate = true,
        CanEdit = true,
        CanDestroy = true,
        Objects = {Blacklist = {CrateId}},
        Capabilities = {"TestInvite"},
    },
})

-- Stands in for a player who is not connected. Rights are keyed by user id and
-- a table carrying one is all a check reads; the budget is keyed by the table,
-- so each stand-in starts with a fresh one. Ids this far below zero are never a
-- real player, Studio's test players included.
const function Ghost(UserId: number): any
    return {UserId = UserId}
end

T:Test("roles register once", function()
    T:Ok(Permissions:GetRegistered().TestBuilder, "registered")
    T:Eq(Permissions:Register("TestBuilder", {}), nil, "duplicate refused")
end)

T:Test("a player with no grant on a scene can do nothing there", function()
    const Plr = Ghost(-2001)
    const Obj = Objects.new(BareId)

    T:Ok(not Permissions:Can(Plr, "Edit", Obj), "cannot edit")
    T:Ok(not Permissions:Can(Plr, "Destroy", Obj), "cannot destroy")
    T:Ok(not Permissions:Can(Plr, "Create", {Scene = Obj.Scene, Parent = BareId}), "cannot create")

    Obj:Destroy()
end)

T:Test("a role granted on a scene holds there and nowhere else", function()
    const Plr = Ghost(-2002)
    const Here = Scenes.new({Name = "TestRightsHere"}):Load()
    const There = Scenes.new({Name = "TestRightsThere"}):Load()
    const InHere = Here:Create(BareId)
    const InThere = There:Create(BareId)

    T:Ok(Here.Owner:Grant(Plr, "TestBuilder"), "granted")
    T:Ok(Permissions:Can(Plr, "Edit", InHere), "may edit here")
    T:Ok(not Permissions:Can(Plr, "Edit", InThere), "and not there")
    T:Eq(Here.Owner:GetRights(Plr).Role, "TestBuilder", "the role it came from is recorded")

    Here.Owner:Destroy()
    There.Owner:Destroy()
end)

T:Test("a present object whitelist is exhaustive, and the blacklist always holds", function()
    Permissions:Register("TestBareOnly", {Scene = {CanEdit = true, Objects = {Whitelist = {BareId}}}})

    const Plr = Ghost(-2003)
    const Copy = Scenes.new({Name = "TestObjectLists"}):Load()
    const Bare = Copy:Create(BareId)
    const Crate = Copy:Create(CrateId)

    Copy.Owner:Grant(Plr, "TestBareOnly")
    T:Ok(Permissions:Can(Plr, "Edit", Bare), "the whitelisted type")
    T:Ok(not Permissions:Can(Plr, "Edit", Crate), "and nothing else")

    Copy.Owner:Grant(Plr, "TestBuilder")
    T:Ok(Permissions:Can(Plr, "Edit", Bare), "an absent whitelist constrains nothing")
    T:Ok(not Permissions:Can(Plr, "Edit", Crate), "but the blacklist does")

    Copy.Owner:Destroy()
end)

T:Test("property lists govern writing, per type where they say so", function()
    Permissions:Register("TestNoCrateTint", {
        Scene = {CanEdit = true, CanDestroy = true, Properties = {Blacklist = {[TintId] = {CrateId}}}},
    })
    Permissions:Register("TestTitleOnly", {Scene = {CanEdit = true, Properties = {Whitelist = {TitleId}}}})

    const Plr = Ghost(-2004)
    const Copy = Scenes.new({Name = "TestPropertyLists"}):Load()
    const Crate = Copy:Create(CrateId)

    Copy.Owner:Grant(Plr, "TestNoCrateTint")
    T:Ok(not Permissions:Can(Plr, "Edit", Crate, TintId), "tint is kept off crates")
    T:Ok(Permissions:Can(Plr, "Edit", Crate, TitleId), "other properties are not")
    T:Ok(Permissions:Can(Plr, "Destroy", Crate), "and a destroy writes no property")

    Copy.Owner:Grant(Plr, "TestTitleOnly")
    T:Ok(Permissions:Can(Plr, "Edit", Crate, TitleId), "the whitelisted property")
    T:Ok(not Permissions:Can(Plr, "Edit", Crate, HealthId), "and nothing else")

    Copy.Owner:Destroy()
end)

T:Test("granting a role replaces what was there, and capabilities come one at a time", function()
    const Plr = Ghost(-2005)
    const Scene = Scenes.new({Name = "TestCapabilities"})

    Scene:Grant(Plr, "TestBuilder")
    T:Ok(Permissions:Has(Plr, "TestInvite", Scene.Id), "the role's capability")

    Scene:GrantCapability(Plr, "TestKick")
    T:Ok(Permissions:Has(Plr, "TestKick", Scene.Id), "one granted on its own")

    Scene:RevokeCapability(Plr, "TestInvite")
    T:Ok(not Permissions:Has(Plr, "TestInvite", Scene.Id), "one revoked on its own")

    Scene:Grant(Plr, "TestViewer")
    T:Ok(not Permissions:Has(Plr, "TestKick", Scene.Id), "a new role clears the set")
    T:Eq(Scene:GetRights(Plr).CanEdit, false, "verbs included")

    Scene:Destroy()
end)

T:Test("a grant names a user id, and goes with its scene", function()
    const Scene = Scenes.new({Name = "TestByUserId", Rights = {[-2006] = "TestBuilder"}})
    const Obj = Scene:Load():Create(BareId)

    -- Granted before anyone holding the id was here, and held by whoever holds
    -- it -- which is what lets an owner rejoin into their own level.
    T:Ok(Permissions:Can(Ghost(-2006), "Edit", Obj), "held by whoever holds the id")
    T:Ok(Scene:GetRights(-2006), "and readable by id")

    Scene:Destroy()
    T:Eq(Permissions:GetOn(Scene, -2006), nil, "gone with the scene")
end)

T:Test("global rights: a budget and whether you may push", function()
    const Plr = Ghost(-2007)

    T:Eq(Permissions:Get(Plr).Rate, 60, "the default budget for anyone ungranted")
    T:Ok(not Permissions:CanPush(Plr), "and no pushing")

    T:Ok(Permissions:Grant(Plr, "TestBuilder"), "granted")
    T:Eq(Permissions:Get(Plr).Rate, 5, "the role's budget")
    T:Ok(Permissions:CanPush(Plr), "its right to push")
    T:Ok(Permissions:Has(Plr, "TestPublish"), "and its global capability")

    Permissions:Revoke(Plr)
    T:Ok(not Permissions:CanPush(Plr), "revoked back to the default")
end)

T:Test("REGRESSION: every set in the payload is a sequential array", function()
    -- Sent as a map, non-sequential numeric keys are not guaranteed to survive
    -- remote serialization, and the client silently allowed blacklisted types.
    const Scene = Scenes.new({Name = "TestPayload", Rights = {[-2009] = "TestBuilder"}})
    const Payload = Permissions:GetPayloadOn(Scene, -2009)

    T:Ok(Payload, "built")

    if Payload then
        T:Eq(#Payload.ObjectBlacklist, 1, "one entry, reachable by length")
        T:Eq(Payload.ObjectBlacklist[1], CrateId, "entry is the object id")
        T:Eq(Payload.Capabilities[1], "TestInvite", "capabilities as a list")
        T:Eq(Payload.Role, "TestBuilder", "role name carried")
    end

    Scene:Destroy()
end)

T:Test("rate limiting cuts off past the budget", function()
    const Plr = Ghost(-2008)
    Permissions:Grant(Plr, "TestBuilder") -- Rate = 5

    local Allowed = 0
    for _ = 1, 20 do
        if Permissions:Consume(Plr) then
            Allowed += 1
        end
    end

    T:Eq(Allowed, 5, "exactly the budget")
    Permissions:Revoke(Plr)
end)

--=============================================================================
-- Transactions
--=============================================================================

T:Describe("Transactions")

const Transactions = Prism.Transactions

-- TestBuilder's rate is five, which is what the budget test wants and what
-- every other test here would trip over. This one is the same role with room to
-- work in, blacklist included.
Permissions:Register("TestBulk", {
    Global = {Rate = 200, CanPush = true},
    Scene = {
        CanCreate = true,
        CanEdit = true,
        CanDestroy = true,
        Objects = {Blacklist = {CrateId}},
    },
})

T:Test("the wire form round trips every operation kind", function()
    const Operations = {
        {Kind = "Create", Object = CrateId, Instance = 0, Properties = {[TitleId] = "Made", [HealthId] = 40}},
        {Kind = "Set", Target = 7, Property = TitleId, Value = "Changed"},
        {Kind = "Destroy", Target = 9},
    }

    const Read = Compressor:DecompressTransaction(Compressor:CompressTransaction(Operations :: any))

    T:Eq(#Read, 3, "three operations")

    T:Eq(Read[1].Kind, "Create", "first is a create")
    T:Eq(Read[1].Object, CrateId, "object type carried")
    T:Eq(Read[1].Instance, 0, "scene copy carried")
    T:Eq(Read[1].Properties[TitleId], "Made", "initial text")
    T:Eq(Read[1].Properties[HealthId], 40, "initial number")

    T:Eq(Read[2].Kind, "Set", "second is a set")
    T:Eq(Read[2].Target, 7, "target carried")
    T:Eq(Read[2].Property, TitleId, "property carried")
    T:Eq(Read[2].Value, "Changed", "value carried")
    T:Eq(Read[2].Type, "Text", "the value's own tag came back with it")

    T:Eq(Read[3].Kind, "Destroy", "third is a destroy")
    T:Eq(Read[3].Target, 9, "target carried")
end)

T:Test("the same edit always produces the same bytes", function()
    -- Written in id order rather than hash order, so one edit can be compared
    -- against another rather than only replayed. The two tables hold the same
    -- pairs, inserted in opposite orders.
    const First = {}
    First[TitleId] = "Same"
    First[HealthId] = 10

    const Second = {}
    Second[HealthId] = 10
    Second[TitleId] = "Same"

    const A = Compressor:CompressTransaction({{Kind = "Create", Object = CrateId, Instance = 3, Properties = First}} :: any)
    const B = Compressor:CompressTransaction({{Kind = "Create", Object = CrateId, Instance = 3, Properties = Second}} :: any)

    T:Eq(buffer.tostring(A), buffer.tostring(B), "byte identical")
end)

T:Test("an operation of an unknown kind is refused outright", function()
    const Encoded = Compressor:CompressTransaction({{Kind = "Destroy", Target = 4}} :: any)

    -- Header, version, count, then the first operation's kind byte.
    buffer.writeu8(Encoded, 5, 200)

    T:Throws(function()
        Compressor:DecompressTransaction(Encoded)
    end, "unknown kind")
end)

T:Test("a truncated transaction throws rather than half decoding", function()
    const Encoded = Compressor:CompressTransaction({
        {Kind = "Set", Target = 1, Property = TitleId, Value = "Cut"},
    } :: any)

    -- Everything up to and including the kind byte, and nothing of the target.
    const Short = buffer.create(6)
    buffer.copy(Short, 0, Encoded, 0, 6)

    T:Throws(function()
        Compressor:DecompressTransaction(Short)
    end, "truncated")
end)

T:Test("a transaction creates, sets and destroys as one", function()
    const Existing = Objects.new(BareId)
    const Doomed = Objects.new(BareId)

    const Applied, Created = Transactions.new()
        :Create(CrateId, {[TitleId] = "FromTransaction"})
        :Set(Existing, TitleId, "Edited")
        :Destroy(Doomed)
        :Commit()

    T:Ok(Applied, "applied")
    T:Eq(#Created, 1, "one object created")

    const Made = Objects:Get(Created[1])
    T:Ok(Made, "the created object is live")
    T:Eq(Made:Get(TitleId), "FromTransaction", "initial value applied")
    T:Eq(Existing:Get(TitleId), "Edited", "the set applied")
    T:Ok(Doomed.Destroyed, "the destroy applied")

    Made:Destroy()
    Existing:Destroy()
end)

T:Test("committing nothing succeeds and sends nothing", function()
    const Applied, Created = Transactions.new():Commit()
    T:Ok(Applied, "succeeded")
    T:Eq(#Created, 0, "created nothing")
end)

T:Test("an operation that cannot be built stops the whole commit", function()
    const Obj = Objects.new(BareId)

    const Edit = Transactions.new()
        :Set(Obj, TitleId, "First")
        :Set(Obj, "NoSuchProperty", "Second")

    T:Eq(Edit.Rejected, 1, "one operation refused while building")
    T:Eq(#Edit.Operations, 1, "the other was still built")
    T:Ok(not Edit:Commit(), "commit refused rather than sending what is left")
    T:Eq(Obj:Get(TitleId), "Untitled", "nothing applied")

    Obj:Destroy()
end)

T:Test("one refused operation applies none of the others", function()
    const Obj = Objects.new(BareId)

    const Applied = Transactions.Apply(nil, {
        {Kind = "Set", Target = Obj.RuntimeId, Property = TitleId, Value = "Never", Type = "Text"},
        {Kind = "Destroy", Target = 999999},
    } :: any)

    T:Ok(not Applied, "refused")
    T:Eq(Obj:Get(TitleId), "Untitled", "the set that came first never happened")

    Obj:Destroy()
end)

T:Test("a value whose tag disagrees with the property is refused", function()
    const Obj = Objects.new(CrateId)

    const Applied = Transactions.Apply(nil, {
        {Kind = "Set", Target = Obj.RuntimeId, Property = HealthId, Value = "not a number", Type = "Text"},
    } :: any)

    T:Ok(not Applied, "refused")
    T:Eq(Obj:Get(HealthId), 100, "unchanged")

    Obj:Destroy()
end)

T:Test("changing and destroying the same object in one transaction applies", function()
    const Obj = Objects.new(BareId)

    -- Declared the other way round. Every operation is resolved before any of
    -- them run, and destroys run last, so the set lands on a live object and
    -- the object goes afterwards.
    const Applied = Transactions.Apply(nil, {
        {Kind = "Destroy", Target = Obj.RuntimeId},
        {Kind = "Set", Target = Obj.RuntimeId, Property = TitleId, Value = "Ordered", Type = "Text"},
    } :: any)

    T:Ok(Applied, "applied")
    T:Ok(Obj.Destroyed, "the destroy landed")
    T:Eq(Obj.Properties[TitleId].Value, "Ordered", "and the set landed before it")
end)

T:Test("naming the same object for destruction twice is not a failure", function()
    const Obj = Objects.new(BareId)

    const Applied = Transactions.Apply(nil, {
        {Kind = "Destroy", Target = Obj.RuntimeId},
        {Kind = "Destroy", Target = Obj.RuntimeId},
    } :: any)

    T:Ok(Applied, "applied")
    T:Ok(Obj.Destroyed, "destroyed once")
end)

T:Test("a list past the cap is refused before anything is planned", function()
    const Obj = Objects.new(BareId)
    const Operations = table.create(1025)

    Operations[1] = {Kind = "Set", Target = Obj.RuntimeId, Property = TitleId, Value = "Never", Type = "Text"}
    for Index = 2, 1025 do
        Operations[Index] = {Kind = "Destroy", Target = 999999}
    end

    T:Ok(not Transactions.Apply(nil, Operations :: any), "refused")
    T:Eq(Obj:Get(TitleId), "Untitled", "nothing applied")

    Obj:Destroy()
end)

T:Test("a create carrying a value its type cannot hold is refused", function()
    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = CrateId, Instance = 0, Properties = {[HealthId] = "not a number"}},
    } :: any), "refused")
end)

T:Test("a create carrying a property its type does not have drops it", function()
    -- What restoring a saved object does with one, rather than a refusal: the
    -- object is still the object that was asked for.
    const Applied, Created = Transactions.Apply(nil, {
        {Kind = "Create", Object = BareId, Instance = 0, Properties = {[TitleId] = "Kept", [HealthId] = 50}},
    } :: any)

    T:Ok(Applied, "applied")

    const Made = Objects:Get(Created[1])
    T:Eq(Made:Get(TitleId), "Kept", "the value it does carry")
    T:Eq(Made:Get(HealthId), nil, "the one it does not")

    Made:Destroy()
end)

T:Test("a create lands in the copy it names", function()
    const Scene = Scenes.new({Name = "TransactionRoom"})
    const Copy = Scene:Load()

    const Applied, Created = Transactions.new()
        :Create(BareId, {[TitleId] = "InRoom"}, Copy.Id)
        :Commit()

    T:Ok(Applied, "applied")

    const Made = Objects:Get(Created[1])
    T:Eq(Made.InstanceId, Copy.Id, "landed in the copy")
    T:Eq(Copy:Find(Made.LocalId), Made, "the copy answers for it")

    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = BareId, Instance = 999999, Properties = {}},
    } :: any), "a copy that is not live is refused")

    Copy:Unload()
end)

T:Test("the create verb and the blacklist are both checked", function()
    const Plr = Ghost(-3001)
    const Default = Scenes:GetDefault()
    Permissions:Grant(Plr, "TestBulk")
    Default:Grant(Plr, "TestBulk")

    T:Ok(not Transactions.Apply(Plr, {
        {Kind = "Create", Object = CrateId, Instance = 0, Properties = {}},
    } :: any), "a blacklisted type is refused")

    const Applied, Created = Transactions.Apply(Plr, {
        {Kind = "Create", Object = BareId, Instance = 0, Properties = {}},
    } :: any)

    T:Ok(Applied, "a permitted type is created")

    Default:Grant(Plr, "TestViewer")
    T:Ok(not Transactions.Apply(Plr, {
        {Kind = "Create", Object = BareId, Instance = 0, Properties = {}},
    } :: any), "a role without the verb cannot create")

    Default:Revoke(Plr)
    Permissions:Revoke(Plr)

    const Made = if Created[1] then Objects:Get(Created[1]) else nil
    if Made then
        Made:Destroy()
    end
end)

T:Test("a transaction is charged one action per operation", function()
    const Plr = Ghost(-3002)
    Permissions:Grant(Plr, "TestBuilder") -- Rate = 5
    Scenes:GetDefault():Grant(Plr, "TestBuilder")

    const Objs = {Objects.new(BareId), Objects.new(BareId), Objects.new(BareId)}

    const function Edit(Count: number): boolean
        const Operations = {}
        for Index = 1, Count do
            table.insert(Operations, {
                Kind = "Set",
                Target = Objs[Index].RuntimeId,
                Property = TitleId,
                Value = `Value{Index}`,
                Type = "Text",
            })
        end

        return (Transactions.Apply(Plr, Operations :: any))
    end

    T:Ok(Edit(3), "three operations fit a budget of five")
    T:Ok(not Edit(3), "three more do not, in the same window")

    Scenes:GetDefault():Revoke(Plr)
    Permissions:Revoke(Plr)

    for _, Obj in Objs do
        Obj:Destroy()
    end
end)

T:Test("an object duplicates into its own copy, values and all", function()
    const Copy = Scenes.new({Name = "TestDuplicated"}):Load()
    const Original = Copy:Create(CrateId, {[TitleId] = "Original", [HealthId] = 40})
    const Twin = Objects:Duplicate(Original)

    T:Ok(Twin and Twin ~= Original, "a new object")

    if not Twin then
        Copy.Owner:Destroy()
        return
    end

    T:Eq(Twin:Get(TitleId), "Original", "holding its text")
    T:Eq(Twin:Get(HealthId), 40, "and its number")
    T:Eq(Twin.InstanceId, Copy.Id, "in the same copy")
    T:Ok(Twin.LocalId ~= Original.LocalId, "under a new local id")
    T:Ok(Twin.Instance and Twin.Instance ~= Original.Instance, "with a part of its own")

    Twin:Set(TitleId, "Twin")
    T:Eq(Original:Get(TitleId), "Original", "and nothing shared with the original")

    const Elsewhere = Scenes.new({Name = "TestDuplicatedElsewhere"}):Load()
    const Moved = Objects:Duplicate(Original, Elsewhere)
    T:Eq(Moved and Moved.InstanceId, Elsewhere.Id, "or into another copy when named")

    Copy.Owner:Destroy()
    Elsewhere.Owner:Destroy()
end)

T:Test("a transaction duplicates as a create", function()
    const Source = Objects.new(BareId, {[TitleId] = "Source"})
    const Applied, Created = Transactions.new():Duplicate(Source):Commit()

    T:Ok(Applied, "applied")

    const Made = if Created[1] then Objects:Get(Created[1]) else nil
    T:Ok(Made, "made one")

    if Made then
        T:Eq(Made:Get(TitleId), "Source", "holding the source's value")
        T:Eq(Made.InstanceId, Source.InstanceId, "in the source's copy")
        Made:Destroy()
    end

    Source:Destroy()
end)

--=============================================================================
-- Locks
--=============================================================================

T:Describe("Locks")

T:Test("a lock keeps everyone else's edits off an object", function()
    const Holder = Ghost(-3101)
    const Other = Ghost(-3102)
    const Default = Scenes:GetDefault()

    for _, Plr in {Holder, Other} do
        Permissions:Grant(Plr, "TestBulk")
        Default:Grant(Plr, "TestBulk")
    end

    const Obj = Objects.new(BareId)

    const function SetAs(Plr: any, Value: string): boolean
        return (Transactions.Apply(Plr, {
            {Kind = "Set", Target = Obj.RuntimeId, Property = TitleId, Value = Value, Type = "Text"},
        } :: any))
    end

    T:Ok(Objects:Lock({Obj}, Holder), "locked")
    T:Eq(Objects:GetLock(Obj), -3101, "held by its user id")
    T:Ok(Objects:Lock({Obj}, Holder), "taking it again is fine for the holder")
    T:Ok(not Objects:Lock({Obj}, Other), "but not for anyone else")

    T:Ok(not SetAs(Other, "Theirs"), "another player's edit is refused")
    T:Ok(SetAs(Holder, "Mine"), "the holder's goes through")
    T:Ok(Transactions.Apply(nil, {
        {Kind = "Set", Target = Obj.RuntimeId, Property = TitleId, Value = "Server", Type = "Text"},
    } :: any), "and the server's own ignores it")

    T:Ok(not Objects:Unlock({Obj}, Other), "someone else cannot release it")
    T:Eq(Objects:GetLock(Obj), -3101, "which stays held")
    T:Ok(Objects:Unlock({Obj}, Holder), "the holder can")
    T:Eq(Objects:GetLock(Obj), nil, "free again")
    T:Ok(SetAs(Other, "Theirs"), "and anyone with rights may edit it")

    -- All or nothing, so a multi-object drag never ends up half held.
    const Second = Objects.new(BareId)
    Objects:Lock({Obj}, Other)
    T:Ok(not Objects:Lock({Second, Obj}, Holder), "one taken refuses the lot")
    T:Eq(Objects:GetLock(Second), nil, "and takes none of it")

    Objects:Unlock({Obj})
    T:Eq(Objects:GetLock(Obj), nil, "the server can release anyone's")

    Objects:Lock({Second}, Holder)
    Second:Destroy()
    T:Eq(Objects:GetLock(Second), nil, "a lock goes with its object")

    Obj:Destroy()

    for _, Plr in {Holder, Other} do
        Default:Revoke(Plr)
        Permissions:Revoke(Plr)
    end
end)

--=============================================================================
-- Scene commits from a client
--=============================================================================

T:Describe("Scene commits")

-- The handler is a plain function on the manifest entry, so it can be called
-- with a stand-in for a Player exactly as the permission tests do -- there is
-- no client in a server-only run to invoke it for real.
const Commit = Networking:Get("Scenes.Commit").OnInvoke

-- Every commit test pushes as the same user, granted and revoked around each
-- one; a fresh table each time gives each test a fresh budget.
const function Pusher(): any
    return {UserId = -5000}
end

const function Packed(LastId: number, Entries: {{Parent: number, LocalId: number, Properties: {[number]: any}}}): buffer
    const Objects_ = {}
    for Index, Entry in Entries do
        Objects_[Index] = {
            __type = "DecompressedObject",
            LocalId = Entry.LocalId,
            Parent = Entry.Parent,
            Properties = Entry.Properties,
        }
    end

    return Compressor:CompressScene(LastId, Objects_ :: any)
end

T:Test("a pack a client built becomes a scene of its own", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted, Identifier = Commit(Ghost, "PushedRoom", Packed(1, {
        {Parent = BareId, LocalId = 1, Properties = {[TitleId] = "Pushed"}},
    }))

    Permissions:Revoke(Ghost)

    T:Ok(Accepted, "accepted")
    T:Ok(Identifier and Identifier > 0, "answered with an id")

    const Scene = Scenes:Get("PushedRoom")
    T:Ok(Scene, "registered under the name it asked for")

    if not Scene then
        return
    end

    T:Eq(Scene.Id, Identifier, "the id it answered with")
    T:Eq(#Scene:GetInstances(), 0, "registered, not loaded")
    T:Ok(not Scene:IsPublic(), "private")
    T:Ok(Scene:Admits(-5000), "to the player who pushed it")
    T:Eq(Scene:GetRights(-5000), nil, "who holds nothing on it with no push role set")

    const Copy = Scene:Load()
    const Restored = Copy:Find(1)

    T:Ok(Restored, "the object came across")
    T:Eq(Restored:Get(TitleId), "Pushed", "with its value")
    T:Eq(Restored.Scene, Scene.Id, "stamped with the server's scene id")

    -- The pack claimed a last id of 1 and held exactly one object, so the next
    -- one is 2 either way. What this checks is that the scene reads a pack the
    -- server wrote rather than the client's bytes: see the next test.
    const Fresh = Copy:Create(BareId)
    T:Eq(Fresh.LocalId, 2, "the counter continues from what the pack held")

    Copy:Unload()
end)

T:Test("a push role is granted to whoever pushes", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")
    Scenes:SetPushRole("TestBulk")

    const Accepted, Identifier = Commit(Ghost, "RoleRoom", Packed(1, {
        {Parent = BareId, LocalId = 1, Properties = {}},
    }))

    Scenes:SetPushRole(nil)
    Permissions:Revoke(Ghost)

    T:Ok(Accepted, "accepted")

    const Scene = Scenes:GetById(Identifier)
    const Rights = if Scene then Scene:GetRights(-5000) else nil
    T:Ok(Rights, "the pusher holds rights on it")

    if Rights then
        T:Eq(Rights.Role, "TestBulk", "from the push role")
    end
end)

T:Test("the id space a pack claims is not taken on trust", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    -- One object, and a last id near the top of the space. Kept as it arrived,
    -- the scene would have room for one more object ever.
    const Accepted = Commit(Ghost, "ClaimedRoom", Packed(Handles.MAX_LOCAL - 1, {
        {Parent = BareId, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)
    T:Ok(Accepted, "accepted")

    const Scene = Scenes:Get("ClaimedRoom")
    if not Scene then
        T:Ok(false, "not registered")
        return
    end

    const Copy = Scene:Load()
    T:Eq(Copy:Create(BareId).LocalId, 2, "the counter was rewritten to what the pack actually held")
    Copy:Unload()
end)

T:Test("a player who may not push cannot commit at all", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestViewer")

    const Accepted = Commit(Ghost, "ViewerRoom", Packed(1, {
        {Parent = BareId, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)

    T:Ok(not Accepted, "refused")
    T:Eq(Scenes:Get("ViewerRoom"), nil, "and registered nothing")
end)

T:Test("an unregistered object type refuses the pack", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "UnknownRoom", Packed(1, {
        {Parent = 99999, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)

    T:Ok(not Accepted, "refused")
    T:Eq(Scenes:Get("UnknownRoom"), nil, "and registered nothing")
end)

T:Test("a name already taken is refused before the pack is read", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "PushedRoom", Packed(1, {
        {Parent = BareId, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)
    T:Ok(not Accepted, "refused")
end)

T:Test("bytes that are not a pack are refused rather than thrown", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "GarbageRoom", buffer.fromstring("not a pack at all"))

    Permissions:Revoke(Ghost)

    T:Ok(not Accepted, "refused")
    T:Eq(Scenes:Get("GarbageRoom"), nil, "and registered nothing")
end)

T:Test("an empty name is refused", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "", Packed(1, {
        {Parent = BareId, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)
    T:Ok(not Accepted, "refused")
end)

T:Test("a pack past the object cap is refused", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Entries = table.create(4097)
    for Index = 1, 4097 do
        Entries[Index] = {Parent = BareId, LocalId = Index, Properties = {}}
    end

    const Accepted = Commit(Ghost, "HugeRoom", Packed(4097, Entries))

    Permissions:Revoke(Ghost)

    T:Ok(not Accepted, "refused")
    T:Eq(Scenes:Get("HugeRoom"), nil, "and registered nothing")
end)

T:Test("a commit costs one action, not one per object", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBuilder") -- Rate = 5

    const Pack = Packed(3, {
        {Parent = BareId, LocalId = 1, Properties = {}},
        {Parent = BareId, LocalId = 2, Properties = {}},
        {Parent = BareId, LocalId = 3, Properties = {}},
    })

    local Allowed = 0
    for Index = 1, 6 do
        const Accepted = Commit(Ghost, `BudgetRoom{Index}`, Pack)
        if Accepted then
            Allowed += 1
        end
    end

    Permissions:Revoke(Ghost)

    -- Five commits of three objects each, not one and two thirds.
    T:Eq(Allowed, 5, "the budget counted packets")
end)

--=============================================================================
-- References
--=============================================================================

T:Describe("References")

-- Registered at load with everything else, so the client receives them too and
-- checks that a reference resolves on its side as well.
const TargetId = Properties:Register({
    Name = "TestTarget",
    Type = "Object",
    DefaultValue = 0,
}) :: number

const DoorOnlyId = Properties:Register({
    Name = "TestDoorOnly",
    Type = "Object",
    DefaultValue = 0,
    Constraints = {Types = {"TestDoor"}},
}) :: number

const DoorId = Objects:Register({
    Name = "TestDoor",
    Properties = {TitleId},
}) :: number

const ButtonId = Objects:Register({
    Name = "TestButton",
    Properties = {TitleId, TargetId, DoorOnlyId},
}) :: number

const function Room(Name: string)
    const Scene = Scenes.new({Name = Name})
    return Scene, Scene:Load() :: any
end

T:Test("a reference reads back as the object it names", function()
    const Scene, Copy = Room("RefRoom")
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})

    T:Eq(Button:Get(TargetId), nil, "nothing pointed at to begin with")

    T:Ok(Button:Set(TargetId, Door), "takes the object itself")
    T:Eq(Button:Get(TargetId), Door, "and hands the object back")
    T:Eq(Button:GetProperty(TargetId).Value, Door.LocalId, "storing its local id")

    T:Ok(Button:Set(TargetId, Door.LocalId), "takes a raw id too")
    T:Eq(Button:Get(TargetId), Door, "resolving to the same object")

    T:Ok(Button:Set(TargetId, nil), "and clears")
    T:Eq(Button:GetProperty(TargetId).Value, 0, "to no target")

    Scene:Destroy()
end)

T:Test("a destroyed target reads as nil and the id stays put", function()
    const Scene, Copy = Room("RefDangling")
    const Door = Copy:Create(DoorId)
    const Button = Copy:Create(ButtonId)

    Button:Set(TargetId, Door)
    const Stored = Button:GetProperty(TargetId).Value

    Door:Destroy()

    T:Eq(Button:Get(TargetId), nil, "reads as nothing")
    T:Eq(Button:GetProperty(TargetId).Value, Stored, "but the id is kept")

    Scene:Destroy()
end)

T:Test("each copy of one scene resolves its own", function()
    const Scene = Scenes.new({Name = "RefTwice"})
    const First = Scene:Load() :: any

    const Door = First:Create(DoorId, {[TitleId] = "Door"})
    const Button = First:Create(ButtonId, {[TitleId] = "Button"})
    Button:Set(TargetId, Door)
    First:Commit()

    const Second = Scene:Load() :: any

    const OtherButton = Second:Find(Button.LocalId)
    const OtherDoor = Second:Find(Door.LocalId)

    T:Ok(OtherButton and OtherDoor, "the second copy restored both")
    T:Ok(OtherButton ~= Button, "and they are not the same objects")

    T:Eq(Button:Get(TargetId), Door, "the first copy's button points at the first copy's door")
    T:Eq(OtherButton:Get(TargetId), OtherDoor, "and the second's at the second's")

    Scene:Destroy()
end)

T:Test("a reference only names objects in the same copy", function()
    const Scene, Here = Room("RefHere")
    const Elsewhere = Scene:Load() :: any

    const Door = Elsewhere:Create(DoorId)
    const Button = Here:Create(ButtonId)

    T:Ok(not Button:Set(TargetId, Door), "refused across copies")
    T:Eq(Button:GetProperty(TargetId).Value, nil, "and nothing was written")

    Scene:Destroy()
end)

T:Test("a constrained reference refuses what it may not point at", function()
    const Scene, Copy = Room("RefConstrained")
    const Door = Copy:Create(DoorId)
    const Button = Copy:Create(ButtonId)
    const Other = Copy:Create(ButtonId)

    T:Ok(Button:Set(DoorOnlyId, Door), "a door is allowed")
    T:Ok(not Button:Set(DoorOnlyId, Other), "a button is not")
    T:Eq(Button:Get(DoorOnlyId), Door, "and the refusal changed nothing")

    -- Nothing to check the constraint against, and refusing would make a pack
    -- restorable only in the order it happened to be written.
    T:Ok(Button:Set(DoorOnlyId, 999999), "a dangling id is allowed")
    T:Eq(Button:Get(DoorOnlyId), nil, "and reads as nothing")

    Scene:Destroy()
end)

T:Test("a reference survives a commit and a reload", function()
    const Scene = Scenes.new({Name = "RefSaved"})
    const Copy = Scene:Load() :: any

    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})
    Button:Set(TargetId, Door)

    Copy:Commit()
    Copy:Unload()

    const Reloaded = Scene:Load() :: any
    const Back = Reloaded:Find(Button.LocalId)

    T:Ok(Back, "the button came back")
    T:Eq(Back:Get(TargetId), Reloaded:Find(Door.LocalId), "still pointing at the door")

    Scene:Destroy()
end)

T:Test("a link on a reference is refused at registration", function()
    -- An Object is a number as far as Luau is concerned, so the type check
    -- would pass and the part would be driven with an id meaning nothing
    -- outside its copy.
    const Linked = Objects:Register({
        Name = "TestLinkedReference",
        Properties = {TargetId},
        Instance = Template,
        Links = {{Property = TargetId, Type = "Attribute", Name = "Target"}},
    }) :: number

    T:Eq(Objects:GetRegistry(Linked).Links, nil, "the link was dropped")
    Objects:Unregister(Linked)
end)

T:Test("duplicating one object keeps its reference, a group remaps it", function()
    const Scene, Copy = Room("RefDuplicate")
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})
    Button:Set(TargetId, Door)

    -- One object on its own: the copy still works the original door, which is
    -- what duplicating a lever without its door should do.
    const Alone = Objects:Duplicate(Button)
    T:Eq(Alone:Get(TargetId), Door, "the lone duplicate keeps the original target")

    const Made = Objects:DuplicateGroup({Button, Door})
    T:Eq(#Made, 2, "both were made")

    const NewButton, NewDoor = Made[1], Made[2]
    T:Ok(NewButton ~= Button and NewDoor ~= Door, "new objects")
    T:Eq(NewButton:Get(TargetId), NewDoor, "and the copy points at the copy")
    T:Eq(Button:Get(TargetId), Door, "the original is untouched")

    Scene:Destroy()
end)

T:Test("a group duplicate keeps references pointing outside it", function()
    const Scene, Copy = Room("RefOutside")
    const Door = Copy:Create(DoorId)
    const First = Copy:Create(ButtonId)
    const Second = Copy:Create(ButtonId)

    First:Set(TargetId, Door)
    Second:Set(TargetId, Door)

    -- The door is not in the group, so both copies keep working it.
    const Made = Objects:DuplicateGroup({First, Second})

    T:Eq(Made[1]:Get(TargetId), Door, "first copy still points outside")
    T:Eq(Made[2]:Get(TargetId), Door, "and so does the second")

    Scene:Destroy()
end)

T:Test("a transaction can create two objects already wired together", function()
    const Scene, Copy = Room("RefWired")

    const Applied, Created = Transactions.Apply(nil, {
        {
            Kind = "Create",
            Object = ButtonId,
            Instance = Copy.Id,
            Properties = {[TitleId] = "Button"},
            References = {[TargetId] = 2},
        },

        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {[TitleId] = "Door"}},
    } :: any)

    T:Ok(Applied, "applied")
    T:Eq(#Created, 2, "two objects")

    const Button = Objects:Get(Created[1])
    const Door = Objects:Get(Created[2])

    -- The id the door answers to did not exist when the operation naming it
    -- was written, which is the whole reason a reference names the operation.
    T:Eq(Button:Get(TargetId), Door, "the button points at the door")

    Scene:Destroy()
end)

T:Test("a reference to something this transaction does not create is refused", function()
    const Scene, Copy = Room("RefBadOperation")
    const Standing = Copy:Create(DoorId, {[TitleId] = "Standing"})

    T:Ok(not Transactions.Apply(nil, {
        {
            Kind = "Create",
            Object = ButtonId,
            Instance = Copy.Id,
            Properties = {},
            References = {[TargetId] = 4},
        },
    } :: any), "no operation 4")

    -- A valid operation, and still not something that makes an object.
    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = ButtonId, Instance = Copy.Id, Properties = {}, References = {[TargetId] = 2}},
        {Kind = "Set", Target = Standing.RuntimeId, Property = TitleId, Value = "Moved", Type = "Text"},
    } :: any), "operation 2 is not a create")

    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = ButtonId, Instance = Copy.Id, Properties = {}, References = {[TitleId] = 2}},
        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {}},
    } :: any), "a Text property cannot hold a reference")

    T:Eq(#Copy:GetObjects(), 1, "nothing was created")
    T:Eq(Standing:Get(TitleId), "Standing", "and the set that rode along never landed")

    Scene:Destroy()
end)

T:Test("references ride the wire inside the create that carries them", function()
    const Operations = {
        {
            Kind = "Create",
            Object = ButtonId,
            Instance = 3,
            Properties = {[TitleId] = "Button"},
            References = {[TargetId] = 2},
        },

        {Kind = "Create", Object = DoorId, Instance = 3, Properties = {}},
    }

    const Read = Compressor:DecompressTransaction(Compressor:CompressTransaction(Operations :: any))

    T:Eq(Read[1].Properties[TitleId], "Button", "the values still came across")
    T:Eq(Read[1].References[TargetId], 2, "and the reference with them")
    T:Eq(Read[2].References, nil, "a create with none carries none")

    -- References are a hash map on the way in and sorted on the way out, for
    -- the reason the values are: one edit has to write one set of bytes.
    T:Eq(
        buffer.tostring(Compressor:CompressTransaction(Operations :: any)),
        buffer.tostring(Compressor:CompressTransaction(Operations :: any)),
        "the same operations write the same bytes"
    )
end)

T:Test("a transaction duplicates a group with its references remapped", function()
    const Scene, Copy = Room("RefGroupTransaction")
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "Button"})
    Button:Set(TargetId, Door)

    const Applied, Created = Transactions.new():DuplicateGroup({Button, Door}):Commit()

    T:Ok(Applied, "applied")
    T:Eq(#Created, 2, "two objects")

    const NewButton = Objects:Get(Created[1])
    const NewDoor = Objects:Get(Created[2])

    T:Eq(NewButton:Get(TargetId), NewDoor, "the new button points at the new door")
    T:Eq(Button:Get(TargetId), Door, "and the originals are untouched")

    Scene:Destroy()
end)

--=============================================================================
-- Suspending
--=============================================================================

T:Describe("Suspending")

T:Test("a suspended object is out of the world but whole", function()
    const Scene, Copy = Room("SuspendRoom")
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const RuntimeId = Door.RuntimeId
    const LocalId = Door.LocalId

    T:Ok(Objects.Suspend(Door), "suspended")

    T:Ok(Door.Destroyed, "reads as destroyed")
    T:Ok(Door.Suspended, "and as suspended")
    T:Eq(Objects:Get(RuntimeId), nil, "gone from the workspace")
    T:Eq(Copy:Find(LocalId), nil, "and from its copy")
    T:Eq(Door.Instance, nil, "its part went with it")
    T:Eq(Door:Get(TitleId), nil, "and it answers like any destroyed object")

    -- What survives is the whole point: the values, and both ids.
    T:Eq(Door.Properties[TitleId].Value, "Door", "the value is still there")
    T:Eq(Door.RuntimeId, RuntimeId, "same runtime id")
    T:Eq(Door.LocalId, LocalId, "same local id")

    T:Ok(Objects.Revive(Door), "revived")
    T:Ok(not Door.Destroyed, "alive again")
    T:Eq(Objects:Get(RuntimeId), Door, "back in the workspace, as itself")
    T:Eq(Copy:Find(LocalId), Door, "and in its copy under its own id")
    T:Eq(Door:Get(TitleId), "Door", "still holding what it held")
    T:Ok(Door.Instance, "with a part again")

    Scene:Destroy()
end)

T:Test("disposing a suspended object ends it", function()
    const Scene, Copy = Room("DisposeRoom")
    const Door = Copy:Create(DoorId)

    Objects.Suspend(Door)
    Objects.Dispose(Door)

    T:Eq(Door.Suspended, nil, "no longer suspended")
    T:Ok(Door.Destroyed, "still destroyed")
    T:Ok(not Objects.Revive(Door), "and past reviving")

    Scene:Destroy()
end)

T:Test("a reference relinks when its target comes back", function()
    const Scene, Copy = Room("SuspendReference")
    const Door = Copy:Create(DoorId)
    const Button = Copy:Create(ButtonId)
    Button:Set(TargetId, Door)

    Objects.Suspend(Door)
    T:Eq(Button:Get(TargetId), nil, "reads as nothing while it is gone")
    T:Eq(Button:GetProperty(TargetId).Value, Door.LocalId, "but the id is kept")

    Objects.Revive(Door)

    -- The reason a destroy withdraws rather than ends: the same local id comes
    -- back, so everything pointing at it is pointing at it again.
    T:Eq(Button:Get(TargetId), Door, "and points at it again")

    Scene:Destroy()
end)

T:Test("a copy that has gone cannot take its objects back", function()
    const Scene, Copy = Room("SuspendUnloaded")
    const Door = Copy:Create(DoorId)

    Objects.Suspend(Door)
    Copy:Unload()

    T:Ok(not Objects.Revive(Door), "nowhere to come back to")
    Scene:Destroy()
end)

--=============================================================================
-- History
--=============================================================================

T:Describe("History")

const History = Prism.History

const function Editor(UserId: number, Scene: any): any
    const Plr = Ghost(UserId)
    Permissions:Grant(Plr, "TestBulk")
    Scene:Grant(Plr, "TestBulk")
    return Plr
end

T:Test("a transaction is one step, undone and redone as a unit", function()
    const Scene, Copy = Room("HistoryUnit")
    const Plr = Editor(-6001, Scene)
    const Door = Copy:Create(DoorId, {[TitleId] = "Before"})

    const Applied = Transactions.Apply(Plr, {
        {Kind = "Set", Target = Door.RuntimeId, Property = TitleId, Value = "After", Type = "Text"},
        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {[TitleId] = "Made"}},
    } :: any)

    T:Ok(Applied, "applied")
    T:Eq(Door:Get(TitleId), "After", "the set landed")
    T:Ok(History:CanUndo(Plr), "and became a step")

    T:Ok(History:Undo(Plr), "undone")
    T:Eq(Door:Get(TitleId), "Before", "the set is back")
    T:Eq(#Copy:GetObjects(), 1, "and what it created is gone")

    T:Ok(History:Redo(Plr), "redone")
    T:Eq(Door:Get(TitleId), "After", "the set again")
    T:Eq(#Copy:GetObjects(), 2, "and the object again")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("undoing a destroy brings back the same object, wired", function()
    const Scene, Copy = Room("HistoryDestroy")
    const Plr = Editor(-6002, Scene)

    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId)
    Button:Set(TargetId, Door)

    const LocalId = Door.LocalId
    const RuntimeId = Door.RuntimeId

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Destroy", Target = RuntimeId},
    } :: any), "destroyed")

    T:Ok(Door.Suspended, "kept rather than ended")
    T:Eq(Button:Get(TargetId), nil, "and the button points at nothing")

    T:Ok(History:Undo(Plr), "undone")

    -- Not a lookalike: the same table, under the same ids, which is what the
    -- reference was holding all along.
    T:Eq(Copy:Find(LocalId), Door, "the same object, under its own local id")
    T:Eq(Objects:Get(RuntimeId), Door, "and its own runtime id")
    T:Eq(Button:Get(TargetId), Door, "so the reference is live again")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a lone destroy is a step of its own", function()
    const Scene, Copy = Room("HistoryLone")
    const Plr = Editor(-6003, Scene)
    const Door = Copy:Create(DoorId)

    -- What the single destroy channel does, which used to be the one edit
    -- nothing could take back.
    Objects.Retire(Plr, Door, true)

    T:Ok(Door.Suspended, "kept")
    T:Ok(History:CanUndo(Plr), "and recorded")
    T:Ok(History:Undo(Plr), "undone")
    T:Eq(Copy:Find(Door.LocalId), Door, "back as itself")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("nothing keeping a destroy makes it final", function()
    const Scene, Copy = Room("HistoryUnkept")
    const Door = Copy:Create(DoorId)

    -- No player, so no stack wants it: exactly what a game that never requires
    -- History gets.
    Objects.Retire(nil, Door, true)

    T:Ok(Door.Destroyed, "destroyed")
    T:Eq(Door.Suspended, nil, "and disposed on the spot")

    Scene:Destroy()
end)

T:Test("a new action forks the redo stack and ends what it held", function()
    const Scene, Copy = Room("HistoryFork")
    const Plr = Editor(-6004, Scene)

    -- Place, undo, place: the first placement sits on the redo stack holding a
    -- suspended object, and the second forks it away.
    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {}},
    } :: any), "placed")

    const Made = Copy:GetObjects()[1]
    T:Ok(Made, "made")

    T:Ok(History:Undo(Plr), "undone")
    T:Ok(Made.Suspended, "held against the redo")

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {}},
    } :: any), "placed again")

    T:Ok(not History:CanRedo(Plr), "the redo is gone")
    T:Eq(Made.Suspended, nil, "and so is what it was holding")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("clearing ends everything the stacks were holding", function()
    const Scene, Copy = Room("HistoryClear")
    const Plr = Editor(-6005, Scene)
    const Door = Copy:Create(DoorId)

    Objects.Retire(Plr, Door, true)
    T:Ok(Door.Suspended, "held")

    History:Clear(Plr)

    T:Ok(not History:CanUndo(Plr), "the stack is empty")
    T:Eq(Door.Suspended, nil, "and the object it held is gone")

    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a step past the limit lets go of what it held", function()
    const Scene, Copy = Room("HistoryLimit")
    const Plr = Editor(-6006, Scene)

    -- One destroy per step, more of them than the stack keeps. The first is the
    -- one pushed off the end.
    const First = Copy:Create(DoorId)
    Objects.Retire(Plr, First, true)
    T:Ok(First.Suspended, "the first is held")

    for _ = 1, 100 do
        Objects.Retire(Plr, Copy:Create(DoorId), true)
    end

    T:Eq(First.Suspended, nil, "and let go once it fell off the stack")
    T:Ok(History:CanUndo(Plr), "while the rest are still there")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
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

-- A button pointing at a door, both in the default scene so both replicate to
-- everyone. The client resolves the reference from its own index rather than
-- from the copy's, and this is what it resolves.
const ReferenceDoor = Objects.new(DoorId)
ReferenceDoor:Set(TitleId, "FixtureReferenceDoor")

const ReferenceButton = Objects.new(ButtonId)
ReferenceButton:Set(TitleId, "FixtureReferenceButton")
ReferenceButton:Set(TargetId, ReferenceDoor)

-- Two private scenes, each admitting only user id 1, which nobody running this
-- is, and each holding one object that replicates to everyone and one kept for
-- the admitted. The test player never gets into the first, and the client
-- checks it is sent the first object and neither the second nor the scene's
-- name. The player is admitted to the second as they arrive, and evicted from
-- it when the client writes the evict marker on the editable fixture.
const HiddenCopy = Scenes.new({Name = "FixtureHidden", Admitted = {1}}):Load()
HiddenCopy:Create(BareId, {[TitleId] = "FixtureHiddenScenery"})
HiddenCopy:Create(PrivateId, {[TitleId] = "FixtureHiddenPrivate"})

const AdmittedScene = Scenes.new({Name = "FixtureAdmitted", Admitted = {1}})
const AdmittedCopy = AdmittedScene:Load()
AdmittedCopy:Create(BareId, {[TitleId] = "FixtureAdmittedScenery"})
AdmittedCopy:Create(PrivateId, {[TitleId] = "FixtureAdmittedPrivate"})

-- A copy the server opened rather than loaded, holding an object whose template
-- replicates. The server builds no part for it; the test player, admitted as
-- they arrive, draws one.
const OpenedScene = Scenes.new({Name = "FixtureOpened", Admitted = {1}})
OpenedScene:Open():Create(ShownId, {[TitleId] = "FixtureOpenedObject"})

-- A property and a type the client watches go. Registered here so they reach
-- the client with everything else, and unregistered when the client writes the
-- unregister marker, by which point it has seen them arrive.
const DoomedProperty = Properties:Register({Name = "FixtureDoomedProperty", Type = "Text", DefaultValue = ""}) :: number
const DoomedType = Objects:Register({Name = "FixtureDoomedType", Properties = {DoomedProperty}}) :: number

-- What the client holds on a scene it pushes, which its push test checks for.
Scenes:SetPushRole("TestBuilder")

-- Global rights for the budget and pushing, and rights on the default scene,
-- which is where every editable fixture above lives.
const function AssignBuilder(Plr: Player)
    Permissions:Grant(Plr, "TestBuilder")
    Scenes:GetDefault():Grant(Plr, "TestBuilder")
    AdmittedScene:Admit(Plr)
    OpenedScene:Admit(Plr)
end

for _, Plr in Players:GetPlayers() do
    AssignBuilder(Plr)
end
Players.PlayerAdded:Connect(AssignBuilder)

-- A client writes this marker while its Permissions.OnChange listener is
-- attached. The server briefly grants the viewer role on the default scene,
-- then the builder again, so the remaining accepted-edit and destroy tests can
-- proceed deterministically.
EditableFixture:OnChange(TitleId, function(Value)
    if Value == "UnregisterPulse" then
        Objects:Unregister(DoomedType)
        Properties:Unregister(DoomedProperty)
        return
    end

    if Value == "EvictPulse" then
        for _, Plr in Players:GetPlayers() do
            AdmittedScene:Evict(Plr)
        end

        return
    end

    if Value ~= "PermissionPulse" then
        return
    end

    for _, Plr in Players:GetPlayers() do
        Scenes:GetDefault():Grant(Plr, "TestViewer")
        task.delay(0.2, function()
            if Plr.Parent then
                Scenes:GetDefault():Grant(Plr, "TestBuilder")
            end
        end)
    end
end)

T:Test("fixtures are live and carry distinct markers", function()
    T:Eq(DeniedFixture:Get(TitleId), "FixtureDenied", "denied fixture")
    T:Eq(EditableFixture:Get(TitleId), "FixtureEditable", "editable fixture")
    T:Eq(DestroyFixture:Get(TitleId), "FixtureDestroy", "destroy fixture")
    T:Ok(DeniedFixture.Instance, "instance-backed fixture")
    T:Eq(ReferenceButton:Get(TargetId), ReferenceDoor, "reference fixture")
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
    const db = Prism.Database.new({
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
            for Index = 1, #Record do
                const Prop = Record[Index]
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
        for Index = 1, #Top do
            const Prop = Top[Index]
            if Prop.Parent == PlaysId then
                T:Eq(Prop.Value, 80, "highest plays first")
            end
        end
    end)

    T:Test("Find filters and honours its limit", function()
        db:Refresh()

        const Matches = db:Find(function(Record)
            for Index = 1, #Record do
                const Prop = Record[Index]
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
            for Index = 1, #Record do
                const Prop = Record[Index]
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

    --T:Test("removes its test keys", function()
    --    for _, Id in Created do
    --        db:Delete(Id)
    --    end

    --    const Store = db.DataStore
    --    for Index = 1, 10 do
    --        pcall(function()
    --            Store:RemoveAsync(`{DATABASE_KEY}:{Index}`)
    --        end)
    --    end

    --    pcall(function()
    --        Store:RemoveAsync("Manifest")
    --    end)

    --    T:Ok(true, "cleanup ran")
    --end)
end

--=============================================================================

-- The template and the three fixtures deliberately remain alive until
-- the play session ends so a late-starting client can receive them via replay.

const Passed = T:Report()
if not Passed then
    error("[ PRISM TEST ] Server suite failed; see the failures above.", 0)
end

if not RUN_DATABASE then
    print("[ PRISM TEST ] Database suite skipped. Set RUN_DATABASE = true to run it.")
end

print("[ PRISM TEST ] Client fixtures are ready; PrismTest.client.luau runs separately.")
