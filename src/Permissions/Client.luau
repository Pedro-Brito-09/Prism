--!strict
-- The client's view of its own rights, so an editor can grey out tools instead
-- of firing requests the server will refuse. The server re-checks everything.
--
-- Global rights arrive as one set; rights over a scene arrive one scene at a
-- time, and only for scenes that have granted this player something.

const Network = require("./Network")
const Shared = require("./Shared")
const Types = require("./Types")

export type Action = Types.Action
export type Target = Types.Target
export type SceneRights = Types.SceneRights
export type GlobalRights = Types.GlobalRights

const Permissions = {}

-- Nil for a change to the global rights, or the scene whose rights changed.
const Listeners: {(Scene: number?) -> ()} = {}

-- Until the server says otherwise: the default budget, and nothing else.
local Global: GlobalRights = Shared.GlobalRights(nil, nil)
const ByScene: {[number]: SceneRights} = {}

function Permissions:Get(): GlobalRights
    return Global
end

function Permissions:GetOn(Scene: number): SceneRights?
    return ByScene[Scene]
end

-- Mirrors the server: Target is the object, or for a create a table naming the
-- scene and the type; Property is the one being written.
function Permissions:Can(Action: Action, Target: Target, Property: number?): boolean
    const Rights = ByScene[Target.Scene]
    if not Rights then
        return false
    end

    return Shared.Allows(Rights, Action, Target.Registry, Property)
end

function Permissions:Has(Capability: string, Scene: number?): boolean
    if Scene == nil then
        return Global.Capabilities[Capability] == true
    end

    const Rights = ByScene[Scene]
    return Rights ~= nil and Rights.Capabilities[Capability] == true
end

function Permissions:OnChange(Callback: (Scene: number?) -> ()): () -> ()
    table.insert(Listeners, Callback)
    return function()
        const Position = table.find(Listeners, Callback)
        if Position then
            table.remove(Listeners, Position)
        end
    end
end

const function Notify(Scene: number?)
    for _, Callback in table.clone(Listeners) do
        task.spawn(Callback, Scene)
    end
end

-- Every set arrives as a sequential array and is rebuilt into a map here:
-- non-sequential numeric keys are not guaranteed to survive a remote, and a map
-- sent as one used to arrive with blacklist entries missing.
Network.Assigned:Connect(function(Payload: Types.GlobalRightsPayload)
    Global = Shared.DecodeGlobal(Payload)
    Notify(nil)
end)

Network.SceneAssigned:Connect(function(Scene: number, Payload: Types.SceneRightsPayload?)
    ByScene[Scene] = if Payload then Shared.DecodeScene(Payload) else nil
    Notify(Scene)
end)

return Permissions
