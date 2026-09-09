--!strict
-- Named containers of objects, and the unit a level is saved and loaded as.
--
-- Before this there was one global workspace: every object the server had ever
-- made, alive for the session, with no way to put a level away without
-- destroying it object by object and no way to hand one to a DataStore.
--
-- A scene is either loaded -- objects live, replicated, instances parented
-- under its container -- or unloaded, in which case it is a single buffer and
-- costs nothing else.
--
-- Load makes one live copy, the canonical one, and that is what Serialize
-- describes. Instance makes extras from the same pack: every copy carries the
-- persistent ids the pack was written with and differs only in its objects'
-- runtime ids, which is what lets five identical rooms stand in the world at
-- once without any of them wondering which one it is.

const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const Registry = require("./Registry")
const Network = require("./Network")
const Handles = require("../Handles")
const IdPool = require("../IdPool")
const Logger = require("../Logger")
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
-- Instances
--=============================================================================

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

const function __instance_destroy(self: SceneInstance)
    const Owner = self.Owner
    if Owner then
        if Owner.Main == self then
            Owner.Main = nil
        end

        Owner.Instances[self.Id] = nil
    end

    Objects.DropInstance(self)
    Network.InstanceRemoved:FireAll(self.Id)
end

const function NewInstance(Owner: Scene, Container: Instance?, Canonical: boolean): SceneInstance
    InstanceCounter += 1

    const Instance_ = {}
    Instance_.Id = InstanceCounter
    Instance_.Scene = Owner.Id
    Instance_.Owner = Owner
    Instance_.Container = Container or Owner.Container
    Instance_.Canonical = Canonical
    Instance_.Objects = {}
    Instance_.ByLocal = {}

    Instance_.Find = __find
    Instance_.GetObjects = __instance_objects
    Instance_.Destroy = __instance_destroy

    Owner.Instances[Instance_.Id] = Instance_ :: any

    -- Announced before its objects, so a client is never handed an object
    -- belonging to an instance it has not been told about.
    Network.InstanceAdded:FireAll(Instance_.Id, Owner.Id)
    return Instance_ :: any
end

-- Rebuilds the objects a pack describes into an instance, under the ids they
-- were saved with, and announces them together.
const function Populate(Instance_: SceneInstance, Data: buffer?): boolean
    if not Data then
        return true
    end

    const Ok, LastId, Decompressed = pcall(function()
        return Compressor:DecompressScene(Data)
    end)

    if not Ok then
        Logger:Warn(`Failed to read the pack for scene {Instance_.Owner.Name}: {LastId}`)
        return false
    end

    -- Moved before anything is built, so a freshly created object cannot be
    -- handed an id one of the restored ones already answers to.
    Instance_.Owner.LastId = math.max(Instance_.Owner.LastId, LastId :: number)

    const Restored = {}
    for _, Object in Decompressed :: {any} do
        const Obj = Objects.restore(Instance_, Object, false)
        if Obj then
            table.insert(Restored, Obj)
        end
    end

    Objects.AnnounceAll(Restored)
    return true
end

--=============================================================================
-- Scenes
--=============================================================================

const function __create(self: Scene, Reference: any, InitialValues: {[number]: any}?): any
    const Main = self.Main
    if not Main then
        -- Deliberately not an implicit load: creating into an unloaded scene
        -- would have to decompress the whole thing first, which is not what a
        -- caller expecting to add one object is asking for.
        Logger:Warn(`Cannot create an object in scene {self.Name} while it is unloaded. Load it first.`)
        return nil
    end

    return Objects.new(Reference, InitialValues, Main)
end

const function __serialize(self: Scene): buffer
    const Main = self.Main
    if not Main then
        -- An unloaded scene is already its own pack. Nil only where one was
        -- registered unloaded and handed nothing, so answer an empty pack
        -- rather than a nil the caller has to check for.
        return self.Data or Compressor:CompressScene(self.LastId, {})
    end

    -- The canonical instance and only it. An extra instance is a disposable
    -- copy of this same pack, so serializing one would either say the same
    -- thing or quietly promote a throwaway to the saved truth.
    const List = Main:GetObjects()

    -- Sorted by local id so the same scene always produces the same bytes. Hash
    -- order would make two identical scenes serialize differently, which rules
    -- out diffing or deduplicating saves -- the same reason a single object's
    -- properties are written in id order.
    table.sort(List, function(A, B)
        return A.LocalId < B.LocalId
    end)

    return Compressor:CompressScene(self.LastId, List :: any)
end

const function __unload(self: Scene): boolean
    if not self.Loaded then
        return false
    end

    -- Written before anything is destroyed, or there would be nothing left to
    -- write.
    self.Data = __serialize(self)
    self.Loaded = false

    -- Every copy, not just the canonical one. Unloaded means the scene is not
    -- in the world, and leaving extras standing would leave objects alive whose
    -- scene claims to hold nothing.
    for _, Instance_ in table.clone(self.Instances) do
        Instance_:Destroy()
    end

    self.Main = nil
    return true
end

const function __load(self: Scene): boolean
    if self.Loaded then
        return false
    end

    const Main = NewInstance(self, nil, true)
    self.Main = Main
    self.Loaded = true

    if not Populate(Main, self.Data) then
        Main:Destroy()
        self.Loaded = false
        return false
    end

    self.Data = nil
    return true
end

const function __instance(self: Scene, Container: Instance?): SceneInstance?
    if not self.Loaded then
        Logger:Warn(`Cannot instance scene {self.Name} while it is unloaded. Load it first.`)
        return nil
    end

    -- Built from what the canonical instance holds right now rather than from
    -- the pack the scene was registered with: a caller asking for another copy
    -- of a room it has been editing means the room as it stands.
    const Instance_ = NewInstance(self, Container, false)
    if not Populate(Instance_, __serialize(self)) then
        Instance_:Destroy()
        return nil
    end

    return Instance_
end

const function __get_objects(self: Scene): {any}
    const Main = self.Main
    return if Main then Main:GetObjects() else {}
end

const function __destroy(self: Scene)
    __unload(self)

    Registry.ById[self.Id] = nil
    Registry.ByName[self.Name] = nil
    self.Data = nil

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
    Scene.Loaded = false
    Scene.LastId = 0
    Scene.Main = nil
    Scene.Instances = {}
    Scene.Data = nil

    Scene.Create = __create
    Scene.Load = __load
    Scene.Unload = __unload
    Scene.Instance = __instance
    Scene.Serialize = __serialize
    Scene.GetObjects = __get_objects
    Scene.Destroy = __destroy

    Registry.ById[Identifier] = Scene
    Registry.ByName[Config.Name] = Scene

    Network.SceneRegistered:FireAll(ToPayload(Scene :: any))

    -- A scene with nothing in it starts loaded: it is the one you can put
    -- objects in, and making a caller load an empty scene before using it would
    -- be ceremony with nothing behind it.
    __load(Scene :: any)
    return Scene :: any
end

-- Restores a scene from a pack, unloaded. Loading it is the caller's call,
-- which is what makes a menu of saved levels cheap: register them all, load the
-- one that gets picked.
function Scenes.fromBuffer(Config: SceneConfig, Data: buffer): Scene?
    const Scene = Scenes.new(Config)
    if not Scene then
        return nil
    end

    Scene:Unload()
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

-- Every live instance across every scene, which is what a joining player has to
-- be told about before any object reaches them.
function Scenes:GetInstances(): {SceneInstance}
    const List = {}
    for _, Scene in Registry.ById do
        for _, Instance_ in Scene.Instances do
            table.insert(List, Instance_)
        end
    end

    return List
end

-- The scene an object lands in when the caller names none, so Objects.new keeps
-- working exactly as it did before scenes existed. Registered here rather than
-- lazily, because Objects.new has to find it on the very first call.
Registry.Default = Scenes.new({Name = "Default"})

function Scenes:GetDefault(): Scene
    return Registry.Default
end

return Scenes
