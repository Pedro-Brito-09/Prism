--!strict
-- MemoryStore JSON serializes its values, so a raw buffer cannot be stored in
-- it directly. Base64 output is ASCII, which survives that round trip.
--
-- Kept as a thin wrapper on purpose: if the EncodingService signature differs
-- from what is written here, this is the only file that needs touching.

const EncodingService = game:GetService("EncodingService")

const Encoding = {}

function Encoding.Encode(Buf: buffer): string
    return buffer.tostring(EncodingService:Base64Encode(Buf))
end

function Encoding.Decode(Text: string): buffer
    return EncodingService:Base64Decode(buffer.fromstring(Text))
end

return Encoding
