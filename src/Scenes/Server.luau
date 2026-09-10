--!strict
-- Named sets of objects, and the unit a level is saved and loaded as.
--
-- Before this there was one global workspace: every object the server had ever
-- made, alive for the session, with no way to put a level away without
-- destroying it object by object and no way to hand one to a DataStore.
--
-- A scene is a document. Registering one creates data and nothing else; Load
-- reads it into a live copy. Load twice and you get two copies, equals in every
-- way, which is what lets one saved room stand in the world five times. There
-- is no canonical copy and no loaded flag, because a scene is not a thing that
-- is either in the world or not -- it is a thing the world can hold copies of.
--
-- Objects therefore live on the copy, not on the scene. Asking a scene loaded
-- twice for "the object with local id 4" has no answer; asking a copy does.

const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const Registry = require("./Registry")
const Network = require("./Network")
const Handles = require("../Handles")
const IdPool = require("../IdPool")
const Logger = require("../Logger")
const ObjectTypes = require("../Objects/Types")
const Types = require("./Types")

export type SceneIdentifier = Types.SceneIdentifier
export type SceneConfig = Types.SceneConfig
export type SceneRegistry = Types.SceneRegistry
export type SceneInstance = Types.SceneInstance
export type Scene = Types.Scene

const Scenes = {}

-- Never recycled, and the reason is the persistent identity itself: an object's
-- saved id carries its scene, so handing id 3 to a different scene later makes
-- every pack that names scene 3 decode as the wrong thing.
const Ids = IdPool.new(Handles.MAX_SCENE, false)

-- Instance ids are the opposite: they name a live copy, never leave the
-- session, and there is no saved data for a reused one to confuse.
local InstanceCounter = 0

const function ToPayload(Scene: Scene): SceneRegistry
    return {
        Id = Scene.Id,
        Name = Scene.Name,
    }
end

--=============================================================================
-- Live copies
--=============================================================================

const function __create(self: SceneInstance, Reference: any, InitialValues: {[number]: any}?): any
    return Objects.new(Reference, InitialValues, self)
end

const function __find(self: SceneInstance, Local: number): any
    return self.ByLocal[Local]
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

    -- Sorted by local id so the same copy always produces the same bytes. Hash
    -- order would make two identical copies serialize differently, which rules
    -- out diffing, merging or deduplicating saves -- the same reason a single
    -- object's properties are written in id order.
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

    Registry.Instances[self.Id] = nil

    Objects.DropInstance(self)
    Network.InstanceRemoved:FireAll(self.Id)
end

const function NewInstance(Owner: Scene, Container: Instance?): SceneInstance
    InstanceCounter += 1

    const Instance_ = {}
    Instance_.Id = InstanceCounter
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

    Owner.Instances[Instance_.Id] = Instance_ :: any
    Registry.Instances[Instance_.Id] = Instance_

    -- Announced before its objects, so a client is never handed an object
    -- belonging to a copy it has not been told about.
    Network.InstanceAdded:FireAll(Instance_.Id, Owner.Id)
    return Instance_ :: any
end

--=============================================================================
-- Scenes
--=============================================================================

const function __load(self: Scene, Container: Instance?): any
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
        Logger:Warn(`Failed to read the pack for scene {self.Name}: {LastId}`)
        Instance_:Unload()
        return nil
    end

    -- Moved before anything is built, so a freshly created object cannot be
    -- handed an id one of the restored ones already answers to.
    self.LastId = math.max(self.LastId, LastId :: number)

    const Restored = {}
    for _, Object in Decompressed :: {any} do
        const Obj = Objects.restore(Instance_, Object, false)
        if Obj then
            table.insert(Restored, Obj)
        end
    end

    Objects.AnnounceAll(Restored)
    return Instance_
end

-- Every copy at once. Nothing is written back: with more than one copy live,
-- saving on unload would have to pick one and cannot, so committing is the
-- copy's own call and always explicit.
const function __unload(self: Scene)
    for _, Instance_ in table.clone(self.Instances) do
        Instance_:Unload()
    end
end

const function __serialize(self: Scene): buffer
    -- What the scene says it is, not what any copy currently holds. A copy that
    -- has drifted answers for itself through its own Serialize.
    return self.Data or Compressor:CompressScene(self.LastId, {})
end

const function __get_instances(self: Scene): {any}
    const List = {}
    for _, Instance_ in self.Instances do
        table.insert(List, Instance_)
    end

    return List
end

const function __destroy(self: Scene)
    -- Unloaded first, so the copies go as copies rather than being orphaned by
    -- a scene that has already stopped existing.
    __unload(self)

    Registry.ById[self.Id] = nil
    Registry.ByName[self.Name] = nil
    self.Data = nil

    Network.SceneUnregistered:FireAll(self.Id)

    -- The id is not released: see the pool above.
end

-- Names have to be unique as well as ids. A name is how a caller asks for a
-- scene back, and two scenes answering to "Lobby" means one of them is
-- unreachable and which one depends on registration order.
function Scenes.new(Config: SceneConfig): Scene?
    if Registry.ByName[Config.Name] then
        Logger:Warn(`There's already a scene named {Config.Name}.`)
        return nil
    end

    const Requested = if Config.CustomId ~= nil
        then IdPool.Normalize(Config.CustomId, "scene", Handles.MAX_SCENE)
        else nil

    const Identifier = Ids:Claim(Requested)
    if not Identifier then
        Logger:Warn(`There's already a scene registered with id {Requested}.`)
        return nil
    end

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
    Scene.Destroy = __destroy

    Registry.ById[Identifier] = Scene
    Registry.ByName[Config.Name] = Scene

    Network.SceneRegistered:FireAll(ToPayload(Scene :: any))
    return Scene :: any
end

-- Registers a scene around a pack someone stored earlier. Nothing goes live
-- until Load, which is what makes a menu of saved levels cheap: register them
-- all, load the one that gets picked.
function Scenes.fromBuffer(Config: SceneConfig, Data: buffer): Scene?
    const Scene = Scenes.new(Config)
    if not Scene then
        return nil
    end

    Scene.Data = Data
    return Scene
end

function Scenes:Get(Name: string): Scene?
    return Registry.ByName[Name]
end

function Scenes:GetById(Identifier: SceneIdentifier): Scene?
    return Registry.ById[Identifier]
end

function Scenes:GetRegistered(): {[SceneIdentifier]: Scene}
    return Registry.ById
end

function Scenes:GetRegistryPayload(Identifier: SceneIdentifier): SceneRegistry?
    const Scene = Registry.ById[Identifier]
    return if Scene then ToPayload(Scene) else nil
end

-- Every live copy across every scene, which is what a joining player has to be
-- told about before any object reaches them.
function Scenes:GetInstances(): {SceneInstance}
    const List = {}
    for _, Instance_ in Registry.Instances do
        table.insert(List, Instance_)
    end

    return List
end

-- One live copy by its own id. The id names a copy rather than a scene, so this
-- answers for a caller holding one off an object or off the wire without having
-- to know which scene it belongs to first.
function Scenes:GetInstance(Identifier: ObjectTypes.SceneInstanceId): SceneInstance?
    return Registry.Instances[Identifier]
end

-- The scene an object lands in when the caller names none, so Objects.new keeps
-- working exactly as it did before scenes existed. Registered here, but not
-- loaded: Objects loads it the first time something actually needs it, so a
-- game that puts everything in its own scenes never pays for this one.
Registry.Default = Scenes.new({Name = "Default"})

function Scenes:GetDefault(): Scene
    return Registry.Default
end

return Scenes
