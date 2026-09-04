--!strict
-- The client's view of its own role, so the editor UI can grey out tools instead
-- of firing remotes the server will refuse. The server re-checks everything.

const Network = require("./Network")
const Types = require("./Types")

export type Action = Types.Action
export type ObjectType = Types.ObjectType
export type Permission = Types.Permission

const Permissions = {}
const Listeners: {(Permission) -> ()} = {}

local Current: Permission = {
    Name = "None",
    Level = 0,
    CanCreate = false,
    CanEdit = false,
    CanDestroy = false,
    Rate = 0,
    Blacklist = {},
}

function Permissions:Get(): Permission
    return Current
end

function Permissions:Can(Action: Action, ObjectType: ObjectType?): boolean
    if Action == "Create" and not Current.CanCreate then
        return false
    elseif Action == "Edit" and not Current.CanEdit then
        return false
    elseif Action == "Destroy" and not Current.CanDestroy then
        return false
    end

    if ObjectType and Current.Blacklist[ObjectType] then
        return false
    end

    return true
end

function Permissions:OnChange(Callback: (Permission) -> ()): () -> ()
    table.insert(Listeners, Callback)
    return function()
        const Position = table.find(Listeners, Callback)
        if Position then
            table.remove(Listeners, Position)
        end
    end
end

-- Blacklist arrives as a sequential array and is rebuilt into a map here.
-- Sending the map directly did not survive remote serialization: non-sequential
-- numeric keys are not guaranteed to be preserved, so entries went missing and
-- Can() started answering true for blacklisted object types.
Network.Assigned:Connect(function(Payload: Types.PermissionPayload)
    const Blacklist: {[ObjectType]: true} = {}
    for _, Entry in Payload.Blacklist or {} do
        Blacklist[Entry] = true
    end

    Current = {
        Name = Payload.Name,
        Level = Payload.Level,
        CanCreate = Payload.CanCreate,
        CanEdit = Payload.CanEdit,
        CanDestroy = Payload.CanDestroy,
        Rate = Payload.Rate,
        Blacklist = Blacklist,
    }

    for _, Callback in table.clone(Listeners) do
        task.spawn(Callback, Current)
    end
end)

return Permissions
