--!strict
-- Binary codecs for the networking layer.
-- A codec measures, writes and reads a single value. Values that cannot live in a
-- buffer (Instances, arbitrary tables) are pushed into a side channel array and
-- referenced by index, so a packet is always one buffer plus an optional table.

const Varint = require("./Varint")
const Logger = require("./Logger")

export type Codec<T> = {
    Measure: (Value: T) -> number,
    Write: (Buf: buffer, Offset: number, Value: T, Extras: {any}) -> number,
    Read: (Buf: buffer, Offset: number, Extras: {any}) -> (T, number),
}

const Codecs = {}

const function Fixed<T>(Size: number, Writer: (buffer, number, T) -> (), Reader: (buffer, number) -> T): Codec<T>
    return {
        Measure = function(): number
            return Size
        end,

        Write = function(Buf: buffer, Offset: number, Value: T): number
            Writer(Buf, Offset, Value)
            return Size
        end,

        Read = function(Buf: buffer, Offset: number): (T, number)
            return Reader(Buf, Offset), Size
        end,
    }
end

Codecs.u8 = Fixed(1, buffer.writeu8, buffer.readu8)
Codecs.u16 = Fixed(2, buffer.writeu16, buffer.readu16)
Codecs.u32 = Fixed(4, buffer.writeu32, buffer.readu32)
Codecs.i8 = Fixed(1, buffer.writei8, buffer.readi8)
Codecs.i16 = Fixed(2, buffer.writei16, buffer.readi16)
Codecs.i32 = Fixed(4, buffer.writei32, buffer.readi32)
Codecs.f32 = Fixed(4, buffer.writef32, buffer.readf32)
Codecs.f64 = Fixed(8, buffer.writef64, buffer.readf64)

-- Same LEB128 the storage format uses, so ids and counts cost one byte on the
-- wire below 128 instead of a flat u16 or u32.
Codecs.Varint = {
    Measure = function(Value: number): number
        return Varint.Measure(Value)
    end,

    Write = function(Buf: buffer, Offset: number, Value: number): number
        return Varint.Write(Buf, Offset, Value)
    end,

    Read = function(Buf: buffer, Offset: number): (number, number)
        return Varint.Read(Buf, Offset)
    end,
} :: Codec<number>

Codecs.SignedVarint = {
    Measure = function(Value: number): number
        return Varint.MeasureSigned(Value)
    end,

    Write = function(Buf: buffer, Offset: number, Value: number): number
        return Varint.WriteSigned(Buf, Offset, Value)
    end,

    Read = function(Buf: buffer, Offset: number): (number, number)
        return Varint.ReadSigned(Buf, Offset)
    end,
} :: Codec<number>

Codecs.Bool = {
    Measure = function(): number
        return 1
    end,

    Write = function(Buf: buffer, Offset: number, Value: boolean): number
        buffer.writeu8(Buf, Offset, Value and 1 or 0)
        return 1
    end,

    Read = function(Buf: buffer, Offset: number): (boolean, number)
        return buffer.readu8(Buf, Offset) == 1, 1
    end,
} :: Codec<boolean>

-- Up to 65535 bytes. Use LongString past that.
Codecs.String = {
    Measure = function(Value: string): number
        return 2 + #Value
    end,

    Write = function(Buf: buffer, Offset: number, Value: string): number
        -- The length field is a u16, so anything longer wraps and decodes as a
        -- different string rather than failing.
        if #Value > 65535 then
            Logger:Error(`String codec takes at most 65535 bytes, got {#Value}. Use LongString.`)
        end

        buffer.writeu16(Buf, Offset, #Value)
        buffer.writestring(Buf, Offset + 2, Value)
        return 2 + #Value
    end,

    Read = function(Buf: buffer, Offset: number): (string, number)
        const Length = buffer.readu16(Buf, Offset)
        return buffer.readstring(Buf, Offset + 2, Length), 2 + Length
    end,
} :: Codec<string>

Codecs.LongString = {
    Measure = function(Value: string): number
        return 4 + #Value
    end,

    Write = function(Buf: buffer, Offset: number, Value: string): number
        buffer.writeu32(Buf, Offset, #Value)
        buffer.writestring(Buf, Offset + 4, Value)
        return 4 + #Value
    end,

    Read = function(Buf: buffer, Offset: number): (string, number)
        const Length = buffer.readu32(Buf, Offset)
        return buffer.readstring(Buf, Offset + 4, Length), 4 + Length
    end,
} :: Codec<string>

Codecs.Buffer = {
    Measure = function(Value: buffer): number
        return 4 + buffer.len(Value)
    end,

    Write = function(Buf: buffer, Offset: number, Value: buffer): number
        const Length = buffer.len(Value)
        buffer.writeu32(Buf, Offset, Length)
        buffer.copy(Buf, Offset + 4, Value, 0)
        return 4 + Length
    end,

    Read = function(Buf: buffer, Offset: number): (buffer, number)
        const Length = buffer.readu32(Buf, Offset)

        -- The length comes straight off the wire, so a client can declare four
        -- gigabytes and have the server try to allocate it before anything else
        -- runs. Bound it by what the packet actually carries first.
        if Length > buffer.len(Buf) - Offset - 4 then
            Logger:Error(`Buffer codec length {Length} overruns the packet.`)
        end

        const Slice = buffer.create(Length)
        buffer.copy(Slice, 0, Buf, Offset + 4, Length)
        return Slice, 4 + Length
    end,
} :: Codec<buffer>

Codecs.Vector = {
    Measure = function(): number
        return 12
    end,

    Write = function(Buf: buffer, Offset: number, Value: Vector3): number
        buffer.writef32(Buf, Offset, Value.X)
        buffer.writef32(Buf, Offset + 4, Value.Y)
        buffer.writef32(Buf, Offset + 8, Value.Z)
        return 12
    end,

    Read = function(Buf: buffer, Offset: number): (Vector3, number)
        return Vector3.new(
            buffer.readf32(Buf, Offset),
            buffer.readf32(Buf, Offset + 4),
            buffer.readf32(Buf, Offset + 8)
        ), 12
    end,
} :: Codec<Vector3>

Codecs.Color = {
    Measure = function(): number
        return 3
    end,

    Write = function(Buf: buffer, Offset: number, Value: Color3): number
        buffer.writeu8(Buf, Offset, math.floor(Value.R * 255))
        buffer.writeu8(Buf, Offset + 1, math.floor(Value.G * 255))
        buffer.writeu8(Buf, Offset + 2, math.floor(Value.B * 255))
        return 3
    end,

    Read = function(Buf: buffer, Offset: number): (Color3, number)
        return Color3.fromRGB(
            buffer.readu8(Buf, Offset),
            buffer.readu8(Buf, Offset + 1),
            buffer.readu8(Buf, Offset + 2)
        ), 3
    end,
} :: Codec<Color3>

Codecs.CFrame = {
    Measure = function(): number
        return 48
    end,

    Write = function(Buf: buffer, Offset: number, Value: CFrame): number
        const Components = {Value:GetComponents()}
        for Index, Component in Components do
            buffer.writef32(Buf, Offset + (Index - 1) * 4, Component)
        end

        return 48
    end,

    Read = function(Buf: buffer, Offset: number): (CFrame, number)
        const Components = table.create(12)
        for Index = 1, 12 do
            Components[Index] = buffer.readf32(Buf, Offset + (Index - 1) * 4)
        end

        return CFrame.new(table.unpack(Components, 1, 12)), 48
    end,
} :: Codec<CFrame>

-- Side channel: the value rides alongside the buffer as a normal remote argument.
-- Two bytes on the wire, and Roblox handles the serialization.
Codecs.Any = {
    Measure = function(): number
        return 2
    end,

    Write = function(Buf: buffer, Offset: number, Value: any, Extras: {any}): number
        -- Index 0 means nil. table.insert would not grow the array for a nil
        -- value, so every later index would shift and decode as the wrong one.
        if Value == nil then
            buffer.writeu16(Buf, Offset, 0)
            return 2
        end

        table.insert(Extras, Value)
        buffer.writeu16(Buf, Offset, #Extras)
        return 2
    end,

    Read = function(Buf: buffer, Offset: number, Extras: {any}): (any, number)
        const Index = buffer.readu16(Buf, Offset)
        if Index == 0 then
            return nil, 2
        end

        return Extras[Index], 2
    end,
} :: Codec<any>

Codecs.Instance = Codecs.Any :: Codec<Instance>
Codecs.Player = Codecs.Any :: Codec<Player>

function Codecs.Optional<T>(Inner: Codec<T>): Codec<T?>
    return {
        Measure = function(Value: T?): number
            return if Value == nil then 1 else 1 + Inner.Measure(Value :: T)
        end,

        Write = function(Buf: buffer, Offset: number, Value: T?, Extras: {any}): number
            if Value == nil then
                buffer.writeu8(Buf, Offset, 0)
                return 1
            end

            buffer.writeu8(Buf, Offset, 1)
            return 1 + Inner.Write(Buf, Offset + 1, Value :: T, Extras)
        end,

        Read = function(Buf: buffer, Offset: number, Extras: {any}): (T?, number)
            if buffer.readu8(Buf, Offset) == 0 then
                return nil, 1
            end

            const Value, Length = Inner.Read(Buf, Offset + 1, Extras)
            return Value, 1 + Length
        end,
    }
end

function Codecs.Array<T>(Inner: Codec<T>): Codec<{T}>
    return {
        Measure = function(Value: {T}): number
            local Size = 2
            for _, Item in Value do
                Size += Inner.Measure(Item)
            end

            return Size
        end,

        Write = function(Buf: buffer, Offset: number, Value: {T}, Extras: {any}): number
            if #Value > 65535 then
                Logger:Error(`Array codec takes at most 65535 entries, got {#Value}.`)
            end

            buffer.writeu16(Buf, Offset, #Value)

            local Cursor = Offset + 2
            for _, Item in Value do
                Cursor += Inner.Write(Buf, Cursor, Item, Extras)
            end

            return Cursor - Offset
        end,

        Read = function(Buf: buffer, Offset: number, Extras: {any}): ({T}, number)
            const Count = buffer.readu16(Buf, Offset)
            const Out = table.create(Count)

            local Cursor = Offset + 2
            for Index = 1, Count do
                const Value, Length = Inner.Read(Buf, Cursor, Extras)
                Out[Index] = Value
                Cursor += Length
            end

            return Out, Cursor - Offset
        end,
    }
end

return Codecs
