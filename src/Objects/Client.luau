--!strict
const CollectionService = game:GetService("CollectionService")
const Players = game:GetService("Players")

const Properties = require("../Properties/Client")
const CustomEnum = require("../CustomEnum")
const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const Network = require("./Network")
const Shared = require("./Shared")
const Handles = require("../Handles")
const Logger = require("../Logger")
const Listeners = require("../Listeners")
const Permissions = require("../Permissions/Client")
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

-- Copies of scenes this client owns. The distinction the server never has to
-- make and this side cannot do without: an edit to one of these applies here
-- and now, and an edit to any other copy is a request. A transaction reads it
-- to know whether committing means sending a packet or doing the work.
const LocalCopies: {[Types.SceneInstanceId]: true} = {}

-- Scenes this client owns, by id. Kept beside the copies because a scene can be
-- asked for before it has any: loading one is exactly the case where there are
-- no copies yet to read the answer off.
const LocalScenes: {[Types.SceneIdentifier]: true} = {}

-- Every object appearing here and going, whichever way it came: replicated
-- from the server, built in a scene this client owns, or drawn for a copy the
-- server opened. UI used to poll GetWorkspace to notice any of it.
-- Restored says the object came back from a pack under the id it was saved
-- with -- a copy reading itself in, rather than anything anyone did. A history
-- would record a step per object in a level without it.
const Added: {(Obj: Object, Restored: boolean) -> ()} = {}
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
function Objects:OnAdded(Callback: (Obj: Object, Restored: boolean) -> ()): () -> ()
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
-- Which objects are held, and by whom where that is a person. A holder need
-- not be one -- the server can hold an object while it animates it -- so being
-- held and being held by somebody are two different questions and get two
-- tables' worth of answer: an entry here means held, and its value is the user
-- id or nil.
const Locks: {[RuntimeId]: true} = {}
const Holders: {[RuntimeId]: number} = {}
const LockChanged: {(RuntimeId: RuntimeId, UserId: number?, Held: boolean) -> ()} = {}

-- One object's hold as this client now knows it, from whichever of two places
-- says so first: the answer to its own Lock or Unlock, or the broadcast. Both
-- arrive for this client's own holds, so listeners hear a change once rather
-- than the same hold twice.
const function Record(Identifier: RuntimeId, IsHeld: boolean, UserId: number?)
    const Holder = if IsHeld then UserId else nil
    if (Locks[Identifier] == true) == IsHeld and Holders[Identifier] == Holder then
        return
    end

    Locks[Identifier] = if IsHeld then true else nil
    Holders[Identifier] = Holder

    Listeners.Notify(LockChanged, Identifier, Holder, IsHeld)
end

-- Whether someone other than this player holds an object, as far as this client
-- has been told. The server refuses an edit to it whatever this says; asking
-- here first is what keeps an edit that is bound to be refused from showing on
-- screen and then snapping back.
const function HeldByOther(RuntimeId: RuntimeId): boolean
    return Locks[RuntimeId] == true and Holders[RuntimeId] ~= Players.LocalPlayer.UserId
end

Permissions.WatchHolds(HeldByOther)

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

    if not Ok or Granted ~= true then
        return false
    end

    -- Recorded from the answer rather than left to the broadcast. The answer
    -- comes back on the remote function and the broadcast on the remote event,
    -- and Roblox orders nothing across the two, so IsLocked used to say free
    -- for a moment after Lock had said yes.
    const Me = Players.LocalPlayer.UserId
    for _, Identifier in Ids do
        Record(Identifier, true, Me)
    end

    return true
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

    if not Ok or Released ~= true then
        return false
    end

    -- True means nobody else holds any of them, so every one named is free
    -- now: this player let go of it or nobody held it. A false answer released
    -- some and not others, and which is left to the broadcast.
    for _, Identifier in Ids do
        Record(Identifier, false, nil)
    end

    return true
end

-- The same, for a transaction the server applied: it takes and releases holds
-- in its own packet and has the same answer to record ahead of the broadcast.
function Objects.RecordHolds(Ids: {RuntimeId}, IsHeld: boolean)
    const Me = if IsHeld then Players.LocalPlayer.UserId else nil
    for _, Identifier in Ids do
        Record(Identifier, IsHeld, Me)
    end
end

-- The user id holding an object, or nil when it is free, when the holder is not
-- a person, or when this player is not admitted to its scene and so is not told.
-- IsLocked answers the other half: whether anything holds it at all.
function Objects:GetLock(Ref: Object | RuntimeId): number?
    return Holders[if type(Ref) == "number" then Ref else Ref.RuntimeId]
end

function Objects:IsLocked(Ref: Object | RuntimeId): boolean
    return Locks[if type(Ref) == "number" then Ref else Ref.RuntimeId] == true
end

-- Fired with a runtime id, the user id now holding it -- nil for nobody or for
-- a holder that is not a person -- and whether it is held at all.
function Objects:OnLockChanged(Callback: (RuntimeId: RuntimeId, UserId: number?, Held: boolean) -> ()): () -> ()
    return Listeners.Watch(LockChanged, Callback, "locks")
end

-- A scene this player is no longer admitted to stops telling them its locks,
-- so what they knew of them is dropped rather than left to go stale.
function Objects.ForgetLocks(Scene: Types.SceneIdentifier)
    for Identifier in table.clone(Locks) do
        const Obj = Workspace[Identifier]
        if not Obj or Obj.Scene == Scene then
            Locks[Identifier] = nil
            Holders[Identifier] = nil
            Listeners.Notify(LockChanged, Identifier, nil, false)
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
-- refusal to correct it.
--
-- Held only for a property this client has edited, from just before the edit
-- shows, and kept current by every PropertyChanged after. Until then the value
-- on screen is the server's: a set and a preview are the only two things that
-- show anything else, and both hold first. It used to be seeded for every
-- property as it arrived, which on a 34,918-object level is 495,279 entries
-- and 16 MB of hash -- kept after the level was unloaded, since a Luau table
-- never gives back the room its emptied keys took, weak or not.
const Confirmed: {[any]: any} = setmetatable({}, {__mode = "k"}) :: any

-- What Confirmed holds for a nil value, which would otherwise read as no entry
-- at all and be held again over whatever is on screen by then.
const NONE = table.freeze({})

const function Hold(Prop: any)
    if Confirmed[Prop] == nil then
        Confirmed[Prop] = if Prop.Value == nil then NONE else Prop.Value
    end
end

-- What a refusal rolls back to. A property never held has never shown
-- anything but the server's value.
const function ConfirmedOf(Prop: any): any
    const Value = Confirmed[Prop]
    if Value == nil then
        return Prop.Value
    end

    return if Value == NONE then nil else Value
end

-- A value the server has asserted, for a property that is held. One that is not
-- shows it already.
const function Confirm(Prop: any, Value: any)
    if Confirmed[Prop] ~= nil then
        Confirmed[Prop] = if Value == nil then NONE else Value
    end
end

-- Properties being set with ClientSided, and the value each held before the
-- first of those sets. A drag used to send a set per frame, which at sixty
-- frames a second sat exactly on the default budget: the limiter refused half
-- way through and every refusal snapped the value back while the player was
-- still holding it. The game knows when a drag starts and ends and the wire
-- does not, so the game says so: every frame is shown here and nowhere else,
-- and the set that ends it is the one edit anybody hears about, starting from
-- the value it started from. Weak keyed, like the two tables above.
const Previewing: {[any]: {Before: any}} = setmetatable({}, {__mode = "k"}) :: any

-- Starts or continues a preview: the value is shown and nothing else happens.
-- Nobody is told of an edit, because there has not been one yet.
const function Preview(Prop: any, Val: any): boolean
    if not Previewing[Prop] then
        Previewing[Prop] = {Before = Prop.Value}
    end

    const Accepted = Prop:Set(Val)
    return Accepted
end

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

-- A value holding pending options with every one whose enum is registered now
-- swapped for the real option: the option itself, or a fresh list for a Table
-- of them. Nil when there is nothing to swap.
const function SettleValue(Prop: PropertyTypes.Property<any>, Value: any): any?
    if Prop.Type == "CustomEnum" then
        return CustomEnum.Settle(Value)
    end

    if Prop.Type ~= "Table" or not Prop.Constraints or Prop.Constraints.Of ~= "CustomEnum" or type(Value) ~= "table" then
        return nil
    end

    local List: {any}? = nil
    for Index, Item in Value do
        const Settled = CustomEnum.Settle(Item)
        if Settled then
            if not List then
                List = table.clone(Value)
            end

            (List :: {any})[Index] = Settled
        end
    end

    return if List then table.freeze(List) else nil
end

const function __getter(self: Object, Reference: Types.PropertyReference): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    const Value = if Prop.Value == nil then Prop.DefaultValue else Prop.Value

    -- A pending option whose enum has been registered since, on an object the
    -- sweep below did not reach because it was set aside at the time.
    const Settled = SettleValue(Prop, Value)
    if Settled then
        return Settled
    end

    -- The live object rather than the id it is stored as, exactly as on the
    -- server. Nil while the target has not replicated here yet, which is the
    -- same nil a destroyed target reads as: the id is kept either way, so the
    -- link comes back the moment the object does.
    if PropertyTypes.HoldsReferences(Prop) then
        return Shared.ResolveValue(self.InstanceId, Prop, Value, Find)
    end

    return Value
end

-- Applies locally first, then confirms with the server on a separate thread. The
-- previous version blocked the caller on a RemoteFunction for every single set,
-- which in an editor means a yield per axis per frame while dragging.
--
-- If the server refuses (permissions, validation) the local value rolls back.
-- If it accepts, its PropertyChanged broadcast reasserts the authoritative value.
--
-- ClientSided shows the value here and sends nothing; see Previewing. The next
-- set without it sends the value it lands on, once, even when the preview had
-- already put that value on screen.
const function __setter(self: Object, Reference: Types.PropertyReference, Value: any?, ClientSided: boolean?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    -- Held by somebody else: the server would refuse it, and an optimistic set
    -- would show the value and then take it back. A preview already open when
    -- the hold was taken is put back now, since nothing can land it.
    if HeldByOther(self.RuntimeId) then
        if Previewing[Prop] then
            Previewing[Prop] = nil
            Prop:Set(ConfirmedOf(Prop))
        end

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

    Hold(Prop)

    if ClientSided then
        return Preview(Prop, Val)
    end

    -- A preview ending. What it showed was never sent, so the edit runs from
    -- where the server last had it rather than from the frame before.
    const Held = Previewing[Prop]
    Previewing[Prop] = nil

    const Before = if Held then Held.Before else Prop.Value
    const Accepted, Changed = Prop:Set(Val)
    if not Accepted then
        if Held then
            Prop:Set(ConfirmedOf(Prop))
        end

        return false
    end

    -- Setting a property to the value it already holds is a no-op, not a reason
    -- to spend a round trip. After a preview the question is whether it differs
    -- from what the server holds, not from the last frame: a drag let go where
    -- it started is a cancel, and costs nothing.
    if Held then
        if PropertyTypes:Equals(Prop.Type, Prop.Value, ConfirmedOf(Prop)) then
            return true
        end
    elseif not Changed then
        return true
    end

    -- Told as it is made, like the value is shown. A refusal rolls the value
    -- back without telling anyone, which leaves an undo of it with nothing to
    -- do: the property no longer holds what the edit set.
    Listeners.Notify(Edited, self, Prop.Parent, Before, Prop.Value)

    const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value, Prop.Constraints)
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

        -- A new drag started while this was in flight. The refused value is
        -- already off screen, and the drag's own last set will be judged on
        -- its own; snapping back now would yank it out of the player's hand.
        if (not Ok or not Allowed) and not self.Destroyed and not Previewing[Prop] then
            Prop:Set(ConfirmedOf(Prop))
        end
    end)

    return true
end

const function __destroy(self: Object): boolean
    -- Not worth the round trip: the server refuses a destroy of an object
    -- somebody else holds, and this client already knows they do.
    if self.Destroyed or HeldByOther(self.RuntimeId) then
        return false
    end

    const Ok, Allowed = pcall(function()
        return Network.Destroy:Invoke(self.RuntimeId)
    end)

    return Ok and Allowed == true
end

-- Leaving the world, which is not the same as ceasing to exist. Everything here
-- can be taken back: the object is unfiled, its part goes and anything watching
-- is told it went, but the table, its values and both its ids survive. A scene
-- this client owns is the client's to undo in, and an undone destroy has to
-- bring back the object it took -- under its own local id, or every reference
-- to it comes back pointing at nothing.
const function Withdraw(Obj: Object)
    Shared.ReleaseLinks(Obj.Links, Obj.Properties)
    Obj.Links = nil

    if Obj.Instance then
        ByPart[Obj.Instance] = nil

        -- A local or drawn part was cloned here, so it is this side's to move:
        -- out of the world and kept, so an object that comes back comes back
        -- with the part it had rather than a fresh copy of the template.
        -- Destroying it is Dispose's, once nothing can bring the object back.
        --
        -- A replicated one belongs to the server and goes when the server takes
        -- it away. There is nothing here to keep and nothing here to destroy,
        -- so only the reference is dropped.
        if Obj.Local or Obj.Drawn then
            Obj.Instance.Parent = nil
        else
            Obj.Instance = nil
        end
    end

    ByRuntimeId[Obj.RuntimeId] = nil
    Unindex(Obj)

    -- Its removal is the only news a listener needs; no lock change follows.
    Locks[Obj.RuntimeId] = nil
    Holders[Obj.RuntimeId] = nil

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

-- The part that cannot be taken back: the values go, the part this side owns
-- goes, and with them any chance of this object being itself again.
const function Dispose(Obj: Object)
    Obj.Suspended = nil

    -- Only ever one this client cloned: a replicated part is the server's and
    -- Withdraw already let go of the reference to it.
    if Obj.Instance then
        Obj.Instance:Destroy()
        Obj.Instance = nil
    end

    for _, Prop in Obj.Properties do
        Prop:Destroy()
    end
end

const function Teardown(Obj: Object)
    if Obj.Destroyed then
        return
    end

    Obj.Destroyed = true
    Withdraw(Obj)
    Dispose(Obj)
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
--
-- ClientSided means the same here as on a replicated object, although nothing
-- is sent either way: the edit is told once, when the preview ends, so a drag
-- is one step of history however long the player paused in the middle of it.
const function __local_setter(self: Object, Reference: Types.PropertyReference, Value: any?, ClientSided: boolean?): boolean
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return false
    end

    const Holdable, Val = Shared.Accept(self, Prop, Value, Find)
    if not Holdable then
        return false
    end

    if ClientSided then
        return Preview(Prop, Val)
    end

    const Held = Previewing[Prop]
    Previewing[Prop] = nil

    const Before = if Held then Held.Before else Prop.Value
    const Accepted = Prop:Set(Val)

    -- Against where the preview started rather than the last frame, for the
    -- same reason as the replicated setter: let go where it began is no edit.
    if Accepted and not PropertyTypes:Equals(Prop.Type, Prop.Value, Before) then
        Listeners.Notify(Edited, self, Prop.Parent, Before, Prop.Value)
    end

    return Accepted
end

const function __local_destroy(self: Object): boolean
    if self.Destroyed then
        return false
    end

    Objects.Retire(self)
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

-- Everything being in a copy this client owns means: a part cloned from the
-- template, links wired to it, a place in the copy and in the workspace, and
-- the signal saying so. The inverse of Withdraw, and written once because an
-- object coming back from a suspend has to arrive exactly as one just built
-- does -- anything this did that reviving forgot would show up only as an
-- undone destroy behaving unlike the object it restored.
--
-- The template came with the registry, and is nil if it lives somewhere that
-- never replicates here. The type still builds objects then; they simply have
-- no instance, which is what a server side object registered without one does.
const function Enter(Obj: any, Ref: ObjectRegistry, Live: any, Restored: boolean?)
    -- Already holding one means this object was withdrawn rather than
    -- destroyed, and its part was parented out of the world and kept. It goes
    -- back rather than being cloned again: a clone would only look like the
    -- part that left.
    local Inst: Instance? = Obj.Instance

    if not Inst then
        const Template = TemplateOf(Ref)
        if Template then
            const Clone = Template:Clone()
            Clone:SetAttribute(Shared.RuntimeAttribute, Obj.RuntimeId)
            CollectionService:AddTag(Clone, Shared.ObjectTag)
            Inst = Clone
        end
    end

    Obj.Instance = Inst

    -- Wired after the values are in place, so a link starts at the object's own
    -- value rather than at the registry default and then being corrected.
    Obj.Links = Shared.BuildLinks(Inst, Ref.Links, Obj.Properties)

    -- Into the copy holding it, exactly as on the server: two copies of one
    -- room have to be able to sit in two places, and the copy's folder is what
    -- moves them. Last, as on the server, so the part enters the world already
    -- holding its values rather than taking each one as a change.
    if Inst then
        Inst.Parent = Live.Folder
    end
    Obj.Set = __local_setter
    Obj.Destroy = __local_destroy

    Obj.Release = function()
        Live.Objects[Obj.RuntimeId] = nil

        if Live.ByLocal[Obj.LocalId] == Obj then
            Live.ByLocal[Obj.LocalId] = nil
        end
    end

    File(Obj, Ref.Properties)
    Live.Objects[Obj.RuntimeId] = Obj
    Live.ByLocal[Obj.LocalId] = Obj
    LocalCopy[Obj] = Live

    Listeners.Notify(Added, Obj, Restored == true)
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
            if PropertyTypes.HoldsReferences(Prop) then
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
    Obj.Registry = Ref.Id
    Obj.Name = Ref.Name
    Obj.Local = true
    Obj.Destroyed = false
    Obj.Properties = Props

    -- Restored when it was given the id it was saved under, which is a copy
    -- reading its pack rather than anybody creating anything. A history that
    -- did not know the difference would record a step for every object in a
    -- level the moment it loaded.
    Enter(Obj, Ref, Live, LocalId ~= nil)
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
    if not Registered[Decompressed.Registry] then
        Logger:Warn(`Failed to restore object. Object type {Decompressed.Registry} is not registered.`)
        return nil
    end

    const Obj = Construct(Decompressed.Registry, Decompressed.Properties, Target, Decompressed.LocalId)
    Obj.Unknown = Shared.Leftovers(Obj, Decompressed)
    return Obj
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

    const New = Construct(Obj.Registry, Shared.Snapshot(Obj), Live, nil)
    New.Unknown = if Obj.Unknown then table.clone(Obj.Unknown) else nil
    return New
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

        const New = Construct(Obj.Registry, Shared.Snapshot(Obj), Live, nil)
        New.Unknown = if Obj.Unknown then table.clone(Obj.Unknown) else nil

        table.insert(Sources, Obj)
        table.insert(Made, New)
        Counterpart[Obj] = New
    end

    for Index, New in Made do
        const Source = Sources[Index]

        for PropertyId, Prop in New.Properties do
            if not PropertyTypes.HoldsReferences(Prop) then
                continue
            end

            const Was = Source.Properties[PropertyId]
            const Remapped = if Was
                then Shared.Remap(Prop, Was.Value, function(Item: number): number?
                    const Pointed = Shared.ResolveReference(Source.InstanceId, Item, Find)
                    const Instead = if Pointed then Counterpart[Pointed] else nil
                    return if Instead then Instead.LocalId else Item
                end)
                else nil

            if Remapped ~= nil then
                Prop:Set(Remapped)
            end
        end
    end

    return Made
end

--=============================================================================
-- Retiring
--=============================================================================

-- The client's half of deferred destruction, and only for scenes it owns: an
-- object the server holds is destroyed where it lives, and what arrives here is
-- the packet saying so. See Objects/Server, which this mirrors -- with no
-- announcement and no permission pass, because a local object is nobody else's.

const Keepers: {(Obj: Object) -> boolean} = {}

-- Synchronous, and answers, for the reason the server's does: the object is
-- disposed the moment nothing claims it.
function Objects.OnRetired(Callback: (Obj: Object) -> boolean): () -> ()
    return Listeners.Watch(Keepers, Callback, "retired objects")
end

function Objects.Suspend(Obj: Object): boolean
    if Obj.Destroyed then
        return false
    end

    Obj.Destroyed = true
    Obj.Suspended = true
    Withdraw(Obj)
    return true
end

-- Back into the copy it left, as itself. False when that copy has been
-- unloaded: its objects are gone, its ids mean nothing, and there is nowhere
-- for this one to return to.
function Objects.Revive(Obj: Object): boolean
    if not Obj.Suspended then
        return false
    end

    const Live = LocalCopy[Obj]
    const Ref = Registered[Obj.Registry]
    if not Live or not Ref or Live.Owner.Instances[Live.Id] ~= Live then
        return false
    end

    if Live.ByLocal[Obj.LocalId] then
        return false
    end

    Obj.Suspended = nil
    Obj.Destroyed = false
    Enter(Obj, Ref, Live)
    return true
end

function Objects.Dispose(Obj: Object)
    if not Obj.Suspended then
        return
    end

    Dispose(Obj)
end

-- Suspend, offer, and dispose if nobody wanted it back. What Object:Destroy on
-- a local object comes down to, so a game that never requires History destroys
-- exactly as immediately as it always did.
function Objects.Retire(Obj: Object)
    if not Objects.Suspend(Obj) then
        return
    end

    for _, Keeper in Keepers do
        if Keeper(Obj) then
            return
        end
    end

    Dispose(Obj)
end

-- Links on a part the server built, so this client's own view of the object
-- reaches the part it sees. Without them a ClientSided drag on an object of a
-- loaded copy moved nothing on the dragging client: the value changed and the
-- part stayed where it was until the closing set came back from the server.
--
-- Writing a replicated part from a client changes it on this client alone, and
-- the server's write replicates over it the next time the server changes it --
-- to the same value, since the server's write is what Confirmed holds. A
-- refusal rolls the property back, and the link puts the part back with it.
--
-- A local or drawn part is wired where it is built and never comes through here.
-- Safe to repeat, because Track runs again on a part that streams back in.
const function WireServerPart(Obj: any)
    if Obj.Local or Obj.Drawn then
        return
    end

    Shared.ReleaseLinks(Obj.Links, Obj.Properties)
    Obj.Links = nil

    const Registry = Registered[Obj.Registry]
    if Obj.Instance and Registry then
        Obj.Links = Shared.BuildLinks(Obj.Instance, Registry.Links, Obj.Properties)
    end
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
        WireServerPart(Obj)
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

        -- Nothing left to drive; Track wires it again if the part comes back.
        WireServerPart(Obj)
    end
end

function Objects:GetWorkspace(): {[RuntimeId]: Object}
    return Workspace
end

-- How many properties this client holds a server value for, which is how many
-- it has edited and still has. A diagnostic: an object arriving must not add to
-- it, since what it adds stays as room in the table after the object is gone.
function Objects:CountConfirmed(): number
    local Count = 0
    for _ in Confirmed do
        Count += 1
    end

    return Count
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
function Objects.TrackInstance(
    Live: Types.SceneInstanceId,
    Scene: Types.SceneIdentifier,
    Folder: Folder?,
    Local: boolean?
)
    InstanceScene[Live] = Scene
    DrawInto[Live] = Folder

    if Local then
        LocalCopies[Live] = true
    end
end

-- Whether a copy belongs to a scene this client owns, which is what decides
-- whether editing it is a thing this side may simply do. The server's answer is
-- always false: nothing there is anybody's local.
function Objects:IsLocalCopy(Live: Types.SceneInstanceId): boolean
    return LocalCopies[Live] == true
end

-- Told by Scenes/Client as it registers and destroys them. Objects cannot ask
-- Scenes -- that is the cycle every module here is arranged to avoid -- so it
-- is told instead, the way it is told which copy belongs to which scene.
function Objects.TrackLocalScene(Scene: Types.SceneIdentifier, Owned: boolean)
    LocalScenes[Scene] = if Owned then true else nil
end

function Objects:IsLocalScene(Scene: Types.SceneIdentifier): boolean
    return LocalScenes[Scene] == true
end

-- Tears down every object of one live copy. Called by Scenes/Client when the
-- server says the copy is gone, which arrives as a single packet: the objects
-- are already gone there and no ObjectRemoved is coming for any of them.
-- Every object of one copy this client owns withdrawn at once, and kept. The
-- server's twin; see Objects/Server. Nothing here is announced either way,
-- because nothing in a scene this client owns ever was.
function Objects.SuspendInstance(Live: Types.SceneInstanceId): {Object}
    const Held = {}
    for _, Obj in table.clone(ByInstance[Live] or {}) do
        if Objects.Suspend(Obj) then
            table.insert(Held, Obj)
        end
    end

    return Held
end

function Objects.ReviveInstance(Held: {Object}): {Object}
    const Back = {}
    for _, Obj in Held do
        if Objects.Revive(Obj) then
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

function Objects.DropInstance(Live: Types.SceneInstanceId)
    InstanceScene[Live] = nil
    DrawInto[Live] = nil
    LocalCopies[Live] = nil

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

    const Registry = Registered[Data.Registry]
    if not Registry then
        Logger:Warn(`Received object {RuntimeId} for unregistered type {Data.Registry}.`)
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
            -- Parented below, once its links have written the object's values.
            const Clone = Template:Clone()
            Clone:SetAttribute(Shared.RuntimeAttribute, RuntimeId)
            CollectionService:AddTag(Clone, Shared.ObjectTag)
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
    Obj.Registry = Data.Registry
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

        Obj.Properties[PropId] = Prop
    end

    -- A drawn part is driven from here, through the links that came with the
    -- registry. Wired after the values land, as on the server, so the part
    -- starts at the object's value rather than the template's. A part the
    -- server built is wired too, for what this client shows ahead of the
    -- server: an optimistic set, or a ClientSided preview.
    if Into then
        Obj.Drawn = true
        Obj.Links = Shared.BuildLinks(Resolved, Registry.Links, Obj.Properties)

        if Resolved then
            Resolved.Parent = Into
        end
    else
        WireServerPart(Obj)
    end

    Obj.Set = __setter
    Obj.Destroy = __destroy

    File(Obj, Registry.Properties)

    -- Never restored: an object arriving from the server is the server's to
    -- have loaded or created, and either way nothing on this side did it.
    Listeners.Notify(Added, Obj, false)
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
Network.LocksChanged:Connect(function(Ids: {RuntimeId}, Who: {number}, Held: {boolean})
    for Index, Identifier in Ids do
        const IsHeld = Held[Index] == true
        const UserId = Who[Index]

        -- Zero is nobody rather than free: Held is what says free.
        Record(Identifier, IsHeld, if UserId ~= 0 then UserId else nil)
    end
end)

Network.ObjectAdded:Connect(AddObject)

-- An enum registered here after values of it arrived. Those values are pending
-- options, holding the enum's name and the option id; swapped now for the real
-- options, so the Value is there and OnChange tells whoever is showing them.
-- What the server last confirmed moves with it, or a refused set later would
-- roll back to the pending option rather than the same value with its Value.
CustomEnum:OnRegistered(function()
    for _, Obj in Workspace do
        for _, Prop in Obj.Properties do
            const Was = Prop.Value
            const Settled = SettleValue(Prop, Was)
            if not Settled then
                continue
            end

            Prop:Set(Settled)
            if Confirmed[Prop] == Was then
                Confirmed[Prop] = Settled
            end

            const Held = Previewing[Prop]
            if Held and Held.Before == Was then
                Held.Before = Settled
            end
        end
    end
end)

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

        -- Somebody else's edit landing under a drag. It is what a refusal or a
        -- cancel returns to from now on, but it does not pull the value out
        -- from under the player's hand; the set that ends the drag decides.
        if Previewing[Prop] then
            const Fixed = PropertyTypes:FixValue(Prop.Type, Value, Prop.Constraints)
            if Fixed ~= nil then
                Confirm(Prop, Fixed)
            end

            return
        end

        Prop:Set(Value)
        Confirm(Prop, Prop.Value)
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
