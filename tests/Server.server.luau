--!strict
--[[
    Prism test suite -- server half.

    Ships in PrismTests.rbxmx beside the client half, Harness and its own copy
    of Prism, and runs with RunContext Server from wherever the model sits. Run
    it with one test player.

    The Database section is on: it writes to real DataStore and MemoryStore keys
    and needs Studio API access enabled. Set RUN_DATABASE to false to skip it.
    It wipes its two keys, PrismSelfTest and PrismSelfTestBurst, before it starts
    and after it finishes, so they never hold more than one run's records.
]]

const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const ServerStorage = game:GetService("ServerStorage")

const RUN_DATABASE = true
const DATABASE_KEY = "PrismSelfTest"

const Prism = require("./Prism")
const Harness = require("./Harness")

const Networking = Prism.Networking
const Properties = Prism.Properties
const PropertyTypes = require("./Prism/Properties/Types")
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

-- The pool takes no id: naming a retired one was a way to make saved records
-- decode as something else. One passed anyway is ignored.
T:Test("hands out its own id, never the one asked for", function()
    const Pool = IdPool.new()
    T:Eq((Pool.Claim :: any)(Pool, 50), 1, "the pool picks")
    T:Eq(Pool:Claim(), 2, "and keeps counting from there")
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

T:Test("Table is a type of its own", function()
    -- Its id is written into saved data as a value's semantic type, so it
    -- cannot move once anything has been saved with it.
    T:Eq(PropertyTypes.Ids.Table, 9, "its id")
    T:Eq(PropertyTypes.Map.Table, "table", "held as a Luau table")
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

T:Test("ids are the pool's to give, never the caller's to ask for", function()
    -- There is no way to name the id a registration gets. An explicit claim
    -- only ever checked whether an id was in use now, not whether it had been,
    -- so asking for a retired one was a way to make every saved record carrying
    -- it decode as something else.
    const First = Properties:Register({Name = "TestPoolA", Type = "Bool", DefaultValue = false})
    const Second = Properties:Register({Name = "TestPoolB", Type = "Bool", DefaultValue = false})

    T:Ok(First and Second, "both registered")
    T:Ok(First ~= Second, "under ids of their own")
    T:Ok(First ~= TitleId and Second ~= TitleId, "and never one already spoken for")
end)

T:Test("instances start at the registry default", function()
    const Prop = Properties.new(TitleId)
    T:Eq(Prop.Value, "Untitled", "value")
    T:Eq(Prop.DefaultValue, "Untitled", "default")
    T:Eq(Prop.Parent, TitleId, "parent")
end)

T:Test("properties of one registry share everything but their values", function()
    const First = Properties.new(HealthId)
    const Second = Properties.new(HealthId)
    const Registry = Properties:GetRegistry(HealthId) :: any

    First:Set(10)
    Second:SetDefault(20)

    T:Eq(First.Value, 10, "a value is the property's own")
    T:Eq(Second.Value, 100, "and the other keeps its own")
    T:Eq(Second.DefaultValue, 20, "as is a default set on it")
    T:Eq(First.DefaultValue, 100, "which the first does not see")

    for _, Prop in {First, Second} do
        T:Eq(Prop.__type, "Property", "still reads as a property")
        T:Eq(Prop.Name, Registry.Name, "named")
        T:Eq(Prop.Type, "Number", "typed")
        T:Eq(Prop.Constraints, Registry.Constraints, "with the registry's constraints")
    end

    -- Eleven fields on every property was most of what a loaded level kept in
    -- memory. Only what differs between two of them is theirs to hold.
    local Own = 0
    for _ in First do
        Own += 1
    end

    T:Eq(Own, 2, "holding nothing but a value and a default")
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

    const Linked = {string.rep("a", 22), string.rep("b", 22)}
    const Record = {
        Id = 7,
        Scenes = Linked,
        Title,
        Plays,
    }

    const _, Records = Compressor:DecompressMetadatas((Compressor:CompressMetadatas(7, {Record :: any})))
    const Back = Records[1]
    T:Eq(Back.Id, 7, "id")
    T:Eq(#Back.Scenes, 2, "linked scenes")
    T:Eq(Back.Scenes[1], Linked[1], "in link order")
    T:Eq(Back.Scenes[2], Linked[2], "both of them")
    T:Eq(#Back, 2, "property count, the scenes not among them")

    -- Indexed rather than iterated: the record carries Id and Scenes beside the
    -- array of properties, and a generic for walks those too and then tries to
    -- index them as properties.
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
        return {Id = Id, Scenes = {}, Title}
    end

    const Records = {Build(1, "One"), Build(2, "Two"), Build(3, "Three")}
    const LastId, Back = Compressor:DecompressMetadatas((Compressor:CompressMetadatas(42, Records :: any)))

    T:Eq(LastId, 42, "last id")
    T:Eq(#Back, 3, "count")
    T:Eq(Back[1].Id, 1, "order preserved")
    T:Eq(Back[3][1].Value, "Three", "third record value")
end)

const function Record(Id: number, Values: {{any}}, Scenes: {string}?): any
    const Out: any = {Id = Id, Scenes = Scenes or {}}
    for _, Pair in Values do
        const Prop = Properties.new(Pair[1])
        Prop:Set(Pair[2])
        table.insert(Out, Prop)
    end

    return Out
end

T:Test("a metadata pack keeps each record's properties in their order", function()
    const Records = {
        Record(1, {{TitleId, "A"}, {PlaysId, 5}}, {string.rep("c", 22)}),
        Record(2, {{PlaysId, 9}, {TitleId, "B"}}),
        Record(3, {{TitleId, "C"}}),
        Record(5, {{TitleId, "E"}, {PlaysId, 0}}),
    }

    const LastId, Back = Compressor:DecompressMetadatas((Compressor:CompressMetadatas(5, Records)))
    T:Eq(LastId, 5, "last id")
    T:Eq(#Back, 4, "every record")
    T:Eq(Back[1].Scenes[1], string.rep("c", 22), "a linked scene")
    T:Eq(#Back[2].Scenes, 0, "and a record linking none has an empty list")
    T:Eq(Back[1][1].Parent, TitleId, "first property first")
    T:Eq(Back[2][1].Parent, PlaysId, "a record built in another order keeps it")
    T:Eq(Back[2][2].Value, "B", "with its values")
    T:Eq(#Back[3], 1, "a record with fewer properties has only those")
    T:Eq(Back[4].Id, 5, "in id order")
end)

T:Test("a metadata pack costs a few bytes a record", function()
    const Records = {}
    for Id = 1, 2000 do
        Records[Id] = Record(Id, {{TitleId, `Level {Id % 40}`}, {PlaysId, if Id % 5 == 0 then Id else 0}})
    end

    const Packed, Unpacked = Compressor:CompressMetadatas(2000, Records)

    T:Ok(buffer.len(Packed) < 2000 * 5, `{buffer.len(Packed)} bytes for 2000 records`)
    T:Ok(Unpacked >= buffer.len(Packed), "the size before compression is reported")

    const _, Back = Compressor:DecompressMetadatas(Packed)
    T:Eq(Back[2000][1].Value, "Level 0", "and it reads back")
end)

T:Test("rejects a metadata pack from a newer format", function()
    const Pack = buffer.create(32)
    buffer.writeu8(Pack, 0, 2)
    T:Throws(function()
        Compressor:DecompressMetadatas(Pack)
    end, "refused")
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
    const Inst = Obj.Instance

    T:Eq(Prop.Drives, Inst, "driving its part while alive")
    Obj:Destroy()
    T:Eq(Prop.Drives, nil, "and no longer")
    T:Eq(Prop.Link, nil, "nor through anything")
end)

-- A link used to be an OnChange listener: a link table, two closures and a
-- listener array a property, 431 bytes, and two thirds of a real level's
-- 495,279 properties drive a part -- about 140 MB of a client's heap.
T:Test("a link costs its property two fields and nothing else", function()
    const One = Objects.new(CrateId)
    const Two = Objects.new(CrateId)
    const Prop = One.Properties[TintId]

    T:Eq(Prop.Listeners, nil, "no listener")
    T:Eq(Prop.Drives, One.Instance, "the part it drives")
    T:Eq(Prop.Link, Two.Properties[TintId].Link, "through the entry every crate shares")
    T:Eq(One.Links, Two.Links, "and the object holds the type's own list")

    -- Written by Set itself, so it is there before the call returns.
    One:Set(TintId, Color3.fromRGB(0, 0, 255))
    T:Eq(One.Instance.Color, Color3.fromRGB(0, 0, 255), "applied at once")

    One:Destroy()
    Two:Destroy()
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
        T:Eq(Copy.Registry, CrateId, "same registry")
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

T:Test("refuses a duplicate name", function()
    const First = Scenes.new({Name = "TestDuplicate"})
    T:Ok(First, "registered")

    T:Eq(Scenes.new({Name = "TestDuplicate"}), nil, "same name refused")

    First:Destroy()
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

-- One property for each way a pack column can be written: a grid for the
-- position, a bit for the flag, a palette for the material, raw for colours
-- that are all different.
const SpotId = Properties:Register({Name = "TestSpot", Type = "Vector", DefaultValue = Vector3.zero}) :: number
const FlagId = Properties:Register({Name = "TestFlag", Type = "Bool", DefaultValue = false}) :: number
const SurfaceId = Properties:Register({
    Name = "TestSurface",
    Type = "Enum",
    DefaultValue = Enum.Material.Plastic,
    Constraints = {Enum = Enum.Material},
}) :: number

const BlockId = Objects:Register({
    Name = "TestBlock",
    Properties = {TitleId, TintId, SpotId, FlagId, SurfaceId},
}) :: number

const Surfaces = {Enum.Material.Plastic, Enum.Material.Wood, Enum.Material.Slate}

-- Values a level actually holds: positions on a half stud grid with a few that
-- are not, a flag that is usually off, three materials, and colours that are
-- all different.
const function BlockValues(Index: number): {[number]: any}
    local Spot = Vector3.new(Index * 0.5, 3, -Index)
    if Index % 50 == 0 then
        Spot = Vector3.new(Index + 0.1, 0.3, 7)
    elseif Index % 70 == 0 then
        Spot = Vector3.new(-0, 1, 2)
    end

    return {
        [TitleId] = if Index % 3 == 0 then "Wall" elseif Index % 3 == 1 then "Floor" else "Roof",
        [TintId] = Color3.fromRGB(Index % 256, (Index * 7) % 256, (Index * 13) % 256),
        [SpotId] = Spot,
        [FlagId] = Index % 10 == 0,
        [SurfaceId] = Surfaces[Index % 3 + 1],
    }
end

const function Header(Version: number, Flags: number, LastId: number): buffer
    const Out = buffer.create(Varint.Measure(Version) + Varint.Measure(Flags) + Varint.Measure(LastId))
    local At = Varint.Write(Out, 0, Version)
    At += Varint.Write(Out, At, Flags)
    Varint.Write(Out, At, LastId)
    return Out
end

const function Join(A: buffer, B: buffer): buffer
    const Out = buffer.create(buffer.len(A) + buffer.len(B))
    buffer.copy(Out, 0, A, 0)
    buffer.copy(Out, buffer.len(A), B, 0)
    return Out
end

T:Test("a pack reads back every value of every column", function()
    const Scene = Scenes.new({Name = "TestPackColumns"})
    const Live = Scene:Load()
    const Made = {}
    for Index = 1, 300 do
        Made[Index] = Live:Create(BlockId, BlockValues(Index))
    end

    const Pack = Live:Serialize()
    const Copy = Scenes.fromBuffer({Name = "TestPackColumnsBack"}, Pack)
    const Back = Copy:Load()

    local Wrong = 0
    for _, Original in Live:GetObjects() do
        const Restored = Back:Find(Original.LocalId)
        if not Restored then
            Wrong += 1
            continue
        end

        for Id in BlockValues(1) do
            if Restored:Get(Id) ~= Original:Get(Id) then
                Wrong += 1
            end
        end
    end

    T:Eq(#Back:GetObjects(), 300, "every object came back")
    T:Eq(Wrong, 0, "holding the values it was saved with")

    -- Equal is not enough for a float: -0 == 0, and a save that turned one
    -- into the other would be changing the level a bit every time.
    const Signed = Back:Find(Made[70].LocalId)
    T:Eq(Signed and 1 / Signed:Get(SpotId).X, -math.huge, "a -0 kept its sign")

    Scene:Destroy()
    Copy:Destroy()
end)

T:Test("a saved level keeps its values when a default changes", function()
    const Scene = Scenes.new({Name = "TestPackDefault"})
    const Live = Scene:Load()

    -- Most objects hold the registry's default, which a pack does not write
    -- once per object -- and must not read back from the registry either.
    const Odd = Live:Create(BlockId, {[TitleId] = "Odd"})
    for _ = 2, 20 do
        Live:Create(BlockId)
    end

    Live:Commit()
    Scene:Unload()

    const Registry = Properties:GetRegistry(TitleId) :: any
    const Before = Registry.DefaultValue
    Registry.DefaultValue = "Renamed"

    const Back = Scene:Load()
    local Kept = 0
    for _, Obj in Back:GetObjects() do
        if Obj:Get(TitleId) == "Untitled" then
            Kept += 1
        end
    end

    Registry.DefaultValue = Before

    T:Eq(Kept, 19, "every object that held the old default still holds it")
    const Restored = Back:Find(Odd.LocalId)
    T:Eq(Restored and Restored:Get(TitleId), "Odd", "and the one that did not, its own value")

    Scene:Destroy()
end)

T:Test("a pack is a fraction of one record per object", function()
    const Scene = Scenes.new({Name = "TestPackSize"})
    const Live = Scene:Load()
    for Index = 1, 2000 do
        Live:Create(BlockId, BlockValues(Index))
    end

    -- Against the records replication sends, one per object, every value
    -- beside its id: what a pack written row by row would come to.
    const Current = buffer.len(Live:Serialize())
    local Records = 0
    for _, Obj in Live:GetObjects() do
        Records += buffer.len(Compressor:CompressObject(Obj))
    end

    T:Ok(Current * 4 < Records, `{Current} bytes against {Records} one record per object`)

    Scene:Destroy()
end)

T:Test("the same copy writes the same bytes", function()
    const Scene = Scenes.new({Name = "TestPackSame"})
    const Live = Scene:Load()
    for Index = 1, 200 do
        Live:Create(BlockId, BlockValues(Index))
    end

    T:Eq(buffer.tostring(Live:Serialize()), buffer.tostring(Live:Serialize()), "byte for byte")

    Scene:Destroy()
end)

T:Test("an object missing a column reads back without it", function()
    const Full: {[number]: any} = {[FlagId] = true}
    Full[TitleId] = "Full"

    const Pack = Compressor:CompressScene(2, {
        {__type = "DecompressedObject", LocalId = 1, Registry = BlockId, Properties = Full},
        {__type = "DecompressedObject", LocalId = 2, Registry = BlockId, Properties = {[FlagId] = true}},
    } :: any)

    const _, Back = Compressor:DecompressScene(Pack)
    T:Eq(Back[1].Properties[TitleId], "Full", "the full row")
    T:Eq(Back[2].Properties[TitleId], nil, "the partial row holds no title")
    T:Eq(Back[2].Properties[FlagId], true, "but holds the rest")
end)

T:Test("a pack this build cannot read is refused", function()
    T:Throws(function()
        Compressor:DecompressScene(Header(2, 0, 0))
    end, "a newer version")

    T:Throws(function()
        Compressor:DecompressScene(Join(Header(1, 2, 0), buffer.create(1)))
    end, "a flag it does not know")

    -- One type, one column, written in encoding 9.
    const Default = Compressor:CompressValue("Bool", true) :: buffer
    const Body = buffer.create(64)
    local At = Varint.Write(Body, 0, 1)
    At += Varint.Write(Body, At, BlockId)
    At += Varint.Write(Body, At, 1)
    At += Varint.Write(Body, At, FlagId)
    buffer.writeu8(Body, At, 9)
    buffer.copy(Body, At + 1, Default, 0)
    T:Throws(function()
        Compressor:DecompressScene(Join(Header(1, 0, 0), Body))
    end, "a column encoding it does not know")
end)

-- A DataStore that keeps keys in a table, every write as a version of its key,
-- and refuses what a real one refuses: a string that is not valid UTF-8, and a
-- key past 50 characters.
const function FakeStore(): any
    const Keys = {}
    const Versions: {[string]: {{Version: string, CreatedTime: number, IsDeleted: boolean, Value: any}}} = {}
    local Written = 0

    const function Pages(Items: {any}): any
        return {
            IsFinished = true,
            GetCurrentPage = function()
                return Items
            end,
            AdvanceToNextPageAsync = function() end,
        }
    end

    return {
        Keys = Keys,
        SetAsync = function(_, Key: string, Value: any)
            if type(Value) == "string" and not utf8.len(Value) then
                error("not valid UTF-8")
            end

            if #Key > 50 then
                error("key too long")
            end

            Keys[Key] = Value
            Written += 1
            Versions[Key] = Versions[Key] or {}
            table.insert(Versions[Key], {Version = `v{Written}`, CreatedTime = Written, IsDeleted = false, Value = Value})
        end,
        GetAsync = function(_, Key: string)
            return Keys[Key]
        end,
        GetVersionAsync = function(_, Key: string, Version: string)
            const List = Versions[Key]
            if not List then
                return nil
            end

            for _, Entry in List do
                if Entry.Version == Version then
                    return Entry.Value
                end
            end

            return nil
        end,
        ListVersionsAsync = function(_, Key: string)
            const Newest = {}
            const List = Versions[Key] or {}
            for Index = #List, 1, -1 do
                table.insert(Newest, List[Index])
            end

            return Pages(Newest)
        end,
        ListKeysAsync = function(_, Prefix: string)
            const Found = {}
            for Key in Keys do
                if string.sub(Key, 1, #Prefix) == Prefix then
                    table.insert(Found, {KeyName = Key})
                end
            end

            return Pages(Found)
        end,
    }
end

const function SavedScene(Name: string, Count: number): (any, any)
    const Scene = Scenes.new({Name = Name}) :: any
    const Live = Scene:Load()
    for Index = 1, Count do
        Live:Create(BlockId, BlockValues(Index))
    end

    Live:Commit()
    return Scene, Live
end

T:Test("every scene gets a Guid of Prism's, unique and found by it", function()
    const A = Scenes.new({Name = "TestGuidA"}) :: any
    const B = Scenes.new({Name = "TestGuidB"}) :: any

    T:Eq(type(A.Guid), "string", "a Guid")
    T:Eq(#A.Guid, 22, "22 characters")
    T:Ok(string.match(A.Guid, "^[%w%-_]+$"), "base64url")
    T:Ok(A.Guid ~= B.Guid, "unique")
    T:Eq(Scenes:GetByGuid(A.Guid), A, "found by it")
    T:Eq(Scenes:GetRegistryPayload(A.Id).Guid, A.Guid, "and goes out with the registry")

    -- A pack carries no Guid: a scene read from one is a new scene.
    const Copy = Scenes.fromBuffer({Name = "TestGuidCopy"}, A:Serialize()) :: any
    T:Ok(Copy.Guid ~= A.Guid, "a buffer gets a fresh one")

    const Guid = A.Guid
    A:Destroy()
    T:Eq(Scenes:GetByGuid(Guid), nil, "and loses it when destroyed")

    B:Destroy()
    Copy:Destroy()
end)

T:Test("a scene saves its draft and reads back as itself", function()
    const Store = FakeStore()
    const Scene = SavedScene("TestSaved", 50)
    const Guid = Scene.Guid

    T:Ok(Scene:Save(Store), "saved")
    T:Eq(type(Store.Keys[`{Guid}:Draft`]), "buffer", "under its Guid, as the buffer itself")
    T:Eq(Store.Keys[`{Guid}:Published`], nil, "and nothing published")

    -- What the old instructions said to do, which a real store refuses.
    T:Ok(not utf8.len(buffer.tostring(Scene:Serialize())), "a pack is not valid UTF-8 as a string")
    Scene:Destroy()

    const Back = Scenes.fromDataStore(Store, Guid, {Name = "TestSavedBack"}) :: any
    T:Eq(Back and #Back:Load():GetObjects(), 50, "every object came back")
    T:Eq(Back and Back.Guid, Guid, "under the Guid it was saved with")

    T:Eq(Scenes.fromDataStore(Store, Guid, {Name = "TestSavedTwice"}), nil, "a Guid already registered is refused")

    if Back then
        Back:Destroy()
    end
end)

T:Test("publishing writes the scene as it is, not the draft", function()
    const Store = FakeStore()
    const Scene, Live = SavedScene("TestPublished", 3)
    Scene:Save(Store)

    Live:Create(BlockId, BlockValues(4))
    Live:Commit()
    T:Ok(Scene:Publish(Store), "published")
    const Guid = Scene.Guid
    Scene:Destroy()

    const Draft = Scenes.fromDataStore(Store, Guid, {Name = "TestPublishedDraft"}) :: any
    T:Eq(#Draft:Load():GetObjects(), 3, "the draft is what was saved")
    Draft:Destroy()

    const Live_ = Scenes.fromDataStore(Store, Guid, {Name = "TestPublishedLive"}, "Published") :: any
    T:Eq(#Live_:Load():GetObjects(), 4, "the published pack has the unsaved edit")
    Live_:Destroy()
end)

T:Test("an earlier version of a draft reads back", function()
    const Store = FakeStore()
    const Scene, Live = SavedScene("TestVersioned", 2)
    Scene:Save(Store)

    Live:Create(BlockId, BlockValues(3))
    Live:Commit()
    Scene:Save(Store)
    const Guid = Scene.Guid
    Scene:Destroy()

    const Versions = Scenes:ListVersions(Store, Guid, "Draft") :: any
    T:Eq(#Versions, 2, "both saves listed")
    T:Ok(Versions[1].Time > Versions[2].Time, "newest first")
    T:Eq(#(Scenes:ListVersions(Store, Guid, "Draft", 1) :: any), 1, "and capped by the limit")

    const Old = Scenes.fromDataStore(Store, Guid, {Name = "TestVersionedOld"}, {Draft = Versions[2].Version}) :: any
    T:Eq(#Old:Load():GetObjects(), 2, "the first save")
    Old:Destroy()
end)

T:Test("a backup is a key of its own and reads back", function()
    const Store = FakeStore()
    const Scene, Live = SavedScene("TestBackedUp", 2)
    const First = Scene:Backup(Store)

    Live:Create(BlockId, BlockValues(3))
    Live:Commit()
    const Second = Scene:Backup(Store)
    const Guid = Scene.Guid
    Scene:Destroy()

    T:Ok(First and Second and Second > First, "ids climb")
    T:Ok(Store.Keys[`{Guid}:Backup:{First}`], "the first is kept")

    const Backups = Scenes:ListBackups(Store, Guid) :: any
    T:Eq(Backups and #Backups, 2, "both listed")
    T:Eq(Backups and Backups[1].Backup, Second, "newest first")
    T:Eq(Backups and Backups[1].Time, Second, "taken when the id says")
    T:Eq(#(Scenes:ListBackups(Store, Guid, 1) :: any), 1, "and capped by the limit")

    -- Listed the way it is read back, as a version's Version is.
    const Back = Scenes.fromDataStore(Store, Guid, {Name = "TestBackedUpOld"}, {Backup = Backups[2].Backup}) :: any
    T:Eq(Back and #Back:Load():GetObjects(), 2, "the first backup")
    if Back then
        Back:Destroy()
    end
end)

T:Test("fromDataStore takes only a Guid Prism made, and only a stored pack", function()
    const Store = FakeStore()
    T:Eq(Scenes.fromDataStore(Store, "Level 1", {Name = "TestNotGuid"}), nil, "a name is refused")

    -- Shaped like a Guid, never saved: an empty key would otherwise hand a
    -- scene an identity Prism never gave it.
    T:Eq(Scenes.fromDataStore(Store, string.rep("a", 22), {Name = "TestNeverSaved"}), nil, "an empty key is refused")
    T:Eq(Scenes:Get("TestNeverSaved"), nil, "and nothing registered")
end)

T:Test("a source names one pack, and versions are kept only of draft and published", function()
    const Store = FakeStore()
    const Scene = SavedScene("TestSources", 1)
    Scene:Save(Store)
    const Id = Scene:Backup(Store)
    const Version = (Scenes:ListVersions(Store, Scene.Guid, "Draft") :: any)[1].Version
    const Guid = Scene.Guid
    Scene:Destroy()

    -- Read as whichever was checked first, before this was refused.
    T:Eq(Scenes.fromDataStore(Store, Guid, {Name = "TestSourcesTwo"}, {Draft = Version, Backup = Id} :: any), nil, "two named is refused")
    T:Eq(Scenes.fromDataStore(Store, Guid, {Name = "TestSourcesNone"}, {} :: any), nil, "none named is refused")
    T:Eq(Scenes.fromDataStore(Store, Guid, {Name = "TestSourcesWord"}, "Backup" :: any), nil, "a word that is not one is refused")

    -- Listed a key nothing writes, and came back as an empty list.
    T:Eq(Scenes:ListVersions(Store, Guid, "Backup" :: any), nil, "versions of a backup are refused")
end)

T:Test("a pack that unpacks past the limit is refused before it is unpacked", function()
    const Bomb = game:GetService("EncodingService"):CompressBuffer(
        buffer.create(64 * 1024 * 1024 + 1),
        Enum.CompressionAlgorithm.Zstd,
        1
    )

    T:Throws(function()
        Compressor:DecompressScene(Join(Header(1, 1, 0), Bomb))
    end, "refused")
end)

-- A pack an older or newer build wrote: an object of a type this one never
-- registered, and on a known object a property nobody registered plus one its
-- type does not list. Built by hand, because nothing registered here can
-- produce it. HealthId is registered but not on TestBare, which is what taking
-- a property off a type leaves behind.
const UNKNOWN_TYPE = 99990
const UNKNOWN_PROPERTY = 99991

const function Foreign(): buffer
    return Compressor:CompressScene(3, {
        {
            __type = "DecompressedObject",
            LocalId = 1,
            Registry = BareId,
            Properties = {[TitleId] = "Known", [HealthId] = 42},
            Unknown = {[UNKNOWN_PROPERTY] = Compressor:CompressValue("Text", "FromElsewhere")},
        },
        {
            __type = "DecompressedObject",
            LocalId = 2,
            Registry = UNKNOWN_TYPE,
            Properties = {[TitleId] = "Stranger"},
            Unknown = {[UNKNOWN_PROPERTY] = Compressor:CompressValue("Text", "StrangerToo")},
        },
        {
            __type = "DecompressedObject",
            LocalId = 3,
            Registry = BareId,
            Properties = {[TitleId] = "After"},
        },
    } :: any)
end

T:Test("an object of an unknown type survives a load and a commit", function()
    const Scene = Scenes.fromBuffer({Name = "TestForeignType"}, Foreign())
    const Live = Scene:Load()

    T:Eq(#Live:GetObjects(), 2, "only the known objects were built")
    T:Eq(Live:Find(2), nil, "nothing answers for the unknown one")
    T:Eq(#Live.Unknown, 1, "but the copy kept it")

    -- A new object must not take the id the kept one is saved under.
    const Made = Live:Create(BareId)
    T:Ok(Made.LocalId > 3, "a new object is minted past it")

    Live:Commit()
    Scene:Unload()

    const _, Back = Compressor:DecompressScene(Scene:Serialize())
    local Kept = nil
    for _, Saved in Back do
        if Saved.LocalId == 2 then
            Kept = Saved
        end
    end

    T:Ok(Kept, "still in the pack after the commit")
    if Kept then
        T:Eq(Kept.Registry, UNKNOWN_TYPE, "under its own type")
        T:Eq(Kept.Properties[TitleId], "Stranger", "with its values")
        T:Ok(Kept.Unknown and Kept.Unknown[UNKNOWN_PROPERTY], "including the ones nobody here can read")
    end

    T:Eq(Back[1].LocalId, 1, "and in its place by local id")
    T:Eq(Back[2].LocalId, 2, "between its neighbours")
    T:Eq(Back[3].LocalId, 3, "rather than at the end")

    Scene:Destroy()
end)

T:Test("a property the type no longer lists survives a load and a commit", function()
    const Scene = Scenes.fromBuffer({Name = "TestForeignProperty"}, Foreign())
    const Live = Scene:Load()
    const Obj = Live:Find(1)

    T:Ok(Obj, "restored")
    if not Obj then
        Scene:Destroy()
        return
    end

    T:Eq(Obj:Get(TitleId), "Known", "a listed property reads as usual")
    T:Eq(Obj:Get(HealthId), nil, "one the type does not list is not the object's")
    T:Ok(Obj.Unknown and Obj.Unknown[HealthId], "but it is kept")
    T:Ok(Obj.Unknown and Obj.Unknown[UNKNOWN_PROPERTY], "and so is one nobody registered")

    -- Replication is not a save: a client has no use for what it cannot read.
    const Sent = Compressor:DecompressObject(Compressor:CompressObject(Obj))
    T:Eq(Sent.Properties[HealthId], nil, "not replicated")
    T:Eq(Sent.Unknown, nil, "at all")

    Obj:Set(TitleId, "Edited")
    Live:Commit()
    Scene:Unload()

    const _, Back = Compressor:DecompressScene(Scene:Serialize())
    const Saved = Back[1]
    T:Eq(Saved.Properties[TitleId], "Edited", "the edit landed")
    T:Eq(Saved.Properties[HealthId], 42, "the unlisted value came back with it")
    T:Ok(Saved.Unknown and Saved.Unknown[UNKNOWN_PROPERTY], "and the unregistered one")

    -- Put back on the type, the value is the object's again. Simulated by
    -- decoding against a registry that lists it: TestCrate carries Health.
    const AsCrate = table.clone(Saved)
    AsCrate.Registry = CrateId
    const Load = Scenes.fromBuffer({Name = "TestForeignBack"}, Compressor:CompressScene(1, {AsCrate} :: any))
    const Crate = Load:Load():Find(1)
    T:Eq(Crate and Crate:Get(HealthId), 42, "a type that lists it reads it")

    Scene:Destroy()
    Load:Destroy()
end)

T:Test("a duplicate carries what its original was keeping", function()
    const Scene = Scenes.fromBuffer({Name = "TestForeignDuplicate"}, Foreign())
    const Live = Scene:Load()
    const Obj = Live:Find(1)

    const Copy = if Obj then Objects:Duplicate(Obj) else nil
    T:Ok(Copy and Copy.Unknown and Copy.Unknown[HealthId], "kept values came along")
    T:Ok(Copy and Obj and Copy.Unknown ~= Obj.Unknown, "as a copy, not the same table")

    Scene:Destroy()
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

    -- A list on a public scene is inert: privacy is a flag now, not something
    -- read off the list, so admitting somebody does not close the scene.
    Scene:Admit(1)
    T:Ok(Scene:IsPublic(), "still public")
    T:Ok(Scene:Admits(2), "and still everybody's")

    Scene:SetPrivate(true)
    T:Ok(not Scene:IsPublic(), "closed")
    T:Ok(Scene:Admits(1), "to the one admitted")
    T:Ok(not Scene:Admits(2), "and to nobody else")

    -- The edge this closes: evicting the last admitted player used to throw the
    -- scene open, to everybody, including the person just shut out of it.
    Scene:Evict(1)
    T:Ok(not Scene:IsPublic(), "evicting the last leaves it closed")
    T:Ok(not Scene:Admits(1), "admitting nobody at all")

    Scene:SetPrivate(false)
    T:Ok(Scene:IsPublic(), "and opening it is its own act")

    Scene:Destroy()
end)

T:Test("admission takes a player or a user id, and belongs to the scene", function()
    const Scene = Scenes.new({Name = "TestAdmitted", Private = true, Admitted = {1, 2}})
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
    T:Ok(not Permissions:Can(Plr, "Create", {Scene = Obj.Scene, Registry = BareId}), "cannot create")

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

T:Test("a hold does not need a player", function()
    const Scene = Scenes.new({Name = "HolderRoom"}) :: any
    const Copy = Scene:Load()
    const Door = Copy:Create(BareId)
    const Tool = {}

    -- Anything at all. The server holding an object while it animates one used
    -- to mean inventing a player to hold it with.
    T:Ok(Objects:Lock({Door}, Tool), "held by a table standing for nobody")
    T:Ok(Objects:IsLocked(Door), "held")
    T:Eq(Objects:GetLock(Door), nil, "by nobody with a user id")
    T:Eq(Objects:GetHolder(Door), Tool, "by that")

    T:Ok(Objects.LockedAgainst(Door, Ghost(-7000)), "against everybody else")
    T:Ok(not Objects.LockedAgainst(Door, Tool), "and not against itself")

    T:Ok(Objects:Unlock({Door}, Tool), "released by the same holder")
    T:Ok(not Objects:IsLocked(Door), "free")

    Scene:Destroy()
end)

T:Test("a hold by a user id and by the player it names are one hold", function()
    const Scene = Scenes.new({Name = "HolderIdRoom"}) :: any
    const Copy = Scene:Load()
    const Door = Copy:Create(BareId)

    T:Ok(Objects:Lock({Door}, -7001), "held by a bare user id")
    T:Eq(Objects:GetLock(Door), -7001, "which is who has it")
    T:Ok(not Objects.LockedAgainst(Door, Ghost(-7001)), "the same person either way")
    T:Ok(Objects.LockedAgainst(Door, Ghost(-7002)), "and somebody else is somebody else")

    Objects:Unlock({Door})
    Scene:Destroy()
end)

T:Test("a hold goes with the admission it was taken under", function()
    const Scene = Scenes.new({Name = "HolderEvicted", Private = true, Admitted = {-7003}}) :: any
    const Copy = Scene:Load()
    const Door = Copy:Create(BareId)

    T:Ok(Objects:Lock({Door}, -7003), "held")

    Scene:Evict(-7003)

    -- Shut out of the room while still holding something in it is a way to stop
    -- everybody else working without being able to work yourself.
    T:Ok(not Objects:IsLocked(Door), "and let go when they were shut out")

    Scene:Destroy()
end)

T:Test("a hold goes with the right that took it", function()
    const Scene = Scenes.new({Name = "HolderRevoked"}) :: any
    const Copy = Scene:Load()
    const Door = Copy:Create(BareId)
    const Plr = Ghost(-7004)

    Scene:Grant(Plr, "TestBulk")
    T:Ok(Objects:Lock({Door}, Plr), "held while they could edit")

    Scene:Revoke(Plr)
    T:Ok(not Objects:IsLocked(Door), "and let go when they no longer could")

    Scene:Destroy()
end)

--=============================================================================
-- Scene commits from a client
--=============================================================================

-- A holder leaving. Losing the right and losing admission have tests of their
-- own above; leaving had none, though it is the commonest of the three.

T:Test("a holder's holds all go when they leave, and nobody else's", function()
    const Holder = Ghost(-3201)
    const Other = Ghost(-3202)
    const A = Scenes.new({Name = "LeaveA"})
    const B = Scenes.new({Name = "LeaveB"})
    const InA = (A:Load() :: any):Create(BareId)
    const InB = (B:Load() :: any):Create(BareId)
    const Theirs = (B:GetInstances()[1] :: any):Create(BareId)

    T:Ok(Objects:Lock({InA, InB}, Holder), "held in two scenes")
    T:Ok(Objects:Lock({Theirs}, Other), "and someone else holds one too")

    -- What Players.PlayerRemoving runs for a player who leaves.
    Objects.ReleaseFor(Holder)

    T:Ok(not Objects:IsLocked(InA) and not Objects:IsLocked(InB), "both of theirs are free")
    T:Eq(Objects:GetLock(Theirs), -3202, "the other holder keeps theirs")

    A:Destroy()
    B:Destroy()
end)

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

const function Packed(LastId: number, Entries: {{Registry: number, LocalId: number, Properties: {[number]: any}}}): buffer
    const Objects_ = {}
    for Index, Entry in Entries do
        Objects_[Index] = {
            __type = "DecompressedObject",
            LocalId = Entry.LocalId,
            Registry = Entry.Registry,
            Properties = Entry.Properties,
        }
    end

    return Compressor:CompressScene(LastId, Objects_ :: any)
end

T:Test("a pushed pack keeps nothing the server cannot read", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "PushedForeign", Compressor:CompressScene(1, {
        {
            __type = "DecompressedObject",
            LocalId = 1,
            Registry = BareId,
            Properties = {[TitleId] = "Pushed"},
            Unknown = {[99992] = Compressor:CompressValue("Text", "Smuggled")},
        },
    } :: any))

    Permissions:Revoke(Ghost)
    T:Ok(Accepted, "accepted")

    const Scene = Scenes:Get("PushedForeign")
    if not Scene then
        T:Ok(false, "not registered")
        return
    end

    -- A save of the server's own keeps what an older build wrote. A packet
    -- from a client is not a save, and its unreadable bytes are not kept.
    const _, Back = Compressor:DecompressScene(Scene:Serialize())
    T:Eq(Back[1].Properties[TitleId], "Pushed", "the readable value landed")
    T:Eq(Back[1].Unknown, nil, "the unreadable one did not")

    Scene:Destroy()
end)

T:Test("a pack a client built becomes a scene of its own", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted, Identifier = Commit(Ghost, "PushedRoom", Packed(1, {
        {Registry = BareId, LocalId = 1, Properties = {[TitleId] = "Pushed"}},
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
        {Registry = BareId, LocalId = 1, Properties = {}},
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
        {Registry = BareId, LocalId = 1, Properties = {}},
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
        {Registry = BareId, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)

    T:Ok(not Accepted, "refused")
    T:Eq(Scenes:Get("ViewerRoom"), nil, "and registered nothing")
end)

T:Test("an unregistered object type refuses the pack", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "UnknownRoom", Packed(1, {
        {Registry = 99999, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)

    T:Ok(not Accepted, "refused")
    T:Eq(Scenes:Get("UnknownRoom"), nil, "and registered nothing")
end)

T:Test("a name already taken is refused before the pack is read", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Accepted = Commit(Ghost, "PushedRoom", Packed(1, {
        {Registry = BareId, LocalId = 1, Properties = {}},
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
        {Registry = BareId, LocalId = 1, Properties = {}},
    }))

    Permissions:Revoke(Ghost)
    T:Ok(not Accepted, "refused")
end)

T:Test("a pack past the object cap is refused", function()
    const Ghost = Pusher()
    Permissions:Grant(Ghost, "TestBulk")

    const Entries = table.create(4097)
    for Index = 1, 4097 do
        Entries[Index] = {Registry = BareId, LocalId = Index, Properties = {}}
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
        {Registry = BareId, LocalId = 1, Properties = {}},
        {Registry = BareId, LocalId = 2, Properties = {}},
        {Registry = BareId, LocalId = 3, Properties = {}},
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
    T:Eq(Button:GetProperty(TargetId).Value, 0, "and it still points at nothing")

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

T:Test("many references to nearby objects survive a save and cost almost nothing", function()
    const Scene = Scenes.new({Name = "RefMany"})
    const Copy = Scene:Load() :: any

    -- Each button made right after its door, the way an editor makes an
    -- attribute right after its block; and one pointing far back, and one at
    -- nothing, so the column holds more than one kind of distance.
    const Pairs = {}
    for Index = 1, 1000 do
        const Door = Copy:Create(DoorId)
        const Button = Copy:Create(ButtonId)
        Button:Set(TargetId, Door)
        Pairs[Index] = {Door = Door.LocalId, Button = Button.LocalId}
    end

    const Far = Copy:Create(ButtonId)
    Far:Set(TargetId, Copy:Find(Pairs[1].Door))
    const Nowhere = Copy:Create(ButtonId)

    Copy:Commit()

    -- Written as the target's id, a thousand references to a thousand
    -- different doors would not fit in this.
    const Size = buffer.len(Scene:Serialize())
    T:Ok(Size < 1000, `{Size} bytes for 2002 objects and 1001 references`)

    Copy:Unload()
    const Reloaded = Scene:Load() :: any

    local Wrong = 0
    for _, Pair in Pairs do
        const Button = Reloaded:Find(Pair.Button)
        if not Button or Button:GetProperty(TargetId).Value ~= Pair.Door then
            Wrong += 1
        end
    end

    T:Eq(Wrong, 0, "every button still points at its own door")
    T:Eq(Reloaded:Find(Far.LocalId):GetProperty(TargetId).Value, Pairs[1].Door, "the one pointing far back too")
    T:Eq(Reloaded:Find(Nowhere.LocalId):GetProperty(TargetId).Value, 0, "and the one pointing at nothing")

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
-- Object signals
--=============================================================================

T:Describe("Large loads")

-- A pack of crates, which have a part to clone and links to wire, so reading
-- one costs what a real level does.
const function CratePack(Name: string, Count: number): any
    const Source = Scenes.new({Name = Name})
    const Copy = Source:Load() :: any
    for Index = 1, Count do
        Copy:Create(CrateId, {[HealthId] = Index % 100})
    end

    Copy:Commit()
    Source:Unload()
    return Source
end

T:Test("a large load does not hold the server for its whole length", function()
    const Scene = CratePack("LargeLoad", 4000)

    -- task.spawn hands control back at the read's first yield, so timing it
    -- times the longest stretch the load holds the server without a break.
    -- Frame gaps would be the wrong measure here: the test player can join
    -- mid-load, and the engine spawning a character is a long frame of its
    -- own. Before the read was budgeted, the first stretch was the whole load.
    local Copy: any = nil
    const Started = os.clock()
    task.spawn(function()
        Copy = Scene:Load()
    end)

    const FirstStretch = os.clock() - Started
    T:Ok(FirstStretch < 0.05, `the first stretch was short, {math.floor(FirstStretch * 1000)} ms`)
    T:Eq(Copy, nil, "and the load was still going after it")

    T:Eventually(function()
        return Copy ~= nil
    end, 15, "the load finished")

    if Copy then
        T:Eq(#Copy:GetObjects(), 4000, "every object was read")
    end

    Scene:Destroy()
end)

-- How many objects the copy a load is building holds the moment the load first
-- hands control back. The announcing after the read yields too, so the load
-- returning would not say whether the reading did.
const function BuiltBeforeFirstYield(Scene: any, Options: any): (number, () -> boolean)
    local Returned = false
    task.spawn(function()
        Scene:Load(nil, Options)
        Returned = true
    end)

    local Built = 0
    for _, Copy in Scene:GetInstances() do
        Built += #Copy:GetObjects()
    end

    return Built, function()
        return Returned
    end
end

T:Test("a load given a budget of math.huge builds everything without waiting", function()
    const Scene = CratePack("LargeLoadWhole", 4000)

    const Built, Done = BuiltBeforeFirstYield(Scene, {Budget = math.huge})
    T:Eq(Built, 4000, "every object before the first yield")
    T:Eventually(Done, 15, "the load returned")

    Scene:Destroy()
end)

T:Test("a load given a budget of math.huge announces everything without waiting", function()
    -- Announcing to nobody sends nothing and waits for nothing, so this says
    -- something only with a player connected to hear it.
    if not Players:GetPlayers()[1] then
        T:Skip("no player to announce to")
        return
    end

    const Scene = CratePack("LargeLoadAnnounced", 4000)

    -- The announce used to wait a frame after every 50 objects whatever the
    -- budget, so this load yielded 80 times after it had finished building.
    const Built, Done = BuiltBeforeFirstYield(Scene, {Budget = math.huge})
    T:Eq(Built, 4000, "every object built")
    T:Ok(Done(), "and announced before the load first yielded")
    T:Eventually(Done, 15, "the load returned")

    Scene:Destroy()
end)

T:Test("a load given a budget it cannot use reads in frames as usual", function()
    const Scene = CratePack("LargeLoadBadBudget", 4000)

    -- Zero would wait a frame for every object; it is refused for the default.
    const Built, Done = BuiltBeforeFirstYield(Scene, {Budget = 0})
    T:Ok(Built > 1 and Built < 4000, `{Built} objects in the first frame, not one and not all`)
    T:Eventually(Done, 15, "the load still finished")

    const Copy = Scene:GetInstances()[1]
    T:Eq(Copy and #Copy:GetObjects(), 4000, "with every object")

    Scene:Destroy()
end)

T:Test("a copy set aside while it is read comes back whole", function()
    const Scene = CratePack("LargeLoadAside", 3000)

    local Loaded: any = nil
    task.spawn(function()
        Loaded = Scene:Load()
    end)

    -- The read has yielded by now, partway through. Setting the copy aside
    -- used to stop it there, and bringing the copy back brought back only
    -- what had been read.
    const Copy = Scene:GetInstances()[1] :: any
    T:Ok(Copy and Copy:Suspend(), "set aside mid-read")

    T:Eventually(function()
        return Loaded ~= nil
    end, 10, "the load returned")

    if Copy then
        T:Ok(Copy:Revive(), "brought back")
        T:Eq(#Copy:GetObjects(), 3000, "with every object in it")
    end

    Scene:Destroy()
end)

T:Test("a copy taken away while it is read gets nothing more", function()
    const Scene = CratePack("LargeLoadAbandoned", 3000)

    local Copy: any = nil
    task.spawn(function()
        Copy = Scene:Load()
    end)

    -- The read has yielded at least once by now; unloading every copy of the
    -- scene takes the one being read with it.
    task.wait()
    Scene:Unload()

    T:Eventually(function()
        return Copy ~= nil
    end, 5, "the read stopped")

    if Copy then
        T:Ok(Scenes:GetInstance(Copy.Id) == nil, "the copy is gone")

        local Live = 0
        for _, Obj in Objects:GetWorkspace() do
            if Obj.InstanceId == Copy.Id then
                Live += 1
            end
        end

        T:Eq(Live, 0, "and nothing was built into it after")
    end

    Scene:Destroy()
end)

--=============================================================================

T:Describe("Object signals")

T:Test("added and removed fire for every object, however it came and went", function()
    const Seen: {any} = {}
    const Gone: {any} = {}
    local Loaded = 0

    const StopAdded = Objects:OnAdded(function(Obj, Restored)
        if Restored then
            Loaded += 1
        else
            table.insert(Seen, Obj)
        end
    end)

    const StopRemoved = Objects:OnRemoved(function(Obj)
        table.insert(Gone, Obj)
    end)

    const Scene, Copy = Room("SignalRoom")
    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})

    T:Eq(Seen[1], Door, "creating fired added")
    T:Eq(Loaded, 0, "and did not call it a restore")

    -- Filed by the time the listener runs, both ways it can be looked up.
    T:Eq(Objects:Get(Door.RuntimeId), Door, "already in the workspace")
    T:Eq(Copy:Find(Door.LocalId), Door, "and in its copy")

    Objects.Suspend(Door)
    T:Eq(Gone[1], Door, "suspending fired removed")
    T:Ok(Door.Destroyed, "with the object already gone")

    Objects.Revive(Door)
    T:Eq(Seen[2], Door, "and reviving fired added again")

    Door:Destroy()
    T:Eq(Gone[2], Door, "destroying fired removed")

    -- A scene load builds its objects silently and sends them in one batch;
    -- the signal is about the object existing, so it fires for each of them.
    Copy:Create(DoorId)
    Copy:Commit()
    Copy:Unload()

    const Before = Loaded
    Scene:Load()
    T:Ok(Loaded > Before, "a load fired added for what it read back")

    StopAdded()
    StopRemoved()
    Scene:Destroy()
end)

T:Test("unloading a copy fires removed for everything it held", function()
    const Scene, Copy = Room("SignalUnload")
    Copy:Create(DoorId)
    Copy:Create(DoorId)

    local Count = 0
    const Stop = Objects:OnRemoved(function()
        Count += 1
    end)

    Copy:Unload()
    T:Eq(Count, 2, "one for each object the copy held")

    Stop()
    Scene:Destroy()
end)

--=============================================================================
-- Suspending
--=============================================================================

T:Describe("Suspending")

T:Test("a suspended object is out of the world but whole", function()
    const Scene, Copy = Room("SuspendRoom")

    -- A crate rather than a door: it has a template, so there is a part to
    -- keep out of the world.
    const Door = Copy:Create(CrateId, {[TitleId] = "Door"})
    const RuntimeId = Door.RuntimeId
    const LocalId = Door.LocalId
    const Part = Door.Instance

    T:Ok(Part, "built with a part")

    T:Ok(Objects.Suspend(Door), "suspended")

    T:Ok(Door.Destroyed, "reads as destroyed")
    T:Ok(Door.Suspended, "and as suspended")
    T:Eq(Objects:Get(RuntimeId), nil, "gone from the workspace")
    T:Eq(Copy:Find(LocalId), nil, "and from its copy")
    T:Eq(Door:Get(TitleId), nil, "and it answers like any destroyed object")

    -- What survives is the whole point: the values, both ids, and the part
    -- itself -- out of the world rather than destroyed.
    T:Eq(Door.Properties[TitleId].Value, "Door", "the value is still there")
    T:Eq(Door.RuntimeId, RuntimeId, "same runtime id")
    T:Eq(Door.LocalId, LocalId, "same local id")
    T:Eq(Door.Instance, Part, "the part is kept")
    T:Eq(Part.Parent, nil, "parented out of the world")

    T:Ok(Objects.Revive(Door), "revived")
    T:Ok(not Door.Destroyed, "alive again")
    T:Eq(Objects:Get(RuntimeId), Door, "back in the workspace, as itself")
    T:Eq(Copy:Find(LocalId), Door, "and in its copy under its own id")
    T:Eq(Door:Get(TitleId), "Door", "still holding what it held")

    -- The same part, not a fresh clone of the template: whatever a game hung
    -- on it is still hanging there.
    T:Eq(Door.Instance, Part, "the part it always had")
    T:Eq(Part.Parent, Copy.Folder, "back in the copy's folder")

    Scene:Destroy()
end)

T:Test("disposing a suspended object ends it, part and all", function()
    const Scene, Copy = Room("DisposeRoom")
    const Door = Copy:Create(DoorId)
    const Part = Door.Instance

    Objects.Suspend(Door)
    T:Eq(Door.Instance, Part, "the part was kept by the suspend")

    Objects.Dispose(Door)

    T:Eq(Door.Suspended, nil, "no longer suspended")
    T:Ok(Door.Destroyed, "still destroyed")
    T:Eq(Door.Instance, nil, "and the part went with it")
    T:Ok(not Objects.Revive(Door), "past reviving")

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

T:Test("the stack is capped by what its steps hold, not only by count", function()
    const Scene, Copy = Room("HistoryWeight")
    const Plr = Editor(-6090, Scene)
    const Limits = History:GetLimits()
    History:SetLimits({Objects = 3})

    const Doors = {}
    for Index = 1, 5 do
        Doors[Index] = Copy:Create(DoorId, {[TitleId] = `Door{Index}`})
    end

    -- Five destroys, one step each, each holding the door it took.
    for _, Door in Doors do
        Transactions.Apply(Plr, {{Kind = "Destroy", Target = Door.RuntimeId}} :: any)
    end

    T:Ok(not Doors[1].Suspended and not Doors[2].Suspended, "the two oldest were let go")
    T:Ok(Doors[3].Suspended and Doors[5].Suspended, "the three that fit are still kept")

    T:Ok(History:Undo(Plr), "one")
    T:Ok(History:Undo(Plr), "two")
    T:Ok(History:Undo(Plr), "three")
    T:Ok(not History:CanUndo(Plr), "and no further")
    T:Eq(#Copy:GetObjects(), 3, "the kept doors came back")

    -- One step heavier than the whole budget is still the newest thing done,
    -- and is kept: an undo that cannot reach the last action is no undo.
    History:Clear(Plr)
    const Ids = {}
    for _, Obj in Copy:GetObjects() do
        table.insert(Ids, {Kind = "Destroy", Target = Obj.RuntimeId})
    end

    const Extra = Copy:Create(DoorId)
    table.insert(Ids, {Kind = "Destroy", Target = Extra.RuntimeId})
    Transactions.Apply(Plr, Ids :: any)

    T:Ok(History:CanUndo(Plr), "a step over the budget on its own is kept")
    T:Ok(Extra.Suspended, "with what it holds")

    History:SetLimits(Limits)
    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

-- A step whose undo yields, as bringing a big copy back does: it announces the
-- copy's objects a chunk a frame. A custom action stands in for it here because
-- its yield does not depend on anyone being connected to hear the chunks, and
-- the server suite runs before the test player arrives.
const function SlowStep(Plr: any, Seconds: number): {Cleared: boolean}
    const Seen = {Cleared = false}
    History:Push(Plr, {
        Undo = function()
            task.wait(Seconds)
        end,

        Redo = function() end,

        Clear = function()
            Seen.Cleared = true
        end,
    })

    return Seen
end

T:Test("another player's edits are recorded while an undo yields", function()
    const Scene, Copy = Room("HistoryYieldOthers")
    const A = Editor(-6301, Scene)
    const B = Editor(-6302, Scene)
    const Door = Copy:Create(DoorId, {[TitleId] = "B's door"})

    SlowStep(A, 0.3)

    local Undone = nil
    task.spawn(function()
        Undone = History:Undo(A)
    end)

    T:Eq(Undone, nil, "A's undo is still running")

    -- B's destroy lands in the middle of it. It used to go unrecorded, because
    -- one flag for the whole server said a step was being applied, and an
    -- unrecorded destroy is disposed on the spot rather than kept.
    T:Ok(Transactions.Apply(B, {{Kind = "Destroy", Target = Door.RuntimeId}} :: any), "B destroyed a door")
    T:Ok(History:CanUndo(B), "and it was recorded as B's")

    T:Eventually(function()
        return Undone ~= nil
    end, 3, "A's undo finished")

    T:Ok(History:Undo(B), "B undoes the destroy")
    T:Eq(Objects:Get(Door.RuntimeId), Door, "and the same door is back")

    History:Clear(A)
    History:Clear(B)
    Scene:Destroy()
end)

T:Test("a clear while an undo yields leaves nothing to redo", function()
    const Scene = Room("HistoryYieldClear")
    const A = Editor(-6303, Scene)
    const Seen = SlowStep(A, 0.3)

    local Undone = nil
    task.spawn(function()
        Undone = History:Undo(A)
    end)

    -- The step is off the stack while it runs, so the clear cannot reach it.
    -- It used to be put on the redo stack afterwards regardless, surviving a
    -- clear that came after it.
    History:Clear(A)

    T:Eventually(function()
        return Undone ~= nil
    end, 3, "the undo finished")

    T:Ok(not History:CanRedo(A), "nothing to redo")
    T:Ok(not History:CanUndo(A), "nothing to undo")
    T:Ok(Seen.Cleared, "and the step was cleared, letting go of what it held")

    Scene:Destroy()
end)

T:Test("a custom undo's own edits go unrecorded, the player's meanwhile do not", function()
    const Scene, Copy = Room("HistoryCustomOwn")
    const A = Editor(-6305, Scene)
    const Door = Copy:Create(DoorId, {[TitleId] = "Before"})

    const function SetAs(Value: string)
        return Transactions.Apply(A, {
            {Kind = "Set", Target = Door.RuntimeId, Property = TitleId, Value = Value, Type = "Text"},
        } :: any)
    end

    History:Push(A, {
        Undo = function()
            -- The action's own edit, through the ordinary API: part of undoing,
            -- not something the player did.
            SetAs("ByAction")
            task.wait(0.3)
        end,

        Redo = function() end,
    })

    local Undone = nil
    task.spawn(function()
        Undone = History:Undo(A)
    end)

    -- The player's own edit while the action waits. It used to go unrecorded,
    -- because recording was off for the player rather than for the action.
    T:Ok(SetAs("ByPlayer"), "the player edited meanwhile")

    T:Eventually(function()
        return Undone ~= nil
    end, 3, "the undo finished")

    T:Ok(History:CanUndo(A), "the player's edit is a step")
    T:Ok(History:Undo(A), "and undoes")
    T:Eq(Door:Get(TitleId), "ByAction", "back to what the action left, not before it")
    T:Ok(not History:CanUndo(A), "and the action's own edit was never a step")

    History:Clear(A)
    Scene:Destroy()
end)

T:Test("a fork while an undo yields leaves the undone step unreachable", function()
    const Scene = Room("HistoryYieldFork")
    const A = Editor(-6304, Scene)
    const Seen = SlowStep(A, 0.3)

    local Undone = nil
    task.spawn(function()
        Undone = History:Undo(A)
    end)

    -- A new action in a scene the client owns forks this half too. With the
    -- redo stack empty at that moment the fork used to do nothing, and the
    -- step then landed on the redo stack, redoable past the newer action.
    History:Fork(A)

    T:Eventually(function()
        return Undone ~= nil
    end, 3, "the undo finished")

    T:Ok(not History:CanRedo(A), "not redoable past the newer action")
    T:Ok(Seen.Cleared, "and cleared")

    Scene:Destroy()
end)

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

T:Test("an action of the game's own takes its place in the order", function()
    const Scene, Copy = Room("HistoryCustom")
    const Plr = Editor(-6008, Scene)
    const Door = Copy:Create(DoorId, {[TitleId] = "Start"})

    -- Pushed as the action happens, so it starts where the action left it.
    local Where = "after"
    T:Ok(History:Push(Plr, {
        Undo = function()
            Where = "before"
        end,

        Redo = function()
            Where = "after"
        end,
    }), "pushed")

    -- An edit after it, so the custom step is not the one on top: undoing has
    -- to reach the edit first and the action second, in the order they happened.
    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Set", Target = Door.RuntimeId, Property = TitleId, Value = "Edited", Type = "Text"},
    } :: any), "edited")

    T:Ok(History:Undo(Plr), "the edit undone")
    T:Eq(Door:Get(TitleId), "Start", "the edit went back")
    T:Eq(Where, "after", "and the action has not been reached yet")

    T:Ok(History:Undo(Plr), "the action undone")
    T:Eq(Where, "before", "its Undo ran")

    T:Ok(History:Redo(Plr), "redone")
    T:Eq(Where, "after", "its Redo ran")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a custom action clears when nothing can reach it", function()
    const Scene = Scenes.new({Name = "HistoryCustomClear"})
    const Plr = Editor(-6009, Scene)

    local Held = true
    History:Push(Plr, {
        Undo = function() end,
        Redo = function() end,
        Clear = function()
            Held = false
        end,
    })

    T:Ok(Held, "held while the step is reachable")

    History:Clear(Plr)
    T:Ok(not Held, "and let go when it is not")

    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a custom action that throws stays on the stack", function()
    const Scene = Scenes.new({Name = "HistoryCustomThrow"})
    const Plr = Editor(-6010, Scene)

    History:Push(Plr, {
        Undo = function()
            error("no")
        end,

        Redo = function() end,
    })

    T:Ok(not History:Undo(Plr), "refused")
    T:Ok(History:CanUndo(Plr), "and left where it was, to be tried again")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("what a custom action does while undoing is not a new step", function()
    const Scene, Copy = Room("HistoryCustomQuiet")
    const Plr = Editor(-6011, Scene)
    const Door = Copy:Create(DoorId, {[TitleId] = "Start"})

    History:Push(Plr, {
        Undo = function()
            -- The ordinary API, from inside a reversal. Recording this would
            -- put a step on top of the one being undone, and the stack would
            -- grow every time it was emptied.
            Transactions.Apply(Plr, {
                {Kind = "Set", Target = Door.RuntimeId, Property = TitleId, Value = "Moved", Type = "Text"},
            } :: any)
        end,

        Redo = function() end,
    })

    T:Ok(History:Undo(Plr), "undone")
    T:Eq(Door:Get(TitleId), "Moved", "what it did landed")
    T:Ok(not History:CanUndo(Plr), "and was not recorded as a step of its own")

    History:Clear(Plr)
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
-- Placing
--=============================================================================

T:Describe("Placing")

-- A pack holding a door and a button wired to it, for the placing tests to
-- paste around. Built once, in a scene of its own, and committed.
const Prefab = (function(): buffer
    const Scene = Scenes.new({Name = "PrefabSource"}) :: any
    const Copy = Scene:Load()

    const Door = Copy:Create(DoorId, {[TitleId] = "PrefabDoor"})
    const Button = Copy:Create(ButtonId, {[TitleId] = "PrefabButton"})
    Button:Set(TargetId, Door)

    const Pack = Copy:Serialize()
    Scene:Destroy()
    return Pack
end)()

T:Test("a placed pack lands under this copy's own ids", function()
    const Scene, Copy = Room("PlaceRoom")
    const Sitting = Copy:Create(DoorId, {[TitleId] = "Sitting"})

    const Made = Copy:Place(Prefab)
    T:Ok(Made and #Made == 2, "both objects placed")

    if not Made then
        Scene:Destroy()
        return
    end

    T:Eq(#Copy:GetObjects(), 3, "beside what was already there")

    for _, Obj in Made do
        T:Ok(Obj.LocalId ~= Sitting.LocalId, "a fresh id, not the saved one")
        T:Eq(Copy:Find(Obj.LocalId), Obj, "filed under it")
        T:Eq(Obj.InstanceId, Copy.Id, "in this copy")
    end

    Scene:Destroy()
end)

T:Test("references inside a placed pack follow it", function()
    const Scene, Copy = Room("PlaceReferences")
    const Made = Copy:Place(Prefab) :: any

    local Door, Button
    for _, Obj in Made do
        if Obj:Get(TitleId) == "PrefabDoor" then
            Door = Obj
        else
            Button = Obj
        end
    end

    T:Ok(Door and Button, "found both")

    if Door and Button then
        -- The saved id named a door in the scene the pack was written in. What
        -- it names here is whatever the placement made.
        T:Eq(Button:Get(TargetId), Door, "the button works the door it came with")
        T:Ok(Button:GetProperty(TargetId).Value ~= 0, "by a real id")
    end

    Scene:Destroy()
end)

T:Test("placing twice gives two independent sets", function()
    const Scene, Copy = Room("PlaceTwice")

    const First = Copy:Place(Prefab) :: any
    const Second = Copy:Place(Prefab) :: any

    T:Eq(#Copy:GetObjects(), 4, "four objects in the copy")

    local FirstButton, SecondButton
    for _, Obj in First do
        if Obj:Get(TitleId) == "PrefabButton" then
            FirstButton = Obj
        end
    end

    for _, Obj in Second do
        if Obj:Get(TitleId) == "PrefabButton" then
            SecondButton = Obj
        end
    end

    T:Ok(FirstButton and SecondButton, "a button in each")

    if FirstButton and SecondButton then
        T:Ok(FirstButton:Get(TargetId) ~= SecondButton:Get(TargetId), "each works its own door")
        T:Ok(table.find(First, FirstButton:Get(TargetId)) ~= nil, "the door it was placed with")
        T:Ok(table.find(Second, SecondButton:Get(TargetId)) ~= nil, "and likewise")
    end

    Scene:Destroy()
end)

T:Test("a reference the pack did not carry is dropped", function()
    const Source = Scenes.new({Name = "PlaceDangling"}) :: any
    const SourceCopy = Source:Load()

    -- A button whose door is not in the pack: the door is destroyed before the
    -- pack is written, so the reference is an id naming nothing.
    const Door = SourceCopy:Create(DoorId)
    const Button = SourceCopy:Create(ButtonId)
    Button:Set(TargetId, Door)
    const Saved = Door.LocalId
    Door:Destroy()

    const Pack = SourceCopy:Serialize()
    Source:Destroy()

    const Scene, Copy = Room("PlaceDanglingTarget")

    -- Something in the target copy answering to the id the pack carried, which
    -- is the whole hazard: carried over, the placed button would come up wired
    -- to this.
    local Filler = Copy:Create(DoorId, {[TitleId] = "NotYours"})
    while Filler.LocalId < Saved do
        Filler = Copy:Create(DoorId, {[TitleId] = "NotYours"})
    end

    const Made = Copy:Place(Pack) :: any
    T:Ok(Made and #Made == 1, "the button placed")

    if Made and Made[1] then
        T:Eq(Made[1]:Get(TargetId), nil, "pointing at nothing")
        T:Eq(Made[1]:GetProperty(TargetId).Value, 0, "with the empty reference written")
    end

    Scene:Destroy()
end)

T:Test("a client places through create rights, as one step", function()
    const Scene, Copy = Room("PlaceTransaction")
    const Plr = Editor(-6100, Scene)

    -- Built as a client builds it, applied as the player rather than as the
    -- server, so the create rights are the ones actually being asked for.
    const Edit = Transactions.new():Place(Prefab, Copy.Id)
    T:Eq(#Edit.Operations, 2, "one create per object in the pack")

    const Applied, Created = Transactions.Apply(Plr, Edit.Operations)

    T:Ok(Applied, "applied")
    T:Eq(#Created, 2, "both landed")

    const First = Objects:Get(Created[1])
    const Second = Objects:Get(Created[2])
    T:Ok(First and Second, "both are here")

    if First and Second then
        const Button = if First:Get(TitleId) == "PrefabButton" then First else Second
        const Door = if Button == First then Second else First
        T:Eq(Button:Get(TargetId), Door, "wired to the door placed with it")
    end

    -- One transaction, so one step: undoing takes the whole placement back
    -- rather than one object of it.
    T:Ok(History:CanUndo(Plr), "recorded")
    T:Ok(History:Undo(Plr), "undone")
    T:Eq(#Copy:GetObjects(), 0, "the placement went as a unit")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a placement a client is not allowed refuses whole", function()
    const Scene, Copy = Room("PlaceRefused")
    const Plr = Ghost(-6101)

    -- No rights on this scene at all.
    const Applied = Transactions.Apply(Plr, Transactions.new():Place(Prefab, Copy.Id).Operations)

    T:Ok(not Applied, "refused")
    T:Eq(#Copy:GetObjects(), 0, "and placed nothing")

    Scene:Destroy()
end)

--=============================================================================
-- Tables
--=============================================================================

T:Describe("Tables")

const ScoresId = Properties:Register({
    Name = "TestScores",
    Type = "Table",
    Constraints = {Of = "Number", Item = {MinValue = 0, AllowDecimals = false}, MaxItems = 4},
    DefaultValue = {},
}) :: number

const DoorsId = Properties:Register({
    Name = "TestDoors",
    Type = "Table",
    Constraints = {Of = "Object", Item = {Types = {"TestDoor"}}},
    DefaultValue = {},
}) :: number

const PanelId = Objects:Register({
    Name = "TestPanel",
    Properties = {TitleId, ScoresId, DoorsId},
}) :: number

T:Test("a Table needs an item type that is not a Table", function()
    T:Eq(Properties:Register({Name = "TestNoOf", Type = "Table", DefaultValue = {}} :: any), nil, "no Of")
    T:Eq(Properties:Register({Name = "TestNested", Type = "Table", Constraints = {Of = "Table"}, DefaultValue = {}} :: any), nil, "a Table of Tables")
    T:Eq(Properties:Register({Name = "TestBadDefault", Type = "Table", Constraints = {Of = "Text"}, DefaultValue = {1}} :: any), nil, "a default that does not fit")

    const Default = Properties:GetRegistry(ScoresId).DefaultValue
    T:Ok(table.isfrozen(Default), "the default is frozen")
end)

T:Test("a list holds its items to the item constraints", function()
    const Scene, Copy = Room("TableNumbers")
    const Panel = Copy:Create(PanelId)

    T:Ok(Panel:Set(ScoresId, {3, -2, 7.4, 1, 9}), "a list is taken")

    const Held = Panel:Get(ScoresId)
    T:Eq(#Held, 4, "cut to MaxItems")
    T:Eq(Held[2], 0, "clamped to MinValue")
    T:Eq(Held[3], 7, "rounded")
    T:Ok(table.isfrozen(Held), "and frozen, so it cannot change behind Set")

    T:Ok(not Panel:Set(ScoresId, {1, "two"}), "an item of the wrong type is refused")
    T:Ok(not Panel:Set(ScoresId, {First = 1}), "a dictionary is not a list")
    T:Eq(Panel:Get(ScoresId), Held, "and the list is untouched")

    -- Equal is no change, which is what keeps a drag from flooding history.
    T:Ok(Panel:Set(ScoresId, {3, 0, 7, 1}), "an equal list is accepted")
    T:Eq(Panel:Get(ScoresId), Held, "and the list held is kept")

    Scene:Destroy()
end)

T:Test("a list survives a commit and a reload", function()
    const Scene = Scenes.new({Name = "TableSaved"})
    const Copy = Scene:Load() :: any

    const Door = Copy:Create(DoorId)
    const Panel = Copy:Create(PanelId)
    Panel:Set(ScoresId, {5, 1e9, 0})
    Panel:Set(DoorsId, {Door})

    Copy:Commit()
    Copy:Unload()

    const Reloaded = Scene:Load() :: any
    const Back = Reloaded:Find(Panel.LocalId)

    T:Ok(Back, "the panel came back")
    const Scores = Back:Get(ScoresId)
    T:Eq(#Scores, 3, "every item")
    T:Eq(Scores[2], 1e9, "a large whole number intact")
    T:Eq(Back:Get(DoorsId)[1], Reloaded:Find(Door.LocalId), "the reference still names the door")

    Scene:Destroy()
end)

T:Test("a list of references reads as the objects it names", function()
    const Scene, Copy = Room("TableRefs")
    const Left = Copy:Create(DoorId)
    const Right = Copy:Create(DoorId)
    const Button = Copy:Create(ButtonId)
    const Panel = Copy:Create(PanelId)

    T:Ok(Panel:Set(DoorsId, {Left, Right.LocalId}), "takes objects and ids alike")

    const Read = Panel:Get(DoorsId)
    T:Eq(Read[1], Left, "first door")
    T:Eq(Read[2], Right, "second door")
    T:Eq(Panel:GetProperty(DoorsId).Value[1], Left.LocalId, "stored as local ids")

    T:Ok(not Panel:Set(DoorsId, {Left, Button}), "an item the constraint refuses refuses the list")
    T:Ok(not Panel:Set(DoorsId, Left), "an object is not a list of them")

    const Elsewhere = Scene:Load() :: any
    T:Ok(not Panel:Set(DoorsId, {Elsewhere:Create(DoorId)}), "an item in another copy is refused")

    Right:Destroy()
    T:Eq(#Panel:Get(DoorsId), 1, "a destroyed target is left out of what reads back")
    T:Eq(#Panel:GetProperty(DoorsId).Value, 2, "while its id is kept")

    T:Ok(Panel:Set(DoorsId, nil), "nil clears")
    T:Eq(#Panel:GetProperty(DoorsId).Value, 0, "to an empty list")

    Scene:Destroy()
end)

T:Test("a list cannot drive an instance", function()
    const Linked = Objects:Register({
        Name = "TestLinkedTable",
        Properties = {ScoresId},
        Instance = Template,
        Links = {{Property = ScoresId, Type = "Attribute", Name = "Scores"}},
    }) :: number

    T:Eq(Objects:GetRegistry(Linked).Links, nil, "the link was dropped")
    Objects:Unregister(Linked)
end)

T:Test("a group duplicate remaps the items pointing into it", function()
    const Scene, Copy = Room("TableDuplicate")
    const Inside = Copy:Create(DoorId)
    const Outside = Copy:Create(DoorId)
    const Panel = Copy:Create(PanelId)
    Panel:Set(DoorsId, {Inside, Outside})

    const Made = Objects:DuplicateGroup({Panel, Inside})
    const NewPanel, NewInside = Made[1], Made[2]

    const Read = NewPanel:Get(DoorsId)
    T:Eq(Read[1], NewInside, "the item in the group follows the copy")
    T:Eq(Read[2], Outside, "the item outside it keeps its target")
    T:Eq(Panel:Get(DoorsId)[1], Inside, "the original is untouched")

    Scene:Destroy()
end)

T:Test("a transaction duplicates a group with its lists remapped", function()
    const Scene, Copy = Room("TableGroupTransaction")
    const Inside = Copy:Create(DoorId)
    const Outside = Copy:Create(DoorId)
    const Panel = Copy:Create(PanelId)
    Panel:Set(DoorsId, {Outside, Inside})

    const Edit = Transactions.new():DuplicateGroup({Panel, Inside})

    -- Across the wire, as a client would send it.
    const Operations = Compressor:DecompressTransaction(Compressor:CompressTransaction(Edit.Operations))
    T:Eq(typeof(Operations[1].References[DoorsId]), "table", "a list of references rides the wire as a list")

    const Applied, Created = Transactions.Apply(nil, Operations)
    T:Ok(Applied, "applied")

    const NewPanel = Objects:Get(Created[1])
    const NewInside = Objects:Get(Created[2])
    const Read = NewPanel:Get(DoorsId)

    T:Eq(Read[1], Outside, "the outside item kept")
    T:Eq(Read[2], NewInside, "the inside item remapped, in its place")

    Scene:Destroy()
end)

T:Test("a list naming an operation that is not a create is refused", function()
    const Scene, Copy = Room("TableBadOperation")

    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = PanelId, Instance = Copy.Id, Properties = {}, References = {[DoorsId] = {0, 5}}},
    } :: any), "no operation 5")

    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = PanelId, Instance = Copy.Id, Properties = {}, References = {[DoorsId] = 2}},
        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {}},
    } :: any), "a single reference for a list")

    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Create", Object = ButtonId, Instance = Copy.Id, Properties = {}, References = {[TargetId] = {2}}},
        {Kind = "Create", Object = DoorId, Instance = Copy.Id, Properties = {}},
    } :: any), "a list for a single reference")

    T:Eq(#Copy:GetObjects(), 0, "nothing was created")
    Scene:Destroy()
end)

T:Test("a set of a list checks its item type", function()
    const Scene, Copy = Room("TableItemType")
    const Panel = Copy:Create(PanelId)

    T:Ok(not Transactions.Apply(nil, {
        {Kind = "Set", Target = Panel.RuntimeId, Property = DoorsId, Value = {1}, Type = "Table", ItemType = "Number"},
    } :: any), "numbers are not references")

    T:Ok(Transactions.Apply(nil, {
        {Kind = "Set", Target = Panel.RuntimeId, Property = ScoresId, Value = {1, 2}, Type = "Table", ItemType = "Number"},
    } :: any), "numbers are numbers")

    T:Eq(#Panel:Get(ScoresId), 2, "and landed")
    Scene:Destroy()
end)

T:Test("a placed pack keeps the list items it carried", function()
    const Source = Scenes.new({Name = "TablePrefab"}) :: any
    const SourceCopy = Source:Load()

    const Kept = SourceCopy:Create(DoorId, {[TitleId] = "Kept"})
    const Gone = SourceCopy:Create(DoorId, {[TitleId] = "Gone"})
    const Panel = SourceCopy:Create(PanelId, {[TitleId] = "Panel"})
    Panel:Set(DoorsId, {Gone, Kept})
    Gone:Destroy()

    const Pack = SourceCopy:Serialize()
    Source:Destroy()

    const Scene, Copy = Room("TablePlaced")
    const Made = Copy:Place(Pack) :: any

    local Door, Placed
    for _, Obj in Made do
        if Obj:Get(TitleId) == "Kept" then
            Door = Obj
        elseif Obj:Get(TitleId) == "Panel" then
            Placed = Obj
        end
    end

    T:Ok(Door and Placed, "found both")
    if Door and Placed then
        T:Eq(#Placed:GetProperty(DoorsId).Value, 1, "the item the pack did not carry is dropped")
        T:Eq(Placed:Get(DoorsId)[1], Door, "the one it did follows it")
    end

    Scene:Destroy()
end)

-- Wiring as a level holds it: each panel made right after the two doors it
-- names, so every list points the same distance back from its own row.
const function WiredPanels(Name: string, Count: number, Wired: boolean)
    const Scene = Scenes.new({Name = Name}) :: any
    const Copy = Scene:Load()
    const Panels = {}
    for Index = 1, Count do
        const First = Copy:Create(DoorId)
        const Second = Copy:Create(DoorId)
        Panels[Index] = Copy:Create(PanelId)
        if Wired then
            Panels[Index]:Set(DoorsId, {First, Second})
        end
    end

    return Scene, Copy, Panels
end

T:Test("a list of references reads back from a pack relative to its row", function()
    const Scene, Copy, Panels = WiredPanels("TableRelative", 300, true)

    -- One panel names a door far away and one names nothing, so the column
    -- holds more than one shape of list.
    Panels[150]:Set(DoorsId, {Panels[1]:Get(DoorsId)[1]})
    Panels[151]:Set(DoorsId, {})

    const BackScene = Scenes.fromBuffer({Name = "TableRelativeBack"}, Copy:Serialize())
    const Back = BackScene:Load()

    local Wrong = 0
    for _, Panel in Panels do
        const Restored = Back:Find(Panel.LocalId)
        const Saved = Panel:GetProperty(DoorsId).Value
        const Read = Restored and Restored:GetProperty(DoorsId).Value
        if not Read or #Read ~= #Saved then
            Wrong += 1
            continue
        end

        for Index, Target in Saved do
            if Read[Index] ~= Target then
                Wrong += 1
            end
        end
    end

    T:Eq(Wrong, 0, "every list holds the ids it was saved with")

    Scene:Destroy()
    BackScene:Destroy()
end)

T:Test("a list of references costs almost nothing in a pack", function()
    const Bare, BareCopy = WiredPanels("TableBare", 2000, false)
    const Wired, WiredCopy = WiredPanels("TableWired", 2000, true)

    -- Written as whole ids, each list was a different few bytes on every row
    -- and zstd kept most of them.
    const Cost = buffer.len(WiredCopy:Serialize()) - buffer.len(BareCopy:Serialize())
    T:Ok(Cost < 200, `2,000 lists of two cost {Cost} bytes`)

    Bare:Destroy()
    Wired:Destroy()
end)

T:Test("undoing a list set puts the list back", function()
    const Scene, Copy = Room("TableHistory")
    const Plr = Editor(-6200, Scene)
    const Panel = Copy:Create(PanelId)

    const function Set(Value: {number})
        return Transactions.Apply(Plr, {
            {Kind = "Set", Target = Panel.RuntimeId, Property = ScoresId, Value = Value, Type = "Table", ItemType = "Number"},
        } :: any)
    end

    T:Ok(Set({1}), "first")
    T:Ok(Set({1, 2}), "second")

    T:Ok(History:Undo(Plr), "undone")
    T:Eq(#Panel:Get(ScoresId), 1, "back to the first list")
    T:Ok(History:Redo(Plr), "redone")
    T:Eq(#Panel:Get(ScoresId), 2, "forward to the second")
    T:Ok(History:Undo(Plr), "undone again")
    T:Eq(#Panel:Get(ScoresId), 1, "and back, with lists compared by their items")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

--=============================================================================
-- Holds and copies as operations
--=============================================================================

T:Describe("Holds and copies as operations")

T:Test("a transaction takes holds, edits, and lets go", function()
    const Scene, Copy = Room("HoldRoom")
    const Plr = Editor(-6200, Scene)
    const Other = Ghost(-6201)

    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})

    const Applied = Transactions.Apply(Plr, {
        {Kind = "Lock", Target = Door.RuntimeId},
        {Kind = "Set", Target = Door.RuntimeId, Property = TitleId, Value = "Held", Type = "Text"},
    } :: any)

    T:Ok(Applied, "applied")
    T:Eq(Door:Get(TitleId), "Held", "the edit landed")
    T:Eq(Objects:GetLock(Door), -6200, "and the hold is still taken")

    -- Held, so somebody else cannot have it.
    T:Ok(Objects.LockedAgainst(Door, Other), "against everyone else")

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Unlock", Target = Door.RuntimeId},
    } :: any), "released")

    T:Eq(Objects:GetLock(Door), nil, "and let go")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a hold somebody else has refuses the whole transaction", function()
    const Scene, Copy = Room("HoldTaken")
    const Plr = Editor(-6202, Scene)
    const Other = Ghost(-6203)

    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    T:Ok(Objects:Lock({Door}, Other), "somebody else has it")

    const Applied = Transactions.Apply(Plr, {
        {Kind = "Lock", Target = Door.RuntimeId},
        {Kind = "Set", Target = Door.RuntimeId, Property = TitleId, Value = "Mine", Type = "Text"},
    } :: any)

    T:Ok(not Applied, "refused")
    T:Eq(Door:Get(TitleId), "Door", "and the edit that rode with it never landed")

    Objects:Unlock({Door})
    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("holds are not undoable", function()
    const Scene, Copy = Room("HoldHistory")
    const Plr = Editor(-6204, Scene)
    const Door = Copy:Create(DoorId)

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Lock", Target = Door.RuntimeId},
    } :: any), "held")

    -- A lock is not a change to the world, so there is nothing to take back.
    T:Ok(not History:CanUndo(Plr), "nothing recorded")
    T:Eq(Objects:GetLock(Door), -6204, "and the hold stands")

    Objects:Unlock({Door})
    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a client loads a scene through create rights", function()
    const Scene = Scenes.new({Name = "LoadTarget"}) :: any
    const Plr = Editor(-6205, Scene)

    -- Something committed, so the copy it loads is not empty.
    const Seed = Scene:Load()
    Seed:Create(DoorId, {[TitleId] = "Inside"})
    Seed:Commit()
    Seed:Unload()

    T:Eq(#Scene:GetInstances(), 0, "nothing live to begin with")

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Load", Scene = Scene.Id},
    } :: any), "loaded")

    const Live = Scene:GetInstances()[1]
    T:Ok(Live, "a copy appeared")

    if Live then
        T:Eq(#Live:GetObjects(), 1, "holding what the scene had")
    end

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a load without create rights on the scene is refused", function()
    const Scene = Scenes.new({Name = "LoadRefused"}) :: any
    const Plr = Ghost(-6206)

    T:Ok(not Transactions.Apply(Plr, {
        {Kind = "Load", Scene = Scene.Id},
    } :: any), "refused")

    T:Eq(#Scene:GetInstances(), 0, "and loaded nothing")
    Scene:Destroy()
end)

T:Test("an unload withdraws the copy, and undoing brings back what was in it", function()
    const Scene, Copy = Room("UnloadRoom")
    const Plr = Editor(-6207, Scene)

    const Door = Copy:Create(DoorId, {[TitleId] = "Door"})
    const Button = Copy:Create(ButtonId)
    Button:Set(TargetId, Door)

    -- Never committed, so the scene's data holds none of this: reloading would
    -- read nothing, and only a withdrawal can bring it back.
    const CopyId = Copy.Id
    const Folder = Copy.Folder

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Unload", Instance = CopyId},
    } :: any), "unloaded")

    T:Ok(Copy.Suspended, "the copy was kept rather than unloaded")
    T:Eq(Scenes:GetInstance(CopyId), nil, "and is not live")
    T:Ok(Door.Suspended and Button.Suspended, "with its objects held")
    T:Eq(Folder.Parent, nil, "and its folder out of the world")

    T:Ok(History:Undo(Plr), "undone")

    T:Eq(Scenes:GetInstance(CopyId), Copy, "the same copy is live again")
    T:Eq(Copy:Find(Door.LocalId), Door, "holding the same objects")
    T:Eq(Button:Get(TargetId), Door, "still wired to each other")
    T:Eq(Door:Get(TitleId), "Door", "with what they held")
    T:Ok(Folder.Parent ~= nil, "and its folder back in the world")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("a withdrawn copy ends when nothing can reach the step", function()
    const Scene, Copy = Room("UnloadCleared")
    const Plr = Editor(-6208, Scene)
    const Door = Copy:Create(DoorId)

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Unload", Instance = Copy.Id},
    } :: any), "unloaded")

    T:Ok(Copy.Suspended, "held")

    History:Clear(Plr)

    T:Eq(Copy.Suspended, nil, "and let go once nothing could bring it back")
    T:Eq(Door.Suspended, nil, "its objects with it")

    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("undoing a load withdraws the copy it made", function()
    const Scene = Scenes.new({Name = "LoadUndo"}) :: any
    const Plr = Editor(-6209, Scene)

    T:Ok(Transactions.Apply(Plr, {
        {Kind = "Load", Scene = Scene.Id},
    } :: any), "loaded")

    const Live = Scene:GetInstances()[1]
    T:Ok(Live, "a copy appeared")

    T:Ok(History:Undo(Plr), "undone")
    T:Eq(#Scene:GetInstances(), 0, "the copy went")

    if Live then
        T:Ok(Live.Suspended, "withdrawn rather than unloaded")
    end

    T:Ok(History:Redo(Plr), "redone")
    T:Eq(Scene:GetInstances()[1], Live, "and the same copy came back")

    History:Clear(Plr)
    Permissions:Revoke(Plr)
    Scene:Destroy()
end)

T:Test("the four new kinds round trip on the wire", function()
    const Operations = {
        {Kind = "Lock", Target = 11},
        {Kind = "Unlock", Target = 12},
        {Kind = "Load", Scene = 13},
        {Kind = "Unload", Instance = 14},
    }

    const Read = Compressor:DecompressTransaction(Compressor:CompressTransaction(Operations :: any))

    T:Eq(#Read, 4, "four operations")
    T:Eq(Read[1].Kind, "Lock", "lock")
    T:Eq(Read[1].Target, 11, "its target")
    T:Eq(Read[2].Kind, "Unlock", "unlock")
    T:Eq(Read[2].Target, 12, "its target")
    T:Eq(Read[3].Kind, "Load", "load")
    T:Eq(Read[3].Scene, 13, "its scene")
    T:Eq(Read[4].Kind, "Unload", "unload")
    T:Eq(Read[4].Instance, 14, "its copy")
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

-- An object with a part the server builds and a link onto it, in the default
-- scene. The client previews a drag on it and checks its own view of the part
-- follows, which it used to for drawn and local parts only.
Objects.new(ShownId, {[TitleId] = "FixtureDragged"})

-- Held by the server itself for the whole run, under a holder that is not a
-- person. The client checks it refuses an edit to it on the spot rather than
-- showing the edit and snapping back when the server says no.
const HeldFixture = Objects.new(BareId, {[TitleId] = "FixtureHeld"})
Objects:Lock({HeldFixture}, "FixtureAnimator")

-- An object holding an option of TestShapes, which the client registers only
-- partway through its run. It checks the value arrives as a pending option --
-- the enum's name and the id, no Value -- rather than as the default, and turns
-- into Square once it registers the enum.
const ShapedType = Objects:Register({Name = "FixtureShapedType", Properties = {TitleId, ShapeId}}) :: number
Objects.new(ShapedType, {[TitleId] = "FixtureShaped", [ShapeId] = Shapes:GetById(2)})

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
ReferenceButton:Set(TitleId, "FixtureRefButton")
ReferenceButton:Set(TargetId, ReferenceDoor)

-- Two private scenes, each admitting only user id 1, which nobody running this
-- is, and each holding one object that replicates to everyone and one kept for
-- the admitted. The test player never gets into the first, and the client
-- checks it is sent the first object and neither the second nor the scene's
-- name. The player is admitted to the second as they arrive, and evicted from
-- it when the client writes the evict marker on the editable fixture.
const HiddenCopy = Scenes.new({Name = "FixtureHidden", Private = true, Admitted = {1}}):Load()
HiddenCopy:Create(BareId, {[TitleId] = "FixtureHiddenScenery"})
HiddenCopy:Create(PrivateId, {[TitleId] = "FixtureHiddenPrivate"})

const AdmittedScene = Scenes.new({Name = "FixtureAdmitted", Private = true, Admitted = {1}})
const AdmittedCopy = AdmittedScene:Load()
AdmittedCopy:Create(BareId, {[TitleId] = "FixtureAdmitScenery"})
AdmittedCopy:Create(PrivateId, {[TitleId] = "FixtureAdmitPrivate"})

-- A copy the server opened rather than loaded, holding an object whose template
-- replicates. The server builds no part for it; the test player, admitted as
-- they arrive, draws one.
-- Private and admitting nobody at all, the state a level editor starts in.
-- Every other private fixture admits user id 1, and an empty list used to read
-- as public: this one was sent whole to every player and editable by anyone
-- with rights on it. The test player is granted rights here as they arrive and
-- never admitted, so the client checks it gets the scenery and nothing else,
-- and that its edit to the scenery is refused.
const ClosedScene = Scenes.new({Name = "FixtureClosed", Private = true})
const ClosedCopy = ClosedScene:Load()
ClosedCopy:Create(BareId, {[TitleId] = "FixtureClosedScenery"})
ClosedCopy:Create(PrivateId, {[TitleId] = "FixtureClosedPrivate"})
ClosedScene:Open():Create(ShownId, {[TitleId] = "FixtureClosedOpened"})

const OpenedScene = Scenes.new({Name = "FixtureOpened", Private = true, Admitted = {1}})
OpenedScene:Open():Create(ShownId, {[TitleId] = "FixtureOpenedObject"})

-- An opened copy the test player is never admitted to. Its object is created
-- when the client writes the opened marker, after the player has joined: an
-- object already there at join goes down the replay, which always checked, and
-- it was a live create that used to reach every player in the server. A
-- control object follows it into the default scene, so the client knows when
-- the hidden one would have arrived.
const OpenedHiddenCopy = Scenes.new({Name = "FixtureOpenedHidden", Private = true, Admitted = {1}}):Open()

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
    ClosedScene:Grant(Plr, "TestBuilder")
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

    if Value == "OpenedPulse" then
        OpenedHiddenCopy:Create(ShownId, {[TitleId] = "FixtureOpenedLeak"})
        Objects.new(BareId, {[TitleId] = "FixtureOpenedControl"})
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
        {Id = 1, Scenes = {}, Title} :: any,
    })

    const _, Back = Compressor:DecompressMetadatas(Encoding.Decode(Encoding.Encode(Packed)))
    T:Eq(#Back, 1, "record count")
    T:Eq(Back[1][1].Value, "Encoded", "value")
end)

--=============================================================================
-- Database (opt in: writes real DataStore and MemoryStore keys)
--=============================================================================

if RUN_DATABASE then
    -- Removes everything a run of these tests leaves under one key: the
    -- manifest and every shard it counts. Run before the section as well as
    -- after it, so a run that stopped partway does not leave the next one
    -- walking its shards. The records used to pile up across runs instead,
    -- and the paging test slowed with every run until it took half a minute.
    const function Wipe(Key: string): boolean
        const Store = game:GetService("DataStoreService"):GetDataStore(Key)
        const Read, Manifest = Try(5, Store.GetAsync, Store, "Manifest")
        if not Read then
            return false
        end

        const Count = if type(Manifest) == "table" then (Manifest.Count or 1) else 1
        local Clean = true
        for Index = 1, Count do
            if not Try(5, Store.RemoveAsync, Store, `{Key}:{Index}`) then
                Clean = false
            end
        end

        return Try(5, Store.RemoveAsync, Store, "Manifest") and Clean
    end

    T:Describe("Database")

    const Title = Properties.new(TitleId)
    Title:Set("New Level")

    const Plays = Properties.new(PlaysId)
    Plays:Set(0)

    T:Test("starts from empty stores", function()
        T:Ok(Wipe(DATABASE_KEY), "the main key")
        T:Ok(Wipe(`{DATABASE_KEY}Burst`), "and the burst key")
    end)

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
                -- Annotated: the default solver types a mixed literal by its
                -- first value and then refuses the number.
                const Changes: {[number]: any} = {[TitleId] = `Level {Index}`, [PlaysId] = Index * 10}
                db:Edit(Id, Changes)
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

    -- Creates that run at once, on one server, against a tail that seals every
    -- couple of records. Each used to read the same tail from the manifest and
    -- append to it after another had sealed it, leaving records past the
    -- boundary readers look them up by: thirty at once left eighteen of them
    -- unreachable by id. Its own key, so a burst does not reshape the shards
    -- the tests above and below walk.
    T:Test("creates at once all land where they can be found", function()
        const Burst = Prism.Database.new({
            Key = `{DATABASE_KEY}Burst`,
            InitialMetadata = {Title, Plays},
            ShardLimit = 120,
            Expiration = 1,
        })

        const Ids = {}
        local Pending = 20
        for _ = 1, 20 do
            task.spawn(function()
                const Ok, Id = Burst:Create()
                if Ok and Id then
                    table.insert(Ids, Id)
                end

                Pending -= 1
            end)
        end

        T:Eventually(function()
            return Pending == 0
        end, 120, "every create finished", 0.5)

        T:Eq(#Ids, 20, "every create succeeded")

        const Seen = {}
        for _, Id in Ids do
            T:Ok(not Seen[Id], `id {Id} handed out once`)
            Seen[Id] = true
        end

        Burst:Refresh()
        for _, Id in Ids do
            const Record = Burst:GetById(Id)
            T:Ok(Record and Record.Id == Id, `id {Id} found by id`)
        end
    end)

    T:Test("id ordered paging walks in both directions", function()
        db:Refresh()

        const Newest = db:Get("Newest", 1)
        T:Eq(#Newest.Records, 3, "page size respected")
        T:Ok(Newest.HasMore, "more pages exist")
        T:Eq(Newest.Records[1].Id, Created[8], "newest first")

        -- The store was wiped first, so this run's first record is the oldest.
        const Oldest = db:Get("Oldest", 1)
        T:Eq(Oldest.Records[1].Id, Created[1], "oldest first")
        T:Ok(Oldest.Records[1].Id < Oldest.Records[2].Id, "ascending")
    end)

    T:Test("paging reaches the end cleanly", function()
        db:Refresh()

        const Seen = {}
        local Page = 1

        while Page < 200 do
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

        -- Earlier runs' records page too, so this checks the ones it made.
        for _, Id in Created do
            T:Ok(Seen[Id], `id {Id} paged`)
        end
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

        -- Done here rather than in a test of its own: the next one deletes a
        -- record and checks the counter, and every write costs a request.
        const Room = Scenes.new({Name = "TestLinkedRoom"}) :: any
        const Hall = Scenes.new({Name = "TestLinkedHall"}) :: any

        T:Ok(db:Link(Created[2], Room.Guid), "linked")
        T:Ok(db:Link(Created[2], Hall.Guid), "a second scene linked")
        T:Ok(db:Link(Created[2], Room.Guid), "linking one already there is fine")
        db:Refresh()

        const Linked = db:GetById(Created[2])
        T:Eq(Linked and #Linked.Scenes, 2, "both, once each")
        T:Eq(Linked and Linked.Scenes[1], Room.Guid, "in link order")
        T:Throws(function()
            table.insert((Linked :: any).Scenes, "x")
        end, "and frozen like the rest of a record")

        T:Ok(db:Unlink(Created[2], Room.Guid), "unlinked")
        T:Ok(not db:Unlink(Created[2], Room.Guid), "unlinking one not there fails")
        T:Ok(not db:Link(Created[2], "Level 1"), "a string that is not a Guid is refused")
        T:Ok(not db:Link(999999, Room.Guid), "linking to a missing id fails")
        db:Refresh()

        const After = db:GetById(Created[2])
        T:Eq(After and #After.Scenes, 1, "one left")
        T:Eq(After and After.Scenes[1], Hall.Guid, "the other one")

        Room:Destroy()
        Hall:Destroy()

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
        T:Ok(Wipe(DATABASE_KEY), "the main key")
        T:Ok(Wipe(`{DATABASE_KEY}Burst`), "and the burst key")
    end)
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

print("[ PRISM TEST ] Client fixtures are ready; the client half runs on its own.")
