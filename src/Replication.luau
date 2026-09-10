--!strict
-- Sends current state to joining players.
--
-- Registration used to broadcast with FireAll and nothing else, so anyone who
-- joined after startup received an empty registry and an empty workspace and
-- stayed that way. Requiring this module on the server closes that hole.
--
-- The replay is driven by the client announcing it is ready, not by PlayerAdded.
-- At PlayerAdded the client has not finished requiring Prism, so nothing is
-- listening yet; Roblox queues unhandled remote events but the queue is bounded,
-- and a registry of any size can overflow it and silently drop entries.
--
-- Order matters and is why this lives in one place rather than as a handler
-- inside each module: property registries have to land before object registries,
-- which have to land before the objects that reference them. Scene registries go
-- first of all, because an object's handle names the scene holding it and one
-- arriving for a scene the client has never heard of cannot be filed.

const Players = game:GetService("Players")

const PropertiesNetwork = require("./Properties/Network")
const ObjectsNetwork = require("./Objects/Network")
const ScenesNetwork = require("./Scenes/Network")
const Scenes = require("./Scenes/Server")
const Permissions = require("./Permissions/Server")
const Properties = require("./Properties/Server")
const Networking = require("./Networking")
const Compressor = require("./Compressor")
const Objects = require("./Objects/Server")

const Ready = Networking:Get("Prism.Ready")

const Replication = {}
const Replayed: {[Player]: true} = {}

-- Entries per packet. The replay used to send one remote fire per registered
-- property, per registered object type, and per live object, all inside the
-- Ready handler with no yield anywhere -- so a large workspace both flooded the
-- remote queue in a single frame and held the server thread while every object
-- was compressed.
const CHUNK_SIZE = 50

const function SendChunks<T>(Plr: Player, Send: ({T}) -> (), Items: {T}): boolean
    const Total = #Items
    local Start = 1

    while Start <= Total do
        if not Plr.Parent then
            return false
        end

        const Stop = math.min(Start + CHUNK_SIZE - 1, Total)
        Send(table.move(Items, Start, Stop, 1, {}))
        Start = Stop + 1

        if Start <= Total then
            task.wait()
        end
    end

    return true
end

function Replication.Replay(Plr: Player)
    const SceneRegistries = {}
    for Identifier in Scenes:GetRegistered() do
        table.insert(SceneRegistries, Scenes:GetRegistryPayload(Identifier))
    end

    const SentScenes = SendChunks(Plr, function(Chunk)
        ScenesNetwork.RegistriesReplayed:Fire(Plr, Chunk)
    end, SceneRegistries)

    if not SentScenes then
        return
    end

    -- Which copies are live, before any object names one. Sent as two parallel
    -- lists for the same reason the object replay is: a codec per element.
    const LiveIds = {}
    const LiveScenes = {}
    for Index, Instance_ in Scenes:GetInstances() do
        LiveIds[Index] = Instance_.Id
        LiveScenes[Index] = Instance_.Scene
    end

    if #LiveIds > 0 then
        if not Plr.Parent then
            return
        end

        ScenesNetwork.InstancesReplayed:Fire(Plr, LiveIds, LiveScenes)
    end

    const PropertyRegistries = {}
    for Identifier in Properties:GetRegistered() do
        table.insert(PropertyRegistries, Properties:GetRegistryPayload(Identifier))
    end

    const SentProperties = SendChunks(Plr, function(Chunk)
        PropertiesNetwork.RegistriesReplayed:Fire(Plr, Chunk)
    end, PropertyRegistries)

    if not SentProperties then
        return
    end

    const ObjectRegistries = {}
    for Identifier in Objects:GetRegistered() do
        table.insert(ObjectRegistries, Objects:GetRegistryPayload(Identifier))
    end

    const SentObjects = SendChunks(Plr, function(Chunk)
        ObjectsNetwork.RegistriesReplayed:Fire(Plr, Chunk)
    end, ObjectRegistries)

    if not SentObjects then
        return
    end

    -- Three parallel lists, because that is what the channel takes. A missing
    -- instance is false rather than nil so the lists stay the same length and
    -- the indices keep lining up with the ids.
    --
    -- Compressed a chunk at a time rather than all at once, so the cost of
    -- serializing a large workspace is spread across frames.
    local RuntimeIds = {}
    local InstanceIds = {}
    local Buffers = {}
    local Instances = {}
    local Count = 0

    const function Flush(): boolean
        if Count == 0 then
            return true
        end

        if not Plr.Parent then
            return false
        end

        ObjectsNetwork.ObjectsReplayed:Fire(Plr, RuntimeIds, InstanceIds, Buffers, Instances)

        RuntimeIds = {}
        InstanceIds = {}
        Buffers = {}
        Instances = {}
        Count = 0

        task.wait()
        return true
    end

    for _, Obj in Objects:GetWorkspace() do
        if Obj.Destroyed then
            continue
        end

        Count += 1
        RuntimeIds[Count] = Obj.RuntimeId
        InstanceIds[Count] = Obj.InstanceId
        Buffers[Count] = Compressor:CompressObject(Obj :: any)
        Instances[Count] = Obj.Instance or false

        if Count >= CHUNK_SIZE and not Flush() then
            return
        end
    end

    Flush()
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
