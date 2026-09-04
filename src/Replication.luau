--!strict
-- Sends current state to joining players.
--
-- Registration used to broadcast with FireAll and nothing else, so anyone who
-- joined after startup received an empty registry and an empty workspace and
-- stayed that way. Requiring this module on the server closes that hole.
--
-- The replay is driven by the client announcing it is ready, not by PlayerAdded.
-- At PlayerAdded the client has not finished requiring Loom, so nothing is
-- listening yet; Roblox queues unhandled remote events but the queue is bounded,
-- and a registry of any size can overflow it and silently drop entries.
--
-- Order matters and is why this lives in one place rather than as a handler
-- inside each module: property registries have to land before object registries,
-- which have to land before the objects that reference them.

const Players = game:GetService("Players")

const PropertiesNetwork = require("./Properties/Network")
const ObjectsNetwork = require("./Objects/Network")
const Permissions = require("./Permissions/Server")
const Properties = require("./Properties/Server")
const Networking = require("./Networking")
const Compressor = require("./Compressor")
const Objects = require("./Objects/Server")

const Ready = Networking:Get("Loom.Ready")

const Replication = {}
const Replayed: {[Player]: true} = {}

function Replication.Replay(Plr: Player)
    for _, Registry in Properties:GetRegistered() do
        if not Plr.Parent then
            return
        end

        PropertiesNetwork.PropertyRegistered:Fire(Plr, Registry)
    end

    for Identifier in Objects:GetRegistered() do
        if not Plr.Parent then
            return
        end

        ObjectsNetwork.ObjectRegistered:Fire(Plr, Objects:GetRegistryPayload(Identifier))
    end

    for _, Obj in Objects:GetWorkspace() do
        if not Plr.Parent then
            return
        end

        if Obj.Destroyed then
            continue
        end

        ObjectsNetwork.ObjectAdded:Fire(
            Plr,
            Obj.RuntimeId,
            Compressor:CompressObject(Obj :: any),
            Obj.Instance
        )
    end
end

-- Answering at all is the signal the client is waiting for, so this must be set
-- by the module that actually performs the replay. Returning true only after
-- Replay finishes means the client knows its state is on the way.
--
-- Guarded per player: without it a client could invoke repeatedly and make the
-- server re-serialize the entire workspace on demand.
Ready.OnInvoke = function(Plr: Player): boolean
    if Replayed[Plr] then
        return true
    end

    Replayed[Plr] = true
    Permissions:SendTo(Plr)
    Replication.Replay(Plr)
    return true
end

Players.PlayerRemoving:Connect(function(Plr: Player)
    Replayed[Plr] = nil
end)

return Replication
