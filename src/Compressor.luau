const RunService = game:GetService("RunService")

const Properties = RunService:IsServer() and require("./Properties/Server") or require("./Properties/Client")
const PropertyTypes = require("./Properties/Types")
const DatabaseTypes = require("./Database/Types")
const ObjectTypes = require("./Objects/Types")
const CustomEnum = require("./CustomEnum")
const Logger = require("./Logger")

export type DecompressedObject = {
    Parent: ObjectTypes.ObjectIdentifier,
    Properties: {[PropertyTypes.PropertyIdentifier]: any},
}

const ARRAY_HEADER = "/a"
const DICTIONARY_HEADER = "/d"
const TABLE_FOOTER = "/t"
const OBJECT_HEADER = "/oh"
const OBJECT_FOOTER = "/of"
const METADATA_HEADER = "/mh"
const METADATA_FOOTER = "/mf"
const PACK_HEADER = "/ph"
const PACK_FOOTER = "/pf"

const Compressor = {}

function Compressor:CompressValue(Type: PropertyTypes.PropertyType, Value: any?): buffer?
    if Value == nil then
        return
    end

    if Type == "Text" then
        const Compressed = buffer.create(2 + #Value :: string)
        buffer.writeu16(Compressed, 0, #Value :: string)
        buffer.writestring(Compressed, 2, Value :: string)
        return Compressed
    elseif Type == "Number" then
        const Compressed = buffer.create(4)
        buffer.writef32(Compressed, 0, Value :: number)
        return Compressed
    elseif Type == "Bool" then
        const Compressed = buffer.create(1)
        buffer.writeu8(Compressed, 0, Value and 1 or 0)
        return Compressed
    elseif Type == "Color" then
        const Compressed = buffer.create(3)
        buffer.writeu8(Compressed, 0, math.floor(Value.R * 255))
        buffer.writeu8(Compressed, 1, math.floor(Value.G * 255))
        buffer.writeu8(Compressed, 2, math.floor(Value.B * 255))
        return Compressed
    elseif Type == "Vector" then
        const Compressed = buffer.create(12)
        buffer.writef32(Compressed, 0, Value.X)
        buffer.writef32(Compressed, 4, Value.Y)
        buffer.writef32(Compressed, 8, Value.Z)
        return Compressed
    elseif Type == "CFrame" then
        const Compressed = buffer.create(48)
        const X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = (Value :: CFrame):GetComponents()
        buffer.writef32(Compressed, 0, X)
        buffer.writef32(Compressed, 4, Y)
        buffer.writef32(Compressed, 8, Z)
        buffer.writef32(Compressed, 12, R00)
        buffer.writef32(Compressed, 16, R01)
        buffer.writef32(Compressed, 20, R02)
        buffer.writef32(Compressed, 24, R10)
        buffer.writef32(Compressed, 28, R11)
        buffer.writef32(Compressed, 32, R12)
        buffer.writef32(Compressed, 36, R20)
        buffer.writef32(Compressed, 40, R21)
        buffer.writef32(Compressed, 44, R22)
        return Compressed
    elseif Type == "Enum" then
        const EnumType = tostring(Value.EnumType)
        const Compressed = buffer.create(2 + #EnumType + 2)
        buffer.writeu16(Compressed, 0, #EnumType)
        buffer.writestring(Compressed, 2, EnumType)
        buffer.writeu16(Compressed, 2 + #EnumType, Value.Value)
        return Compressed
    elseif Type == "CustomEnum" then
        const Name = Value.Parent
        const Compressed = buffer.create(2 + #Name + 2)
        buffer.writeu16(Compressed, 0, #Name)
        buffer.writestring(Compressed, 2, Name)
        buffer.writeu16(Compressed, 2 + #Name, Value.Id)
        return Compressed
    -- elseif Type == "Table" then
    --     local IsArray = false
    --     local Count = 0
    --     for _, _ in Value :: {} do
    --         Count += 1
    --     end

    --     if Count == 0 then
    --         const Compressed = buffer.create(#TABLE_FOOTER)
    --         buffer.writestring(Compressed, 0, TABLE_FOOTER)
    --         return Compressed
    --     elseif Count == #Value :: {} then
    --         IsArray = true
    --     end

    --     local Size = 0
    --     const Buffers = {}
    --     for i, v in Value :: {} do
    --         if not IsArray then
    --             const IndexType = PropertyTypes:GetTypeFromValue(i)
    --             const IndexTypeBuffer = buffer.create(1)
    --             buffer.writeu8(IndexTypeBuffer, 0, PropertyTypes:GetTypeId(IndexType))
    --             Size += 1
    --             table.insert(Buffers, IndexTypeBuffer)

    --             const IndexBuffer = Compressor:CompressValue(IndexType, i)
    --             Size += buffer.len(IndexBuffer)
    --             table.insert(Buffers, IndexBuffer)
    --         end

    --         const ValueType = PropertyTypes:GetTypeFromValue(v)
    --         const ValueTypeBuffer = buffer.create(1)
    --         buffer.writeu8(ValueTypeBuffer, 0, PropertyTypes:GetTypeId(ValueType))
    --         Size += 1
    --         table.insert(Buffers, ValueTypeBuffer)

    --         const ValueBuffer = Compressor:CompressValue(ValueType, v)
    --         Size += buffer.len(ValueBuffer)
    --         table.insert(Buffers, ValueBuffer)
    --     end

    --     const Header = IsArray and ARRAY_HEADER or DICTIONARY_HEADER
    --     const Compressed = buffer.create(Size + #Header + #TABLE_FOOTER)
    --     buffer.writestring(Compressed, 0, Header)

    --     local Offset = #Header
    --     for _, v in Buffers do
    --         buffer.copy(Compressed, Offset, v, 0)
    --         Offset += buffer.len(v)
    --     end

    --     buffer.writestring(Compressed, Offset, TABLE_FOOTER)
    --     return Compressed
    else
        Logger:Error(`Tried compressing unsupported value type: {Type}`)
    end

    return
end

function Compressor:DecompressValue(Type: PropertyTypes.PropertyType, Value: buffer, Offset: number?): (any?, number)
    Offset = Offset or 0
    if Type == "Text" then
        const Length = buffer.readu16(Value, Offset)
        return buffer.readstring(Value, Offset + 2, Length), 2 + Length
    elseif Type == "Number" then
        return buffer.readf32(Value, Offset), 4
    elseif Type == "Bool" then
        return buffer.readu8(Value, Offset) == 1, 1
    elseif Type == "Color" then
        const R = buffer.readu8(Value, Offset)
        const G = buffer.readu8(Value, Offset + 1)
        const B = buffer.readu8(Value, Offset + 2)
        return Color3.fromRGB(R, G, B), 3
    elseif Type == "Vector" then
        const X = buffer.readf32(Value, Offset)
        const Y = buffer.readf32(Value, Offset + 4)
        const Z = buffer.readf32(Value, Offset + 8)
        return Vector3.new(X, Y, Z), 12
    elseif Type == "CFrame" then
        const X = buffer.readf32(Value, Offset)
        const Y = buffer.readf32(Value, Offset + 4)
        const Z = buffer.readf32(Value, Offset + 8)
        const R00 = buffer.readf32(Value, Offset + 12)
        const R01 = buffer.readf32(Value, Offset + 16)
        const R02 = buffer.readf32(Value, Offset + 20)
        const R10 = buffer.readf32(Value, Offset + 24)
        const R11 = buffer.readf32(Value, Offset + 28)
        const R12 = buffer.readf32(Value, Offset + 32)
        const R20 = buffer.readf32(Value, Offset + 36)
        const R21 = buffer.readf32(Value, Offset + 40)
        const R22 = buffer.readf32(Value, Offset + 44)
        return CFrame.new(X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22), 48
    elseif Type == "Enum" then
        const EnumType, Length = Compressor:DecompressValue("Text", Value, Offset)
        const EnumValue = buffer.readu16(Value, Offset + Length)
        return Enum[EnumType]:FromValue(EnumValue), Length + 2
    elseif Type == "CustomEnum" then
        const Name, Length = Compressor:DecompressValue("Text", Value, Offset)
        const Id = buffer.readu16(Value, Offset + Length)
        if not CustomEnum:GetEnum(Name) then
            return CustomEnum.UNKNOWN, Length + 2
        end

        return CustomEnum:GetEnum(Name):GetById(Id) or CustomEnum.UNKNOWN, Length + 2
    -- elseif Type == "Table" then
    --     const TableType = buffer.readstring(Value, Offset, #TABLE_FOOTER)
    --     if TableType == TABLE_FOOTER then
    --         return {}, #TABLE_FOOTER
    --     end

    --     const IsArray = TableType == ARRAY_HEADER
    --     local Result = {}
    --     Offset += (IsArray and #ARRAY_HEADER or #DICTIONARY_HEADER)
    --     while true do
    --         const NextType = buffer.readstring(Value, Offset, 2)
    --         if NextType == TABLE_FOOTER then
    --             Offset += #TABLE_FOOTER
    --             break
    --         end

    --         local Key;
    --         if not IsArray then
    --             const IndexTypeId = buffer.readu8(Value, Offset)
    --             const IndexType = PropertyTypes:GetTypeFromId(IndexTypeId)
    --             Offset += 1

    --             const _Key, Length = Compressor:DecompressValue(IndexType, Value, Offset)
    --             Offset += Length
    --             Key = _Key
    --         end

    --         const ValueTypeId = buffer.readu8(Value, Offset)
    --         const ValueType = PropertyTypes:GetTypeFromId(ValueTypeId)
    --         Offset += 1

    --         const Val, Length = Compressor:DecompressValue(ValueType, Value, Offset)
    --         Offset += Length

    --         Result[Key or #Result + 1] = Val
    --     end

    --     return Result, Offset
    else
        Logger:Error(`Tried decompressing unsupported value type: {Type}`)
    end

    return nil, 0
end

function Compressor:CompressObject(Obj: ObjectTypes.Object | DecompressedObject): buffer
    local Size = 0
    const Buffers = {}
    for i, v in Obj.Properties :: {} do
        local Id, Type, Value;
        if (Obj :: any).__type == "DecompressedObject" then
            const Property = Properties:GetRegistry(i)
            if not Property then
                Logger:Warn(`Tried compressing an object with invalid property id: {i}. Skipping property.`)
                continue
            end

            Id, Type, Value = i, Property.Type, v
        else
            Id, Type, Value = v.Parent, v.Type, v.Value
        end

        const ValueBuffer = Compressor:CompressValue(Type, Value)
        if not ValueBuffer then
            continue
        end

        const IdBuffer = buffer.create(2)
        buffer.writeu16(IdBuffer, 0, Id)
        table.insert(Buffers, IdBuffer)
        Size += 2

        table.insert(Buffers, ValueBuffer)
        Size += buffer.len(ValueBuffer)
    end

    const Compressed = buffer.create(Size + #OBJECT_HEADER + 2 + #OBJECT_FOOTER)
    buffer.writestring(Compressed, 0, OBJECT_HEADER)
    buffer.writeu16(Compressed, #OBJECT_HEADER, Obj.Parent) -- Object Registry Id
    
    local Offset = #OBJECT_HEADER + 2
    for _, v in Buffers do
        buffer.copy(Compressed, Offset, v, 0)
        Offset += buffer.len(v)
    end

    buffer.writestring(Compressed, Offset, OBJECT_FOOTER)
    return Compressed
end

function Compressor:DecompressObject(CompressedObj: buffer): DecompressedObject
    if buffer.readstring(CompressedObj, 0, #OBJECT_HEADER) ~= OBJECT_HEADER then
        Logger:Error("Tried to decompress invalid object buffer.")
    end

    const RegistryId = buffer.readu16(CompressedObj, #OBJECT_HEADER)
    local Offset = #OBJECT_HEADER + 2

    const Obj = {
        __type = "DecompressedObject",
        Parent = RegistryId,
        Properties = {},
    }

    while true do
        if buffer.readstring(CompressedObj, Offset, #OBJECT_FOOTER) == OBJECT_FOOTER then
            Offset += #OBJECT_FOOTER
            break
        end

        const PropertyId = buffer.readu16(CompressedObj, Offset)
        Offset += 2

        const Property = Properties:GetRegistry(PropertyId)
        if not Property then
            Logger:Error(`Tried decompressing object with invalid property id: {PropertyId}`)
        end

        const Value, Length = Compressor:DecompressValue(Property.Type, CompressedObj, Offset)
        Offset += Length

        Obj.Properties[PropertyId] = Value
    end
    
    return Obj
end

function Compressor:CompressMetadata(Metadata: DatabaseTypes.Metadata): buffer
    local Size = 0
    const Buffers = {}

    for Index, Prop in Metadata do
        if type(Index) == "string" then
            continue
        end

        const ValueBuffer = Compressor:CompressValue(Prop.Type, Prop.Value)
        if not ValueBuffer then
            continue
        end

        const IdBuffer = buffer.create(2)
        buffer.writeu16(IdBuffer, 0, Prop.Parent)
        table.insert(Buffers, IdBuffer)
        Size += 2
        
        table.insert(Buffers, ValueBuffer)
        Size += buffer.len(ValueBuffer)
    end

    const Compressed = buffer.create(Size + #METADATA_HEADER + 12 + #METADATA_FOOTER)
    buffer.writestring(Compressed, 0, METADATA_HEADER)
    buffer.writeu32(Compressed, #METADATA_HEADER, Metadata.Id)
    buffer.writeu32(Compressed, #METADATA_HEADER + 4, Metadata.SavedVersion)
    buffer.writeu32(Compressed, #METADATA_HEADER + 8, Metadata.PublishedVersion)

    local Offset = #METADATA_HEADER + 12
    for _, v in Buffers do
        buffer.copy(Compressed, Offset, v, 0)
        Offset += buffer.len(v)
    end

    buffer.writestring(Compressed, Offset, METADATA_FOOTER)
    return Compressed
end

function Compressor:DecompressMetadata(CompressedMetadata: buffer): DatabaseTypes.Metadata
    if buffer.readstring(CompressedMetadata, 0, #METADATA_HEADER) ~= METADATA_HEADER then
        Logger:Error("Tried to decompress invalid metadata buffer.")
    end

    const Metadata = {
        Id = buffer.readu32(CompressedMetadata, #METADATA_HEADER),
        SavedVersion = buffer.readu32(CompressedMetadata, #METADATA_HEADER + 4),
        PublishedVersion = buffer.readu32(CompressedMetadata, #METADATA_HEADER + 8)
    }

    local Offset = #METADATA_HEADER + 12
    while true do
        if buffer.readstring(CompressedMetadata, Offset, #METADATA_FOOTER) == METADATA_FOOTER then
            Offset += #METADATA_FOOTER
            break
        end

        const PropertyId = buffer.readu16(CompressedMetadata, Offset)
        Offset += 2

        const Property = Properties:GetRegistry(PropertyId)
        if not Property then
            Logger:Error(`Tried decompressing metadata with invalid property id: {PropertyId}`)
        end

        const Value, ValLength = Compressor:DecompressValue(Property.Type, CompressedMetadata, Offset)
        Offset += ValLength

        const Prop = Properties.new(Property) :: PropertyTypes.Property<any>
        Prop:Set(Value)

        table.insert(Metadata, Prop)
    end

    return Metadata
end

function Compressor:PackBuffers(Buffers: {buffer}): buffer
    local Size = 0
    for _, v in Buffers do
        Size += 4 + buffer.len(v)
    end

    const Pack = buffer.create(Size + #PACK_HEADER + #PACK_FOOTER)
    buffer.writestring(Pack, 0, PACK_HEADER)

    local Offset = #PACK_HEADER
    for _, v in Buffers do
        const Length = buffer.len(v)
        buffer.writeu32(Pack, Offset, Length)
        Offset += 4

        buffer.copy(Pack, Offset, v, 0)
        Offset += Length
    end

    buffer.writestring(Pack, Offset, PACK_FOOTER)
    return Pack
end

function Compressor:UnpackBuffers(PackedBuffers: buffer, Offset: number?): {buffer}
    Offset = Offset or 0
    if buffer.readstring(PackedBuffers, Offset, #PACK_HEADER) ~= PACK_HEADER then
        Logger:Error("Tried to unpack invalid buffer pack.")
    end

    const Unpacked = {}
    Offset += #PACK_HEADER
    while true do
        if buffer.readstring(PackedBuffers, Offset, #PACK_FOOTER) == PACK_FOOTER then
            Offset += #PACK_FOOTER
            break
        end

        const Length = buffer.readu32(PackedBuffers, Offset)
        Offset += 4

        const Slice = buffer.create(Length)
        buffer.copy(Slice, 0, PackedBuffers, Offset, Length)
        table.insert(Unpacked, Slice)
        Offset += Length
    end

    return Unpacked
end

function Compressor:CompressMetadatas(LastId: number, Metadatas: {DatabaseTypes.Metadata}): buffer
    const Compressed = {}
    for _, v in Metadatas do
        table.insert(Compressed, Compressor:CompressMetadata(v))
    end

    const Packed = Compressor:PackBuffers(Compressed)
    const Buffer = buffer.create(4 + buffer.len(Packed))
    buffer.writeu32(Buffer, 0, LastId)
    buffer.copy(Buffer, 4, Packed, 0)
    return Buffer
end

function Compressor:DecompressMetadatas(CompressedMetadatas: buffer): (number, {DatabaseTypes.Metadata})
    const LastId = buffer.readu32(CompressedMetadatas, 0)
    const Metadatas = {}
    for _, Compressed in Compressor:UnpackBuffers(CompressedMetadatas, 4) do -- First 4 bytes are reserved for Id counter (u32)
        table.insert(Metadatas, Compressor:DecompressMetadata(Compressed))
    end

    return LastId, Metadatas
end

return Compressor