--!strict
-- Named containers of objects, and the unit a level is saved and loaded as.
--
-- Before this there was one global workspace: every object the server had ever
-- made, alive for the session, with no way to put a level away without
-- destroying it object by object and no way to hand one to a DataStore.
--
-- A scene is either loaded -- its objects live, replicated, instances parented
-- under its container -- or unloaded, in which case it is a single buffer and
-- costs nothing else. Load and unload move between the two.

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
export type Scene = Types.Scene

const Scenes = {}

-- Never recycled, and the reason is the whole identity scheme: an object's
-- handle carries its scene id, so handing id 3 to a different scene later makes
-- every saved handle that names scene 3 point into the wrong one.
const Ids = IdPool.new(Handles.MAX_SCENE, false)

const function ToPayload(Scene: Scene): SceneRegistry
    return {
        Id = Scene.Id,
        Name = Scene.Name,
    }
end

const function __create(
    self: Scene,
    Reference: any,
    InitialValues: {[number]: any}?
): any
    if not self.Loaded then
        -- Deliberately not an implicit load: creating into an unloaded scene
        -- would have to decompress the whole thing first, which is not what a
        -- caller expecting to add one object is asking for.
        Logger:Warn(`Cannot create an object in scene {self.Name} while it is unloaded. Load it first.`)
        return nil
    end

    return Objects.new(Reference, InitialValues, self)
end

const function __serialize(self: Scene): buffer
    if not self.Loaded then
        -- An unloaded scene is already its own pack. Nil only where one was
        -- registered unloaded and handed nothing, so answer an empty pack
        -- rather than a nil the caller has to check for.
        return self.Data or Compressor:CompressScene(self.LastId, {})
    end

    const List = {}
    for _, Obj in self.Objects do
        if not Obj.Destroyed then
            table.insert(List, Obj)
        end
    end

    -- Sorted by local id so the same scene always produces the same bytes.
    -- Hash order would make two identical scenes serialize differently, which
    -- rules out diffing or deduplicating saves -- the same reason a single
    -- object's properties are written in id order.
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

    Objects.DropScene(self)
    Network.SceneUnloaded:FireAll(self.Id)
    return true
end

const function __load(self: Scene): boolean
    if self.Loaded then
        return false
    end

    self.Loaded = true

    const Data = self.Data
    if not Data then
        -- A scene that has never held anything. Loaded is still the right
        -- state: it is now the one you can create objects in.
        return true
    end

    const Ok, LastId, Decompressed = pcall(function()
        return Compressor:DecompressScene(Data)
    end)

    if not Ok then
        self.Loaded = false
        Logger:Warn(`Failed to load scene {self.Name}: {LastId}`)
        return false
    end

    -- Restored before the counter moves, so an object cannot be handed an id a
    -- saved one already answers to.
    self.LastId = math.max(self.LastId, LastId :: number)

    const Restored = {}
    for _, Object in Decompressed :: {any} do
        const Obj = Objects.restore(self, Object, false)
        if Obj then
            table.insert(Restored, Obj)
        end
    end

    self.Data = nil
    Objects.AnnounceAll(Restored)
    return true
end

const function __get_objects(self: Scene): {any}
    const List = {}
    for _, Obj in self.Objects do
        if not Obj.Destroyed then
            table.insert(List, Obj)
        end
    end

    return List
end

const function __destroy(self: Scene)
    if self.Loaded then
        __unload(self)
    end

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
    Scene.Loaded = true
    Scene.LastId = 0
    Scene.Objects = {}
    Scene.Data = nil

    Scene.Create = __create
    Scene.Load = __load
    Scene.Unload = __unload
    Scene.Serialize = __serialize
    Scene.GetObjects = __get_objects
    Scene.Destroy = __destroy

    Registry.ById[Identifier] = Scene
    Registry.ByName[Config.Name] = Scene

    Network.SceneRegistered:FireAll(ToPayload(Scene :: any))
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

    Scene.Loaded = false
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

-- The scene an object lands in when the caller names none, so Objects.new keeps
-- working exactly as it did before scenes existed. Registered here rather than
-- lazily, because Objects.new has to find it on the very first call.
Registry.Default = Scenes.new({Name = "Default"})

function Scenes:GetDefault(): Scene
    return Registry.Default
end

return Scenes
