--!strict
const CollectionService = game:GetService("CollectionService")

const Properties = require("../Properties/Client")
const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const Network = require("./Network")
const Shared = require("./Shared")
const Handles = require("../Handles")
const Logger = require("../Logger")
const Listeners = require("../Listeners")
const Types = require("./Types")

export type ObjectIdentifier = Types.ObjectIdentifier
export type ObjectRegistry = Types.ObjectRegistry
export type RuntimeId = Types.RuntimeId
export type Object = Types.Object

const Objects = {}

const Registered: {[ObjectIdentifier]: ObjectRegistry} = {}
const Workspace: {[RuntimeId]: Object} = {}
const ByPart: {[Instance]: RuntimeId} = setmetatable({}, {__mode = "k"}) :: any

-- The other direction, and the reason an object can find its instance at all
-- when the reference sent beside it did not survive: a tagged part carries its
-- runtime id, so it can be filed here before its object arrives and claimed
-- afterwards. Weak valued, so a part that is destroyed or streamed out is not
-- held here by this table alone.
const ByRuntimeId: {[RuntimeId]: Instance} = setmetatable({}, {__mode = "v"}) :: any

-- Objects grouped by the live scene copy holding them. A copy going away is one
-- packet naming it, not an ObjectRemoved per object, so the client has to be
-- able to answer for a whole copy without walking the workspace.
--
-- By copy and not by scene, because a scene can be live more than once and an
-- editor showing two copies of one room has to keep them apart.
const ByInstance: {[Types.SceneInstanceId]: {[RuntimeId]: Object}} = {}

-- The same objects by the id a reference names them with, per copy. A local id
-- is unique only inside one copy, so this is two levels deep for the same
-- reason instance:Find is scoped to a copy.
const LocalIds: {[Types.SceneInstanceId]: {[number]: Object}} = {}

-- Which scene each live copy came from. Kept here rather than in Scenes/Client
-- because an arriving object needs it to work out its own persistent identity,
-- and Objects cannot require Scenes without a cycle.
const InstanceScene: {[Types.SceneInstanceId]: Types.SceneIdentifier} = {}

-- The folder this client draws each opened copy into. A copy with no entry
-- here is one the server loaded, whose parts are the server's.
const DrawInto: {[Types.SceneInstanceId]: Folder} = {}

-- Every object appearing here and going, whichever way it came: replicated
-- from the server, built in a scene this client owns, or drawn for a copy the
-- server opened. UI used to poll GetWorkspace to notice any of it.
const Added: {(Obj: Object) -> ()} = {}
const Removed: {(Obj: Object) -> ()} = {}

-- This client's own edits through Object:Set, with the value either side --
-- which is what an undo history records. Not changes arriving from the server
-- or another player, and not a refused set rolling back.
const Edited: {(Obj: Object, Property: PropertyTypes.PropertyIdentifier, Before: any, After: any) -> ()} = {}

function Objects:OnEdited(Callback: (Obj: Object, Property: PropertyTypes.PropertyIdentifier, Before: any, After: any) -> ()): () -> ()
    return Listeners.Watch(Edited, Callback, "edits")
end

-- Fired once the object is filed everywhere it will be, so a listener can look
-- it up by runtime id or through its copy straight away.
function Objects:OnAdded(Callback: (Obj: Object) -> ()): () -> ()
    return Listeners.Watch(Added, Callback, "objects appearing")
end

-- Fired after teardown, so the object handed over already reports Destroyed
-- and is gone from the workspace. It still carries its ids, which is what a
-- listener needs to drop whatever it kept for it.
function Objects:OnRemoved(Callback: (Obj: Object) -> ()): () -> ()
    return Listeners.Watch(Removed, Callback, "objects going")
end

--=============================================================================
-- Locks
--=============================================================================

-- Who holds each locked object, by runtime id, as the server last said. Told
-- only for scenes this player is admitted to.
const Locks: {[RuntimeId]: number} = {}
const LockChanged: {(RuntimeId: RuntimeId, UserId: number?) -> ()} = {}

const function Named(Refs: Object | {Object}): {Object}
    return if (Refs :: any).RuntimeId ~= nil then {Refs :: Object} else Refs :: {Object}
end

-- The ids worth asking the server about. An object in a scene this client owns
-- is nobody else's to touch, so there is nothing to lock.
const function Remote(List: {Object}): {RuntimeId}
    const Ids = {}
    for _, Obj in List do
        if not Obj.Local and not Obj.Destroyed then
            table.insert(Ids, Obj.RuntimeId)
        end
    end

    return Ids
end

-- Takes an object, or several at once, all or none. Yields for the server's
-- answer: while this player holds them, nobody else may edit or destroy them.
function Objects:Lock(Refs: Object | {Object}): boolean
    const Ids = Remote(Named(Refs))
    if #Ids == 0 then
        return true
    end

    const Ok, Granted = pcall(function()
        return Network.Lock:Invoke(Ids)
    end)

    return Ok and Granted == true
end

-- Lets go of what this player holds among the objects named. False if any of
-- them is held by someone else.
function Objects:Unlock(Refs: Object | {Object}): boolean
    const Ids = Remote(Named(Refs))
    if #Ids == 0 then
        return true
    end

    const Ok, Released = pcall(function()
        return Network.Unlock:Invoke(Ids)
    end)

    return Ok and Released == true
end

-- The user id holding an object, or nil when it is free -- or when this player
-- is not admitted to its scene, and so is not told.
function Objects:GetLock(Ref: Object | RuntimeId): number?
    return Locks[if type(Ref) == "number" then Ref else Ref.RuntimeId]
end

-- Fired with a runtime id and the user id now holding it, nil once free.
function Objects:OnLockChanged(Callback: (RuntimeId: RuntimeId, UserId: number?) -> ()): () -> ()
    return Listeners.Watch(LockChanged, Callback, "locks")
end

-- A scene this player is no longer admitted to stops telling them its locks,
-- so what they knew of them is dropped rather than left to go stale.
function Objects.ForgetLocks(Scene: Types.SceneIdentifier)
    for Identifier in table.clone(Locks) do
        const Obj = Workspace[Identifier]
        if not Obj or Obj.Scene == Scene then
            Locks[Identifier] = nil
            Listeners.Notify(LockChanged, Identifier, nil)
        end
    end
end

const function Index(Obj: Object)
    local Held = ByInstance[Obj.InstanceId]
    if not Held then
        Held = {}
        ByInstance[Obj.InstanceId] = Held
    end

    Held[Obj.RuntimeId] = Obj

    local ByLocal = LocalIds[Obj.InstanceId]
    if not ByLocal then
        ByLocal = {}
        LocalIds[Obj.InstanceId] = ByLocal
    end

    ByLocal[Obj.LocalId] = Obj
end

const function Unindex(Obj: Object)
    const ByLocal = LocalIds[Obj.InstanceId]
    if ByLocal then
        -- Only if it is still the one filed there, like the server's Release.
        -- An object rebuilt under the id a torn down one held must not have the
        -- loser clear the winner's entry.
        if ByLocal[Obj.LocalId] == Obj then
            ByLocal[Obj.LocalId] = nil
        end

        if next(ByLocal) == nil then
            LocalIds[Obj.InstanceId] = nil
        end
    end

    const Held = ByInstance[Obj.InstanceId]
    if not Held then
        return
    end

    Held[Obj.RuntimeId] = nil
    if next(Held) == nil then
        ByInstance[Obj.InstanceId] = nil
    end
end

-- One object in one copy by the id a reference stores. The server reads its
-- copy's ByLocal for this; a copy the server owns has no such table on this
-- side, so the index above is kept for every object the client holds however it
-- arrived -- replicated, drawn, or built in a scene this client owns.
const function Find(Copy: Types.SceneInstanceId, Local: number): Object?
    const ByLocal = LocalIds[Copy]
    return if ByLocal then ByLocal[Local] else nil
end

-- Every optimistic set takes a ticket, and only the newest outstanding one for
-- a property is allowed to roll back. Dragging issues a set per frame: without
-- this, a refusal for frame 1 arriving after frame 2 applied would roll the
-- value back to what it held before frame 1 and discard frame 2 entirely.
-- Weak keyed so a destroyed object's properties do not pin entries here.
local Ticket = 0
const Pending: {[any]: number} = setmetatable({}, {__mode = "k"}) :: any

-- The value the server has actually asserted for a property. A refusal rolls
-- back to this rather than to whatever was on screen just before the refused
-- set: two refused sets in a row used to leave the second one's starting value
-- in place, which is the first refused value, and no broadcast follows a
-- refusal to correct it. Seeded when the object arrives, updated on every
-- PropertyChanged.
const Confirmed: {[any]: any} = setmetatable({}, {__mode = "k"}) :: any

-- Runtime ids for objects this client made itself, counted down from the top
-- while the server counts up from one. The two meet only if a single session
-- mints four billion objects, and a local id never crosses the wire in any
-- case: a local object is not replicated, and committing its scene sends a
-- pack, which carries no runtime ids at all.
const MAX_RUNTIME_ID = 4294967295
local LocalRuntime = MAX_RUNTIME_ID

-- The copy each object of a scene this client owns was built in, so it can be
-- duplicated back into it. Weak keyed: an object nobody holds any more is not
-- kept alive by this table alone.
const LocalCopy: {[any]: any} = setmetatable({}, {__mode = "k"}) :: any

-- Types already warned about, so a template that cannot be seen here is said
-- once rather than once per object.
const WarnedTemplate: {[ObjectIdentifier]: true} = {}

-- The template to build a type's instances from here, for an object in a scene
-- this client owns or in a copy it draws. Warned about the first time it is
-- missing for a type that has one -- the moment it matters, and on the side it
-- matters to. Registration used to guess from where the template sat, which
-- warned for every type in ServerStorage, including every type in a game whose
-- clients never build anything.
const function TemplateOf(Registry: ObjectRegistry): Instance?
    if Registry.Instance then
        return Registry.Instance
    end

    if Registry.HasTemplate and not WarnedTemplate[Registry.Id] then
        WarnedTemplate[Registry.Id] = true
        Logger:Warn(`Object {Registry.Name} has a template that does not replicate to this client, so its objects are built here with no instance. Put the template in ReplicatedStorage.`)
    end

    return nil
end

const function __getter(self: Object, Reference: Types.PropertyReference): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    const Value = if Prop.Value == nil then Prop.DefaultValue else Prop.Value

    -- The live object rather than the id it is stored as, exactly as on the
    -- server. Nil while the target has not replicated here yet, which is the
    -- same nil a destroyed target reads as: the id is kept either way, so the
    -- link comes back the moment the object does.
    if Prop.Type == "Object" then
        return Shared.ResolveReference(self.InstanceId, Value, Find)
    end

    return Value
end

-- Applies locally first, then confirms with the server on a separate thread. The
-- previous version blocked the caller on a RemoteFunction for every single set,
-- which in an editor means a yield per axis per frame while dragging.
--
-- If the server refuses (permissions, validation) the local value rolls back.
-- If it accepts, its PropertyChanged broadcast reasserts the authoritative value.
const function __setter(self: Object, Reference: Types.PropertyReference, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    -- A reference given as the target object, resolved to the id that is
    -- actually stored before anything is applied or sent. Refused here rather
    -- than by the server, which would cost a round trip to be told what this
    -- side already knows.
    const Holdable, Val = Shared.Accept(self, Prop, Value, Find)
    if not Holdable then
        return false
    end

    const Before = Prop.Value
    const Accepted, Changed = Prop:Set(Val)
    if not Accepted then
        return false
    end

    -- Setting a property to the value it already holds is a no-op, not a reason
    -- to spend a round trip.
    if not Changed then
        return true
    end

    -- Told as it is made, like the value is shown. A refusal rolls the value
    -- back without telling anyone, which leaves an undo of it with nothing to
    -- do: the property no longer holds what the edit set.
    Listeners.Notify(Edited, self, Prop.Parent, Before, Prop.Value)

    const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value)
    if not Compressed then
        return false
    end

    const RuntimeId = self.RuntimeId
    const PropId = Prop.Parent

    Ticket += 1
    const Mine = Ticket
    Pending[Prop] = Mine

    task.spawn(function()
        const Ok, Allowed = pcall(function()
            return Network.SetProperty:Invoke(RuntimeId, PropId, Compressed)
        end)

        -- Superseded while in flight: the newer set owns the value now, and its
        -- own answer will decide whether to roll back.
        if Pending[Prop] ~= Mine then
            return
        end

        Pending[Prop] = nil

        if (not Ok or not Allowed) and not self.Destroyed then
            Prop:Set(Confirmed[Prop])
        end
    end)

    return true
end

const function __destroy(self: Object): boolean
    if self.Destroyed then
        return false
    end

    const Ok, Allowed = pcall(function()
        return Network.Destroy:Invoke(self.RuntimeId)
    end)

    return Ok and Allowed == true
end

const function Teardown(Obj: Object)
    if Obj.Destroyed then
        return
    end

    Obj.Destroyed = true

    Shared.ReleaseLinks(Obj.Links)
    Obj.Links = nil

    for _, Prop in Obj.Properties do
        Prop:Destroy()
    end

    if Obj.Instance then
        ByPart[Obj.Instance] = nil

        -- A replicated object's part belongs to the server and goes when the
        -- server takes it away. A local or drawn one was cloned here and is
        -- nobody else's to remove.
        if Obj.Local or Obj.Drawn then
            Obj.Instance:Destroy()
        end

        Obj.Instance = nil
    end

    ByRuntimeId[Obj.RuntimeId] = nil
    Unindex(Obj)

    -- Its removal is the only news a listener needs; no lock change follows.
    Locks[Obj.RuntimeId] = nil

    -- Out of the scene copy before out of the workspace, so a copy walking its
    -- own objects while they are torn down never sees one that is already gone
    -- from the world but still listed as its own.
    if Obj.Release then
        Obj.Release()
        Obj.Release = nil
    end

    -- Cleared here rather than by each caller. The two callers that come off
    -- the wire did it themselves and a local Destroy did not, so an object this
    -- client destroyed stayed answerable through Objects:Get for the rest of
    -- the session -- destroyed, but still there to be found.
    Workspace[Obj.RuntimeId] = nil

    -- Not table.clear: a stale reference should still be able to report its own
    -- handle and read Destroyed rather than turning into an empty table
    -- whose every method throws.
    Obj.Get = Shared.Destroyed.Get
    Obj.Set = Shared.Destroyed.Set
    Obj.GetProperty = Shared.Destroyed.GetProperty
    Obj.OnChange = Shared.Destroyed.OnChange
    Obj.Destroy = Shared.Destroyed.Destroy

    Listeners.Notify(Removed, Obj)
end

--=============================================================================
-- Scenes this client owns
--=============================================================================

-- A local object answers for itself. There is nobody to ask, nothing to roll
-- back to and no broadcast coming to confirm it: for a scene the client owns,
-- the client is the authority, which is the whole point of owning one.
--
-- Links still fire, because a link is a listener on the property rather than
-- anything to do with the network.
const function __local_setter(self: Object, Reference: Types.PropertyReference, Value: any?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    const Holdable, Val = Shared.Accept(self, Prop, Value, Find)
    if not Holdable then
        return false
    end

    const Before = Prop.Value
    const Accepted, Changed = Prop:Set(Val)
    if Accepted and Changed then
        Listeners.Notify(Edited, self, Prop.Parent, Before, Prop.Value)
    end

    return Accepted
end

const function __local_destroy(self: Object): boolean
    if self.Destroyed then
        return false
    end

    Teardown(self)
    return true
end

-- What every object here shares, filed into the tables the workspace is read
-- through. Set and Destroy are the caller's: a replicated object asks the
-- server for both, a local one does neither.
const function File(Obj: any, Order: {PropertyTypes.PropertyIdentifier})
    Obj.Names = Shared.BuildNameMap(Order, Obj.Properties)
    Obj.Get = __getter
    Obj.GetProperty = Shared.GetProperty
    Obj.OnChange = Shared.OnChange

    Workspace[Obj.RuntimeId] = Obj
    Index(Obj)

    if Obj.Instance then
        ByPart[Obj.Instance] = Obj.RuntimeId
        ByRuntimeId[Obj.RuntimeId] = Obj.Instance
    end
end

-- The client's own constructor, and deliberately not the server's: no
-- announcement, no permission pass, no round trip, because nothing outside this
-- client has a claim on the object.
--
-- LocalId is the object's id within its scene. Creating mints the next one;
-- restoring from a pack passes the id the object was saved under, which is what
-- makes a reference survive a reload here exactly as it does on the server.
const function Construct(
    Reference: ObjectRegistry | ObjectIdentifier,
    InitialValues: {[PropertyTypes.PropertyIdentifier]: any}?,
    Live: any,
    LocalId: number?
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

    -- A copy of a scene this client owns, and nothing else. A scene the server
    -- owns is edited by asking it to, which is what a transaction is for; there
    -- is no such thing as creating into one from here.
    if not Live or not Live.ByLocal then
        Logger:Error("Objects.new on the client needs a copy of a scene this client owns. Load one with Scenes.new, or edit a server scene through a transaction.")
    end

    const Owner = Live.Owner
    local Local = LocalId

    if Local then
        if Live.ByLocal[Local] then
            Logger:Error(`Scene {Owner.Name} already holds an object with local id {Local} in this copy.`)
        end

        Owner.LastId = math.max(Owner.LastId, Local)
    else
        if Owner.LastId >= Handles.MAX_LOCAL then
            Logger:Error(`Scene {Owner.Name} has exhausted its object id space.`)
        end

        Owner.LastId += 1
        Local = Owner.LastId
    end

    if LocalRuntime <= 0 then
        Logger:Error("Local runtime id space exhausted.")
    end

    const RuntimeId = LocalRuntime
    LocalRuntime -= 1

    -- The template came with the registry, and is nil if it lives somewhere
    -- that never replicates here. The type still builds objects then -- they
    -- simply have no instance, which is exactly what a server side object
    -- registered without one does.
    local Inst: Instance? = nil
    const Template = TemplateOf(Ref)

    if Template then
        const Clone = Template:Clone()
        Clone:SetAttribute(Shared.RuntimeAttribute, RuntimeId)
        CollectionService:AddTag(Clone, Shared.ObjectTag)

        -- Into the copy holding it, exactly as on the server: two copies of
        -- one room have to be able to sit in two places, and the copy's model
        -- is what moves them.
        Clone.Parent = Live.Folder

        Inst = Clone
    end

    const Props = Shared.BuildProperties(Ref.Properties)
    if InitialValues then
        for PropertyId, Value in InitialValues do
            const Prop = Props[PropertyId]
            if not Prop then
                continue
            end

            -- Against the copy the object is going into, as on the server: a
            -- reference is read against a copy, and the object carrying it does
            -- not exist yet.
            if Prop.Type == "Object" then
                const Target, Why = Shared.Reference(Live.Id, Prop, Value, Find)
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
    Obj.PersistentId = Handles.Join(Live.Scene, Local :: number)
    Obj.Scene = Live.Scene
    Obj.LocalId = Local
    Obj.InstanceId = Live.Id
    Obj.Parent = Ref.Id
    Obj.Name = Ref.Name
    Obj.Local = true
    Obj.Destroyed = false
    Obj.Properties = Props
    Obj.Instance = Inst
    -- Wired after the initial values land, so a link starts at the object's own
    -- value rather than at the registry default and then being corrected.
    Obj.Links = Shared.BuildLinks(Inst, Ref.Links, Props)
    Obj.Set = __local_setter
    Obj.Destroy = __local_destroy

    Obj.Release = function()
        Live.Objects[RuntimeId] = nil

        if Live.ByLocal[Local] == Obj then
            Live.ByLocal[Local] = nil
        end
    end

    File(Obj, Ref.Properties)
    Live.Objects[RuntimeId] = Obj
    Live.ByLocal[Local] = Obj
    LocalCopy[Obj] = Live

    Listeners.Notify(Added, Obj)
    return Obj :: any
end

-- Creates an object in a copy of a scene this client owns. Target is that copy
-- and is not optional: the implicit Default scene is the server's, and this
-- side has no equivalent to fall back on.
function Objects.new(
    Reference: ObjectRegistry | ObjectIdentifier,
    InitialValues: {[PropertyTypes.PropertyIdentifier]: any}?,
    Target: any
): Object
    return Construct(Reference, InitialValues, Target, nil)
end

-- Rebuilds an object under the id it was saved with, for a local scene reading
-- its own pack back.
function Objects.restore(Target: any, Decompressed: any): Object?
    if not Registered[Decompressed.Parent] then
        Logger:Warn(`Failed to restore object. Object type {Decompressed.Parent} is not registered.`)
        return nil
    end

    return Construct(Decompressed.Parent, Decompressed.Properties, Target, Decompressed.LocalId)
end

-- A new object of the same type holding the same values, in the same copy of a
-- scene this client owns. An object the server holds is duplicated by asking
-- it to, which is a transaction's Duplicate: this module cannot build one,
-- because Transactions is built on it.
function Objects:Duplicate(Obj: Object): Object?
    if Obj.Destroyed then
        return nil
    end

    const Live = LocalCopy[Obj]
    if not Obj.Local or not Live then
        Logger:Warn(`{Obj.Name} is the server's to duplicate. Use Transactions.new():Duplicate(object):Commit().`)
        return nil
    end

    return Construct(Obj.Parent, Shared.Snapshot(Obj), Live, nil)
end

-- The group form, for scenes this client owns. References that point inside the
-- group follow the copies; references that point outside it are left as they
-- are. See the server's DuplicateGroup, which this mirrors -- with no
-- announcement to batch, because nothing here is replicated.
function Objects:DuplicateGroup(List: {Object}): {Object}
    const Sources: {Object} = {}
    const Made: {Object} = {}
    const Counterpart: {[Object]: Object} = {}

    for _, Obj in List do
        if Obj.Destroyed then
            continue
        end

        const Live = LocalCopy[Obj]
        if not Obj.Local or not Live then
            Logger:Warn(`{Obj.Name} is the server's to duplicate. Use Transactions.new():DuplicateGroup(objects):Commit().`)
            continue
        end

        const New = Construct(Obj.Parent, Shared.Snapshot(Obj), Live, nil)

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

    return Made
end

-- A tagged part has arrived: file it, and hand it to its object if that object
-- is already here. The two halves reach a client in either order -- the object
-- travels over the remote, the part over ordinary replication -- so whichever
-- lands second completes the pair. Track runs again on a part that streams back
-- in, which is why it must be safe to repeat.
const function Track(Inst: Instance)
    const RuntimeId = Inst:GetAttribute(Shared.RuntimeAttribute)
    if type(RuntimeId) ~= "number" then
        return
    end

    ByPart[Inst] = RuntimeId
    ByRuntimeId[RuntimeId] = Inst

    const Obj = Workspace[RuntimeId]
    if Obj and not Obj.Destroyed then
        Obj.Instance = Inst
    end
end

-- Destroyed, or streamed out. Either way the reference is no longer a part of
-- the world, and an object holding it would hand callers something detached
-- from everything. The pairing is rebuilt by Track if it streams back in.
const function Untrack(Inst: Instance)
    const RuntimeId = ByPart[Inst]
    ByPart[Inst] = nil

    if RuntimeId == nil then
        return
    end

    if ByRuntimeId[RuntimeId] == Inst then
        ByRuntimeId[RuntimeId] = nil
    end

    const Obj = Workspace[RuntimeId]
    if Obj and Obj.Instance == Inst then
        Obj.Instance = nil
    end
end

function Objects:GetWorkspace(): {[RuntimeId]: Object}
    return Workspace
end

function Objects:Get(RuntimeId: RuntimeId): Object?
    return Workspace[RuntimeId]
end

-- The object a stored reference names, for a caller holding the raw local id
-- rather than reading it off a property. Scoped to a copy, because that is the
-- only scope a local id answers in.
function Objects:Resolve(Copy: Types.SceneInstanceId, Local: number): Object?
    return Find(Copy, Local)
end

-- What may be written into an Object property of an object in this copy, as a
-- local id, or nil and the reason it may not. The server's twin, so a
-- transaction built here refuses what the server would refuse -- before the
-- packet rather than after the round trip.
function Objects.Reference(
    Copy: Types.SceneInstanceId,
    Prop: PropertyTypes.Property<any>,
    Value: any
): (number?, string?)
    return Shared.Reference(Copy, Prop, Value, Find)
end

-- The two halves of a persistent id, for a caller holding one that did not come
-- off an object. Objects carry Scene and LocalId already.
function Objects:Split(Persistent: Types.PersistentId): (Types.SceneIdentifier, number)
    return Handles.Split(Persistent)
end

function Objects:GetInstance(Live: Types.SceneInstanceId): {Object}
    const Out = {}
    for _, Obj in ByInstance[Live] or {} do
        table.insert(Out, Obj)
    end

    return Out
end

function Objects:GetInstanceScene(Live: Types.SceneInstanceId): Types.SceneIdentifier?
    return InstanceScene[Live]
end

-- Told by Scenes/Client as the server announces copies appearing, with the
-- folder to draw into when the server opened the copy rather than loading it.
function Objects.TrackInstance(Live: Types.SceneInstanceId, Scene: Types.SceneIdentifier, Folder: Folder?)
    InstanceScene[Live] = Scene
    DrawInto[Live] = Folder
end

-- Tears down every object of one live copy. Called by Scenes/Client when the
-- server says the copy is gone, which arrives as a single packet: the objects
-- are already gone there and no ObjectRemoved is coming for any of them.
function Objects.DropInstance(Live: Types.SceneInstanceId)
    InstanceScene[Live] = nil
    DrawInto[Live] = nil

    const Held = ByInstance[Live]
    if not Held then
        return
    end

    for _, Obj in table.clone(Held) do
        Teardown(Obj)
    end

    ByInstance[Live] = nil

    -- Emptied by the tearing down above, which unindexes each object, and
    -- cleared here for the same reason the line above it is: the copy is gone,
    -- so nothing about it is worth keeping on a maybe.
    LocalIds[Live] = nil
end

function Objects:GetRegistered(): {[ObjectIdentifier]: ObjectRegistry}
    return Registered
end

function Objects:GetRegistry(Identifier: ObjectIdentifier): ObjectRegistry?
    return Registered[Identifier]
end

-- Editor convenience: turn a clicked part back into the object that owns it.
function Objects:FromInstance(Inst: Instance): Object?
    local Current: Instance? = Inst
    while Current do
        const RuntimeId = ByPart[Current]
        if RuntimeId then
            return Workspace[RuntimeId]
        end

        Current = Current.Parent
    end

    return nil
end

-- Shared by the live ObjectAdded broadcast and the batched join replay, which
-- carry the same three values and differ only in how many arrive at once.
const function AddObject(
    RuntimeId: RuntimeId,
    Live: Types.SceneInstanceId,
    Compressed: buffer,
    Inst: Instance?
)
    const Ok, Data = pcall(function()
        return Compressor:DecompressObject(Compressed)
    end)

    if not Ok or not Data then
        Logger:Warn(`Failed to decompress object {RuntimeId}.`)
        return
    end

    const Registry = Registered[Data.Parent]
    if not Registry then
        Logger:Warn(`Received object {RuntimeId} for unregistered type {Data.Parent}.`)
        return
    end

    -- A copy the server opened has no part anywhere: this client draws one,
    -- from the template that came with the registry, into the folder it keeps
    -- for the copy. Anything else has a part the server built, and the
    -- reference that came with the object is the fast path to it. When that did
    -- not survive, the part may already be here and tracked under its runtime
    -- id.
    const Into = DrawInto[Live]
    local Resolved: Instance? = nil

    if Into then
        const Template = TemplateOf(Registry)
        if Template then
            const Clone = Template:Clone()
            Clone:SetAttribute(Shared.RuntimeAttribute, RuntimeId)
            CollectionService:AddTag(Clone, Shared.ObjectTag)
            Clone.Parent = Into
            Resolved = Clone
        end
    else
        Resolved = Inst or ByRuntimeId[RuntimeId]
    end

    -- The persistent half is assembled here rather than sent: the local id
    -- rides inside the buffer already, and the scene is whichever one the copy
    -- came from. Unknown only if an object outran the packet announcing its
    -- copy, which the server orders against.
    const Scene = InstanceScene[Live]
    if not Scene then
        Logger:Warn(`Object {RuntimeId} arrived for unknown scene instance {Live}.`)
    end

    const Obj = {}
    Obj.RuntimeId = RuntimeId
    Obj.InstanceId = Live
    Obj.Scene = Scene or 0
    Obj.LocalId = Data.LocalId
    Obj.PersistentId = Handles.Join(Scene or 0, Data.LocalId)
    Obj.Parent = Data.Parent
    Obj.Name = Registry.Name
    Obj.Destroyed = false
    Obj.Instance = Resolved
    Obj.Links = nil
    Obj.Properties = {}

    for _, PropId in Registry.Properties do
        const Prop = Properties.new(PropId)
        if Data.Properties[PropId] ~= nil then
            Prop:Set(Data.Properties[PropId])
        end

        -- Whatever the object arrived holding is what the server holds.
        Confirmed[Prop] = Prop.Value
        Obj.Properties[PropId] = Prop
    end

    -- A drawn part is driven from here, through the links that came with the
    -- registry. Wired after the values land, as on the server, so the part
    -- starts at the object's value rather than the template's.
    if Into then
        Obj.Drawn = true
        Obj.Links = Shared.BuildLinks(Resolved, Registry.Links, Obj.Properties)
    end

    Obj.Set = __setter
    Obj.Destroy = __destroy

    File(Obj, Registry.Properties)
    Listeners.Notify(Added, Obj)
end

-- GetTagged first: parts that replicated before this module loaded never fire
-- the added signal, and on a join that is most of them.
for _, Inst in CollectionService:GetTagged(Shared.ObjectTag) do
    Track(Inst)
end

CollectionService:GetInstanceAddedSignal(Shared.ObjectTag):Connect(Track)
CollectionService:GetInstanceRemovedSignal(Shared.ObjectTag):Connect(Untrack)

Network.ObjectRegistered:Connect(function(Registry: ObjectRegistry)
    Registered[Registry.Id] = Registry
end)

Network.RegistriesReplayed:Connect(function(Registries: {ObjectRegistry})
    for _, Registry in Registries do
        Registered[Registry.Id] = Registry
    end
end)

-- Gone on the server, which refuses while any object of it is live there.
-- Objects of it in scenes this client owns keep what they were built from;
-- nothing new can be made of it.
Network.ObjectUnregistered:Connect(function(Identifier: ObjectIdentifier)
    Registered[Identifier] = nil
end)

-- Kept by runtime id rather than on the object, so a lock that arrives ahead of
-- its object -- the reveal sends locks before it streams objects -- is still
-- there when the object lands.
Network.LocksChanged:Connect(function(Ids: {RuntimeId}, Holders: {number})
    for Index, Identifier in Ids do
        const Holder = Holders[Index]
        Locks[Identifier] = if Holder ~= 0 then Holder else nil
        Listeners.Notify(LockChanged, Identifier, Locks[Identifier])
    end
end)

Network.ObjectAdded:Connect(AddObject)

-- The instance list carries false where an object has no instance: a nil entry
-- would leave a hole in the array and shift every later index against the ids.
Network.ObjectsReplayed:Connect(function(
    RuntimeIds: {number},
    Live: {number},
    Buffers: {buffer},
    Instances: {any}
)
    for Index, RuntimeId in RuntimeIds do
        const Inst = Instances[Index]
        const Resolved = if Inst == false then nil else Inst

        -- One bad entry must not cost the rest of the batch.
        const Ok, Err = pcall(AddObject, RuntimeId, Live[Index], Buffers[Index], Resolved)
        if not Ok then
            Logger:Warn(`Failed to add replayed object {RuntimeId}: {Err}`)
        end
    end
end)

-- Shared by the single broadcast and the batched one a transaction answers
-- with, which carry the same thing and differ only in how many arrive at once.
const function RemoveObject(RuntimeId: RuntimeId)
    const Obj = Workspace[RuntimeId]
    if not Obj then
        return
    end

    Teardown(Obj)
end

const function ApplyChange(RuntimeId: RuntimeId, PropId: PropertyTypes.PropertyIdentifier, Compressed: buffer)
    const Obj = Workspace[RuntimeId]
    if not Obj then
        return
    end

    const Prop = Obj.Properties[PropId]
    if not Prop then
        return
    end

    const Ok, Value, Type = pcall(function()
        const Decoded, _, DecodedType = Compressor:DecompressValue(Compressed, 0)
        return Decoded, DecodedType
    end)

    if Ok and Type == Prop.Type then
        -- The server has spoken, so no in-flight set may roll back over this,
        -- and this is now the value a later refusal should return to.
        Pending[Prop] = nil
        Prop:Set(Value)
        Confirmed[Prop] = Prop.Value
    end
end

Network.ObjectRemoved:Connect(RemoveObject)

Network.ObjectsRemoved:Connect(function(RuntimeIds: {RuntimeId})
    for _, RuntimeId in RuntimeIds do
        RemoveObject(RuntimeId)
    end
end)

Network.PropertyChanged:Connect(ApplyChange)

-- Three parallel lists, like the object replay, and for the same reason: a
-- codec is per element, so one array of records cannot be declared.
Network.PropertiesChanged:Connect(function(
    RuntimeIds: {RuntimeId},
    PropIds: {PropertyTypes.PropertyIdentifier},
    Values: {buffer}
)
    for Index, RuntimeId in RuntimeIds do
        -- One bad entry must not cost the rest of the batch.
        const Ok, Err = pcall(ApplyChange, RuntimeId, PropIds[Index], Values[Index])
        if not Ok then
            Logger:Warn(`Failed to apply a batched change to object {RuntimeId}: {Err}`)
        end
    end
end)

return Objects
