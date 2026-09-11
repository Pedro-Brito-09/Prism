--!strict
-- Applying a transaction: the whole list or none of it.
--
-- This is also the only path by which a client can create an object. Before it
-- there was no channel that asked for one, so Permissions:Can(_, "Create", _)
-- was reachable by nothing and a client editor could edit and delete but never
-- build.
--
-- Three phases, in this order and for these reasons.
--
-- Budget first, by the size of the list rather than by the packet. A limiter
-- that charges per call lets one packet carrying ten thousand operations spend
-- a single unit and walk past it, and a flood of transactions that all get
-- refused still has to cost the flooder something.
--
-- Then plan: resolve every operation and check every one of them, touching
-- nothing. A single refusal ends the transaction here, where the world has not
-- moved yet.
--
-- Then apply, creates before sets before destroys. That order is what makes the
-- thing atomic rather than merely batched: a create can be taken back by
-- destroying what it made and a set by writing back what it overwrote, but a
-- destroy cannot be taken back at all, so nothing irreversible happens until
-- everything reversible has already succeeded.

const PropertyTypes = require("../Properties/Types")
const Permissions = require("../Permissions/Server")
const Properties = require("../Properties/Server")
const ObjectTypes = require("../Objects/Types")
const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const Scenes = require("../Scenes/Server")
const Audience = require("../Scenes/Audience")
const Network = require("./Network")
const Shared = require("./Shared")
const Logger = require("../Logger")
const Types = require("./Types")

export type Operation = Types.Operation
export type Transaction = Types.Transaction

-- A ceiling on one packet, not on how much work a role may do: the rate budget
-- is what actually bounds that, and at any sane rate it binds long before this
-- does. This is here so a decode loop cannot be handed a length that costs more
-- to walk than the packet cost to send.
const MAX_OPERATIONS = 1024

const Transactions = {}

type PlannedCreate = {
    Object: ObjectTypes.ObjectIdentifier,

    -- The live scene copy the object goes in, or nil for the one Objects.new
    -- would have picked on its own.
    Instance: any,
    Properties: {[PropertyTypes.PropertyIdentifier]: any},

    -- Object properties pointing at something else this transaction creates,
    -- by the position of that object in the plan's own create list rather than
    -- by the operation index the packet named. Resolved to ids once the creates
    -- have run and the copy has minted them.
    References: {[PropertyTypes.PropertyIdentifier]: number}?,
}

type PlannedSet = {
    Object: ObjectTypes.Object,
    Property: PropertyTypes.Property<any>,
    Value: any,
}

-- One create's reference to another, while the plan is still being built. It
-- cannot be answered where it is read -- the create it names may be further
-- down the list, which is how a button is created before its door -- so it is
-- held with everything needed to check it once the whole list is known.
type PendingReference = {
    -- Where in Creates the object doing the pointing is.
    Create: number,

    Property: PropertyTypes.PropertyIdentifier,

    -- The operation the author named, and the copy the create carrying this
    -- reference is going into, as the packet wrote it.
    Operation: number,
    Instance: number,
}

type Plan = {
    Creates: {PlannedCreate},
    Sets: {PlannedSet},
    Destroys: {ObjectTypes.Object},
}

-- A client is told nothing but false, and is told it silently: a refusal that
-- logs is a refusal a client can spam to fill the server's output. A
-- transaction the server itself built is the opposite -- there is no one to
-- return false to but the caller, and a silent one is a bug with no thread to
-- pull.
const function Refuse(Plr: Player?, Message: string): nil
    if not Plr then
        Logger:Warn(`Transaction refused: {Message}`)
    end

    return nil
end

const function BuildPlan(Plr: Player?, Operations: {Operation}): Plan?
    const Creates: {PlannedCreate} = {}
    const Sets: {PlannedSet} = {}
    const Destroys: {ObjectTypes.Object} = {}

    -- Objects already listed for destruction. Naming one twice is a redundant
    -- operation rather than an invalid one, and dropping the repeat here keeps
    -- it out of the packet that announces the removals.
    const Doomed: {[ObjectTypes.RuntimeId]: true} = {}

    -- Where each create operation ended up in Creates. A reference names an
    -- operation, because that is what the author could name; everything after
    -- the plan works in creates, because that is what the apply has in hand.
    const CreateAt: {[number]: number} = {}

    -- References cannot be checked as they are read: one may name a create
    -- further down the list, which is how a button is created before the door
    -- it points at. Held until the whole list is known, then checked together.
    const Pending: {PendingReference} = {}

    for OperationIndex, Operation in Operations do
        if Operation.Kind == "Create" then
            const Registry = Objects:GetRegistry(Operation.Object)
            if not Registry then
                return Refuse(Plr, `object type {Operation.Object} is not registered.`)
            end

            -- Zero is "wherever Objects.new would have put it", which is the
            -- implicit default scene. Anything else has to name a copy that is
            -- actually live: a scene loaded twice has two, and guessing between
            -- them puts the object in a room the caller did not choose.
            local Live: any = nil
            if Operation.Instance ~= 0 then
                Live = Scenes:GetInstance(Operation.Instance)
                if not Live then
                    return Refuse(Plr, `scene copy {Operation.Instance} is not live.`)
                end
            end

            -- What the create is checked against: the scene it lands in and
            -- the type it makes, which is what an object carries once it
            -- exists.
            const Target = {
                Scene = if Live then Live.Scene else Scenes:GetDefault().Id,
                Parent = Operation.Object,
            }

            -- A copy of a scene the player was never admitted to is one they
            -- have not been told exists, and is refused as if it were not live.
            if Plr and not Audience.Sees(Plr, Target.Scene) then
                return Refuse(Plr, `scene copy {Operation.Instance} is not live.`)
            end

            if Plr and not Permissions:Can(Plr, "Create", Target) then
                return Refuse(Plr, `not allowed to create {Registry.Name}.`)
            end

            const Carried: {[PropertyTypes.PropertyIdentifier]: true} = {}
            for _, PropertyId in Registry.Properties do
                Carried[PropertyId] = true
            end

            const Initial = {}
            for PropertyId, Value in Operation.Properties do
                -- Dropped rather than refused, which is what restoring a saved
                -- object does with a value for a property the type no longer
                -- carries.
                if not Carried[PropertyId] then
                    continue
                end

                const PropertyRegistry = Properties:GetRegistry(PropertyId)
                if not PropertyRegistry then
                    continue
                end

                -- Refused rather than dropped. The property is one the object
                -- will have, so quietly creating it holding something else is
                -- handing back an object that is not the one that was asked
                -- for. Clamping is not this: a value outside MinValue is valid
                -- and lands clamped, exactly as it would through Set.
                if not PropertyTypes:IsValid(PropertyRegistry.Type, Value, PropertyRegistry.Constraints) then
                    return Refuse(Plr, `{PropertyRegistry.Name} cannot hold the value the create carried.`)
                end

                -- An initial value is a write, so the property lists get their
                -- say over it exactly as they do over an edit.
                if Plr and not Permissions:Can(Plr, "Create", Target, PropertyId) then
                    return Refuse(Plr, `not allowed to write {PropertyRegistry.Name}.`)
                end

                Initial[PropertyId] = Value
            end

            table.insert(Creates, {
                Object = Operation.Object,
                Instance = Live,
                Properties = Initial,
            })

            CreateAt[OperationIndex] = #Creates

            if Operation.References then
                for PropertyId, Names in Operation.References do
                    -- Refused rather than dropped, unlike a value for a
                    -- property the type does not carry. A value can be left out
                    -- and leave a coherent object behind; a reference left out
                    -- leaves an object whose whole reason for being created
                    -- alongside the others is missing, and nothing downstream
                    -- can tell.
                    if not Carried[PropertyId] then
                        return Refuse(Plr, `{Registry.Name} does not carry property {PropertyId}.`)
                    end

                    const PropertyRegistry = Properties:GetRegistry(PropertyId)
                    if not PropertyRegistry then
                        return Refuse(Plr, `property {PropertyId} is not registered.`)
                    end

                    if PropertyRegistry.Type ~= "Object" then
                        return Refuse(Plr, `{PropertyRegistry.Name} is a {PropertyRegistry.Type}, which cannot hold a reference.`)
                    end

                    -- A reference is a write of that property, so it asks for
                    -- what writing it through a value would ask for.
                    if Plr and not Permissions:Can(Plr, "Create", Target, PropertyId) then
                        return Refuse(Plr, `not allowed to write {PropertyRegistry.Name}.`)
                    end

                    table.insert(Pending, {
                        Create = #Creates,
                        Property = PropertyId,
                        Operation = Names,
                        Instance = Operation.Instance,
                    })
                end
            end
        elseif Operation.Kind == "Set" then
            -- An object in a scene the player was never admitted to is not
            -- here, as far as they are concerned. The same goes for destroys.
            const Obj = Objects:Get(Operation.Target)
            if not Obj or Obj.Destroyed or (Plr and not Audience.Sees(Plr, Obj.Scene)) then
                return Refuse(Plr, `object {Operation.Target} is not here.`)
            end

            -- Held by someone else. The server's own transactions pass: a lock
            -- is between players, and the server is the one enforcing it.
            if Plr and Objects.LockedAgainst(Obj, Plr) then
                return Refuse(Plr, `{Obj.Name} is locked by someone else.`)
            end

            if Plr and not Permissions:Can(Plr, "Edit", Obj, Operation.Property) then
                return Refuse(Plr, `not allowed to edit {Obj.Name}.`)
            end

            const Prop = Obj.Properties[Operation.Property]
            if not Prop then
                return Refuse(Plr, `{Obj.Name} has no property {Operation.Property}.`)
            end

            -- The payload describes itself, so this is the author's own claim
            -- about what it wrote being checked against what the property
            -- holds, not the registry being asked twice.
            if Operation.Type ~= Prop.Type then
                return Refuse(Plr, `{Prop.Name} is a {Prop.Type} and the operation carried a {tostring(Operation.Type)}.`)
            end

            if not PropertyTypes:IsValid(Prop.Type, Operation.Value, Prop.Constraints) then
                return Refuse(Plr, `{Prop.Name} cannot hold {tostring(Operation.Value)}.`)
            end

            -- The rest of what an Object property will take, which IsValid
            -- cannot answer: it sees a number, and whether that number names
            -- something this property may point at depends on the copy holding
            -- the object being written. Refused here, where the world has not
            -- moved, rather than dropped inside the apply.
            local Value = Operation.Value
            if Prop.Type == "Object" then
                const Reference, Why = Objects.Reference(Obj.InstanceId, Prop, Value)
                if Reference == nil then
                    return Refuse(Plr, `{Obj.Name}.{Prop.Name} cannot point there: {Why}.`)
                end

                Value = Reference
            end

            table.insert(Sets, {
                Object = Obj,
                Property = Prop,
                Value = Value,
            })
        elseif Operation.Kind == "Destroy" then
            const Obj = Objects:Get(Operation.Target)
            if not Obj or Obj.Destroyed or (Plr and not Audience.Sees(Plr, Obj.Scene)) then
                return Refuse(Plr, `object {Operation.Target} is not here.`)
            end

            if Plr and Objects.LockedAgainst(Obj, Plr) then
                return Refuse(Plr, `{Obj.Name} is locked by someone else.`)
            end

            if Plr and not Permissions:Can(Plr, "Destroy", Obj) then
                return Refuse(Plr, `not allowed to destroy {Obj.Name}.`)
            end

            if not Doomed[Obj.RuntimeId] then
                Doomed[Obj.RuntimeId] = true
                table.insert(Destroys, Obj)
            end
        else
            return Refuse(Plr, `unknown operation kind {tostring((Operation :: any).Kind)}.`)
        end
    end

    -- Now that every operation has been read, the references can be answered.
    for _, Reference in Pending do
        const Names = CreateAt[Reference.Operation]
        if not Names then
            return Refuse(Plr, `a reference names operation {Reference.Operation}, which is not a create in this transaction.`)
        end

        -- Both creates have to land in the same copy, because a local id means
        -- nothing outside one. Compared as the packet wrote them: two creates
        -- of one group carry the same copy, and a caller mixing "this copy" and
        -- "wherever creates go" is told so rather than guessed at.
        const Other = Operations[Reference.Operation] :: Types.CreateOperation
        if Other.Instance ~= Reference.Instance then
            return Refuse(Plr, "a reference names a create going into another copy.")
        end

        const Create = Creates[Reference.Create]
        if not Create.References then
            Create.References = {}
        end

        (Create.References :: any)[Reference.Property] = Names
    end

    return {
        Creates = Creates,
        Sets = Sets,
        Destroys = Destroys,
    }
end

-- Plr is who to check against, and nil means the server itself: it authored the
-- list, so there is no role to consult and no budget to spend.
function Transactions.Apply(Plr: Player?, Operations: {Operation}): (boolean, {ObjectTypes.RuntimeId})
    if #Operations > MAX_OPERATIONS then
        Refuse(Plr, `{#Operations} operations is past the {MAX_OPERATIONS} a single transaction may carry.`)
        return false, {}
    end

    if Plr and not Permissions:Consume(Plr, #Operations) then
        return false, {}
    end

    const Planned = BuildPlan(Plr, Operations)
    if not Planned then
        return false, {}
    end

    const Created: {ObjectTypes.Object} = {}
    const Removed: {ObjectTypes.Object} = {}

    -- What to broadcast, and at most one entry per property: two sets on the
    -- same property in one transaction are one change by the time it lands, and
    -- sending both would replay the transaction's history rather than its
    -- result. Keyed by the property instance, which is already unique per
    -- object and property.
    const Changes: {{Object: ObjectTypes.Object, Property: PropertyTypes.PropertyIdentifier, Value: buffer}} = {}
    const At: {[any]: number} = {}

    -- What to write back if the apply throws partway, captured before the first
    -- set touches it. A list as well as a map, because a property whose value
    -- was nil leaves no entry in the map to iterate and would never be
    -- restored.
    const Touched: {PropertyTypes.Property<any>} = {}
    const Captured: {[any]: true} = {}
    const Previous: {[any]: any} = {}

    const Ok, Err = pcall(function()
        for _, Create in Planned.Creates do
            -- Silent: the objects go out together at the end, down the chunked
            -- path a scene load uses, rather than one packet each.
            table.insert(Created, Objects.new(Create.Object, Create.Properties, Create.Instance, false))
        end

        -- Every create has run, so every id a reference was waiting on exists.
        -- Before the announcement rather than after, which is what makes an
        -- object go out already pointing where it should: a client never sees
        -- the moment where a duplicated button still names the original door.
        for Index, Create in Planned.Creates do
            if not Create.References then
                continue
            end

            const Obj = Created[Index]
            for PropertyId, Names in Create.References do
                const Prop = Obj.Properties[PropertyId]
                const Points = Created[Names]
                if not Prop or not Points then
                    continue
                end

                -- Through the same check a set makes, against the objects now
                -- that they are real. The plan compared what the packet said;
                -- this compares what was built, and a failure here throws into
                -- the rollback below rather than leaving half a wiring.
                const Target, Why = Objects.Reference(Obj.InstanceId, Prop, Points)
                if Target == nil then
                    error(`{Obj.Name}.{Prop.Name} cannot point at {Points.Name}: {Why}.`)
                end

                Prop:Set(Target)
            end
        end

        for _, Set in Planned.Sets do
            const Prop = Set.Property

            if not Captured[Prop] then
                Captured[Prop] = true
                Previous[Prop] = Prop.Value
                table.insert(Touched, Prop)
            end

            -- The property itself rather than the object's Set, which would
            -- fire a packet per operation. Links are property listeners, so
            -- they still run.
            const _, Changed = Prop:Set(Set.Value)
            if not Changed then
                continue
            end

            const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value)
            if not Compressed then
                continue
            end

            const Entry = {
                Object = Set.Object,
                Property = Prop.Parent,
                Value = Compressed,
            }

            const Position = At[Prop]
            if Position then
                Changes[Position] = Entry
            else
                table.insert(Changes, Entry)
                At[Prop] = #Changes
            end
        end

        for _, Obj in Planned.Destroys do
            Objects.Drop(Obj)
            table.insert(Removed, Obj)
        end
    end)

    if not Ok then
        Logger:Warn(`A transaction failed partway through and was rolled back: {Err}`)

        -- None of this was announced, so undoing it needs no packet either.
        for _, Obj in Created do
            Objects.Drop(Obj)
        end

        for _, Prop in Touched do
            Prop:Set(Previous[Prop])
        end

        -- Except the destroys that had already run. Those cannot be taken back
        -- -- which is why they go last -- and they still have to reach the
        -- clients, or every client keeps drawing objects the server no longer
        -- has.
        if #Removed > 0 then
            Objects.AnnounceRemoved(Removed)
        end

        return false, {}
    end

    if #Created > 0 then
        Objects.AnnounceAll(Created)
    end

    if #Changes > 0 then
        const Announce = {}
        for _, Change in Changes do
            -- A property changed on an object the same transaction went on to
            -- destroy is not worth a packet: its removal is already in the one
            -- below.
            if not Change.Object.Destroyed then
                table.insert(Announce, Change)
            end
        end

        Objects.AnnounceChanged(Announce)
    end

    if #Removed > 0 then
        Objects.AnnounceRemoved(Removed)
    end

    const Identifiers = table.create(#Created)
    for Index, Obj in Created do
        Identifiers[Index] = Obj.RuntimeId
    end

    return true, Identifiers
end

-- The server's own half of Commit. It authored the list, so it applies straight
-- away: no packet, no permission pass, and the same batched broadcast a
-- client's transaction gets.
const New = Shared.factory(Objects, function(Transaction: Transaction)
    return Transactions.Apply(nil, Transaction.Operations)
end)

function Transactions.new(): Transaction
    return New()
end

Network.Apply.OnInvoke = function(Plr: Player, Compressed: buffer): (boolean, {ObjectTypes.RuntimeId})
    -- Bytes a client authored: a malformed list is a dropped packet, not an
    -- error thrown out of the remote handler.
    const Ok, Operations = pcall(function()
        return Compressor:DecompressTransaction(Compressed)
    end)

    if not Ok or not Operations then
        return false, {}
    end

    return Transactions.Apply(Plr, Operations)
end

return Transactions
