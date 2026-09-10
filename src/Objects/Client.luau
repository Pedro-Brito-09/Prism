--!strict
const CollectionService = game:GetService("CollectionService")

const Properties = require("../Properties/Client")
const PropertyTypes = require("../Properties/Types")
const Compressor = require("../Compressor")
const Network = require("./Network")
const Shared = require("./Shared")
const Handles = require("../Handles")
const Logger = require("../Logger")
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

-- Which scene each live copy came from. Kept here rather than in Scenes/Client
-- because an arriving object needs it to work out its own persistent identity,
-- and Objects cannot require Scenes without a cycle.
const InstanceScene: {[Types.SceneInstanceId]: Types.SceneIdentifier} = {}

const function Index(Obj: Object)
    local Held = ByInstance[Obj.InstanceId]
    if not Held then
        Held = {}
        ByInstance[Obj.InstanceId] = Held
    end

    Held[Obj.RuntimeId] = Obj
end

const function Unindex(Obj: Object)
    const Held = ByInstance[Obj.InstanceId]
    if not Held then
        return
    end

    Held[Obj.RuntimeId] = nil
    if next(Held) == nil then
        ByInstance[Obj.InstanceId] = nil
    end
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

const function __getter(self: Object, Reference: Types.PropertyReference): any?
    const Prop = Shared.GetProperty(self, Reference)
    if not Prop then
        return nil
    end

    return if Prop.Value == nil then Prop.DefaultValue else Prop.Value
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

    const Accepted, Changed = Prop:Set(Value)
    if not Accepted then
        return false
    end

    -- Setting a property to the value it already holds is a no-op, not a reason
    -- to spend a round trip.
    if not Changed then
        return true
    end

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

    for _, Prop in Obj.Properties do
        Prop:Destroy()
    end

    if Obj.Instance then
        ByPart[Obj.Instance] = nil
        Obj.Instance = nil
    end

    ByRuntimeId[Obj.RuntimeId] = nil
    Unindex(Obj)

    -- Not table.clear: a stale reference should still be able to report its own
    -- handle and read Destroyed rather than turning into an empty table
    -- whose every method throws.
    Obj.Get = Shared.Destroyed.Get
    Obj.Set = Shared.Destroyed.Set
    Obj.GetProperty = Shared.Destroyed.GetProperty
    Obj.OnChange = Shared.Destroyed.OnChange
    Obj.Destroy = Shared.Destroyed.Destroy
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

-- Told by Scenes/Client as the server announces copies appearing.
function Objects.TrackInstance(Live: Types.SceneInstanceId, Scene: Types.SceneIdentifier)
    InstanceScene[Live] = Scene
end

-- Tears down every object of one live copy. Called by Scenes/Client when the
-- server says the copy is gone, which arrives as a single packet: the objects
-- are already gone there and no ObjectRemoved is coming for any of them.
function Objects.DropInstance(Live: Types.SceneInstanceId)
    InstanceScene[Live] = nil

    const Held = ByInstance[Live]
    if not Held then
        return
    end

    for RuntimeId, Obj in table.clone(Held) do
        Workspace[RuntimeId] = nil
        Teardown(Obj)
    end

    ByInstance[Live] = nil
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

    -- The reference that came with the object is the fast path. When it did not
    -- survive, the part may already be here and tracked under its runtime id.
    const Resolved = Inst or ByRuntimeId[RuntimeId]

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

    Obj.Names = Shared.BuildNameMap(Registry.Properties, Obj.Properties)
    Obj.Get = __getter
    Obj.Set = __setter
    Obj.GetProperty = Shared.GetProperty
    Obj.OnChange = Shared.OnChange
    Obj.Destroy = __destroy

    Workspace[RuntimeId] = Obj
    Index(Obj :: any)

    if Resolved then
        ByPart[Resolved] = RuntimeId
        ByRuntimeId[RuntimeId] = Resolved
    end
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

    Workspace[RuntimeId] = nil
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
