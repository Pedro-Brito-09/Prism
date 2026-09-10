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

const Permissions = require("../Permissions/Server")
const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const Registry = require("./Registry")
const Audience = require("./Audience")
const World = require("../World")
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
export type Scene = Types.ServerScene

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
-- Who hears about a scene
--=============================================================================

-- Scene registries per packet when several are revealed at once, as at a join.
const REGISTRY_CHUNK = 50

-- Sends one player whatever they are owed of some scenes and do not yet hold.
-- Every player is owed a scene's copies and the objects that replicate to
-- everyone; an admitted player is owed its name and the rest of its objects as
-- well. The names and copies go out before anything yields, so from the moment
-- the player holds a scene at a reach there is nothing a broadcast at that
-- reach could name that they have not already been handed. The objects stream
-- after, and stop for any scene withdrawn from the player part way through.
const function Reveal(Plr: Player, List: {Scene})
    const Tokens: {[SceneIdentifier]: {[string]: number}} = {}
    const Payloads: {SceneRegistry} = {}
    const CopyIds: {number} = {}
    const CopyScenes: {SceneIdentifier} = {}
    const Held: {any} = {}

    for _, Scene in List do
        if Registry.ById[Scene.Id] ~= Scene then
            continue
        end

        const Glimpse = not Audience.Holds(Plr, Scene.Id, "Everyone")
        const Whole = Audience.Sees(Plr, Scene.Id) and not Audience.Holds(Plr, Scene.Id, "Admitted")

        if not Glimpse and not Whole then
            continue
        end

        -- Everyone before Admitted, which is only ever held on top of it.
        const Taken: {[string]: number} = {}
        Tokens[Scene.Id] = Taken

        if Glimpse then
            Taken.Everyone = Audience.Remember(Plr, Scene.Id, "Everyone")
        end

        if Whole then
            Taken.Admitted = Audience.Remember(Plr, Scene.Id, "Admitted")
            table.insert(Payloads, ToPayload(Scene))
        end

        for _, Copy in Scene.Instances do
            if Glimpse then
                table.insert(CopyIds, Copy.Id)
                table.insert(CopyScenes, Scene.Id)
            end

            for _, Obj in Copy.Objects do
                if Taken[Objects.ReachOf(Obj)] then
                    table.insert(Held, Obj)
                end
            end
        end
    end

    if #Payloads == 1 then
        Network.SceneRegistered:Fire(Plr, Payloads[1])
    else
        for Start = 1, #Payloads, REGISTRY_CHUNK do
            const Stop = math.min(Start + REGISTRY_CHUNK - 1, #Payloads)
            Network.RegistriesReplayed:Fire(Plr, table.move(Payloads, Start, Stop, 1, {}))
        end
    end

    if #CopyIds > 0 then
        Network.InstancesReplayed:Fire(Plr, CopyIds, CopyScenes)
    end

    Objects.Stream(Plr, Held, function(Obj: any): boolean
        const Reach = Objects.ReachOf(Obj)
        return Audience.Holds(Plr, Obj.Scene, Reach, Tokens[Obj.Scene][Reach])
    end)
end

-- Admission taken away. The scene's name goes, and so does every object kept
-- for the admitted; its copies and the objects that replicate to everyone stay,
-- because every player is owed those. The removals stream, and stop if the
-- player is admitted again before they are through: the reveal that follows is
-- sending those objects back, and a late removal would take one of them away.
const function Withdraw(Plr: Player, Scene: Scene)
    if not Audience.Holds(Plr, Scene.Id, "Admitted") then
        return
    end

    Audience.Forget(Plr, Scene.Id, "Admitted")
    Network.SceneUnregistered:Fire(Plr, Scene.Id)

    const Kept = {}
    for _, Copy in Scene.Instances do
        for _, Obj in Copy.Objects do
            if not Obj.Destroyed and Objects.ReachOf(Obj) == "Admitted" then
                table.insert(Kept, Obj.RuntimeId)
            end
        end
    end

    Objects.Unsend(Plr, Kept, function(): boolean
        return not Audience.Holds(Plr, Scene.Id, "Admitted")
    end)
end

-- Brings what one player holds of one scene into line with whether they are
-- admitted to it. Both directions yield as they stream, so each gets a thread
-- of its own -- which task.spawn only hands back after the part that must land
-- first is out, because nothing before it yields.
const function Settle(Plr: Player, Scene: Scene)
    const Sees = Audience.Sees(Plr, Scene.Id)
    const Admitted = Audience.Holds(Plr, Scene.Id, "Admitted")

    if not Audience.Holds(Plr, Scene.Id, "Everyone") or (Sees and not Admitted) then
        task.spawn(Reveal, Plr, {Scene})
    elseif Admitted and not Sees then
        task.spawn(Withdraw, Plr, Scene)
    end
end

-- Every player past their join, after a scene appears or its admission list
-- changes. A player still joining is left alone: their replay settles every
-- scene once it is through, and a scene revealed to them now could reach them
-- ahead of the object types its objects need.
const function Reconcile(Scene: Scene)
    for _, Plr in Audience.GetSynced() do
        Settle(Plr, Scene)
    end
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

    -- The folder goes after its objects, so nothing is left holding a
    -- reference to an instance that is already gone.
    World.DropCopy(self.Scene, self.Folder)
    Audience.Fire(Network.InstanceRemoved, self.Scene, "Everyone", self.Id)
end

const function NewInstance(Owner: Scene, Parent: Instance?): SceneInstance
    InstanceCounter += 1

    const Instance_ = {}
    Instance_.Id = InstanceCounter
    Instance_.Scene = Owner.Id
    Instance_.Owner = Owner
    Instance_.Folder = World.Copy(Owner.Id, Instance_.Id, Parent)
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
    -- To every player, not only the admitted: an object that replicates to
    -- everyone has to be filed under its copy, and this is the copy. It says a
    -- copy of some scene exists, and nothing more.
    Audience.Fire(Network.InstanceAdded, Owner.Id, "Everyone", Instance_.Id, Owner.Id)
    return Instance_ :: any
end

--=============================================================================
-- Scenes
--=============================================================================

const function __load(self: Scene, Parent: Instance?): any
    const Instance_ = NewInstance(self, Parent)

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

    -- To whoever was told its name, after which nobody holds it at all. Its
    -- copies went to everyone already, one packet each, as they unloaded.
    Audience.Fire(Network.SceneUnregistered, self.Id, "Admitted", self.Id)
    Audience.ForgetScene(self.Id)

    -- The id is not released: see the pool above.
end

-- Admitting someone to a public scene makes it private, and everyone else
-- present is told it is gone. Evicting the last makes it public again, and
-- everyone is told about it -- the evicted included, because an empty list
-- means public. Admit the next person before evicting the last to keep a scene
-- closed while its list changes hands.
const function __admit(self: Scene, Who: Player | number)
    const UserId = Audience.Resolve(Who)
    if not UserId then
        Logger:Warn(`Scene {self.Name} admits a Player or a user id, not a {typeof(Who)}.`)
        return
    end

    if self.Admitted[UserId] then
        return
    end

    self.Admitted[UserId] = true
    Reconcile(self)
end

const function __evict(self: Scene, Who: Player | number)
    const UserId = Audience.Resolve(Who)
    if not UserId then
        Logger:Warn(`Scene {self.Name} evicts a Player or a user id, not a {typeof(Who)}.`)
        return
    end

    if not self.Admitted[UserId] then
        return
    end

    self.Admitted[UserId] = nil
    Reconcile(self)
end

const function __admits(self: Scene, Who: Player | number): boolean
    const UserId = Audience.Resolve(Who)
    return UserId ~= nil and (next(self.Admitted) == nil or self.Admitted[UserId] == true)
end

const function __get_admitted(self: Scene): {number}
    const List = {}
    for UserId in self.Admitted do
        table.insert(List, UserId)
    end

    return List
end

const function __is_public(self: Scene): boolean
    return next(self.Admitted) == nil
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
    Scene.LastId = 0
    Scene.Data = nil
    Scene.Instances = {}

    -- Filled before the scene is announced, so a scene that should never be
    -- public never is, not even for the packet that registers it.
    Scene.Admitted = {}
    for _, Who in Config.Admitted or {} do
        const UserId = Audience.Resolve(Who)
        if UserId then
            Scene.Admitted[UserId] = true
        else
            Logger:Warn(`Scene {Config.Name} admits a Player or a user id, not a {typeof(Who)}.`)
        end
    end

    Scene.Load = __load
    Scene.Unload = __unload
    Scene.Serialize = __serialize
    Scene.GetInstances = __get_instances
    Scene.Destroy = __destroy
    Scene.Admit = __admit
    Scene.Evict = __evict
    Scene.Admits = __admits
    Scene.GetAdmitted = __get_admitted
    Scene.IsPublic = __is_public

    Registry.ById[Identifier] = Scene
    Registry.ByName[Config.Name] = Scene

    -- Told to whoever it admits, which for a scene with no list is everyone.
    Reconcile(Scene :: any)
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

-- The scene half of a join, called by Replication once the player has every
-- property and object type. Every scene is revealed at once, each as far as
-- the player is owed, so the names and copies share packets. Then the player
-- counts as synced, and whatever changed while this streamed -- a scene
-- registered, an admission granted or taken -- is settled against what they
-- were actually sent.
function Scenes.Catchup(Plr: Player)
    const All = {}
    for _, Scene in Registry.ById do
        table.insert(All, Scene)
    end

    Reveal(Plr, All)

    if not Plr.Parent then
        return
    end

    Audience.MarkSynced(Plr)

    for _, Scene in Registry.ById do
        Settle(Plr, Scene)
    end
end

--=============================================================================
-- Commits from a client
--=============================================================================

-- What one commit may carry. The byte cap is what actually bounds the work --
-- decoding walks the buffer and does nothing else until it is through -- and
-- the object cap is what stops a well formed pack of a hundred thousand
-- objects becoming a scene nobody asked for. The name cap is only there so a
-- registry key cannot be a novel.
const MAX_COMMIT_BYTES = 524288
const MAX_COMMIT_OBJECTS = 4096
const MAX_NAME_LENGTH = 64

-- A client handing over a scene it built locally. Refusals are silent and say
-- nothing but false, like every other client facing handler here: a refusal
-- that logs is a refusal a client can spam to fill the server's output.
Network.Commit.OnInvoke = function(Plr: Player, Name: string, Data: buffer): (boolean, SceneIdentifier)
    -- One action for the packet rather than one per object in it. A transaction
    -- charges per operation because every operation reaches into the world as
    -- it stands; this arrives whole, and what bounds it is its size, which is
    -- known before a byte of it is read.
    if not Permissions:Consume(Plr) then
        return false, 0
    end

    if buffer.len(Data) > MAX_COMMIT_BYTES then
        return false, 0
    end

    if #Name == 0 or #Name > MAX_NAME_LENGTH then
        return false, 0
    end

    -- Names are how a scene is asked for, so the first one to take a name keeps
    -- it. Refused here as well as in Scenes.new so the pack is not decoded for
    -- a commit that cannot land anyway.
    if Registry.ByName[Name] then
        return false, 0
    end

    const Ok, _, Decompressed = pcall(function()
        return Compressor:DecompressScene(Data)
    end)

    if not Ok or not Decompressed then
        return false, 0
    end

    const Packed = Decompressed :: {any}
    if #Packed > MAX_COMMIT_OBJECTS then
        return false, 0
    end

    -- Every object type in the pack, checked once each rather than once per
    -- object, and the whole commit refused if any one of them is denied. A
    -- scene arriving with half its objects dropped is not the scene that was
    -- sent, and the client would have no way to tell.
    const Seen: {[number]: true} = {}
    local Highest = 0

    for _, Object in Packed do
        if not Objects:GetRegistry(Object.Parent) then
            return false, 0
        end

        if not Seen[Object.Parent] then
            Seen[Object.Parent] = true

            if not Permissions:Can(Plr, "Create", Object.Parent) then
                return false, 0
            end
        end

        Highest = math.max(Highest, Object.LocalId)
    end

    -- Re-encoded rather than kept as it arrived, so the pack the server holds
    -- is the one the server wrote. Its LastId is the highest id actually in it
    -- rather than whatever the client claimed -- a pack declaring an id space
    -- already spent would otherwise give the scene room for nothing.
    const Scene = Scenes.fromBuffer({Name = Name}, Compressor:CompressScene(Highest, Packed))
    if not Scene then
        return false, 0
    end

    return true, Scene.Id
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
