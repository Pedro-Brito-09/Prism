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

    GetById: (self: CustomEnum<T>, Id: number) -> RegisteredOption<T>?,
    GetByValue: (self: CustomEnum<T>, Value: T) -> RegisteredOption<T>?,
}

const CustomEnum = {}
const Registered: {[EnumName]: CustomEnum<any>}  = {}

const function __get_by_id<T>(self: CustomEnum<T>, Id: number): RegisteredOption<T>?
    for _, v in self.Options do
        if v.Id == Id then
            return v
        end
    end

    return nil
end

const function __get_by_value<T>(self: CustomEnum<T>, Value: T): RegisteredOption<T>?
    for _, v in self.Options do
        if v.Value == Value then
            return v
        end
    end

    return nil
end

function CustomEnum:Register<T>(Name: string, Options: EnumOptions<T>): CustomEnum<T>?
    if Registered[Name] then
        Logger:Warn(`Custom enum {Name} is already registered.`)
        return
    end

    const Found = {}
    const Valid = {}
    for Value, Id in Options do
        if type(Id) ~= "number" then
            Logger:Warn(`Cannot register custom enum option {Value} with a non integer id, got {type(Id)}. Will be skipped`)
            continue
        end

        if Found[Id] then
            Logger:Warn(`Cannot register custom enum option {Value} with duplicate id, {Found[Id]} already uses id {Id}. Will be skipped`)
            continue
        end

        Found[Id] = Value
        table.insert(Valid, {
            __type = "CustomEnumOption",
            Id = Id,
            Value = Value,
            Parent = Name,
        })
    end

    Registered[Name] = {
        __type = "CustomEnum",
        Name = Name,
        Options = Valid,

        GetById = __get_by_id,
        GetByValue = __get_by_value,
    }

    return Registered[Name]
end

function CustomEnum:GetEnum<T>(Name: string): CustomEnum<T>?
    return Registered[Name]
end

CustomEnum.UNKNOWN = CustomEnum:Register("Unknown", {
    Unknown = 1,
}).Options[1]

return CustomEnum