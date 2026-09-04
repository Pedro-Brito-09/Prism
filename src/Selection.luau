const ObjectNetwork = require("./Objects/Network")
const ObjectTypes = require("./Objects/Types")
const Objects = require("./Objects/Client")

const Selection = {}
const Selected = {}

function Selection:Add(Obj: ObjectTypes.Object | ObjectTypes.RuntimeId): boolean
    local Id;
    if type(Obj) == "number" and Objects:Get(Obj) then
        Id = Obj  
    elseif type(Obj) == "table" and Objects:Get(Obj.RuntimeId) then
        Id = Obj.RuntimeId
    end

    if Id and not table.find(Selected, Id) then
        table.insert(Selected, Id)
        return true
    end

    return false
end

function Selection:Remove(Obj: ObjectTypes.Object | ObjectTypes.RuntimeId): boolean
    local Id;
    if type(Obj) == "number" and Objects:Get(Obj) then
        Id = Obj  
    elseif type(Obj) == "table" and Objects:Get(Obj.RuntimeId) then
        Id = Obj.RuntimeId
    end

    if Id then
        const Position = table.find(Selected, Id)
        if Position then
            table.remove(Selected, Position)
            return true
        end
    end

    return false
end

function Selection:Clear()
    table.clear(Selected)
end

function Selection:Set(Objs: {ObjectTypes.Object | ObjectTypes.RuntimeId}): boolean
    local Worked = false

    Selection:Clear()
    for _, v in Objs do
        if Selection:Add(v) then
            Worked = true
        end
    end

    return Worked
end

function Selection:Get()
    const All = {}
    const ToRemove = {}
    for _, v in Selected do
        const Obj = Objects:Get(v)
        if not Obj then
            table.insert(ToRemove, v)
            continue
        end

        table.insert(All, Obj)
    end

    for _, v in ToRemove do
        Selection:Remove(v)
    end

    return All
end

function Selection:Query(Comparator: (Obj: Object) -> boolean)
    const All = {}
    const ToRemove = {}
    for _, v in Selected do
        const Obj = Objects:Get(v)
        if not Obj then
            table.insert(ToRemove, v)
            continue
        end

        if Comparator(Obj) then
            table.insert(All, Obj)
        end
    end

    for _, v in ToRemove do
        Selection:Remove(v)
    end

    return All
end

return Selection