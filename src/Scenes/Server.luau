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

const HttpService = game:GetService("HttpService")

const Permissions = require("../Permissions/Server")
const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const ObjectShared = require("../Objects/Shared")
const Registry = require("./Registry")
const Audience = require("./Audience")
const World = require("../World")
const Network = require("./Network")
const Handles = require("../Handles")
const IdPool = require("../IdPool")
const Encoding = require("../Encoding")
const Logger = require("../Logger")
const Try = require("../Try")
const ObjectTypes = require("../Objects/Types")
const Types = require("./Types")

export type SceneIdentifier = Types.SceneIdentifier
export type SceneConfig = Types.SceneConfig
export type LoadOptions = Types.LoadOptions
export type SceneRegistry = Types.SceneRegistry
export type SceneSource = Types.SceneSource
export type SceneVersion = Types.SceneVersion
export type SceneBackup = Types.SceneBackup
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

-- The id above is unique on one server for one session: it is claimed in
-- registration order, so scene 3 here is not scene 3 on the next server or
-- after a restart, and a key built from it would read back the wrong level. It
-- also has to fit the u16 the wire and every persistent id carry, which is
-- 65,535 scenes for a whole game, ever. A Guid is the identity a scene is saved
-- under instead: 128 random bits, so no server has to ask another which ones
-- are taken, and nothing yields to make one.
--
-- Written as base64url without padding, 22 characters, because it goes into
-- DataStore keys and a key is capped at 50: the longest one built from it,
-- "<Guid>:Backup:<13 digits>", is 43.
const GUID_LENGTH = 22

const function NewGuid(): string
    const Hex = (string.gsub(HttpService:GenerateGUID(false), "-", ""))
    const Bytes = buffer.create(16)
    for Index = 0, 15 do
        buffer.writeu8(Bytes, Index, tonumber(string.sub(Hex, Index * 2 + 1, Index * 2 + 2), 16) :: number)
    end

    -- Sixteen bytes are 24 base64 characters, the last two padding.
    const Text = string.sub(Encoding.Encode(Bytes), 1, GUID_LENGTH)
    return (string.gsub(Text, "[+/]", {["+"] = "-", ["/"] = "_"}))
end

-- Only Prism makes Guids, so anything else handed in as one is a mistake --
-- and reading a key that does not hold a Prism scene would hand a scene an
-- identity Prism never gave it.
const function IsGuid(Text: any): boolean
    return type(Text) == "string" and #Text == GUID_LENGTH and string.match(Text, "^[%w%-_]+$") ~= nil
end

const function ToPayload(Scene: Scene): SceneRegistry
    return {
        Id = Scene.Id,
        Name = Scene.Name,
        Guid = Scene.Guid,
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
    const CopyOpened: {boolean} = {}
    const Held: {any} = {}

    -- Every object in a scene revealed whole, for its locks: who holds what is
    -- told to the admitted, whatever each object's own reach.
    const Watched: {any} = {}

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
            -- A loaded copy is every player's to know of. An opened one is kept
            -- for the admitted: a player who is not admitted has no part of it
            -- to attach anything to, so telling them would buy nothing.
            if (Glimpse and not Copy.Opened) or (Whole and Copy.Opened) then
                table.insert(CopyIds, Copy.Id)
                table.insert(CopyScenes, Scene.Id)
                table.insert(CopyOpened, Copy.Opened)
            end

            for _, Obj in Copy.Objects do
                if Taken[Objects.ReachOf(Obj)] then
                    table.insert(Held, Obj)
                end

                if Whole then
                    table.insert(Watched, Obj)
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
        Network.InstancesReplayed:Fire(Plr, CopyIds, CopyScenes, CopyOpened)
    end

    -- Before anything yields, like the copies: a lock taken from here on is
    -- announced to this player, so the one they were owed has to be out first.
    Objects.SendLocks(Plr, Watched)

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
        -- An opened copy goes whole: everything in it was kept for the
        -- admitted, and the client drops what it drew along with the copy.
        if Copy.Opened then
            Network.InstanceRemoved:Fire(Plr, Copy.Id)
            continue
        end

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

-- A pack read into this copy rather than into a copy of its own: pasting a
-- saved group of objects into a level somebody is editing.
--
-- The opposite of loading in the one way that matters. A load restores every
-- object under the id it was saved with, which is what keeps a pack meaning the
-- same thing every time it is read. A placement cannot: the copy it is going
-- into already has objects, and their ids are already spoken for. So every
-- object is created afresh, the scene mints the ids, and the pack's own LastId
-- is ignored -- it belongs to the scene the pack came from and says nothing
-- about this one.
--
-- Which leaves the references. They are held back while the objects are built
-- and written afterwards against what was actually made: a reference to another
-- object in the pack follows it to its new id, and a reference to anything else
-- is dropped rather than carried over. Carrying it would be worse than losing
-- it -- the id would name whatever in this copy happens to answer to it, and a
-- pasted button would come up wired to a door it has never met.
const function __place(self: SceneInstance, Pack: buffer): {ObjectTypes.Object}?
    const Ok, _, Decompressed = pcall(function()
        return Compressor:DecompressScene(Pack)
    end)

    if not Ok or not Decompressed then
        Logger:Warn(`Failed to read a pack being placed into a copy of {self.Owner.Name}.`)
        return nil
    end

    const Made: {ObjectTypes.Object} = {}

    -- What the placement made, by the id the pack knew each object as.
    const Placed: {[number]: ObjectTypes.Object} = {}
    const Pending: {{Object: ObjectTypes.Object, References: {[number]: any}}} = {}

    for _, Saved in Decompressed :: {any} do
        if not Objects:GetRegistry(Saved.Registry) then
            -- Skipped rather than refused, like restoring a saved object of a
            -- type this build no longer has: the rest of the pack is still a
            -- thing worth placing.
            Logger:Warn(`Skipped an object while placing a pack: object type {Saved.Registry} is not registered.`)
            continue
        end

        const Values, References = ObjectShared.SplitReferences(Saved.Properties)
        const Obj = Objects.new(Saved.Registry, Values, self, false)

        table.insert(Made, Obj)
        Placed[Saved.LocalId] = Obj

        if References then
            table.insert(Pending, {Object = Obj, References = References})
        end
    end

    for _, Entry in Pending do
        for PropertyId, Saved in Entry.References do
            const Prop = Entry.Object.Properties[PropertyId]
            if not Prop then
                continue
            end

            -- Left at nothing when the pack did not carry what it pointed at,
            -- which is what a property never written reads as. A list loses
            -- just that item.
            const Remapped = ObjectShared.Remap(Prop, Saved, function(Item: number): number?
                const Target = Placed[Item]
                return if Target then Target.LocalId else nil
            end)

            if Remapped ~= nil then
                Prop:Set(Remapped)
            end
        end
    end

    -- One announcement for the lot, down the chunked path a load uses. Building
    -- them silently is also what keeps a reference from going out twice: once
    -- holding an id from another scene, once corrected.
    if #Made > 0 then
        Objects.AnnounceAll(Made)
    end

    return Made
end

const function __instance_serialize(self: SceneInstance): buffer
    const List: {any} = __instance_objects(self)

    -- Objects of a type this build does not have go back in beside the rest,
    -- in their place by local id.
    for _, Kept in (self :: any).Unknown do
        table.insert(List, Kept)
    end

    -- Sorted by local id so the same copy always produces the same bytes. Hash
    -- order would make two identical copies serialize differently, which rules
    -- out diffing, merging or deduplicating saves -- the same reason a single
    -- object's properties are written in id order.
    table.sort(List, function(A, B)
        return A.LocalId < B.LocalId
    end)

    -- Each kept object as the tagged values it was read with, untouched.
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

-- A copy withdrawn from the world rather than unloaded, and kept whole: the
-- same thing suspending does to an object, one level up.
--
-- Unloading is final. It exists because a game decides a room is done with, and
-- nothing about that needs taking back. But a player asking for a copy to go is
-- a player who may want it back a second later, and a copy cannot be rebuilt
-- from its scene the way it was: loading reads what the scene last committed,
-- which is not what was on screen unless somebody had just saved. So the copy
-- is set aside instead -- out of the registries, its folder out of the world,
-- every object in it suspended -- and put back exactly as it was.
--
-- What it costs while it is away is what the objects cost, which is what they
-- cost anyway: they are the same tables, out of sight.
local FinishReading: (Instance_: any) -> ()

const function __instance_suspend(self: SceneInstance): boolean
    if self.Suspended then
        return false
    end

    const Owner = self.Owner
    if not Owner or Owner.Instances[self.Id] ~= self then
        return false
    end

    -- Still being read: the rest is read now, so what is set aside -- and what
    -- comes back -- is the whole copy rather than however much had been read.
    FinishReading(self)

    -- The objects first, while the copy is still filed: each unfiles itself
    -- from the tables below on the way out.
    self.Suspended = Objects.SuspendInstance(self)

    Owner.Instances[self.Id] = nil
    Registry.Instances[self.Id] = nil

    -- Out of the world, not destroyed -- the same distinction an object's part
    -- gets, and for the same reason: what comes back has to be what left,
    -- including anything the game hung on the folder.
    if self.Folder then
        -- Remembered rather than recomputed: a game that loaded this copy into
        -- PlayerGui or into a Model of its own gets it back there.
        self.Parent = self.Folder.Parent
        self.Folder.Parent = nil
    end

    Audience.Fire(Network.InstanceRemoved, self.Scene, if self.Opened then "Admitted" else "Everyone", self.Id)
    return true
end

const function __instance_revive(self: SceneInstance): boolean
    const Held = self.Suspended
    if not Held then
        return false
    end

    const Owner = self.Owner
    if not Owner or not Registry.ById[self.Scene] then
        -- Its scene has been unregistered while it was away. There is nothing
        -- to put it back into.
        return false
    end

    self.Suspended = nil

    -- Filed before its objects, which file themselves into it as they come
    -- back, and announced before them for the reason a load announces its copy
    -- first: a client must never be handed an object of a copy it has not been
    -- told about.
    Owner.Instances[self.Id] = self :: any
    Registry.Instances[self.Id] = self

    if self.Folder then
        World.Place(self.Folder, self.Scene, self.Parent)
    end

    Audience.Fire(
        Network.InstanceAdded,
        self.Scene,
        if self.Opened then "Admitted" else "Everyone",
        self.Id,
        self.Scene,
        self.Opened
    )

    Objects.AnnounceAll(Objects.ReviveInstance(Held))
    return true
end

-- The end of a suspended copy: its objects for good, and the folder they were
-- in. Everything else about it was already done when it was withdrawn.
const function __instance_dispose(self: SceneInstance)
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

    Registry.Instances[self.Id] = nil

    Objects.DropInstance(self)

    -- The folder goes after its objects, so nothing is left holding a
    -- reference to an instance that is already gone.
    World.DropCopy(self.Scene, self.Folder)
    Audience.Fire(Network.InstanceRemoved, self.Scene, if self.Opened then "Admitted" else "Everyone", self.Id)
end

const function NewInstance(Owner: Scene, Parent: Instance?, Opened: boolean): SceneInstance
    InstanceCounter += 1

    const Instance_ = {}
    Instance_.Id = InstanceCounter
    Instance_.Scene = Owner.Id
    Instance_.Owner = Owner
    Instance_.Opened = Opened

    -- None for an opened copy. It would hold nothing, and an empty folder named
    -- for the scene, in a workspace every player can see, is exactly the
    -- announcement opening exists to avoid.
    Instance_.Folder = if Opened then nil else World.Copy(Owner.Id, Instance_.Id, Parent)
    Instance_.Objects = {}
    Instance_.ByLocal = {}

    -- Decoded records of objects whose type is not registered. See Read.
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

    Owner.Instances[Instance_.Id] = Instance_ :: any
    Registry.Instances[Instance_.Id] = Instance_

    -- Announced before its objects, so a client is never handed an object
    -- belonging to a copy it has not been told about.
    -- A loaded copy to every player, not only the admitted: an object that
    -- replicates to everyone has to be filed under its copy, and this is the
    -- copy. It says a copy of some scene exists, and nothing more. An opened
    -- copy only to the admitted, who are the only ones it sends anything to.
    Audience.Fire(Network.InstanceAdded, Owner.Id, if Opened then "Admitted" else "Everyone", Instance_.Id, Owner.Id, Opened)
    return Instance_ :: any
end

--=============================================================================
-- Scenes
--=============================================================================

-- How long reading a pack may run in one frame before it waits for the next,
-- unless the load says otherwise. Building every object at once held the server
-- for over half a second on a five thousand object level, every player's frame
-- with it.
const READ_BUDGET = 1 / 120

-- The budget a load asked for, or the default. A wrong one is said rather than
-- obeyed: zero or less would wait a frame for every object.
const function BudgetOf(Options: Types.LoadOptions?): number
    const Budget = Options and Options.Budget
    if Budget == nil then
        return READ_BUDGET
    end

    if type(Budget) ~= "number" or Budget ~= Budget or Budget <= 0 then
        Logger:Warn(`A load's Budget is seconds a frame, above zero; got {tostring(Budget)}. Using {READ_BUDGET}.`)
        return READ_BUDGET
    end

    return Budget
end

-- Load and Open are one reading of the pack, and differ only in whether the
-- server builds the parts.
-- One object of a pack into a copy. A type this build does not have is kept as
-- the bytes it was read from and written back where it was by the next commit;
-- restoring used to warn and leave it out, and committing the copy afterwards
-- then wrote it out of the pack for good.
const function ReadOne(Scene: Scene, Instance_: any, Object: any, Restored: {any})
    if not Objects:GetRegistry(Object.Registry) then
        Logger:Warn(`Scene {Scene.Name} holds an object of type {Object.Registry}, which is not registered. Kept as saved, and written back unchanged.`)
        table.insert(Instance_.Unknown, Object)
        return
    end

    const Obj = Objects.restore(Instance_, Object, false)
    if Obj then
        table.insert(Restored, Obj)
    end
end

-- The rest of a read still in progress, read now and without a break. What
-- sets a copy aside calls this first; the read itself sees it has been
-- finished for it and stops.
FinishReading = function(Instance_: any)
    const Reading = Instance_.Reading
    if not Reading then
        return
    end

    Instance_.Reading = nil
    while Reading.Next <= #Reading.Objects do
        const Object = Reading.Objects[Reading.Next]
        Reading.Next += 1
        ReadOne(Reading.Scene, Instance_, Object, Reading.Restored)
    end
end

-- Load and Open are one reading of the pack, and differ only in whether the
-- server builds the parts.
const function Read(self: Scene, Parent: Instance?, Opened: boolean, Budget: number): any
    const Instance_ = NewInstance(self, Parent, Opened) :: any

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
    const Reading = {Scene = self, Objects = Decompressed :: {any}, Next = 1, Restored = Restored}
    Instance_.Reading = Reading
    local Since = os.clock()

    while Reading.Next <= #Reading.Objects do
        -- A frame's worth at a time. Load already yields while it announces
        -- what it read, so a caller sees nothing new, only a server that keeps
        -- running. Set aside meanwhile, the rest was read as it went; unloaded,
        -- nothing more goes into it. Either way what was read is announced below
        -- only if it is still there.
        if os.clock() - Since > Budget then
            task.wait()
            Since = os.clock()

            if Instance_.Reading ~= Reading then
                break
            end

            if Registry.Instances[Instance_.Id] ~= Instance_ then
                Instance_.Reading = nil
                break
            end
        end

        const Object = Reading.Objects[Reading.Next]
        Reading.Next += 1
        ReadOne(self, Instance_, Object, Restored)
    end

    if Instance_.Reading == Reading then
        Instance_.Reading = nil
    end

    Objects.AnnounceAll(Restored, Budget)
    return Instance_
end

const function __load(self: Scene, Parent: Instance?, Options: Types.LoadOptions?): any
    return Read(self, Parent, false, BudgetOf(Options))
end

const function __open(self: Scene, Options: Types.LoadOptions?): any
    return Read(self, nil, true, BudgetOf(Options))
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

const SAVE_ATTEMPTS = 5

-- Every key a scene is stored under starts with its Guid. A draft and a
-- published pack are one key each, overwritten in place: their history is the
-- DataStore's own versions, which it keeps for thirty days. A backup is a key
-- of its own per call, so it outlives that, and nothing here ever deletes one.
const function KeyOf(Guid: string, Which: string): string
    return `{Guid}:{Which}`
end

const function BackupKey(Guid: string, Id: number): string
    return KeyOf(Guid, `Backup:{Id}`)
end

-- The buffer itself rather than buffer.tostring of it. A DataStore only takes
-- a string that is valid UTF-8, and a pack is binary through and through: any
-- byte past 127 that does not open a UTF-8 sequence makes the write fail.
const function Write(self: Scene, Store: DataStore, Key: string): boolean
    const Success = Try(SAVE_ATTEMPTS, Store.SetAsync, Store, Key, __serialize(self))
    if not Success then
        Logger:Warn(`Failed to write scene {self.Name} to key {Key}.`)
    end

    return Success
end

-- What a draft and a published pack hold is the same thing -- the scene as it
-- was last committed -- and publishing does not read the draft back. A scene
-- published without being saved first goes live as it is, which is what the
-- game asked for by publishing it.
const function __save(self: Scene, Store: DataStore): boolean
    return Write(self, Store, KeyOf(self.Guid, "Draft"))
end

const function __publish(self: Scene, Store: DataStore): boolean
    return Write(self, Store, KeyOf(self.Guid, "Published"))
end

-- Climbs within a server, so two backups in the same millisecond do not land on
-- one key and leave the first unreachable.
local LastBackup = 0

-- When to take one is the game's: after every publish, once a day, before a
-- risky edit. The id is the moment it was taken, in unix milliseconds.
const function __backup(self: Scene, Store: DataStore): number?
    const Id = math.max(DateTime.now().UnixTimestampMillis, LastBackup + 1)
    LastBackup = Id

    if not Write(self, Store, BackupKey(self.Guid, Id)) then
        return nil
    end

    return Id
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

    -- Its rights go with it, told to whoever held them while the scene can
    -- still be found.
    Permissions.DropScene(self)

    Registry.ById[self.Id] = nil
    Registry.ByName[self.Name] = nil
    Registry.ByGuid[self.Guid] = nil
    self.Data = nil

    -- To whoever was told its name, after which nobody holds it at all. Its
    -- copies went to everyone already, one packet each, as they unloaded.
    Audience.Fire(Network.SceneUnregistered, self.Id, "Admitted", self.Id)
    Audience.ForgetScene(self.Id)

    -- The id is not released: see the pool above.
end

-- Admitting and evicting change who is told about a private scene. On a public
-- one they change nothing that anybody can see: everyone is already owed all of
-- it, and the list sits there until the scene is closed.
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

    -- What they were holding in this scene goes with their admission. Shut out
    -- of a room, still holding three things in it, is a way to stop everybody
    -- else working without being able to work yourself.
    Objects.ReleaseFor(UserId, self.Id)
    Reconcile(self)
end

const function __admits(self: Scene, Who: Player | number): boolean
    if not self.Private then
        return true
    end

    const UserId = Audience.Resolve(Who)
    return UserId ~= nil and self.Admitted[UserId] == true
end

const function __get_admitted(self: Scene): {number}
    const List = {}
    for UserId in self.Admitted do
        table.insert(List, UserId)
    end

    return List
end

const function __is_public(self: Scene): boolean
    return not self.Private
end

-- Closing a scene takes it away from everyone it does not admit; opening it
-- hands it to everybody. Either way the reconcile below is what actually moves
-- it, the same as admitting or evicting somebody.
const function __set_private(self: Scene, Private: boolean)
    const Wanted = Private == true
    if self.Private == Wanted then
        return
    end

    self.Private = Wanted
    Reconcile(self)
end

-- Rights live in Permissions, which keeps them on the scene; these are the
-- scene's own handles on them.
const function __grant(self: Scene, Who: Player | number, Role: string): boolean
    return Permissions:GrantOn(self, Who, Role)
end

const function __revoke(self: Scene, Who: Player | number)
    Permissions:RevokeOn(self, Who)
end

const function __grant_capability(self: Scene, Who: Player | number, Capability: string)
    Permissions:GrantCapabilityOn(self, Who, Capability)
end

const function __revoke_capability(self: Scene, Who: Player | number, Capability: string)
    Permissions:RevokeCapabilityOn(self, Who, Capability)
end

const function __get_rights(self: Scene, Who: Player | number): any
    return Permissions:GetOn(self, Who)
end

-- Names have to be unique as well as ids. A name is how a caller asks for a
-- scene back, and two scenes answering to "Lobby" means one of them is
-- unreachable and which one depends on registration order.
--
-- Guid is only ever one Prism made: a fresh one, or the one a stored scene was
-- saved under, handed back by fromDataStore. The config has no field for it,
-- so a game cannot give a scene an identity of its own choosing.
const function Build(Config: SceneConfig, Guid: string?): Scene?
    if Registry.ByName[Config.Name] then
        Logger:Warn(`There's already a scene named {Config.Name}.`)
        return nil
    end

    -- The same level read back twice on one server would be two scenes saving
    -- over each other's keys, each believing it was the level.
    if Guid and Registry.ByGuid[Guid] then
        Logger:Warn(`Scene {Registry.ByGuid[Guid].Name} is already registered under {Guid}.`)
        return nil
    end

    const Identifier = Ids:Claim()
    if not Identifier then
        Logger:Warn("The scene id pool is exhausted.")
        return nil
    end

    const Scene = {}
    Scene.Id = Identifier
    Scene.Name = Config.Name
    Scene.Guid = Guid or NewGuid()
    Scene.LastId = 0
    Scene.Data = nil
    Scene.Instances = {}

    -- Set before the scene is announced, so a scene that should never be public
    -- never is, not even for the packet that registers it.
    Scene.Private = Config.Private == true

    Scene.Admitted = {}
    for _, Who in Config.Admitted or {} do
        const UserId = Audience.Resolve(Who)
        if UserId then
            Scene.Admitted[UserId] = true
        else
            Logger:Warn(`Scene {Config.Name} admits a Player or a user id, not a {typeof(Who)}.`)
        end
    end

    -- Said rather than silently ignored: a list on a public scene is inert, and
    -- somebody writing one has almost certainly meant to close the scene.
    if not Scene.Private and next(Scene.Admitted) ~= nil then
        Logger:Warn(`Scene {Config.Name} admits people but is not private, so the list does nothing. Pass Private = true to close it.`)
    end

    Scene.Rights = {}

    Scene.Load = __load
    Scene.Open = __open
    Scene.Unload = __unload
    Scene.Serialize = __serialize
    Scene.Save = __save
    Scene.Publish = __publish
    Scene.Backup = __backup
    Scene.GetInstances = __get_instances
    Scene.Destroy = __destroy
    Scene.Admit = __admit
    Scene.Evict = __evict
    Scene.Admits = __admits
    Scene.SetPrivate = __set_private
    Scene.GetAdmitted = __get_admitted
    Scene.IsPublic = __is_public
    Scene.Grant = __grant
    Scene.Revoke = __revoke
    Scene.GrantCapability = __grant_capability
    Scene.RevokeCapability = __revoke_capability
    Scene.GetRights = __get_rights

    Registry.ById[Identifier] = Scene
    Registry.ByName[Config.Name] = Scene
    Registry.ByGuid[Scene.Guid] = Scene

    -- Told to whoever it admits, which for a scene with no list is everyone.
    Reconcile(Scene :: any)

    for Who, Role in Config.Rights or {} do
        Permissions:GrantOn(Scene, Who, Role)
    end

    return Scene :: any
end

-- A new scene, under a Guid nobody has used.
function Scenes.new(Config: SceneConfig): Scene?
    return Build(Config, nil)
end

-- Registers a scene around a pack someone stored earlier. Nothing goes live
-- until Load, which is what makes a menu of saved levels cheap: register them
-- all, load the one that gets picked. A pack carries no Guid, so this is a new
-- scene with a new one -- the way to read a saved scene back as itself is
-- fromDataStore.
function Scenes.fromBuffer(Config: SceneConfig, Data: buffer): Scene?
    const Scene = Scenes.new(Config)
    if not Scene then
        return nil
    end

    Scene.Data = Data
    return Scene
end

-- Which stored pack fromDataStore reads, and how: the current draft or
-- published pack, one of the DataStore's own versions of either, or a backup.
-- Returns where it read from, or nil for a source that names no single pack --
-- a table naming two would otherwise read whichever was checked first.
const function ReadStored(Store: DataStore, Guid: string, Source: Types.SceneSource): (boolean, any, string?)
    if Source == "Draft" or Source == "Published" then
        const Key = KeyOf(Guid, Source)
        const Success, Stored = Try(SAVE_ATTEMPTS, Store.GetAsync, Store, Key)
        return Success, Stored, Key
    end

    if type(Source) ~= "table" then
        return false, nil, nil
    end

    local Named = 0
    for _ in Source do
        Named += 1
    end

    if Named ~= 1 then
        return false, nil, nil
    end

    if type(Source.Backup) == "number" then
        const Key = BackupKey(Guid, Source.Backup)
        const Success, Stored = Try(SAVE_ATTEMPTS, Store.GetAsync, Store, Key)
        return Success, Stored, Key
    end

    const Which = if type(Source.Draft) == "string" then "Draft" elseif type(Source.Published) == "string" then "Published" else nil
    if not Which then
        return false, nil, nil
    end

    const Version = (Source.Draft or Source.Published) :: string
    const Key = KeyOf(Guid, Which)
    const Success, Stored = Try(SAVE_ATTEMPTS, Store.GetVersionAsync, Store, Key, Version)
    return Success, Stored, `{Key} at version {Version}`
end

-- Registers a saved scene as itself: under the Guid it was saved with, so
-- saving it again writes the same keys. The draft unless Source names another
-- pack. Nil when the Guid is not one Prism made, the pack could not be read,
-- or there is nothing there -- a new level is Scenes.new, which gets a Guid of
-- its own, and reading an empty key as an empty scene would let any string
-- shaped like a Guid become one.
--
-- The store and the Guid lead, as they do in every call that reads a stored
-- scene, and the config follows: it says how to register what was found.
function Scenes.fromDataStore(Store: DataStore, Guid: string, Config: SceneConfig, Source: Types.SceneSource?): Scene?
    if not IsGuid(Guid) then
        Logger:Warn(`{Guid} is not a scene Guid. Only Prism makes them; read one off Scene.Guid.`)
        return nil
    end

    const Success, Stored, Where = ReadStored(Store, Guid, Source or "Draft")
    if not Where then
        Logger:Warn(`Cannot read scene {Config.Name}: a source is "Draft", "Published", or a table naming one of Draft, Published or Backup.`)
        return nil
    end

    if not Success then
        Logger:Warn(`Failed to read scene {Config.Name} from {Where}.`)
        return nil
    end

    if Stored == nil then
        Logger:Warn(`Nothing is stored at {Where}.`)
        return nil
    end

    if type(Stored) ~= "buffer" then
        Logger:Warn(`{Where} holds a {typeof(Stored)}, not a scene pack.`)
        return nil
    end

    const Scene = Build(Config, Guid)
    if not Scene then
        return nil
    end

    Scene.Data = Stored
    return Scene
end

-- How many entries a listing asks the DataStore for at once.
const LIST_PAGE_SIZE = 100

-- The DataStore's own history of a draft or a published pack, newest first:
-- every write in the last thirty days, which is as long as it keeps them. Nil
-- when the listing could not be read. Limit caps how many come back; a scene
-- saved on every edit has a great many.
function Scenes:ListVersions(Store: DataStore, Guid: string, Which: "Draft" | "Published", Limit: number?): {Types.SceneVersion}?
    if not IsGuid(Guid) then
        Logger:Warn(`{Guid} is not a scene Guid.`)
        return nil
    end

    -- Anything else names a key nothing writes, and would list as no versions
    -- at all rather than as a mistake.
    if Which ~= "Draft" and Which ~= "Published" then
        Logger:Warn(`Versions are kept of "Draft" and "Published", not {Which}. Backups are listed by ListBackups.`)
        return nil
    end

    const Wanted = Limit or math.huge
    const Success, Versions = Try(SAVE_ATTEMPTS, function(): {Types.SceneVersion}
        const Found: {Types.SceneVersion} = {}
        const Pages = Store:ListVersionsAsync(KeyOf(Guid, Which), Enum.SortDirection.Descending, 0, 0, math.min(Wanted, LIST_PAGE_SIZE))

        while true do
            for _, Info in Pages:GetCurrentPage() do
                -- A version the key was removed at holds no pack to read.
                if Info.IsDeleted then
                    continue
                end

                table.insert(Found, {Version = Info.Version, Time = Info.CreatedTime})
                if #Found >= Wanted then
                    return Found
                end
            end

            if Pages.IsFinished then
                return Found
            end

            Pages:AdvanceToNextPageAsync()
        end
    end)

    if not Success then
        Logger:Warn(`Failed to list versions of scene {Guid}.`)
        return nil
    end

    return Versions
end

-- Every backup of a scene, newest first, shaped like a version: Backup is the
-- id fromDataStore takes back as {Backup = id}, as Version is for a version.
-- The id is the moment it was taken, so Time is the same number. Nil when the
-- listing could not be read.
--
-- Limit cuts the list after sorting rather than stopping the walk early: keys
-- list in name order, which is oldest first, so the newest are the last read.
function Scenes:ListBackups(Store: DataStore, Guid: string, Limit: number?): {Types.SceneBackup}?
    if not IsGuid(Guid) then
        Logger:Warn(`{Guid} is not a scene Guid.`)
        return nil
    end

    const Prefix = KeyOf(Guid, "Backup:")
    const Success, Ids = Try(SAVE_ATTEMPTS, function(): {number}
        const Found: {number} = {}
        const Pages = Store:ListKeysAsync(Prefix, LIST_PAGE_SIZE, "", true)

        while true do
            for _, Key in Pages:GetCurrentPage() do
                const Id = tonumber(string.sub(Key.KeyName, #Prefix + 1))
                if Id then
                    table.insert(Found, Id)
                end
            end

            if Pages.IsFinished then
                return Found
            end

            Pages:AdvanceToNextPageAsync()
        end
    end)

    if not Success then
        Logger:Warn(`Failed to list backups of scene {Guid}.`)
        return nil
    end

    table.sort(Ids, function(A: number, B: number): boolean
        return A > B
    end)

    const Backups: {Types.SceneBackup} = {}
    for Index = 1, math.min(#Ids, Limit or math.huge) do
        table.insert(Backups, {Backup = Ids[Index], Time = Ids[Index]})
    end

    return Backups
end

function Scenes:Get(Name: string): Scene?
    return Registry.ByName[Name]
end

function Scenes:GetById(Identifier: SceneIdentifier): Scene?
    return Registry.ById[Identifier]
end

function Scenes:GetByGuid(Guid: string): Scene?
    return Registry.ByGuid[Guid]
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

-- The role a player is granted on a scene they push, or nil for none. A pushed
-- scene admits only its author either way: it was built where nobody else could
-- see it, and registering it should not change that.
local PushRole: string? = nil

function Scenes:SetPushRole(Role: string?)
    if Role and not Permissions:GetRegistered()[Role] then
        Logger:Warn(`Cannot grant unregistered role {Role} on pushed scenes.`)
        return
    end

    PushRole = Role
end

-- A client handing over a scene it built locally. Refusals are not logged,
-- like every other client facing handler here: a refusal that logs is a
-- refusal a client can spam to fill the server's output. They do say why to
-- the client that asked, which costs nothing and is the one thing a game needs
-- to tell its player.
const function Refuse(Reason: string): (boolean, SceneIdentifier, string)
    return false, 0, Reason
end

Network.Commit.OnInvoke = function(Plr: Player, Name: string, Data: buffer): (boolean, SceneIdentifier, string)
    -- One action for the packet rather than one per object in it. A transaction
    -- charges per operation because every operation reaches into the world as
    -- it stands; this arrives whole, and what bounds it is its size, which is
    -- known before a byte of it is read.
    if not Permissions:Consume(Plr) then
        return Refuse("Budget")
    end

    -- A global right rather than a check against the pack's types. The scene
    -- does not exist yet, so there are no rights over it to consult, and
    -- registering a scene at all is exactly the kind of thing that is about the
    -- session rather than a document.
    if not Permissions:CanPush(Plr) then
        return Refuse("NoPushRight")
    end

    if buffer.len(Data) > MAX_COMMIT_BYTES then
        return Refuse("TooLarge")
    end

    if #Name == 0 or #Name > MAX_NAME_LENGTH then
        return Refuse("BadName")
    end

    -- Names are how a scene is asked for, so the first one to take a name keeps
    -- it. Refused here as well as in Scenes.new so the pack is not decoded for
    -- a commit that cannot land anyway.
    if Registry.ByName[Name] then
        return Refuse("NameTaken")
    end

    const Ok, _, Decompressed = pcall(function()
        return Compressor:DecompressScene(Data)
    end)

    if not Ok or not Decompressed then
        return Refuse("Unreadable")
    end

    const Packed = Decompressed :: {any}
    if #Packed > MAX_COMMIT_OBJECTS then
        return Refuse("TooManyObjects")
    end

    -- Every object type in the pack has to be one the server knows, and the
    -- whole commit is refused if any is not. A scene arriving with half its
    -- objects dropped is not the scene that was sent, and the client would
    -- have no way to tell.
    local Highest = 0

    for _, Object in Packed do
        if not Objects:GetRegistry(Object.Registry) then
            return Refuse("UnknownType")
        end

        -- A client's pack keeps no bytes the server cannot read. A save of the
        -- server's own keeps what an older build wrote; a packet from a client
        -- is untrusted, and this is the server writing its own pack.
        Object.Unknown = nil

        Highest = math.max(Highest, Object.LocalId)
    end

    -- Re-encoded rather than kept as it arrived, so the pack the server holds
    -- is the one the server wrote. Its LastId is the highest id actually in it
    -- rather than whatever the client claimed -- a pack declaring an id space
    -- already spent would otherwise give the scene room for nothing.
    -- Private to its author from the packet that registers it, and theirs to
    -- edit if the game has said what a pusher holds.
    const Scene = Scenes.fromBuffer({
        Name = Name,
        Private = true,
        Admitted = {Plr.UserId},
        Rights = if PushRole then {[Plr.UserId] = PushRole} else nil,
    }, Compressor:CompressScene(Highest, Packed))
    if not Scene then
        return Refuse("Failed")
    end

    return true, Scene.Id, ""
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
