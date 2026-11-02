--!strict
-- The part of the suite that runs without Roblox.
--
-- Everything in tests/Server.server.luau and tests/Client.client.luau needs a
-- DataModel, players and replication, so it can only run in Studio. These
-- modules need none of that: Varint, Handles and IdPool are plain Luau over
-- buffers and numbers. They are also the floor the storage format stands on --
-- every id, length and count in a pack is a varint, every saved object is
-- addressed by a persistent id, and every registry id comes out of a pool --
-- so they are the last place a fault should go unnoticed until someone plays
-- the game.
--
-- Run with scripts/test-pure.sh, which CI also runs.
--
-- Not in Studio: scripts/build.js puts the two suites and the harness in
-- PrismTests.rbxmx, and this is deliberately not among them.

local Varint = require("../src/Varint")
local Handles = require("../src/Handles")
local IdPool = require("../src/IdPool")
local Room = require("../src/Room")
local Codecs = require("../src/Codecs")
local PermissionsShared = require("../src/Permissions/Shared")
local PropertiesShared = require("../src/Properties/Shared")
local PropertyTypes = require("../src/Properties/Types")
local Try = require("../src/Try")
local CustomEnum = require("../src/CustomEnum")

local failures = 0
local checks = 0
local function ok(condition: boolean, what: string)
    checks += 1
    if not condition then
        failures += 1
        print("FAIL: " .. what)
    end
end

-- Varint round trip, including every byte-length boundary the README names.
local values = {
    0, 1, 2, 126, 127, 128, 129, 255, 256, 16383, 16384, 16385,
    2097151, 2097152, 268435455, 268435456, 4294967295, 4294967296,
    2 ^ 40, 2 ^ 52, 2 ^ 53 - 1,
}

for _, v in values do
    local measured = Varint.Measure(v)
    local buf = buffer.create(measured + 8)
    local written = Varint.Write(buf, 0, v)
    ok(written == measured, `Measure({v}) = {measured} but Write returned {written}`)

    local got, read = Varint.Read(buf, 0)
    ok(got == v, `Read after Write({v}) gave {got}`)
    ok(read == written, `Read({v}) consumed {read}, Write produced {written}`)
end

-- The one-byte-below-128, two-below-16384 claim the README makes.
ok(Varint.Measure(127) == 1, "127 should be one byte")
ok(Varint.Measure(128) == 2, "128 should be two bytes")
ok(Varint.Measure(16383) == 2, "16383 should be two bytes")
ok(Varint.Measure(16384) == 3, "16384 should be three bytes")

-- Signed: zigzag both ways, and round trip through the buffer.
for _, v in {0, -1, 1, -2, 2, -127, 127, -128, 128, -65535, 65535, -(2 ^ 40), 2 ^ 40} do
    ok(Varint.Unzigzag(Varint.Zigzag(v)) == v, `zigzag round trip of {v}`)

    local measured = Varint.MeasureSigned(v)
    local buf = buffer.create(measured + 8)
    local written = Varint.WriteSigned(buf, 0, v)
    ok(written == measured, `MeasureSigned({v}) = {measured} but wrote {written}`)

    local got, read = Varint.ReadSigned(buf, 0)
    ok(got == v, `ReadSigned after WriteSigned({v}) gave {got}`)
    ok(read == written, `ReadSigned({v}) consumed {read} of {written}`)
end

-- Writing at a non-zero offset must not disturb what is already there.
do
    local buf = buffer.create(32)
    buffer.writeu8(buf, 0, 0xAB)
    local written = Varint.Write(buf, 1, 300)
    ok(buffer.readu8(buf, 0) == 0xAB, "Write at offset 1 clobbered byte 0")
    local got = Varint.Read(buf, 1)
    ok(got == 300, "Read at offset 1 gave " .. tostring(got))
    ok(written == Varint.Measure(300), "offset write length")
end

-- Handles: the README's PersistentId = SceneId * 2^32 + LocalId, and 48 bits
-- staying exact inside the 53 a Luau number holds.
for _, pair in {{1, 1}, {1, 4294967295}, {65535, 1}, {65535, 4294967295}, {4096, 123456}} do
    local scene, id = pair[1], pair[2]
    local joined = Handles.Join(scene, id)
    local gotScene, gotLocal = Handles.Split(joined)
    ok(gotScene == scene, `Split(Join({scene},{id})) scene gave {gotScene}`)
    ok(gotLocal == id, `Split(Join({scene},{id})) local gave {gotLocal}`)
    ok(Handles.Scene(joined) == scene, `Scene(Join({scene},{id}))`)
    ok(Handles.Local(joined) == id, `Local(Join({scene},{id}))`)
    ok(joined == scene * 2 ^ 32 + id, `Join({scene},{id}) is not Scene*2^32+Local`)
end

-- An address: a reference into another scene. Both halves come back, and only
-- what Address itself would write is one, since a second spelling of the same
-- target would read as a change of target.
do
    local guid = "abcdefghij-_0123456789"
    ok(Handles.IsGuid(guid), "the guid under test should be one")

    for _, id in {1, 127, 70000, Handles.MAX_LOCAL} do
        local address = Handles.Address(guid, id)
        local gotGuid, gotLocal = Handles.ParseAddress(address)
        ok(gotGuid == guid, `ParseAddress({address}) guid gave {gotGuid}`)
        ok(gotLocal == id, `ParseAddress({address}) local gave {gotLocal}`)
        ok(PropertyTypes:IsValid("Object", address), `{address} should be a valid Object value`)
    end

    for _, bad in {
        guid,
        `{guid}:`,
        `{guid}:0`,
        `{guid}:007`,
        `{guid}:1.5`,
        `{guid}:-1`,
        `{guid}:{Handles.MAX_LOCAL + 1}`,
        `{guid}:1:2`,
        `short:1`,
        `:1`,
        "",
    } do
        ok(Handles.ParseAddress(bad) == nil, `ParseAddress should refuse "{bad}"`)
        ok(not PropertyTypes:IsValid("Object", bad), `"{bad}" should not be a valid Object value`)
    end

    -- Through inserts: a slash each, in order from the outermost.
    for _, path in {{3}, {3, 12}, {1, 2, 4}} do
        local address = Handles.Address(guid, 9, path)
        local gotGuid, gotLocal, gotPath = Handles.ParseAddress(address)
        ok(gotGuid == guid and gotLocal == 9, `ParseAddress({address}) lost its ends`)
        ok(gotPath ~= nil and #gotPath == #path, `ParseAddress({address}) path length`)
        for index, id in path do
            ok(gotPath ~= nil and gotPath[index] == id, `ParseAddress({address}) path item {index}`)
        end
        ok(PropertyTypes:IsValid("Object", address), `{address} should be a valid Object value`)
    end

    local _, _, noPath = Handles.ParseAddress(Handles.Address(guid, 9))
    ok(noPath == nil, "an address with no inserts has no path")

    for _, bad in {`{guid}/:1`, `{guid}//2:1`, `{guid}/2/:1`, `{guid}/02:1`, `{guid}2:1`} do
        ok(Handles.ParseAddress(bad) == nil, `ParseAddress should refuse "{bad}"`)
    end

    ok(Handles.ParseAddress(4) == nil, "a number is not an address")
    ok(PropertyTypes:IsValid("Object", 4), "a local id is still a valid Object value")
end


-- A map that empties out is copied, keeping what is live and its weak mode, and
-- only once it is down to a quarter of the most it held.
do
    -- Held here too, or the collector could take them out of the weak map.
    local held = {}
    local map = Room.new("v")
    for id = 1, 2000 do
        held[id] = {}
        Room.Put(map, id, held[id])
    end
    Room.Put(map, 1, map[1])

    local live, peak = Room.CountOf(map)
    ok(live == 2000 and peak == 2000, `writing a key twice counted it twice: {live}, {peak}`)

    local kept = map
    for id = 1, 1499 do
        kept = Room.Take(kept, id)
    end
    ok(kept == map, "the map was copied before it was down to a quarter")

    kept = Room.Take(kept, 1500)
    ok(kept ~= map, "the map was not copied at a quarter of its peak")
    ok(getmetatable(kept).__mode == "v", "the copy lost the map's weak mode")

    local count, stray = 0, nil
    for id, value in kept do
        count += 1
        if id <= 1500 or value ~= held[id] then
            stray = id
        end
    end
    ok(stray == nil, `the copy holds {stray}, which is not live`)
    ok(count == 500, `the copy holds {count} entries, not the 500 live`)
    ok(Room.Take(kept, 999999) == kept, "taking a missing key changed the map")

    local small = Room.new()
    for id = 1, 100 do
        Room.Put(small, id, true)
    end
    for id = 1, 100 do
        small = Room.Take(small, id)
    end
    ok(Room.CountOf(small) == 0, "a small map's count did not reach zero")
end

-- The point of it: a map filled the way a level fills the workspace, by runtime
-- ids that only climb, and emptied by an unload gives its room back where a
-- plain table keeps it.
do
    -- The heap once the collector has been through it: garbage until a cycle
    -- finishes, a few times over, and the lowest reading.
    local function settled(): number
        local low = math.huge
        for _ = 1, 4 do
            local peak = gcinfo()
            local junk = {}
            for _ = 1, 200 do
                for i = 1, 500 do
                    junk[i] = table.create(16, 0)
                end
                local now = gcinfo()
                if now < peak - 256 then
                    break
                end
                peak = math.max(peak, now)
            end
            junk = nil
            low = math.min(low, gcinfo())
        end
        return low
    end

    local function heldAfterEmptying(useRoom: boolean): number
        local before = settled()
        local map = if useRoom then Room.new() else {}
        for id = 100001, 135000 do
            if useRoom then
                Room.Put(map, id, true)
            else
                map[id] = true
            end
        end
        for id = 100001, 135000 do
            if useRoom then
                map = Room.Take(map, id)
            else
                map[id] = nil
            end
        end
        local held = settled() - before
        ok(next(map) == nil, "the map was not empty")
        return held
    end

    local plain = heldAfterEmptying(false)
    local room = heldAfterEmptying(true)
    ok(plain > 512, `a plain table kept only {plain} KB, so this proves nothing`)
    -- Against the plain table rather than zero: the heap is read by settling it,
    -- which is good to a hundred KB or so.
    ok(room < plain / 4, `an emptied map still held {room} KB, against {plain} KB for a plain table`)
end

-- Recycling pool: ids come back after release.
do
    local pool = IdPool.new(10, true)
    local a, b, c = pool:Claim(), pool:Claim(), pool:Claim()
    ok(a == 1 and b == 2 and c == 3, `first three ids were {a},{b},{c}`)
    ok(pool:IsUsed(2), "2 should be used")

    pool:Release(2)
    ok(not pool:IsUsed(2), "2 should be free after release")
    ok(pool:Claim() == 2, "a recycling pool should hand 2 back")
end

-- Non-recycling pool: a released id is never handed out again. This is the
-- property the whole storage format leans on for property, object and scene
-- ids, so it is worth asserting rather than assuming.
do
    local pool = IdPool.new(10, false)
    local a, b = pool:Claim(), pool:Claim()
    ok(a == 1 and b == 2, "first two ids")
    pool:Release(1)
    ok(not pool:IsUsed(1), "1 should not read as used once released")
    ok(pool:Claim() == 3, "a non-recycling pool must not reissue 1")
    pool:Release(3)
    ok(pool:Claim() == 4, "still climbing after a second release")
end

-- Releasing something never claimed, or twice, must not corrupt the pool.
do
    local pool = IdPool.new(10, true)
    pool:Release(7)
    ok(pool:Claim() == 1, "releasing an unclaimed id must not seed the free set")
    pool:Release(1)
    pool:Release(1)
    local first = pool:Claim()
    local second = pool:Claim()
    ok(first == 1 and second == 2, `double release gave {first} then {second}`)
end

-- Exhaustion: the pool refuses rather than handing out something the wire
-- cannot carry. Logger:Error throws, so this is a pcall.
do
    local pool = IdPool.new(2, false)
    pool:Claim()
    pool:Claim()
    local fine = pcall(function() return pool:Claim() end)
    ok(not fine, "a pool at its max should refuse to claim")
end

-- The default max is the u16 the network layer addresses property ids with.
do
    local pool = IdPool.new()
    ok(pool.Max == 65535, `default max was {pool.Max}`)
    ok(pool.Recycle == true, "Recycle should default to true")
    ok(IdPool.new(10, false).Recycle == false, "Recycle false should stick")
end


-- Codecs: every one that does not need a Roblox type. Vector, Color, CFrame,
-- Instance and Player are left to the Studio suite, which has them.
local function roundTrip(name: string, codec: any, value: any, eq: ((any, any) -> boolean)?)
    local extras = {}
    local measured = codec.Measure(value)
    local buf = buffer.create(measured + 16)
    local written = codec.Write(buf, 0, value, extras)
    ok(written == measured, `{name}: Measure said {measured}, Write wrote {written}`)

    local got, read = codec.Read(buf, 0, extras)
    local same = if eq then eq(got, value) else got == value
    ok(same, `{name}: wrote {tostring(value)}, read back {tostring(got)}`)
    ok(read == written, `{name}: Read consumed {read}, Write produced {written}`)
end

-- A colour channel becomes the nearest byte, clamped. Flooring made 0.5 come
-- back a step short, and a channel past 1 wrapped round to a dark one.
ok(Codecs.ColorByte(0.5) == 128, `0.5 -> {Codecs.ColorByte(0.5)}`)
ok(Codecs.ColorByte(1) == 255 and Codecs.ColorByte(0) == 0, "the ends")
ok(Codecs.ColorByte(1.5) == 255, `1.5 clamps, got {Codecs.ColorByte(1.5)}`)
ok(Codecs.ColorByte(-0.2) == 0, `below zero clamps, got {Codecs.ColorByte(-0.2)}`)
for Byte = 0, 255 do
    ok(Codecs.ColorByte(Byte / 255) == Byte, `byte {Byte} survives`)
end

roundTrip("u8 min", Codecs.u8, 0); roundTrip("u8 max", Codecs.u8, 255)
roundTrip("u16 max", Codecs.u16, 65535)
roundTrip("u32 max", Codecs.u32, 4294967295)
roundTrip("i8 min", Codecs.i8, -128); roundTrip("i8 max", Codecs.i8, 127)
roundTrip("i16 min", Codecs.i16, -32768)
roundTrip("i32 min", Codecs.i32, -2147483648)
roundTrip("i32 max", Codecs.i32, 2147483647)
roundTrip("f32", Codecs.f32, 1.5)
roundTrip("f32 neg", Codecs.f32, -0.25)
roundTrip("f64 pi", Codecs.f64, 3.14159265358979)
roundTrip("f64 big", Codecs.f64, 1e300)
roundTrip("Varint 0", Codecs.Varint, 0)
roundTrip("Varint 127", Codecs.Varint, 127)
roundTrip("Varint 128", Codecs.Varint, 128)
roundTrip("Varint big", Codecs.Varint, 2 ^ 53 - 1)
roundTrip("SignedVarint neg", Codecs.SignedVarint, -1099511627776)
roundTrip("SignedVarint pos", Codecs.SignedVarint, 1099511627776)
roundTrip("Bool true", Codecs.Bool, true)
roundTrip("Bool false", Codecs.Bool, false)
roundTrip("String empty", Codecs.String, "")
roundTrip("String ascii", Codecs.String, "hello world")
roundTrip("String utf8", Codecs.String, "caf\u{00E9} \u{2014} \u{1F600}")
roundTrip("String 1000", Codecs.String, string.rep("x", 1000))
roundTrip("String 65535", Codecs.String, string.rep("y", 65535))
roundTrip("LongString", Codecs.LongString, string.rep("z", 70000))

local function bufEq(a, b)
    if buffer.len(a) ~= buffer.len(b) then return false end
    return buffer.tostring(a) == buffer.tostring(b)
end
roundTrip("Buffer", Codecs.Buffer, buffer.fromstring("some bytes \0 with a nul"), bufEq)
roundTrip("Buffer empty", Codecs.Buffer, buffer.create(0), bufEq)

local OptU8 = Codecs.Optional(Codecs.u8)
roundTrip("Optional nil", OptU8, nil)
roundTrip("Optional value", OptU8, 42)
roundTrip("Optional zero", OptU8, 0)

local function arrEq(a: {any}, b: {any})
    if #a ~= #b then return false end
    for i, v in b do if a[i] ~= v then return false end end
    return true
end
local ArrU16 = Codecs.Array(Codecs.u16)
roundTrip("Array empty", ArrU16, {}, arrEq)
roundTrip("Array three", ArrU16, {1, 2, 65535}, arrEq)
roundTrip("Array strings", Codecs.Array(Codecs.String), {"a", "", "ccc"}, arrEq)
roundTrip("Array of arrays", Codecs.Array(ArrU16), {{1}, {}, {2, 3}}, function(a, b)
    if #a ~= #b then return false end
    for i, v in b do if not arrEq(a[i], v) then return false end end
    return true
end)

-- A String over the u16 length field must be refused, not wrapped: the comment
-- on the codec says so and it is the difference between an error and silently
-- decoding as a different string.
do
    local fine = pcall(function()
        local v = string.rep("q", 65536)
        local b = buffer.create(70000)
        Codecs.String.Write(b, 0, v, {})
    end)
    ok(not fine, "String should refuse more than 65535 bytes")
end


-- Permissions: which verbs, object types and properties a set of scene rights
-- lets through. Pure table work, and the place a mistake is a hole rather than
-- a glitch, so the lists are checked in both directions.
local Crate, Enemy, Door = 1, 2, 3
local Tint, Health = 10, 11
local function rights(cfg) return PermissionsShared.SceneRights(cfg, "Test") end

-- No grant means nothing, and an unrecognised verb denies rather than falling
-- through to the allow path.
do
    local none = rights(nil)
    ok(not PermissionsShared.Allows(none, "Create", Crate), "no config should deny Create")
    ok(not PermissionsShared.Allows(none, "Edit", Crate), "no config should deny Edit")
    local all = rights({CanCreate = true, CanEdit = true, CanDestroy = true})
    ok(not PermissionsShared.Allows(all, "Publish", Crate), "an unknown verb must deny")
    ok(not PermissionsShared.Allows(all, "", Crate), "an empty verb must deny")
    ok(PermissionsShared.Allows(all, "Create", Crate), "granted Create should allow")
end

-- An absent whitelist constrains nothing; a present one is exhaustive.
do
    local open = rights({CanEdit = true})
    ok(PermissionsShared.Allows(open, "Edit", Crate), "absent object whitelist allows Crate")
    ok(PermissionsShared.Allows(open, "Edit", Enemy), "absent object whitelist allows Enemy")

    local only = rights({CanEdit = true, Objects = {Whitelist = {Crate}}})
    ok(PermissionsShared.Allows(only, "Edit", Crate), "whitelisted type allowed")
    ok(not PermissionsShared.Allows(only, "Edit", Enemy), "whitelist must be exhaustive")

    local banned = rights({CanEdit = true, Objects = {Blacklist = {Enemy}}})
    ok(PermissionsShared.Allows(banned, "Edit", Crate), "unlisted type still allowed")
    ok(not PermissionsShared.Allows(banned, "Edit", Enemy), "blacklisted type denied")

    -- Blacklist beats whitelist: naming a type in both must deny.
    local both = rights({CanEdit = true, Objects = {Whitelist = {Crate}, Blacklist = {Crate}}})
    ok(not PermissionsShared.Allows(both, "Edit", Crate), "blacklist must win over whitelist")
end

-- Property lists govern writing only, and take either a plain id or the
-- [Property] = {ObjectType} form that limits an entry to those types.
do
    local plain = rights({CanEdit = true, Properties = {Blacklist = {Tint}}})
    ok(not PermissionsShared.Allows(plain, "Edit", Crate, Tint), "blacklisted property denied")
    ok(PermissionsShared.Allows(plain, "Edit", Crate, Health), "other property still allowed")

    local scoped = rights({CanEdit = true, Properties = {Blacklist = {[Tint] = {Crate}}}})
    ok(not PermissionsShared.Allows(scoped, "Edit", Crate, Tint), "Tint on a Crate denied")
    ok(PermissionsShared.Allows(scoped, "Edit", Door, Tint), "Tint on a Door still allowed")

    local wl = rights({CanEdit = true, Properties = {Whitelist = {Health}}})
    ok(PermissionsShared.Allows(wl, "Edit", Crate, Health), "whitelisted property allowed")
    ok(not PermissionsShared.Allows(wl, "Edit", Crate, Tint), "property whitelist is exhaustive")

    local wlScoped = rights({CanEdit = true, Properties = {Whitelist = {[Tint] = {Crate}}}})
    ok(PermissionsShared.Allows(wlScoped, "Edit", Crate, Tint), "scoped whitelist allows its type")
    ok(not PermissionsShared.Allows(wlScoped, "Edit", Door, Tint), "scoped whitelist denies other types")
end

-- A destroy writes no property, so the property lists say nothing about one.
do
    local r = rights({CanDestroy = true, CanEdit = true, Properties = {Blacklist = {Tint}}})
    ok(PermissionsShared.Allows(r, "Destroy", Crate, Tint), "a destroy ignores the property lists")
    ok(not PermissionsShared.Allows(r, "Edit", Crate, Tint), "an edit does not")
end

-- A verb the role lacks is denied whatever the lists say.
do
    local r = rights({CanEdit = true, Objects = {Whitelist = {Crate}}})
    ok(not PermissionsShared.Allows(r, "Create", Crate), "Create is not granted by CanEdit")
    ok(not PermissionsShared.Allows(r, "Destroy", Crate), "Destroy is not granted by CanEdit")
end

-- The ungranted default: 60 actions a second, a ceiling rather than a right.
ok(PermissionsShared.DEFAULT_RATE == 60, `default rate was {PermissionsShared.DEFAULT_RATE}`)

-- Properties: how a registry becomes a property panel.
-- Built the way registration builds one: PropertiesShared.Display fills every field in,
-- so a partial Display never reaches Layout. The server normalises at Register
-- and the client stores the payload that was normalised before it was sent.
local function reg(t: {[number]: any}): {[number]: any}
    local out: {[number]: any} = {}
    for id, d in t do
        out[id] = {Id = id, Name = d.Name, Display = PropertiesShared.Display(d.Display, d.Name)}
    end
    return out
end

local R = reg({
    [1] = {Name = "Speed", Display = {Category = "Motion", Order = 2}},
    [2] = {Name = "Drag", Display = {Category = "Motion", Order = 1}},
    [3] = {Name = "Tint", Display = {Category = "Look", Order = 5}},
    [4] = {Name = "Secret", Display = {Category = "Look", Order = 6, Hidden = true}},
    [5] = {Name = "Plain"},
})

-- Grouped by category, sorted by Order within one.
do
    local s = PropertiesShared.Layout(R, {1, 2, 3})
    ok(#s == 2, `expected two sections, got {#s}`)
    ok(s[1].Properties[1].Name == "Drag", `Motion first was {s[1].Properties[1].Name}`)
    ok(s[1].Properties[2].Name == "Speed", `Motion second was {s[1].Properties[2].Name}`)
end

-- A category's place follows the lowest Order in it, not where it was first
-- mentioned: the sort runs across every entry before anything is grouped.
do
    local s = PropertiesShared.Layout(R, {3, 1, 2})
    ok(s[1].Category == "Motion", `lowest Order should lead, got {s[1].Category}`)
    ok(s[2].Category == "Look", `second section was {s[2].Category}`)

    local first = PropertiesShared.Layout(reg({
        [1] = {Name = "Late", Display = {Category = "Z", Order = 0}},
        [2] = {Name = "Early", Display = {Category = "A", Order = 9}},
    }), {2, 1})
    ok(first[1].Category == "Z", `Z holds Order 0 so it should lead, got {first[1].Category}`)
end

-- Hidden is left out unless asked for.
do
    local without = PropertiesShared.Layout(R, {3, 4})
    ok(#without == 1, `Hidden should leave one section, got {#without}`)
    ok(#without[1].Properties == 1, "Hidden should be left out")
    ok(without[1].Properties[1].Name == "Tint", "the visible one should remain")

    local with = PropertiesShared.Layout(R, {3, 4}, true)
    ok(#with[1].Properties == 2, "Hidden should be included when asked for")
end

-- No Display at all: Category defaults to General, Order to 0.
do
    local s = PropertiesShared.Layout(R, {5})
    ok(#s == 1 and s[1].Category == "General", `default category was {s[1].Category}`)
    ok(R[5].Display.Order == 0, "Order should default to 0")
    ok(R[5].Display.Hidden == false, "Hidden should default to false")
    ok(R[5].Display.ReadOnly == false, "ReadOnly should default to false")
end

-- Ties on Order keep the order the ids were given in, which is what "the order
-- the object type lists them in" means.
do
    local T = reg({
        [1] = {Name = "A", Display = {Category = "C", Order = 0}},
        [2] = {Name = "B", Display = {Category = "C", Order = 0}},
        [3] = {Name = "C", Display = {Category = "C", Order = 0}},
    })
    local forward = PropertiesShared.Layout(T, {1, 2, 3})[1].Properties
    ok(forward[1].Name == "A" and forward[3].Name == "C", "ties should keep the given order")

    local backward = PropertiesShared.Layout(T, {3, 2, 1})[1].Properties
    ok(backward[1].Name == "C" and backward[3].Name == "A", "ties should follow a reversed list too")
end

-- An id the registry does not hold is skipped rather than throwing.
do
    local s = PropertiesShared.Layout(R, {1, 999})
    ok(#s == 1 and #s[1].Properties == 1, "an unknown id should be skipped")
    ok(#PropertiesShared.Layout(R, {}) == 0, "an empty list gives no sections")
end

-- The wrong-type fallback (Display = 42, Order = "soon") is left to the Studio
-- suite: it reports through Logger:Warn, and warn is a Roblox global the Luau
-- CLI does not have.

-- Try: only the paths that never reach task.wait, which the Luau CLI has no
-- scheduler for. A first attempt that succeeds never waits, and neither does a
-- single attempt that fails.
do
    local calls = 0
    local okFlag, a, b = Try(3, function(x: number, y: number)
        calls += 1
        return x + y, "done"
    end, 2, 3)
    ok(okFlag == true, "a successful call should report true")
    ok(a == 5 and b == "done", `results came back as {tostring(a)}, {tostring(b)}`)
    ok(calls == 1, `a success should not retry, called {calls} times`)
end

-- The reason it uses table.pack rather than {pcall(...)}: trailing nils.
do
    local okFlag, first, second = Try(1, function()
        return 1, nil
    end)
    ok(okFlag == true, "should succeed")
    ok(first == 1 and second == nil, "a trailing nil should survive the round trip")
end

-- A failure with one attempt returns false and does not wait.
do
    local calls = 0
    local okFlag = Try(1, function()
        calls += 1
        error("no")
    end)
    ok(okFlag == false, "a failing call should report false")
    ok(calls == 1, `one attempt means one call, got {calls}`)
end

-- math.max(1, Attempts): zero or a negative still runs once rather than never.
do
    local calls = 0
    Try(0, function() calls += 1 end)
    ok(calls == 1, `Attempts = 0 should still run once, ran {calls}`)

    calls = 0
    Try(-5, function() calls += 1 end)
    ok(calls == 1, `a negative Attempts should still run once, ran {calls}`)
end

-- CustomEnum: options come back sorted by id however the table was written,
-- which is what keeps a pack byte identical between runs -- Options is built by
-- iterating a dictionary, and that order is not stable.
do
    local Material = CustomEnum:Register("TestMaterial", {
        Stone = 30,
        Wood = 10,
        Glass = 20,
    })
    ok(Material ~= nil, "Register should return the enum")
    assert(Material)

    ok(#Material.Options == 3, `expected three options, got {#Material.Options}`)
    ok(Material.Options[1].Id == 10, `first option id was {Material.Options[1].Id}`)
    ok(Material.Options[2].Id == 20, `second option id was {Material.Options[2].Id}`)
    ok(Material.Options[3].Id == 30, `third option id was {Material.Options[3].Id}`)
    ok(Material.Options[1].Value == "Wood", `lowest id should be Wood, got {Material.Options[1].Value}`)

    local glass = Material:GetById(20)
    ok(glass ~= nil and glass.Value == "Glass", "GetById should find Glass")
    local stone = Material:GetByValue("Stone")
    ok(stone ~= nil and stone.Id == 30, "GetByValue should find Stone")
    ok(Material.Options[1].Parent == "TestMaterial", "an option should name its enum")

    ok(CustomEnum:GetEnum("TestMaterial") == Material, "GetEnum should return the same table")
    ok(CustomEnum:GetEnum("NoSuchEnum") == nil, "an unregistered name gives nil")
end

-- The built-in Unknown, which a decoder falls back to for an option id that no
-- longer exists.
do
    ok(CustomEnum.UNKNOWN ~= nil, "UNKNOWN should exist")
    ok(CustomEnum.UNKNOWN.Value == "Unknown", `UNKNOWN.Value was {tostring(CustomEnum.UNKNOWN.Value)}`)
end

-- Table: a list of one item type, every item held to that type's constraints.
do
    local Numbers = {Of = "Number", Item = {MinValue = 0, MaxValue = 10, AllowDecimals = false}, MinItems = 1, MaxItems = 3}

    ok(PropertyTypes:IsValid("Table", {1, 2, 3}, Numbers), "a list of whole numbers in range should be valid")
    ok(not PropertyTypes:IsValid("Table", {}, Numbers), "a list shorter than MinItems should be refused")
    local wrong: any = {1}
    wrong[2] = "two"
    ok(not PropertyTypes:IsValid("Table", wrong, Numbers), "an item of the wrong type should be refused")
    local holed: any = {1}
    holed[3] = 3
    ok(not PropertyTypes:IsValid("Table", holed, Numbers), "a list with a hole should be refused")
    ok(not PropertyTypes:IsValid("Table", {1, Extra = 2} :: any, Numbers), "a list with a named field should be refused")
    ok(not PropertyTypes:IsValid("Table", {1, 2}, nil), "a Table with no constraints names no item type")
    ok(not PropertyTypes:IsValid("Table", {{1}}, {Of = "Table"}), "a Table of Tables should be refused")
    ok(not PropertyTypes:IsValid("Table", 5 :: any, Numbers), "a number is not a list")

    -- MaxItems cuts and each item is fixed as its own type would be.
    local fixed = PropertyTypes:FixValue("Table", {12, 4.6, -1, 7}, Numbers) :: {number}
    ok(fixed ~= nil and #fixed == 3, `MaxItems should cut to three, got {fixed and #fixed}`)
    ok(fixed[1] == 10 and fixed[2] == 5 and fixed[3] == 0, `items should be clamped and rounded, got {fixed[1]}, {fixed[2]}, {fixed[3]}`)
    ok(table.isfrozen(fixed), "a fixed list should be frozen")

    -- A frozen list nothing had to change comes back as the same table.
    local same: any = table.freeze({1, 2})
    ok(PropertyTypes:FixValue("Table", same, Numbers) :: any == same, "an untouched frozen list should come back as itself")

    -- Object items keep an Object property's bounds.
    local Refs = {Of = "Object"}
    ok(PropertyTypes:IsValid("Table", {0, 3, 9}, Refs), "whole local ids should be valid references")
    ok(not PropertyTypes:IsValid("Table", {1.5}, Refs), "a fractional id is not a reference")
    ok(not PropertyTypes:IsValid("Table", {-1}, Refs), "a negative id is not a reference")

    ok(PropertyTypes.HoldsReferences({Type = "Table", Constraints = Refs}), "a Table of Object holds references")
    ok(not PropertyTypes.HoldsReferences({Type = "Table", Constraints = Numbers}), "a Table of Number does not")
    ok(PropertyTypes.HoldsReferences({Type = "Object"}), "an Object property holds a reference")
end

-- Equals compares lists by their items, everything else as == does.
do
    ok(PropertyTypes:Equals("Table", {1, 2}, {1, 2}), "two lists with the same items should be equal")
    ok(not PropertyTypes:Equals("Table", {1, 2}, {2, 1}), "order should matter")
    ok(not PropertyTypes:Equals("Table", {1, 2}, {1, 2, 3}), "length should matter")
    ok(not PropertyTypes:Equals("Table", {1}, nil), "a list is not nil")
    ok(PropertyTypes:Equals("Number", 3, 3), "numbers compare as ==")
    ok(not PropertyTypes:Equals("Text", {} :: any, {} :: any), "only a Table compares by items")
end

-- A property set to an equal list is no change, and keeps the list it held.
do
    local Registry = {
        Id = 1,
        Name = "TestList",
        Type = "Table",
        Constraints = {Of = "Text"},
        DefaultValue = table.freeze({}),
    }

    local prop = PropertiesShared.new({[1] = Registry :: any}, 1)
    local accepted, changed = prop:Set({"a", "b"})
    ok(accepted and changed, "setting a new list should be a change")

    local held = prop.Value
    ok(table.isfrozen(held), "the held list should be frozen")

    accepted, changed = prop:Set({"a", "b"})
    ok(accepted and not changed, "setting an equal list should not be a change")
    ok(prop.Value == held, "an equal set should keep the list already held")

    local mixed: any = {"a"}
    mixed[2] = 1
    ok(not (prop:Set(mixed)), "a list with a wrong item should be refused")
end

print(`{checks - failures}/{checks} checks passed`)
if failures > 0 then
    error(`{failures} failures`, 0)
end
