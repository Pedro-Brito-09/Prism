--!strict
-- The client's view of the server's scenes.
--
-- Read only at this stage: the client is told which scenes exist and which
-- objects belong to them, and can ask, but cannot create one or load one. A
-- scene the client owns outright -- a prefab preview, a local sandbox the
-- server never sees -- is a separate mechanism and comes later.

const Objects = require("../Objects/Client")
const Network = require("./Network")
const Types = require("./Types")

export type SceneIdentifier = Types.SceneIdentifier
export type SceneRegistry = Types.SceneRegistry

const Scenes = {}
const Registered: {[SceneIdentifier]: SceneRegistry} = {}

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

-- The objects the client currently holds for a scene. Answers for an unloaded
-- one too, with an empty list, rather than refusing: the client does not track
-- loaded state, it tracks what it has been sent.
function Scenes:GetObjects(Identifier: SceneIdentifier): {any}
    return Objects:GetScene(Identifier)
end

const function Register(Payload: SceneRegistry)
    Registered[Payload.Id] = Payload
end

Network.SceneRegistered:Connect(Register)

Network.RegistriesReplayed:Connect(function(Payloads: {SceneRegistry})
    for _, Payload in Payloads do
        Register(Payload)
    end
end)

-- One packet for the whole scene. The objects are already gone on the server
-- and no ObjectRemoved is coming for any of them, so the client tears down what
-- it holds for that scene itself.
Network.SceneUnloaded:Connect(function(Identifier: SceneIdentifier)
    Objects.DropScene(Identifier)
end)

return Scenes
