--!strict
-- Two things live here, and they are not the same thing.
--
-- The client's view of the server's scenes is read only, and stays that way: it
-- is told which scenes exist, which copies of them are live, and which objects
-- belong to each copy. It cannot create one, load one or edit one -- editing a
-- server scene means asking, which is what a transaction is for.
--
-- A scene the client owns is the other half. It is the same document a server
-- scene is -- copies, packs, persistent ids, Commit -- except that nothing in
-- it replicates and nothing in it needs asking for. Its objects apply their own
-- edits on the spot, because there is nobody to ask and nothing to roll back
-- to. A prefab preview, a sandbox, a room being built before anyone else sees
-- it.
--
-- The two never collide. Server scene ids count up from one and local ones
-- count down from the top of the sixteen bit scene space, and the same for copy
-- ids, so a local scene can be filed beside a server one without either
-- shadowing the other. It costs nothing to keep them apart: a scene id is never
-- written into a pack -- only local ids are -- so a local id cannot leak into
-- anything durable even when a scene is handed to the server.
--
-- Objects are filed under their copy rather than their scene, because a scene
-- can be live more than once and an editor showing five identical rooms has to
-- be able to tell them apart.

const Compressor = require("../Compressor")
const Objects = require("../Objects/Client")
const Network = require("./Network")
const Handles = require("../Handles")
const Logger = require("../Logger")
const Types = require("./Types")

export type SceneIdentifier = Types.SceneIdentifier
export type SceneRegistry = Types.SceneRegistry
export type SceneConfig = Types.SceneConfig
export type SceneInstance = Types.SceneInstance
export type LocalScene = Types.LocalScene
export type SceneInstanceId = number

const Scenes = {}

--=============================================================================
-- The server's scenes
--=============================================================================

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

-- Which scene a live copy came from. Answers for a local copy too, which is
-- filed the same way.
function Scenes:GetInstanceScene(Instance_: SceneInstanceId): SceneIdentifier?
    return Objects:GetInstanceScene(Instance_)
end

-- The live copies of one of the server's scenes, in no particular order. A
-- local scene answers for its own through its GetInstances, because it holds
-- them itself.
function Scenes:GetInstances(Identifier: SceneIdentifier): {SceneInstanceId}
    const List = {}
    for _, Instance_ in Known do
        if Objects:GetInstanceScene(Instance_) == Identifier then
            table.insert(List, Instance_)
        end
    end

    return List
end

-- The objects the client holds for one live copy, local or not.
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

--=============================================================================
-- Scenes this client owns
--=============================================================================

const Owned: {[SceneIdentifier]: any} = {}
const OwnedByName: {[string]: any} = {}

-- Counted down from the top, where the server counts up from one. They meet
-- only if the two together exhaust the scene space, and a scene id is never
-- written into a pack in any case: only local ids are packed, and the scene
-- half is stamped on by whichever scene reads it. That is the same property
-- that makes one prefab loadable under two scenes, and it is what lets a local
-- pack be handed to the server and become a scene there with no remapping.
local NextSceneId = Handles.MAX_SCENE
local NextInstanceId = 4294967295

const function __create(self: SceneInstance, Reference: any, InitialValues: {[number]: any}?): any
    return Objects.new(Reference, InitialValues, self)
end

const function __find(self: SceneInstance, Local_: number): any
    return self.ByLocal[Local_]
end

const function __instance_objects(self: SceneInstance): {any}
    const List = {}
    for _, Obj in self.Objects do
        if not Obj.Destroyed then
            table.insert(List, Obj)
        end
    end

    return List
end

const function __instance_serialize(self: SceneInstance): buffer
    const List = __instance_objects(self)

    -- Sorted by local id so the same copy always produces the same bytes, for
    -- the same reason the server sorts: hash order would make two identical
    -- copies serialize differently, which rules out diffing, merging or
    -- deduplicating anything.
    table.sort(List, function(A, B)
        return A.LocalId < B.LocalId
    end)

    return Compressor:CompressScene(self.Owner.LastId, List :: any)
end

const function __commit(self: SceneInstance)
    self.Owner.Data = __instance_serialize(self)
end

const function __instance_unload(self: SceneInstance)
    const Owner = self.Owner
    if Owner then
        Owner.Instances[self.Id] = nil
    end

    -- Every object it held, torn down here rather than announced: nothing
    -- outside this client ever knew about them.
    Objects.DropInstance(self.Id)
    table.clear(self.Objects)
    table.clear(self.ByLocal)
end

const function NewInstance(Owner: any, Container: Instance?): SceneInstance
    if NextInstanceId <= 0 then
        Logger:Error("Local scene copy id space exhausted.")
    end

    const Instance_ = {}
    Instance_.Id = NextInstanceId
    NextInstanceId -= 1

    Instance_.Scene = Owner.Id
    Instance_.Owner = Owner
    Instance_.Container = Container or Owner.Container
    Instance_.Objects = {}
    Instance_.ByLocal = {}

    Instance_.Create = __create
    Instance_.Find = __find
    Instance_.GetObjects = __instance_objects
    Instance_.Serialize = __instance_serialize
    Instance_.Commit = __commit
    Instance_.Unload = __instance_unload

    Owner.Instances[Instance_.Id] = Instance_

    -- Filed the same way a replicated copy is, so an object of this copy can
    -- work out its own persistent identity and Objects:GetInstance answers for
    -- it like any other.
    Objects.TrackInstance(Instance_.Id, Owner.Id)
    return Instance_ :: any
end

const function __load(self: any, Container: Instance?): any
    const Instance_ = NewInstance(self, Container)

    const Data = self.Data
    if not Data then
        -- A scene that has never been committed. An empty copy is the right
        -- answer: it is the one you can now put objects in.
        return Instance_
    end

    const Ok, LastId, Decompressed = pcall(function()
        return Compressor:DecompressScene(Data)
    end)

    if not Ok then
        Logger:Warn(`Failed to read the pack for local scene {self.Name}: {LastId}`)
        Instance_:Unload()
        return nil
    end

    -- Moved before anything is built, so a freshly created object cannot be
    -- handed an id one of the restored ones already answers to.
    self.LastId = math.max(self.LastId, LastId :: number)

    for _, Object in Decompressed :: {any} do
        Objects.restore(Instance_, Object)
    end

    return Instance_
end

const function __unload(self: any)
    for _, Instance_ in table.clone(self.Instances) do
        Instance_:Unload()
    end
end

const function __serialize(self: any): buffer
    -- What the scene says it is, not what any copy currently holds. A copy that
    -- has drifted answers for itself through its own Serialize.
    return self.Data or Compressor:CompressScene(self.LastId, {})
end

const function __get_instances(self: any): {any}
    const List = {}
    for _, Instance_ in self.Instances do
        table.insert(List, Instance_)
    end

    return List
end

-- Hands the committed pack to the server, which registers a scene of its own
-- from it and answers with its id.
--
-- What it sends is what the scene says it is, so commit the copy you mean
-- first: a copy that has drifted is not the document. Nothing here becomes the
-- server's -- the local scene stays local and the two are separate documents
-- from that moment, which is also why pushing twice registers two scenes rather
-- than updating one.
--
-- Yields, and can be refused: the server checks that it may create every object
-- type in the pack before it takes any of it.
const function __push(self: any, Name: string): (boolean, SceneIdentifier?)
    const Data = __serialize(self)

    const Ok, Accepted, Identifier = pcall(function()
        return Network.Commit:Invoke(Name, Data)
    end)

    if not Ok then
        Logger:Warn(`A local scene was not committed to the server: {Accepted}`)
        return false, nil
    end

    if not Accepted then
        return false, nil
    end

    return true, Identifier
end

const function __destroy(self: any)
    -- Unloaded first, so the copies go as copies rather than being orphaned by
    -- a scene that has already stopped existing.
    __unload(self)

    Owned[self.Id] = nil
    OwnedByName[self.Name] = nil
    self.Data = nil
end

-- Registers a scene this client owns. Nothing about it reaches the server until
-- Push, and nothing about it reaches the rest of the world at all.
function Scenes.new(Config: SceneConfig): LocalScene?
    if OwnedByName[Config.Name] then
        Logger:Warn(`This client already owns a scene named {Config.Name}.`)
        return nil
    end

    if NextSceneId <= 0 then
        Logger:Error("Local scene id space exhausted.")
    end

    const Identifier = NextSceneId
    NextSceneId -= 1

    const Scene = {}
    Scene.Id = Identifier
    Scene.Name = Config.Name
    Scene.Container = Config.Container
    Scene.LastId = 0
    Scene.Data = nil
    Scene.Instances = {}

    Scene.Load = __load
    Scene.Unload = __unload
    Scene.Serialize = __serialize
    Scene.GetInstances = __get_instances
    Scene.Push = __push
    Scene.Destroy = __destroy

    Owned[Identifier] = Scene
    OwnedByName[Config.Name] = Scene

    return Scene :: any
end

-- Registers a local scene around a pack, which is how a prefab the server sent
-- down becomes something this client can load, look at and edit without anyone
-- else seeing it.
function Scenes.fromBuffer(Config: SceneConfig, Data: buffer): LocalScene?
    const Scene = Scenes.new(Config)
    if not Scene then
        return nil
    end

    const Document: any = Scene
    Document.Data = Data
    return Scene
end

function Scenes:GetLocal(Name: string): LocalScene?
    return OwnedByName[Name]
end

function Scenes:GetLocalById(Identifier: SceneIdentifier): LocalScene?
    return Owned[Identifier]
end

function Scenes:GetOwned(): {[SceneIdentifier]: LocalScene}
    return Owned
end

return Scenes
