--!strict
-- LEB128 variable length integers.
--
-- Ids, lengths and counts are overwhelmingly small, and paying a fixed u16 or
-- u32 for every one of them is most of the overhead in a record. A varint costs
-- one byte below 128, two below 16384, and grows only as the value does.
--
-- Everything here is bounded by 2^53, the largest integer a Lua number holds
-- exactly. Past that a double starts skipping values, so a wider encoding would
-- store bytes that cannot be read back into a usable number.

const Logger = require("./Logger")

const Varint = {}

const MAX_BYTES = 8
const MAX_SAFE = 9007199254740991 -- 2^53 - 1

-- Zigzag doubles the magnitude to make room for the sign bit, so signed values
-- are bounded by half the unsigned range.
const MAX_SIGNED = 4503599627370495 -- 2^52 - 1

Varint.MAX_SAFE = MAX_SAFE
Varint.MAX_SIGNED = MAX_SIGNED

function Varint.Measure(Value: number): number
    local Remaining = Value
    local Count = 1

    while Remaining >= 128 do
        Remaining = math.floor(Remaining / 128)
        Count += 1
    end

    return Count
end

function Varint.Write(Buf: buffer, Offset: number, Value: number): number
    if Value < 0 or Value > MAX_SAFE or Value % 1 ~= 0 then
        Logger:Error(`Varint expects a whole number between 0 and {MAX_SAFE}, got {Value}.`)
    end

    local Remaining = Value
    local Written = 0

    while Remaining >= 128 do
        buffer.writeu8(Buf, Offset + Written, (Remaining % 128) + 128)
        Remaining = math.floor(Remaining / 128)
        Written += 1
    end

    buffer.writeu8(Buf, Offset + Written, Remaining)
    return Written + 1
end

function Varint.Read(Buf: buffer, Offset: number): (number, number)
    local Value = 0
    local Scale = 1
    local Read = 0

    while true do
        const Byte = buffer.readu8(Buf, Offset + Read)
        Read += 1

        Value += (Byte % 128) * Scale
        if Byte < 128 then
            break
        end

        Scale *= 128
        if Read >= MAX_BYTES then
            Logger:Error(`Malformed varint at offset {Offset}: no terminator within {MAX_BYTES} bytes.`)
        end
    end

    return Value, Read
end

-- Maps signed to unsigned so that small negatives stay small: 0, -1, 1, -2, 2
-- become 0, 1, 2, 3, 4. Without this, -1 would encode as the maximum value and
-- cost the full eight bytes.
function Varint.Zigzag(Value: number): number
    return if Value < 0 then -2 * Value - 1 else 2 * Value
end

function Varint.Unzigzag(Value: number): number
    return if Value % 2 == 1 then -(Value + 1) / 2 else Value / 2
end

function Varint.MeasureSigned(Value: number): number
    return Varint.Measure(Varint.Zigzag(Value))
end

function Varint.WriteSigned(Buf: buffer, Offset: number, Value: number): number
    if Value < -MAX_SIGNED - 1 or Value > MAX_SIGNED then
        Logger:Error(`Signed varint expects a value within +/-{MAX_SIGNED}, got {Value}.`)
    end

    return Varint.Write(Buf, Offset, Varint.Zigzag(Value))
end

function Varint.ReadSigned(Buf: buffer, Offset: number): (number, number)
    const Value, Read = Varint.Read(Buf, Offset)
    return Varint.Unzigzag(Value), Read
end

return Varint
