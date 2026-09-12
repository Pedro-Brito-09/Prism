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
-- Not synced into Studio: default.project.json maps the two suites and the
-- harness by name, and this is deliberately not among them.

local Varint = require("../src/Varint")
local Handles = require("../src/Handles")
local IdPool = require("../src/IdPool")

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

print(`{checks - failures}/{checks} checks passed`)
if failures > 0 then
    error(`{failures} failures`, 0)
end
