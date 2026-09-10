--!strict
-- The client's view of the server's scenes.
--
-- Read only at this stage: the client is told which scenes exist, which copies
-- of them are live, and which objects belong to each copy. It cannot create a
-- scene or load one. A scene the client owns outright -- a prefab preview, a
-- local sandbox the server never sees -- is a separate mechanism and comes
-- later.
--
-- Objects are filed under their instance rather than their scene, because a
-- scene can be live more than once and an editor showing five identical rooms
-- has to be able to tell them apart.

const Objects = require("../Objects/Client")
const Network = require("./Network")
const Types = require("./Types")

export type SceneIdentifier = Types.SceneIdentifier
export type SceneRegistry = Types.SceneRegistry
export type SceneInstanceId = number

const Scenes = {}
const Registered: {[SceneIdentifier]: SceneRegistry} = {}

-- Which copies are live. The scene each belongs to is Objects' to hold, because
-- an object arriving needs it before this module could hand it over.
const Known: {[SceneInstanceId]: SceneInstanceId} = {}

function Scenes:GetRegistered(): {[SceneIdentifier]: SceneRegistry}
    return Registered
end

function Scenes:GetById(Identifier: SceneIdentifier): SceneRegistry?
    return Registered[Identifier]
end

function Scenes:Get(Name: string): SceneRegistry?
    for _, Scene in Registered do
        if Scene.Name == Name then
            return Scene
        end
    end

    return nil
end

-- Which scene a live copy came from.
function Scenes:GetInstanceScene(Instance_: SceneInstanceId): SceneIdentifier?
    return Objects:GetInstanceScene(Instance_)
end

-- The live copies of one scene, in no particular order.
function Scenes:GetInstances(Identifier: SceneIdentifier): {SceneInstanceId}
    const List = {}
    for _, Instance_ in Known do
        if Objects:GetInstanceScene(Instance_) == Identifier then
            table.insert(List, Instance_)
        end
    end

    return List
end

-- The objects the client holds for one live copy.
function Scenes:GetObjects(Instance_: SceneInstanceId): {any}
    return Objects:GetInstance(Instance_)
end

const function Register(Payload: SceneRegistry)
    Registered[Payload.Id] = Payload
end

-- Gone on the server. Its copies were dropped by their own packets first, so
-- there is nothing here but the registry entry -- which an editor listing the
-- scenes would otherwise keep drawing.
Network.SceneUnregistered:Connect(function(Identifier: SceneIdentifier)
    Registered[Identifier] = nil
end)

Network.SceneRegistered:Connect(Register)

Network.RegistriesReplayed:Connect(function(Payloads: {SceneRegistry})
    for _, Payload in Payloads do
        Register(Payload)
    end
end)

const function AddInstance(Instance_: SceneInstanceId, Scene: SceneIdentifier)
    Known[Instance_] = Instance_
    Objects.TrackInstance(Instance_, Scene)
end

Network.InstanceAdded:Connect(AddInstance)

Network.InstancesReplayed:Connect(function(Instances: {SceneInstanceId}, Scenes_: {SceneIdentifier})
    for Index, Instance_ in Instances do
        AddInstance(Instance_, Scenes_[Index])
    end
end)

-- One packet for a whole copy going away. Its objects are already gone on the
-- server and no ObjectRemoved is coming for any of them, so the client tears
-- down what it holds itself.
Network.InstanceRemoved:Connect(function(Instance_: SceneInstanceId)
    Known[Instance_] = nil
    Objects.DropInstance(Instance_)
end)

return Scenes
