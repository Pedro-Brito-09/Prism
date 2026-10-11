--!strict
const CollectionService = game:GetService("CollectionService")
const Players = game:GetService("Players")

const Properties = require("../Properties/Server")
const Permissions = require("../Permissions/Server")
const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const SceneRegistry = require("../Scenes/Registry")
const Audience = require("../Scenes/Audience")
const Network = require("./Network")
const Shared = require("./Shared")
const Handles = require("../Handles")
const IdPool = require("../IdPool")
const Listeners = require("../Listeners")
const Logger = require("../Logger")
const Types = require("./Types")

export type ObjectIdentifier = Types.ObjectIdentifier
export type InstanceLinkRegistry = Types.InstanceLinkRegistry
export type InstanceLink = Types.InstanceLink
export type ObjectRegistry = Types.ObjectRegistry
export type ObjectConfig = Types.ObjectConfig
export type RuntimeId = Types.RuntimeId
export type Object = Types.Object

const MAX_RUNTIME_ID = 4294967295

const Objects = {}
local RuntimeCounter = 0

const Registered: {[ObjectIdentifier]: ObjectRegistry} = {}

-- Every live object on the server. Keyed by runtime id rather than by the
-- persistent one, because the persistent one is not unique here: instancing a
-- scene twice puts two objects carrying the same persistent id in this table.
const Workspace: {[RuntimeId]: Object} = {}

-- Who holds each locked object: the holder's user id, and the connection the
-- lock was taken on, which is what lets it go with the player who took it.
-- Who holds each locked object. The holder is whatever was handed in -- a
-- Player, a table standing in for one, a module, a string naming a tool -- and
-- UserId is filled in only where that resolves to a person, which is the part a
-- client can be told about.
--
-- A hold used to require a player, so the server holding an object meant
-- inventing a fake one. Nothing about a hold needs a person: it says this is
-- being worked on, leave it alone.
const Locks: {[RuntimeId]: {UserId: number?, Holder: any}} = {}
-- Never recycled, for the same reason property ids are not: a registry id is
-- written into every saved object as its Registry, so handing the same id to a
-- different object type later makes every stored object of the old type decode
-- as the new one.
const Ids = IdPool.new(nil, false)

-- Every object appearing here and going, however it came and however it went:
-- created, restored by a scene load, revived from a suspend, destroyed,
-- suspended, or taken away with the copy that held it. Server scripts that
-- drive objects -- a spinner reading its speed -- used to poll GetWorkspace to
-- notice any of it.
--
-- The client's twin, down to the argument: Restored says the object came back
-- from a pack under the id it was saved with, which is a copy reading itself in
-- rather than anything anyone did. It is the difference between an editor
-- listing a new object and an editor listing a level.
--
-- Deliberately not the same thing as the packet that announces an object. A
-- scene load builds its objects silently and sends them in bulk afterwards;
-- these fire either way, because they are about the object existing rather than
-- about anybody being told.
const Added: {(Obj: Object, Restored: boolean) -> ()} = {}
const Removed: {(Obj: Object) -> ()} = {}

-- Fired once the object is filed in the workspace and in its copy, so a
-- listener can look it up either way straight off.
function Objects:OnAdded(Callback: (Obj: Object, Restored: boolean) -> ()): () -> ()
    return Listeners.Watch(Added, Callback, "objects appearing")
end

-- Fired once the object has left both, so it already reports Destroyed and is
-- nowhere to be found. It still carries its ids, which is what a listener needs
-- to drop whatever it was keeping for it.
function Objects:OnRemoved(Callback: (Obj: Object) -> ()): () -> ()
    return Listeners.Watch(Removed, Callback, "objects going")
end

-- Whether an object's data goes to every player or only to the ones its scene
-- admits. A type that is somehow not registered answers Admitted, which sends
-- nothing to anybody not already owed everything.
--
-- An object in an opened copy is kept for the admitted whatever its type says.
-- Replicate only means anything for a copy the server built: a player who is
-- not admitted has no part of an opened copy to attach data to, so sending it
-- would buy nothing.
const function ReachOf(Obj: Object): Types.Reach
    const Copy = SceneRegistry.Instances[Obj.InstanceId]
    if Copy and Copy.Opened then
        return "Admitted"
    end

    const Registry = Registered[Obj.Registry]
    return if Registry then Registry.Replicate else "Admitted"
end

-- One object in one copy, by the id a reference stores. The crossing between
-- the two identities, and scoped to a copy for the reason Find is.
const function Find(Copy: Types.SceneInstanceId, Local: number): Object?
    const Live = SceneRegistry.Instances[Copy]
    return if Live then Live.ByLocal[Local] else nil
end

const function __getter(self: Object, Reference: Types.PropertyReference): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    const Value = if Prop.Value == nil then Prop.DefaultValue else Prop.Value

    -- A reference reads as the object it names rather than as the id it
    -- stores, because the id is the storage and the object is the answer.
    -- Nothing is hidden by this: the raw id is still there on the property
    -- itself, through GetProperty, which is where everything Get and Set do
    -- not cover lives.
    if Prop.Type == "Object" then
        return Shared.ResolveReference(self.InstanceId, Value, Find)
    end

    return Value
end

const function __setter(self: Object, Reference: Types.PropertyReference, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    -- Takes the target object as readily as its id, which is the counterpart
    -- to Get handing one back.
    const Allowed, Val = Shared.Accept(self, Prop, Value, Find)
    if not Allowed then
        return false
    end

    const Accepted, Changed = Prop:Set(Val)
    if not Accepted then
        return false
    end

    if Changed then
        const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value)
        if Compressed then
            Audience.Fire(Network.PropertyChanged, self.Scene, ReachOf(self), self.RuntimeId, Prop.Parent, Compressed)
        end
    end

    return true
end

-- Leaving the world, which is not the same as ceasing to exist. Everything
-- here is undoable: the object is unfiled, its part goes, its lock goes and
-- every client is told it is gone -- but the table, its property values and
-- both its ids survive, which is what lets a destroy be taken back as the same
-- object rather than replaced by a lookalike holding the same numbers.
--
-- The local id matters most. A reference stores one, and a scene never hands a
-- local id out twice, so an object that comes back under its own is pointed at
-- again by everything that was pointing at it.
const function Withdraw(self: Object, Announce: boolean)
    Shared.ReleaseLinks(self.Links)
    self.Links = nil

    -- Gone with its object. The packet saying the object went is all a client
    -- needs to drop the lock it knew about.
    Locks[self.RuntimeId] = nil

    -- Out of the world rather than destroyed, and kept. To every client the two
    -- are the same thing -- a part with no parent is not in the DataModel, so
    -- it replicates away exactly as a destroyed one does -- but coming back
    -- means coming back as the same part, with whatever the game hung on it
    -- still hanging there. A fresh clone from the template would lose all of
    -- it. Destroying is Dispose's, once nothing can bring the object back.
    if self.Instance then
        self.Instance.Parent = nil
    end

    -- Out of the scene before out of the workspace, so a scene walking its own
    -- objects while they are being destroyed never sees one that is already
    -- gone from the world but still listed as its own.
    if self.Release then
        self.Release()
        self.Release = nil
    end

    if Workspace[self.RuntimeId] then
        Workspace[self.RuntimeId] = nil

        -- A scene unloading announces itself once, by name, instead of once per
        -- object it held.
        if Announce then
            Audience.Fire(Network.ObjectRemoved, self.Scene, ReachOf(self), self.RuntimeId)
        end
    end

    self.Get = Shared.Destroyed.Get
    self.Set = Shared.Destroyed.Set
    self.GetProperty = Shared.Destroyed.GetProperty
    self.OnChange = Shared.Destroyed.OnChange
    self.Destroy = Shared.Destroyed.Destroy

    -- Last, so a listener is handed an object that is already gone from
    -- everywhere it can be looked up rather than one halfway out.
    Listeners.Notify(Removed, self)
end

-- The part that cannot be taken back: the values go, the part goes, and with
-- them any chance of this object being itself again.
const function Dispose(self: Object)
    self.Suspended = nil

    if self.Instance then
        self.Instance:Destroy()
        self.Instance = nil
    end

    for _, Prop in self.Properties do
        Prop:Destroy()
    end
end

const function Teardown(self: Object, Announce: boolean)
    if self.Destroyed then
        return
    end

    self.Destroyed = true
    Withdraw(self, Announce)
    Dispose(self)
end

const function __destroy(self: Object)
    Teardown(self, true)
end

-- The whole registry, template and links included, because a client drawing a
-- copy or owning a scene builds instances from exactly what the server does.
-- The template is a plain reference: it resolves on a client exactly when that
-- instance replicates to them, and arrives as nil otherwise. The links are
-- plain data and were validated against the template at registration.
const function ToRegistryPayload(Registry: ObjectRegistry)
    return {
        Id = Registry.Id,
        Name = Registry.Name,
        Properties = Registry.Properties,
        Instance = Registry.Instance,
        Links = Registry.Links,
        Replicate = Registry.Replicate,

        -- Whether there is a template at all, so a client whose reference came
        -- back nil can tell "none" from "one I cannot see" and say so.
        HasTemplate = Registry.Instance ~= nil,
    }
end

function Objects:Register(Config: ObjectConfig): ObjectIdentifier?
    const Identifier = Ids:Claim()
    if not Identifier then
        Logger:Warn("The object type id pool is exhausted.")
        return
    end

    const Valid = {}
    for _, PropId in Config.Properties do
        if Properties:GetRegistry(PropId) then
            table.insert(Valid, PropId)
        else
            Logger:Warn(`Object {Config.Name} references unregistered property {PropId}. Will be skipped.`)
        end
    end

    -- Everyone unless told otherwise, so a type registered before this field
    -- existed behaves exactly as it did. A value that is neither is kept to the
    -- admitted: a typo meant to keep something back should keep it back rather
    -- than send it to every player.
    local Replicate: Types.Reach = "Everyone"
    if Config.Replicate == "Admitted" then
        Replicate = "Admitted"
    elseif Config.Replicate ~= nil and Config.Replicate ~= "Everyone" then
        Logger:Warn(`Object {Config.Name} has Replicate = {tostring(Config.Replicate)}, which is neither "Everyone" nor "Admitted". Kept to the admitted.`)
        Replicate = "Admitted"
    end

    const Obj: ObjectRegistry = {
        Id = Identifier,
        Name = Config.Name,
        Properties = Valid,
        Instance = Config.Instance,
        Links = Shared.ValidateLinks(Config.Name, Config.Instance, Config.Links, Valid),
        Replicate = Replicate,
    }

    -- Its properties cannot be unregistered from under it while it stands.
    for _, PropId in Valid do
        Properties.Retain(PropId)
    end

    Registered[Identifier] = Obj
    Network.ObjectRegistered:FireAll(ToRegistryPayload(Obj))
    return Identifier
end

-- Refused while any object of the type is live: each was built from this
-- registry and names it as its Registry, and a client rebuilding one would find
-- nothing to build it from. Destroy them, or unload what holds them, first.
--
-- The id is never handed out again. Packs name it, and a later type under the
-- same id would decode every saved object of this one as the new one. A pack
-- that still names it restores its other objects and warns about these.
function Objects:Unregister(Identifier: ObjectIdentifier): boolean
    const Registry = Registered[Identifier]
    if not Registry then
        return false
    end

    for _, Obj in Workspace do
        if Obj.Registry == Identifier and not Obj.Destroyed then
            Logger:Warn(`Cannot unregister object type {Registry.Name}: objects of it are still live.`)
            return false
        end
    end

    Registered[Identifier] = nil
    Ids:Release(Identifier)

    for _, PropId in Registry.Properties do
        Properties.Unretain(PropId)
    end

    Network.ObjectUnregistered:FireAll(Identifier)
    return true
end

-- Entries per packet, matching the join replay: one packet per object is what
-- made a large workspace flood the remote queue in a single frame.
const ANNOUNCE_CHUNK = 50

-- Splits a batch by the scene each entry's object belongs to and by how far
-- that object reaches. A scene has an audience per reach, and one transaction
-- is free to touch several scenes.
const function Group<T>(List: {T}, ObjectOf: (T) -> Object): {[Types.SceneIdentifier]: {[string]: {T}}}
    const Groups: {[Types.SceneIdentifier]: {[string]: {T}}} = {}
    for _, Entry in List do
        const Obj = ObjectOf(Entry)

        local ByReach = Groups[Obj.Scene]
        if not ByReach then
            ByReach = {}
            Groups[Obj.Scene] = ByReach
        end

        const Reach = ReachOf(Obj)
        local Entries = ByReach[Reach]
        if not Entries then
            Entries = {}
            ByReach[Reach] = Entries
        end

        table.insert(Entries, Entry)
    end

    return Groups
end

const function Itself(Obj: Object): Object
    return Obj
end

-- The chunked path every batch of whole objects goes down: a scene loading, a
-- transaction's creates, a player being told about a scene. Send is handed one
-- chunk at a time and answers whether to go on; Keep, where given, drops an
-- object at the moment it would have been packed.
const function SendObjects(
    List: {Object},
    Send: (RuntimeIds: {RuntimeId}, InstanceIds: {number}, Buffers: {buffer}, Instances: {any}) -> boolean,
    Keep: ((Object) -> boolean)?
)
    local RuntimeIds = {}
    local InstanceIds = {}
    local Buffers = {}
    local Instances = {}
    local Count = 0

    const function Flush(): boolean
        if Count == 0 then
            return true
        end

        const Continue = Send(RuntimeIds, InstanceIds, Buffers, Instances)
        RuntimeIds = {}
        InstanceIds = {}
        Buffers = {}
        Instances = {}
        Count = 0
        task.wait()
        return Continue
    end

    for _, Obj in List do
        if Obj.Destroyed or (Keep and not Keep(Obj)) then
            continue
        end

        Count += 1
        RuntimeIds[Count] = Obj.RuntimeId
        InstanceIds[Count] = Obj.InstanceId
        Buffers[Count] = Compressor:CompressObject(Obj :: any)
        Instances[Count] = Obj.Instance or false

        if Count >= ANNOUNCE_CHUNK and not Flush() then
            return
        end
    end

    Flush()
end

-- Announces a batch of objects to whoever has been told about the scene each
-- belongs to, down the same chunked path a joining player receives. A scene
-- loading uses this rather than letting each object announce itself as it is
-- built.
--
-- The audience is taken once, before the first chunk. Someone told about the
-- scene while this is still sending was handed these objects by that telling,
-- and sending them here as well would send them twice.
function Objects.AnnounceAll(List: {Object})
    for Scene, ByReach in Group(List, Itself) do
        for Key, Entries in ByReach do
            const Reach = Key :: Types.Reach
            const Hearing = Audience.Hearing(Scene, Reach)
            if next(Hearing) == nil then
                continue
            end

            SendObjects(Entries, function(RuntimeIds, InstanceIds, Buffers, Instances): boolean
                Audience.FireHearing(Network.ObjectsReplayed, Scene, Reach, Hearing, RuntimeIds, InstanceIds, Buffers, Instances)
                return true
            end)
        end
    end
end

-- One player's half of the same path, for a scene being revealed to them. Keep
-- is asked per object, so a scene withdrawn part way stops being sent.
function Objects.Stream(Plr: Player, List: {Object}, Keep: (Object) -> boolean)
    SendObjects(List, function(RuntimeIds, InstanceIds, Buffers, Instances): boolean
        if not Plr.Parent then
            return false
        end

        Network.ObjectsReplayed:Fire(Plr, RuntimeIds, InstanceIds, Buffers, Instances)
        return true
    end, Keep)
end

-- The reverse of Stream: one player losing objects they were sent, a chunk at a
-- time, for as long as Going says the loss still stands.
function Objects.Unsend(Plr: Player, RuntimeIds: {RuntimeId}, Going: () -> boolean)
    for Start = 1, #RuntimeIds, ANNOUNCE_CHUNK do
        if not Plr.Parent or not Going() then
            return
        end

        const Stop = math.min(Start + ANNOUNCE_CHUNK - 1, #RuntimeIds)
        Network.ObjectsRemoved:Fire(Plr, table.move(RuntimeIds, Start, Stop, 1, {}))
        task.wait()
    end
end

Objects.ReachOf = ReachOf

-- Destroys everything a scene instance holds without a packet per object. The
-- caller sends one naming the instance instead.
-- Every object of one copy withdrawn at once, and kept. The copy itself is
-- withdrawn around them -- see Scenes/Server -- so nothing here announces:
-- one packet says the copy is gone, which is all a client needs, and a removal
-- per object would be the flood the chunked paths exist to avoid.
--
-- The list comes back because the copy tables empty as this runs: each object
-- unfiles itself on the way out, which is what makes them findable nowhere
-- while they are away. Whatever holds the copy holds this beside it.
function Objects.SuspendInstance(Instance_: any): {Object}
    const Held = {}
    for _, Obj in table.clone(Instance_.Objects) do
        if Objects.Suspend(Obj, false) then
            table.insert(Held, Obj)
        end
    end

    table.clear(Instance_.Objects)
    table.clear(Instance_.ByLocal)
    return Held
end

-- The other direction, once the copy is back in place: silent again, and the
-- caller announces the lot in one go.
function Objects.ReviveInstance(Held: {Object}): {Object}
    const Back = {}
    for _, Obj in Held do
        if Objects.Revive(Obj, false) then
            table.insert(Back, Obj)
        end
    end

    return Back
end

function Objects.DisposeInstance(Held: {Object})
    for _, Obj in Held do
        Objects.Dispose(Obj)
    end
end

function Objects.DropInstance(Instance_: any)
    for _, Obj in table.clone(Instance_.Objects) do
        Teardown(Obj, false)
    end

    table.clear(Instance_.Objects)
    table.clear(Instance_.ByLocal)
end

-- The bulk counterpart to the PropertyChanged a single Set fires, chunked on
-- the same terms as the object replay. A transaction is one packet on the way
-- up; answering it with one packet per operation on the way down would put the
-- flood back where it was taken out.
--
-- Each change carries its object, because the object's scene and type are who
-- hears about it.
function Objects.AnnounceChanged(Changes: {{Object: Object, Property: PropertyTypes.PropertyIdentifier, Value: buffer}})
    for Scene, ByReach in Group(Changes, function(Change): Object
        return Change.Object
    end) do
        for Key, Entries in ByReach do
            const Reach = Key :: Types.Reach
            const Hearing = Audience.Hearing(Scene, Reach)
            if next(Hearing) == nil then
                continue
            end

            local RuntimeIds = {}
            local PropertyIds = {}
            local Values = {}
            local Count = 0

            const function Flush()
                if Count == 0 then
                    return
                end

                Audience.FireHearing(Network.PropertiesChanged, Scene, Reach, Hearing, RuntimeIds, PropertyIds, Values)
                RuntimeIds = {}
                PropertyIds = {}
                Values = {}
                Count = 0
            end

            for _, Change in Entries do
                Count += 1
                RuntimeIds[Count] = Change.Object.RuntimeId
                PropertyIds[Count] = Change.Property
                Values[Count] = Change.Value

                if Count >= ANNOUNCE_CHUNK then
                    Flush()
                    task.wait()
                end
            end

            Flush()
        end
    end
end

-- Objects going away together. A whole copy unloading is still one packet
-- naming the copy rather than a list naming its objects -- this is for a
-- transaction, which destroys some of a copy rather than all of it.
--
-- Handed the objects rather than their ids: they are already torn down, and
-- the scene each belonged to is the only way left to know who to tell.
function Objects.AnnounceRemoved(Removed: {Object})
    for Scene, ByReach in Group(Removed, Itself) do
        for Key, Entries in ByReach do
            const Reach = Key :: Types.Reach
            const Hearing = Audience.Hearing(Scene, Reach)
            if next(Hearing) == nil then
                continue
            end

            local Chunk = {}
            local Count = 0

            const function Flush()
                if Count == 0 then
                    return
                end

                Audience.FireHearing(Network.ObjectsRemoved, Scene, Reach, Hearing, Chunk)
                Chunk = {}
                Count = 0
            end

            for _, Obj in Entries do
                Count += 1
                Chunk[Count] = Obj.RuntimeId

                if Count >= ANNOUNCE_CHUNK then
                    Flush()
                    task.wait()
                end
            end

            Flush()
        end
    end
end

-- Destroys one object without a packet naming it, for a caller that will send
-- one covering the whole batch. Objects.DropInstance is the same idea for
-- everything a scene copy holds.
function Objects.Drop(Obj: Object)
    Teardown(Obj, false)
end


-- The client's twin, and always false here: a copy the server holds is the
-- server's, and there is no such thing as a scene this side owns privately.
-- Asked by the shared transaction builder, which decides what committing means
-- from the answer and must be able to ask either side.
function Objects:IsLocalCopy(_Live: Types.SceneInstanceId): boolean
    return false
end

function Objects:IsLocalScene(_Scene: Types.SceneIdentifier): boolean
    return false
end

function Objects:GetWorkspace(): {[RuntimeId]: Object}
    return Workspace
end

function Objects:Get(Identifier: RuntimeId): Object?
    return Workspace[Identifier]
end

-- The two halves of a persistent id, for a caller holding one that did not come
-- off an object. Objects carry Scene and LocalId already.
function Objects:Split(Persistent: Types.PersistentId): (Types.SceneIdentifier, number)
    return Handles.Split(Persistent)
end

-- The object a stored reference names, for a caller holding the raw local id
-- rather than reading it off a property. Scoped to a copy, because that is the
-- only scope a local id answers in.
function Objects:Resolve(Copy: Types.SceneInstanceId, Local: number): Object?
    return Find(Copy, Local)
end

-- What may be written into an Object property of an object in this copy, as a
-- local id, or nil and the reason it may not. Exported so a transaction makes
-- exactly the check Object:Set makes: a reference that means one thing through
-- a set and another through a transaction is worse than either rule alone.
function Objects.Reference(
    Copy: Types.SceneInstanceId,
    Prop: PropertyTypes.Property<any>,
    Value: any
): (number?, string?)
    return Shared.Reference(Copy, Prop, Value, Find)
end

function Objects:GetRegistered(): {[ObjectIdentifier]: ObjectRegistry}
    return Registered
end

function Objects:GetRegistry(Identifier: ObjectIdentifier): ObjectRegistry?
    return Registered[Identifier]
end

function Objects:GetRegistryPayload(Identifier: ObjectIdentifier)
    const Registry = Registered[Identifier]
    return if Registry then ToRegistryPayload(Registry) else nil
end

-- Everything being in the world means: a part of its own, links wired to it, a
-- place in the copy and in the workspace, and the packet saying so. The inverse
-- of Withdraw, and written once rather than twice because an object that comes
-- back from a suspend has to arrive exactly as one that was just built does --
-- anything this did that reviving forgot would be a difference nobody would
-- find until an undone destroy behaved unlike the object it restored.
--
-- The registry instance is a template. Handing the same one to every object
-- meant they all drove the same part, and destroying any one of them took the
-- part away from the rest.
--
-- Stamped and tagged before it is parented, so the handle and the tag replicate
-- together with the instance and a client that only ever sees the part -- never
-- the reference sent beside the object -- can still find its owner. None at all
-- in an opened copy, whose parts each admitted client draws.
const function Enter(Obj: any, Ref: ObjectRegistry, Instance_: any, Announce: boolean, Restored: boolean?)
    -- Already holding one means this object has been here before and was
    -- withdrawn rather than destroyed: its part was parented out of the world
    -- and kept, so it goes back rather than being cloned again. Cloning would
    -- hand back a part that only looks like the one that left.
    local Inst: Instance? = Obj.Instance

    if Inst then
        Inst.Parent = Instance_.Folder
    elseif Ref.Instance and not Instance_.Opened then
        const Clone = Ref.Instance:Clone()
        Clone:SetAttribute(Shared.RuntimeAttribute, Obj.RuntimeId)
        CollectionService:AddTag(Clone, Shared.ObjectTag)

        -- Into the copy holding it, and nowhere else. Which copy rather than
        -- which scene, because two copies of one room have to be able to sit
        -- in two places -- and where that is, is the copy's folder's business
        -- rather than this object's.
        Clone.Parent = Instance_.Folder

        Inst = Clone
    end

    Obj.Instance = Inst

    -- Wired after the values are in place, so a link starts at the object's own
    -- value rather than at the registry default and then being corrected.
    Obj.Links = Shared.BuildLinks(Inst, Ref.Links, Obj.Properties)

    Obj.Get = __getter
    Obj.Set = __setter
    Obj.GetProperty = Shared.GetProperty
    Obj.OnChange = Shared.OnChange
    Obj.Destroy = __destroy

    Obj.Release = function()
        Instance_.Objects[Obj.RuntimeId] = nil

        -- Only if it is still the one filed there. Restoring refuses a
        -- duplicate, so it always is, but a scene tearing down while another
        -- rebuilds must not have the loser clear the winner's entry.
        if Instance_.ByLocal[Obj.LocalId] == Obj then
            Instance_.ByLocal[Obj.LocalId] = nil
        end
    end

    Workspace[Obj.RuntimeId] = Obj
    Instance_.Objects[Obj.RuntimeId] = Obj
    Instance_.ByLocal[Obj.LocalId] = Obj

    -- Only the compressed values go out. Firing the live object sent Property
    -- tables carrying Set/SetDefault functions and links carrying connections,
    -- neither of which a remote can serialize, so this threw every time.
    --
    -- A scene being loaded announces nothing here: its objects go out together
    -- through the chunked replay path instead of one packet each.
    --
    -- ReachOf rather than the type's Replicate, as every other packet about an
    -- object: an object in an opened copy is for the admitted whatever its type
    -- says. Reading Replicate here sent every object created in a private
    -- opened copy, values and all, to every player in the server.
    if Announce then
        Audience.Fire(
            Network.ObjectAdded,
            Obj.Scene,
            ReachOf(Obj),
            Obj.RuntimeId,
            Instance_.Id,
            Compressor:CompressObject(Obj),
            Inst
        )
    end

    -- After the packet, and fired whether or not there was one.
    Listeners.Notify(Added, Obj, Restored == true)
end

-- InitialValues are applied before the links are wired and before the broadcast.
-- Restoring a saved object used to call Objects.new and then Set once per
-- property, which broadcast the defaults and then one PropertyChanged for each
-- property -- a 500 object level at ten properties each cost several thousand
-- packets, and every object's first packet carried state that was already wrong.
--
-- LocalId is the object's id within its scene. Creating mints the next one;
-- restoring from a pack passes the id the object was saved under, which is the
-- whole reason a saved reference still names the same object after a reload.
const function Construct(
    Reference: ObjectRegistry | ObjectIdentifier,
    InitialValues: {[PropertyTypes.PropertyIdentifier]: any}?,
    Instance_: any,
    LocalId: number?,
    Announce: boolean
): Object
    const TypeOf = typeof(Reference)
    local Ref: ObjectRegistry

    if TypeOf == "number" then
        Ref = Registered[Reference :: ObjectIdentifier]
        if not Ref then
            Logger:Error(`Invalid object reference. No object registered with id {Reference}.`)
        end
    elseif TypeOf == "table" then
        Ref = Reference :: ObjectRegistry
    else
        Logger:Error(`Invalid object reference. Expected a registry or an id, got {TypeOf}.`)
    end

    if not Ref or not Ref.Id or not Registered[Ref.Id] then
        Logger:Error("Invalid object reference. The registry it points at is not registered.")
    end

    if not Instance_ then
        Logger:Error("Tried creating an object with no live scene. Either Prism.Scenes was never required -- it registers the default one -- or the scene named is unloaded.")
    end

    const Owner = Instance_.Owner

    local Local = LocalId
    if Local then
        -- Restored under the id it was saved with. Refused rather than allowed
        -- to overwrite, because within one instance a persistent id still has
        -- to name exactly one object -- that is what makes Find answerable.
        if Instance_.ByLocal[Local] then
            Logger:Error(`Scene {Owner.Name} already holds an object with local id {Local} in this instance.`)
        end

        -- The counter only ever climbs, so a pack whose ids came from a longer
        -- lived scene cannot make the next created object reuse one.
        Owner.LastId = math.max(Owner.LastId, Local)
    else
        if Owner.LastId >= Handles.MAX_LOCAL then
            Logger:Error(`Scene {Owner.Name} has exhausted its object id space.`)
        end

        Owner.LastId += 1
        Local = Owner.LastId
    end

    if RuntimeCounter >= MAX_RUNTIME_ID then
        Logger:Error("Runtime id space exhausted.")
    end

    RuntimeCounter += 1
    const RuntimeId = RuntimeCounter
    const Persistent = Handles.Join(Instance_.Scene, Local :: number)

    -- The registry instance is a template. Handing the same one to every object
    -- meant they all drove the same part, and destroying any one of them took
    -- the part away from the rest.
    --
    -- Stamped and tagged before it is parented, so the handle and the tag
    -- replicate together with the instance and a client that only ever sees the
    -- part -- never the reference sent beside the object -- can still find its
    -- owner.
    --
    const Props = Shared.BuildProperties(Ref.Properties)
    if InitialValues then
        for PropertyId, Value in InitialValues do
            const Prop = Props[PropertyId]
            if not Prop then
                continue
            end

            -- Against the copy the object is going into, which is the only
            -- copy its references will ever mean anything in. The object
            -- itself does not exist yet, and does not need to: a reference is
            -- read against the copy, not against whoever holds it.
            if Prop.Type == "Object" then
                const Target, Why = Shared.Reference(Instance_.Id, Prop, Value, Find)
                if Target == nil then
                    Logger:Warn(`Dropped the initial value of {Prop.Name} on {Ref.Name}: {Why}.`)
                    continue
                end

                Prop:Set(Target)
                continue
            end

            Prop:Set(Value)
        end
    end

    const Obj = {}
    Obj.RuntimeId = RuntimeId
    Obj.PersistentId = Persistent
    Obj.Scene = Instance_.Scene
    Obj.LocalId = Local
    Obj.InstanceId = Instance_.Id
    Obj.Registry = Ref.Id
    Obj.Name = Ref.Name
    Obj.Destroyed = false
    Obj.Properties = Props
    Obj.Names = Shared.BuildNameMap(Ref.Properties, Props)

    -- Restored when it was given the id it was saved under, which is a copy
    -- reading its pack rather than anybody creating anything.
    Enter(Obj, Ref, Instance_, Announce, LocalId ~= nil)
    return Obj :: any
end

--=============================================================================
-- Retiring
--=============================================================================

-- A destroy is not always final. One a player asked for is withdrawn from the
-- world and then offered to whatever might want it back: History keeps it on
-- that player's stack, so an undo restores that object, under its own local id,
-- and everything that pointed at it is pointing at it again. Only when nothing
-- wants it -- a game that never requires History, a step that has fallen off
-- the end of the stack -- is it disposed, and that is the only point at which
-- the values are gone.
--
-- A destroy the world imposes is still final and immediate: a scene unloading,
-- a type unregistering, a server script calling Object:Destroy. Nobody asked
-- for those and there is nothing to take back.

const Keepers: {(Plr: Player?, Obj: Object) -> boolean} = {}

-- A property a player changed through the single set channel, with the value
-- either side. What a transaction does is told through Transactions.OnApplied
-- instead, whole rather than one property at a time. Synchronous, like the
-- keepers below: a history recording these has to see them in the order they
-- happened, and a spawned callback only mostly does.
const Edited: {(Plr: Player, Obj: Object, Property: PropertyTypes.PropertyIdentifier, Before: any, After: any) -> ()} = {}

-- This player's own edits, for a history to record. Not the server's, which
-- belong to nobody and are nobody's to undo.
function Objects.OnPlayerEdited(
    Callback: (Plr: Player, Obj: Object, Property: PropertyTypes.PropertyIdentifier, Before: any, After: any) -> ()
): () -> ()
    return Listeners.Watch(Edited, Callback, "player edits")
end

-- Deliberately not Listeners.Notify: a keeper answers, and it answers before
-- the caller moves on. A callback spawned on a thread of its own could do
-- neither, and the object would be disposed while the answer was still coming.
function Objects.OnRetired(Callback: (Plr: Player?, Obj: Object) -> boolean): () -> ()
    return Listeners.Watch(Keepers, Callback, "retired objects")
end

-- Out of the world, still itself. True if it went; false if it was already
-- gone, which makes suspending idempotent the way destroying is.
function Objects.Suspend(Obj: Object, Announce: boolean?): boolean
    if Obj.Destroyed then
        return false
    end

    Obj.Destroyed = true
    Obj.Suspended = true
    Withdraw(Obj, Announce ~= false)
    return true
end

-- Back where it was, as itself: the same table, the same runtime id, the same
-- local id. False when the copy it belonged to has gone, which is the one thing
-- no undo can work around -- there is nowhere to put it, and its local id means
-- nothing outside the copy that issued it.
function Objects.Revive(Obj: Object, Announce: boolean?): boolean
    if not Obj.Suspended then
        return false
    end

    const Instance_ = SceneRegistry.Instances[Obj.InstanceId]
    const Ref = Registered[Obj.Registry]
    if not Instance_ or not Ref then
        return false
    end

    -- Its id is still its own: a scene's counter only ever climbs, so nothing
    -- was ever given this id to hold in the meantime.
    if Instance_.ByLocal[Obj.LocalId] then
        return false
    end

    Obj.Suspended = nil
    Obj.Destroyed = false

    -- Announced unless the caller knows nobody was told it went: a transaction
    -- that rolls its own destroys back suspended them silently, and an added
    -- packet for an object no client ever stopped drawing would draw a second.
    Enter(Obj, Ref, Instance_, Announce ~= false)
    return true
end

-- The end of a suspended object. Everything else about it was already done
-- when it was withdrawn; this is only the values letting go.
function Objects.Dispose(Obj: Object)
    if not Obj.Suspended then
        return
    end

    Dispose(Obj)
end

-- Suspend, offer, and dispose if nobody wanted it. The single destroy channel's
-- path; a transaction suspends its destroys itself, because what claims them is
-- the record of the whole transaction rather than each object on its own.
function Objects.Retire(Plr: Player?, Obj: Object, Announce: boolean?)
    if not Objects.Suspend(Obj, Announce) then
        return
    end

    for _, Keeper in Keepers do
        if Keeper(Plr, Obj) then
            return
        end
    end

    Dispose(Obj)
end

-- Loaded the first time anything needs it rather than when it registers, so a
-- game that puts everything in scenes of its own never pays for this one.
const function DefaultInstance(): any
    const Scene = SceneRegistry.Default
    if not Scene then
        return nil
    end

    const _, Existing = next(Scene.Instances)
    return Existing or Scene:Load()
end

-- A live copy is what an object goes into, but callers reach for the scene, so
-- both are taken. A Scene is the one carrying Instances; a SceneInstance
-- carries Owner.
const function ResolveInstance(Target: any): any
    if not Target then
        return DefaultInstance()
    end

    if not Target.Instances then
        return Target
    end

    const First, Instance_ = next(Target.Instances)
    if not First then
        Logger:Error(`Scene {Target.Name} has no live copy to put an object in. Load it first.`)
    end

    -- Resolved only while there is one obvious answer. A scene loaded twice
    -- names two equally good copies, and quietly picking one would put the
    -- object somewhere the caller did not choose.
    if next(Target.Instances, First) then
        Logger:Error(`Scene {Target.Name} is loaded more than once, so which copy this object belongs in is ambiguous. Name the copy.`)
    end

    return Instance_
end

-- Announce defaults to true and is the caller's only where it has a batch to
-- send instead: a transaction builds its objects silently and announces them
-- together, down the same chunked path a scene load uses.
function Objects.new(
    Reference: ObjectRegistry | ObjectIdentifier,
    InitialValues: {[PropertyTypes.PropertyIdentifier]: any}?,
    Target: any?,
    Announce: boolean?
): Object
    return Construct(Reference, InitialValues, ResolveInstance(Target), nil, Announce ~= false)
end

-- Rebuilds an object under the id it was saved with. Used by a scene loading its
-- pack; Announce is the caller's, because a load sends its objects in bulk.
function Objects.restore(Target: any, Decompressed: any, Announce: boolean?): Object?
    if not Registered[Decompressed.Registry] then
        Logger:Warn(`Failed to restore object. Object type {Decompressed.Registry} is not registered.`)
        return nil
    end

    const Obj = Construct(
        Decompressed.Registry,
        Decompressed.Properties,
        ResolveInstance(Target),
        Decompressed.LocalId,
        Announce == true
    )

    Obj.Unknown = Shared.Leftovers(Obj, Decompressed)
    return Obj
end

-- A new object of the same type holding the same values: in the copy the
-- original sits in, or in Target when one is named. A new local id and a new
-- part; nothing is shared with the original from here on.
function Objects:Duplicate(Obj: Object, Target: any?): Object?
    if Obj.Destroyed then
        return nil
    end

    const New = Objects.new(Obj.Registry, Shared.Snapshot(Obj), Target or SceneRegistry.Instances[Obj.InstanceId])

    -- Kept values travel with the rest, or duplicating a room and deleting the
    -- original would lose them as surely as the save used to.
    New.Unknown = if Obj.Unknown then table.clone(Obj.Unknown) else nil
    return New
end

-- Several objects duplicated as one thing, which is not the same as duplicating
-- each of them. A reference is copied verbatim by Duplicate, so a duplicated
-- button still points at the original door -- right for one object, wrong for a
-- room copied whole, where the new button should point at the new door.
--
-- So: references that point inside the group are remapped onto the new objects,
-- and references that point outside it are left alone. A path node duplicated
-- with the node it points at follows its copy; a lever duplicated on its own
-- still works the door it always worked.
--
-- Silent creates and one announcement at the end, down the chunked path a scene
-- load uses. Announcing each object as it is made would send every reference
-- twice: once pointing at the original, once corrected a moment later.
function Objects:DuplicateGroup(List: {Object}, Target: any?): {Object}
    const Sources: {Object} = {}
    const Made: {Object} = {}

    -- Which new object stands for which original. Keyed by the object rather
    -- than by its local id, because a group can span copies and two copies
    -- hand out the same ids.
    const Counterpart: {[Object]: Object} = {}

    for _, Obj in List do
        if Obj.Destroyed then
            continue
        end

        const New = Objects.new(
            Obj.Registry,
            Shared.Snapshot(Obj),
            Target or SceneRegistry.Instances[Obj.InstanceId],
            false
        )

        New.Unknown = if Obj.Unknown then table.clone(Obj.Unknown) else nil

        table.insert(Sources, Obj)
        table.insert(Made, New)
        Counterpart[Obj] = New
    end

    for Index, New in Made do
        const Source = Sources[Index]

        for PropertyId, Prop in New.Properties do
            if Prop.Type ~= "Object" then
                continue
            end

            -- Read from the original, against the original's copy: that is
            -- where the id it was written with means what it meant. The
            -- duplicate holds the same id, but nothing says it names the same
            -- object there.
            const Was = Source.Properties[PropertyId]
            const Pointed = if Was then Shared.ResolveReference(Source.InstanceId, Was.Value, Find) else nil
            if not Pointed then
                continue
            end

            const Instead = Counterpart[Pointed]
            if Instead then
                Prop:Set(Instead.LocalId)
            end
        end
    end

    if #Made > 0 then
        Objects.AnnounceAll(Made)
    end

    return Made
end

-- A copy, not a restore. The buffer carries the id its original was saved
-- under, and handing that to the new object would alias the two while both are
-- live -- so this mints a fresh one. Loading a scene wants the saved id and
-- calls restore instead, on a scene where the original is gone.
function Objects.fromCompression(CompressedObj: buffer, Target: any?): Object?
    const Ok, Decompressed = pcall(function()
        return Compressor:DecompressObject(CompressedObj)
    end)

    if not Ok or not Decompressed then
        Logger:Warn("Failed to create object from compression.")
        return nil
    end

    if not Registered[Decompressed.Registry] then
        Logger:Warn(`Failed to create object from compression. Object type {Decompressed.Registry} is not registered.`)
        return nil
    end

    return Construct(
        Decompressed.Registry,
        Decompressed.Properties,
        ResolveInstance(Target),
        nil,
        true
    )
end

--=============================================================================
-- Locks
--=============================================================================

-- A lock is explicit: a client takes one when it starts on an object, and while
-- it holds it nobody else may edit or destroy that object. Presence comes with
-- it -- who holds what is told to the players the object's scene admits, and
-- nobody else, because who is editing a private level is part of the level.

-- The most one request may name, for the same reason a transaction has a cap.
const MAX_LOCKS = 1024

-- The person a holder stands for, or nil where it stands for nobody. A bare
-- number is a user id, the way it is everywhere else a person is named -- Admit,
-- Evict and Grant all take a Player or a user id -- so releasing what somebody
-- holds works from either.
const function UserIdOf(Who: any): number?
    if typeof(Who) == "Instance" and Who:IsA("Player") then
        return (Who :: Player).UserId
    end

    if type(Who) == "number" then
        return Who
    end

    if type(Who) == "table" and type(Who.UserId) == "number" then
        return Who.UserId
    end

    return nil
end

-- Who holds what, to the players each object's scene admits. Zero means free.
const function AnnounceLocks(Changed: {Object})
    const ByScene: {[Types.SceneIdentifier]: {Ids: {RuntimeId}, Holders: {number}, Held: {boolean}}} = {}

    for _, Obj in Changed do
        local Batch = ByScene[Obj.Scene]
        if not Batch then
            Batch = {Ids = {}, Holders = {}, Held = {}}
            ByScene[Obj.Scene] = Batch
        end

        const Held = Locks[Obj.RuntimeId]
        table.insert(Batch.Ids, Obj.RuntimeId)

        -- Zero where the holder is not a person. Held is what says whether
        -- there is a hold, so zero is a user id nobody has rather than a way of
        -- saying free.
        table.insert(Batch.Holders, if Held then Held.UserId or 0 else 0)
        table.insert(Batch.Held, Held ~= nil)
    end

    for Scene, Batch in ByScene do
        Audience.Fire(Network.LocksChanged, Scene, "Admitted", Batch.Ids, Batch.Holders, Batch.Held)
    end
end

-- Takes every object named for Who, or none of them: an object someone else
-- holds refuses the lot, so a multi-object drag never ends up half held.
-- Taking one Who already holds is not a refusal.
-- Whether two holders are the same one. By user id where both resolve to a
-- person, so a Player and a table standing in for the same player are one
-- holder; by identity otherwise, which is what lets anything at all hold an
-- object.
const function SameHolder(Held: {UserId: number?, Holder: any}, Who: any): boolean
    const UserId = UserIdOf(Who)
    if UserId and Held.UserId then
        return Held.UserId == UserId
    end

    return Held.Holder == Who
end

function Objects:Lock(List: {Object}, Who: any): boolean
    if Who == nil then
        return false
    end

    for _, Obj in List do
        const Held = Locks[Obj.RuntimeId]
        if Obj.Destroyed or (Held and not SameHolder(Held, Who)) then
            return false
        end
    end

    const UserId = UserIdOf(Who)
    for _, Obj in List do
        Locks[Obj.RuntimeId] = {UserId = UserId, Holder = Who}
    end

    AnnounceLocks(List)
    return true
end

-- Releases what Who holds among the objects named. With no Who it is the
-- server releasing anyone's. Answers false if any named object is held by
-- someone else, which stays theirs; the rest are released regardless.
function Objects:Unlock(List: {Object}, Who: any?): boolean
    const Released = {}
    local All = true

    for _, Obj in List do
        const Held = Locks[Obj.RuntimeId]
        if not Held then
            continue
        end

        if Who ~= nil and not SameHolder(Held, Who) then
            All = false
            continue
        end

        Locks[Obj.RuntimeId] = nil
        table.insert(Released, Obj)
    end

    if #Released > 0 then
        AnnounceLocks(Released)
    end

    return All
end

-- The user id holding an object, or nil when it is free.
-- The user id holding an object, nil when it is free or held by something that
-- is not a person. GetHolder is the whole answer; this is the part a client can
-- be told and the part a game usually wants.
function Objects:GetLock(Obj: Object): number?
    const Held = Locks[Obj.RuntimeId]
    return if Held then Held.UserId else nil
end

function Objects:GetHolder(Obj: Object): any?
    const Held = Locks[Obj.RuntimeId]
    return if Held then Held.Holder else nil
end

function Objects:IsLocked(Obj: Object): boolean
    return Locks[Obj.RuntimeId] ~= nil
end

-- Everything one holder has, let go at once. What a player being evicted from a
-- scene comes down to, and what losing the right to edit one comes down to:
-- both leave somebody holding objects they may no longer touch, and nobody else
-- able to touch them either.
--
-- Scoped to a scene when one is named, because being shut out of one room is
-- not being shut out of the others.
function Objects.ReleaseFor(Who: any, Scene: Types.SceneIdentifier?)
    const Released = {}

    for Identifier, Held in Locks do
        if not SameHolder(Held, Who) then
            continue
        end

        const Obj = Workspace[Identifier]
        if Obj and (Scene == nil or Obj.Scene == Scene) then
            table.insert(Released, Obj)
        end
    end

    if #Released > 0 then
        Objects:Unlock(Released)
    end
end

-- Whether someone other than Plr holds the object, which is what every edit
-- path asks before it lets one through.
function Objects.LockedAgainst(Obj: Object, Who: any): boolean
    const Held = Locks[Obj.RuntimeId]
    return Held ~= nil and not SameHolder(Held, Who)
end

-- The locks among some objects, for a player a scene is being revealed to:
-- they are owed who holds what as well as the objects themselves.
function Objects.SendLocks(Plr: Player, List: {Object})
    const Ids = {}
    const Holders = {}
    const Flags = {}

    for _, Obj in List do
        const Held = Locks[Obj.RuntimeId]
        if Held and not Obj.Destroyed then
            table.insert(Ids, Obj.RuntimeId)

            -- Zero where the holder is not a person, exactly as AnnounceLocks
            -- sends it. UserId is nil for a holder that is a module or a
            -- string, and table.insert of a nil leaves a hole that shifts
            -- every later holder against its id.
            table.insert(Holders, Held.UserId or 0)
            table.insert(Flags, true)
        end
    end

    if #Ids > 0 then
        Network.LocksChanged:Fire(Plr, Ids, Holders, Flags)
    end
end

-- Resolves what a client named, refusing the whole request over one it may not
-- have: an object that is gone, in a scene it was never admitted to, or one it
-- may not edit. A lock on something you cannot change would only be a way to
-- stop others changing it.
const function Claimable(Plr: Player, Ids: {RuntimeId}): {Object}?
    if #Ids > MAX_LOCKS or not Permissions:Consume(Plr, #Ids) then
        return nil
    end

    const List = {}
    for _, Identifier in Ids do
        const Obj = Workspace[Identifier]
        if not Obj or Obj.Destroyed or not Audience.Sees(Plr, Obj.Scene) or not Permissions:Can(Plr, "Edit", Obj) then
            return nil
        end

        table.insert(List, Obj)
    end

    return List
end

Network.Lock.OnInvoke = function(Plr: Player, Ids: {RuntimeId}): boolean
    const List = Claimable(Plr, Ids)
    return List ~= nil and Objects:Lock(List, Plr)
end

-- Releasing needs no rights: a player who lost them since should still be able
-- to let go. Objects that are gone are simply skipped.
Network.Unlock.OnInvoke = function(Plr: Player, Ids: {RuntimeId}): boolean
    if #Ids > MAX_LOCKS or not Permissions:Consume(Plr) then
        return false
    end

    const List = {}
    for _, Identifier in Ids do
        const Obj = Workspace[Identifier]
        if Obj and not Obj.Destroyed then
            table.insert(List, Obj)
        end
    end

    return Objects:Unlock(List, Plr)
end

-- A lock goes with the connection it was taken on.
-- A hold goes with whoever had it. Leaving is the obvious way to lose one;
-- Permissions below is the other, and Scenes calls ReleaseFor when it evicts
-- somebody.
Players.PlayerRemoving:Connect(function(Plr: Player)
    Objects.ReleaseFor(Plr)
end)

-- Rights over a scene changed for somebody. A hold is worth having only where
-- an edit would be allowed, so one held by a player who may no longer edit
-- there is a hold nobody benefits from and nobody else can take: they keep the
-- object to themselves without being able to do anything with it.
Permissions.OnSceneRights(function(UserId: number, Scene: Types.SceneIdentifier)
    -- By user id throughout. Asking Players for the person would answer nil for
    -- anybody not connected, and rights are granted to people who have not
    -- arrived yet -- Scenes.new takes a whole collaborator list.
    const Rights = Permissions:GetOn(Scene, UserId)
    if Rights and Rights.CanEdit then
        return
    end

    Objects.ReleaseFor(UserId, Scene)
end)

Network.SetProperty.OnInvoke = function(Plr: Player, Identifier: RuntimeId, PropId: PropertyTypes.PropertyIdentifier, Compressed: buffer): boolean
    -- Budget first. Check used to run after the workspace lookup, so a client
    -- spamming runtime ids that do not exist returned early and never spent any
    -- of its allowance -- the one flood the limiter most needed to catch.
    if not Permissions:Consume(Plr) then
        return false
    end

    const Obj = Workspace[Identifier]
    if not Obj or Obj.Destroyed then
        return false
    end

    -- A scene this player was never admitted to is one they have not been told
    -- exists, so its objects are answered for exactly as missing ones are.
    -- Holding rights over such a scene is inert rather than clever, and this is
    -- what makes it so.
    if not Audience.Sees(Plr, Obj.Scene) then
        return false
    end

    if Objects.LockedAgainst(Obj, Plr) then
        return false
    end

    if not Permissions:Can(Plr, "Edit", Obj, PropId) then
        return false
    end

    const Prop = Obj.Properties[PropId]
    if not Prop then
        return false
    end

    -- The payload is self describing, so this also confirms the client sent the
    -- type the property actually expects rather than trusting it to.
    const Ok, Value, Type = pcall(function()
        const Decoded, _, DecodedType = Compressor:DecompressValue(Compressed, 0)
        return Decoded, DecodedType
    end)

    if not Ok or Type ~= Prop.Type then
        return false
    end

    -- Read before the write and compared after, because a set that changed
    -- nothing is not a step: a drag issuing one per frame would otherwise fill
    -- a player's history with entries that undo to themselves.
    const Before = Prop.Value
    if not Obj:Set(PropId, Value) then
        return false
    end

    if Prop.Value ~= Before then
        for _, Callback in Edited do
            Callback(Plr, Obj, PropId, Before, Prop.Value)
        end
    end

    return true
end

Network.Destroy.OnInvoke = function(Plr: Player, Identifier: RuntimeId): boolean
    if not Permissions:Consume(Plr) then
        return false
    end

    const Obj = Workspace[Identifier]
    if not Obj or Obj.Destroyed or not Audience.Sees(Plr, Obj.Scene) then
        return false
    end

    if Objects.LockedAgainst(Obj, Plr) then
        return false
    end

    if not Permissions:Can(Plr, "Destroy", Obj) then
        return false
    end

    -- Retired rather than destroyed: a player's own destroy is theirs to take
    -- back, and this is the channel a lone Object:Destroy on the client comes
    -- down. Nothing keeping it means it is gone as immediately as it used to
    -- be.
    Objects.Retire(Plr, Obj, true)
    return true
end

return Objects
