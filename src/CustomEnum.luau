--!strict
const Logger = require("./Logger")

export type EnumName = string
export type OptionId = number
export type EnumOptions<T> = {[T]: OptionId}
export type RegisteredOption<T> = {
    __type: "CustomEnumOption",
    Id: OptionId,
    Value: T,
    Parent: EnumName
}

export type CustomEnum<T> = {
    __type: "CustomEnum",
    Name: EnumName,
    Options: {RegisteredOption<T>},
    ById: {[OptionId]: RegisteredOption<T>},

    GetById: (self: CustomEnum<T>, Id: number) -> RegisteredOption<T>?,
    GetByValue: (self: CustomEnum<T>, Value: T) -> RegisteredOption<T>?,
}

const MAX_OPTION_ID = 65535

const CustomEnum = {}
const Registered: {[EnumName]: CustomEnum<any>} = {}

-- Indexed rather than scanned: the compressor calls this for every CustomEnum
-- property it decodes.
const function __get_by_id<T>(self: CustomEnum<T>, Id: number): RegisteredOption<T>?
    return self.ById[Id]
end

const function __get_by_value<T>(self: CustomEnum<T>, Value: T): RegisteredOption<T>?
    for _, Option in self.Options do
        if Option.Value == Value then
            return Option
        end
    end

    return nil
end

function CustomEnum:Register<T>(Name: string, Options: EnumOptions<T>): CustomEnum<T>?
    if Registered[Name] then
        Logger:Warn(`Custom enum {Name} is already registered.`)
        return nil
    end

    const ById = {}
    const Valid = {}

    for Value, Id in Options do
        if type(Id) ~= "number" or Id ~= math.floor(Id) then
            Logger:Warn(`Cannot register custom enum option {Value} with a non integer id, got {Id}. Will be skipped`)
            continue
        end

        -- The compressor writes option ids as a u16.
        if Id < 0 or Id > MAX_OPTION_ID then
            Logger:Warn(`Cannot register custom enum option {Value} with id {Id}, outside 0 to {MAX_OPTION_ID}. Will be skipped`)
            continue
        end

        if ById[Id] then
            Logger:Warn(`Cannot register custom enum option {Value} with duplicate id, {ById[Id].Value} already uses id {Id}. Will be skipped`)
            continue
        end

        const Option = {
            __type = "CustomEnumOption",
            Id = Id,
            Value = Value,
            Parent = Name,
        }

        ById[Id] = Option
        table.insert(Valid, Option)
    end

    -- Options is built by iterating a dictionary, so without this the array
    -- order changes between runs.
    table.sort(Valid, function(A, B)
        return A.Id < B.Id
    end)

    const Enum = {
        __type = "CustomEnum",
        Name = Name,
        Options = Valid,
        ById = ById,

        GetById = __get_by_id,
        GetByValue = __get_by_value,
    }

    Registered[Name] = Enum :: any
    return Enum :: any
end

function CustomEnum:GetEnum<T>(Name: string): CustomEnum<T>?
    return Registered[Name]
end

function CustomEnum:GetRegistered(): {[EnumName]: CustomEnum<any>}
    return Registered
end

const Unknown = CustomEnum:Register("Unknown", {
    Unknown = 1,
})

if not Unknown then
    Logger:Error("Failed to register the built in Unknown enum.")
end

-- Returned by the compressor when a saved option no longer resolves.
CustomEnum.UNKNOWN = (Unknown :: CustomEnum<string>).ById[1]

return CustomEnum
