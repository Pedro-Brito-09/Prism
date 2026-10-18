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
const ObjectShared = require("../Objects/Shared")
const World = require("../World")
const Network = require("./Network")
const Handles = require("../Handles")
const Logger = require("../Logger")
const Listeners = require("../Listeners")
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

-- The folder this client draws each opened copy into. A loaded copy has none:
-- its parts are the server's, in the server's folder.
const Folders: {[SceneInstanceId]: Folder} = {}

-- Plain listener lists, the way Properties and Selection keep theirs.
const CopyAdded: {(Copy: SceneInstanceId, Scene: SceneIdentifier, Folder: Folder?) -> ()} = {}
const CopyRemoved: {(Copy: SceneInstanceId, Scene: SceneIdentifier) -> ()} = {}

const Watch = Listeners.Watch
const Notify = Listeners.Notify

-- A copy of one of the server's scenes appearing here. Folder is where this
-- client draws the copy when the server opened it, and nil when the server
-- loaded it and the parts are its own. Reparent the folder to put the copy
-- somewhere else -- into PlayerGui, for a scene made of interfaces -- and
-- everything drawn in it goes along. Copies already here when this connects
-- are not replayed to it.
function Scenes:OnCopyAdded(Callback: (Copy: SceneInstanceId, Scene: SceneIdentifier, Folder: Folder?) -> ()): () -> ()
    return Watch(CopyAdded, Callback, "copies appearing")
end

function Scenes:OnCopyRemoved(Callback: (Copy: SceneInstanceId, Scene: SceneIdentifier) -> ()): () -> ()
    return Watch(CopyRemoved, Callback, "copies going")
end

-- The folder this client draws an opened copy into, or nil for a copy the
-- server loaded.
function Scenes:GetFolder(Copy: SceneInstanceId): Folder?
    return Folders[Copy]
end

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

    -- Who holds what is told to the admitted, and this player no longer is:
    -- whatever they still have of the scene, they stop being told its locks.
    Objects.ForgetLocks(Identifier)
end)

Network.SceneRegistered:Connect(Register)

Network.RegistriesReplayed:Connect(function(Payloads: {SceneRegistry})
    for _, Payload in Payloads do
        Register(Payload)
    end
end)

const function AddInstance(Instance_: SceneInstanceId, Scene: SceneIdentifier, Opened: boolean)
    Known[Instance_] = Instance_

    -- An opened copy has no parts on the server, so this client draws it, into
    -- a folder of its own built where the server builds one for a copy it
    -- loads. Built before the copy is filed, because its objects are drawn
    -- into it the moment they arrive.
    local Folder = Folders[Instance_]
    if Opened and not Folder then
        Folder = World.Copy(Scene, Instance_, nil)
        Folders[Instance_] = Folder
    end

    Objects.TrackInstance(Instance_, Scene, if Opened then Folder else nil, false)
    Notify(CopyAdded, Instance_, Scene, if Opened then Folder else nil)
end

Network.InstanceAdded:Connect(AddInstance)

Network.InstancesReplayed:Connect(function(Instances: {SceneInstanceId}, Scenes_: {SceneIdentifier}, Opened: {boolean})
    for Index, Instance_ in Instances do
        AddInstance(Instance_, Scenes_[Index], Opened[Index] == true)
    end
end)

-- One packet for a whole copy going away. Its objects are already gone on the
-- server and no ObjectRemoved is coming for any of them, so the client tears
-- down what it holds itself -- and, for a copy it was drawing, the folder it
-- drew into.
Network.InstanceRemoved:Connect(function(Instance_: SceneInstanceId)
    const Scene = Objects:GetInstanceScene(Instance_)

    Known[Instance_] = nil
    Objects.DropInstance(Instance_)

    const Folder = Folders[Instance_]
    if Folder then
        Folders[Instance_] = nil
        World.DropCopy(Scene or 0, Folder)
    end

    if Scene then
        Notify(CopyRemoved, Instance_, Scene)
    end
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

-- A pack read into this copy rather than into a copy of its own. The server's
-- twin -- see Scenes/Server, which explains why the references cannot simply be
-- carried across -- with nothing to announce, because a scene this client owns
-- replicates to nobody.
const function __place(self: SceneInstance, Pack: buffer): any
    const Ok, _, Decompressed = pcall(function()
        return Compressor:DecompressScene(Pack)
    end)

    if not Ok or not Decompressed then
        Logger:Warn(`Failed to read a pack being placed into a copy of {self.Owner.Name}.`)
        return nil
    end

    const Made = {}
    const Placed: {[number]: any} = {}
    const Pending: {{Object: any, References: {[number]: any}}} = {}

    for _, Saved in Decompressed :: {any} do
        if not Objects:GetRegistry(Saved.Registry) then
            Logger:Warn(`Skipped an object while placing a pack: object type {Saved.Registry} is not registered.`)
            continue
        end

        const Values, References = ObjectShared.SplitReferences(Saved.Properties)
        const Obj = Objects.new(Saved.Registry, Values, self)

        table.insert(Made, Obj)
        Placed[Saved.LocalId] = Obj

        if References then
            table.insert(Pending, {Object = Obj, References = References})
        end
    end

    for _, Entry in Pending do
        for PropertyId, Saved in Entry.References do
            const Prop = Entry.Object.Properties[PropertyId]
            const Target = Placed[Saved]

            if Prop and Target then
                Prop:Set(Target.LocalId)
            end
        end
    end

    return Made
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
    const List: {any} = __instance_objects(self)

    -- Objects of a type this build does not have, back in beside the rest.
    for _, Kept in (self :: any).Unknown do
        table.insert(List, Kept)
    end

    -- Sorted by local id so the same copy always produces the same bytes, for
    -- the same reason the server sorts: hash order would make two identical
    -- copies serialize differently, which rules out diffing, merging or
    -- deduplicating anything.
    table.sort(List, function(A, B)
        return A.LocalId < B.LocalId
    end)

    -- Each kept record as the bytes it was read from, untouched.
    for Index, Entry in List do
        if Entry.__type == "DecompressedObject" then
            List[Index] = Entry.Source
        end
    end

    return Compressor:CompressScene(self.Owner.LastId, List :: any)
end

const function __commit(self: SceneInstance)
    self.Owner.Data = __instance_serialize(self)
end

-- A copy withdrawn from the world rather than unloaded, and kept whole. The
-- server's twin; see Scenes/Server for why a player asking for a copy to go
-- gets this rather than the real thing. Nothing is announced, because nothing
-- in a scene this client owns ever is.
local FinishReading: (Instance_: any) -> ()

const function __instance_suspend(self: any): boolean
    if self.Suspended then
        return false
    end

    const Owner = self.Owner
    if not Owner or Owner.Instances[self.Id] ~= self then
        return false
    end

    -- Still being read: the rest is read now, as on the server, so what comes
    -- back is the whole copy.
    FinishReading(self)

    self.Suspended = Objects.SuspendInstance(self.Id)
    Owner.Instances[self.Id] = nil

    if self.Folder then
        self.Parent = self.Folder.Parent
        self.Folder.Parent = nil
    end

    Notify(CopyRemoved, self.Id, self.Scene)
    return true
end

const function __instance_revive(self: any): boolean
    const Held = self.Suspended
    if not Held then
        return false
    end

    const Owner = self.Owner
    if not Owner or not Owned[self.Scene] then
        -- Its scene has been destroyed while it was away.
        return false
    end

    self.Suspended = nil
    Owner.Instances[self.Id] = self

    if self.Folder then
        World.Place(self.Folder, self.Scene, self.Parent)
        self.Parent = nil
    end

    -- Filed before its objects, which file themselves back into it, and told
    -- before them for the reason a load tells of its copy first.
    Notify(CopyAdded, self.Id, self.Scene, nil)
    Objects.ReviveInstance(Held)
    return true
end

const function __instance_dispose(self: any)
    const Held = self.Suspended
    if not Held then
        return
    end

    self.Suspended = nil
    Objects.DisposeInstance(Held)

    if self.Folder then
        self.Folder:Destroy()
        self.Folder = nil
    end
end

const function __instance_unload(self: SceneInstance)
    const Owner = self.Owner
    if Owner then
        Owner.Instances[self.Id] = nil
    end

    -- Every object it held, torn down here rather than announced: nothing
    -- outside this client ever knew about them.
    Objects.DropInstance(self.Id)
    World.DropCopy(self.Scene, self.Folder)
    table.clear(self.Objects)
    table.clear(self.ByLocal)
end

const function NewInstance(Owner: any, Parent: Instance?): SceneInstance
    if NextInstanceId <= 0 then
        Logger:Error("Local scene copy id space exhausted.")
    end

    const Instance_ = {}
    Instance_.Id = NextInstanceId
    NextInstanceId -= 1

    Instance_.Scene = Owner.Id
    Instance_.Owner = Owner
    Instance_.Opened = false

    -- The same tree the server's copies default into, built locally. A local
    -- scene's ids count down from the top of the space while the server's count
    -- up, so a folder of this client's cannot be mistaken for one of the
    -- server's -- and a client editing interfaces hands PlayerGui to Load and
    -- never touches the workspace at all.
    Instance_.Folder = World.Copy(Owner.Id, Instance_.Id, Parent)
    Instance_.Objects = {}
    Instance_.ByLocal = {}

    -- Decoded records of objects whose type is not registered. See __load.
    Instance_.Unknown = {}

    Instance_.Create = __create
    Instance_.Place = __place
    Instance_.Find = __find
    Instance_.GetObjects = __instance_objects
    Instance_.Serialize = __instance_serialize
    Instance_.Commit = __commit
    Instance_.Unload = __instance_unload
    Instance_.Suspend = __instance_suspend
    Instance_.Revive = __instance_revive
    Instance_.Dispose = __instance_dispose

    Owner.Instances[Instance_.Id] = Instance_

    -- Filed the same way a replicated copy is, so an object of this copy can
    -- work out its own persistent identity and Objects:GetInstance answers for
    -- it like any other.
    Objects.TrackInstance(Instance_.Id, Owner.Id, nil, true)
    return Instance_ :: any
end

-- How long reading a local pack may run in one frame, as on the server. A
-- client that loaded a five thousand object sandbox in one go froze for half a
-- second.
const READ_BUDGET = 1 / 120

-- Whole, or a frame's worth at a time. A transaction reads whole: a local
-- commit applies on the spot and never yields, so a load inside one cannot
-- either. Anything else reads in frames, and stops if the copy is taken away
-- while it waits.
const function ReadOne(Scene: any, Instance_: any, Object: any)
    -- Kept rather than dropped, exactly as on the server; see its ReadOne.
    if not Objects:GetRegistry(Object.Registry) then
        Logger:Warn(`Local scene {Scene.Name} holds an object of type {Object.Registry}, which is not registered. Kept as saved, and written back unchanged.`)
        table.insert(Instance_.Unknown, Object)
        return
    end

    Objects.restore(Instance_, Object)
end

FinishReading = function(Instance_: any)
    const Reading = Instance_.Reading
    if not Reading then
        return
    end

    Instance_.Reading = nil
    while Reading.Next <= #Reading.Objects do
        const Object = Reading.Objects[Reading.Next]
        Reading.Next += 1
        ReadOne(Reading.Scene, Instance_, Object)
    end
end

const function Read(self: any, Parent: Instance?, InFrames: boolean): any
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
        Logger:Warn(`Failed to read the pack for local scene {self.Name}: {LastId}`)
        Instance_:Unload()
        return nil
    end

    -- Moved before anything is built, so a freshly created object cannot be
    -- handed an id one of the restored ones already answers to.
    self.LastId = math.max(self.LastId, LastId :: number)

    const Reading = {Scene = self, Objects = Decompressed :: {any}, Next = 1}
    ;(Instance_ :: any).Reading = Reading
    local Since = os.clock()

    while Reading.Next <= #Reading.Objects do
        if InFrames and os.clock() - Since > READ_BUDGET then
            task.wait()
            Since = os.clock()

            -- Set aside meanwhile, and the rest was read as it went; unloaded,
            -- and nothing more goes into it.
            if (Instance_ :: any).Reading ~= Reading then
                break
            end

            if self.Instances[Instance_.Id] ~= Instance_ then
                (Instance_ :: any).Reading = nil
                break
            end
        end

        const Object = Reading.Objects[Reading.Next]
        Reading.Next += 1
        ReadOne(self, Instance_, Object)
    end

    if (Instance_ :: any).Reading == Reading then
        (Instance_ :: any).Reading = nil
    end

    return Instance_
end

const function __load(self: any, Parent: Instance?): any
    return Read(self, Parent, true)
end

-- For a local transaction, which must not yield.
const function __load_whole(self: any, Parent: Instance?): any
    return Read(self, Parent, false)
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
-- The third value says why a push was refused, so a game can tell its player:
-- Budget, NoPushRight, TooLarge, TooManyObjects, BadName, NameTaken,
-- UnknownType, Unreadable or Failed -- or Unreachable when the request never
-- got an answer.
const function __push(self: any, Name: string): (boolean, SceneIdentifier?, string?)
    const Data = __serialize(self)

    const Ok, Accepted, Identifier, Reason = pcall(function()
        return Network.Commit:Invoke(Name, Data)
    end)

    if not Ok then
        Logger:Warn(`A local scene was not committed to the server: {Accepted}`)
        return false, nil, "Unreachable"
    end

    if not Accepted then
        return false, nil, Reason
    end

    return true, Identifier, nil
end

const function __destroy(self: any)
    -- Unloaded first, so the copies go as copies rather than being orphaned by
    -- a scene that has already stopped existing.
    __unload(self)

    Owned[self.Id] = nil
    Objects.TrackLocalScene(self.Id, false)
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
    Scene.LastId = 0
    Scene.Data = nil
    Scene.Instances = {}

    Scene.Load = __load
    Scene.LoadWhole = __load_whole
    Scene.Unload = __unload
    Scene.Serialize = __serialize
    Scene.GetInstances = __get_instances
    Scene.Push = __push
    Scene.Destroy = __destroy

    Owned[Identifier] = Scene
    Objects.TrackLocalScene(Identifier, true)
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

-- One live copy of a scene this client owns, by its id, or nil for anything
-- else -- a copy of the server's, or one that has been unloaded. What a
-- transaction asks before applying itself here: an operation naming a copy this
-- side does not own is one it has no business doing on its own.
function Scenes:GetLocalCopy(Copy: SceneInstanceId): SceneInstance?
    for _, Scene in Owned do
        const Instance_ = (Scene :: any).Instances[Copy]
        if Instance_ then
            return Instance_
        end
    end

    return nil
end

return Scenes
