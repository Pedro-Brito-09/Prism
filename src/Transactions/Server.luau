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
-- Then apply, creates before sets before destroys. That order was originally
-- what made the thing atomic rather than merely batched: a create could be
-- taken back by destroying what it made and a set by writing back what it
-- overwrote, while a destroy could not be taken back at all, so nothing
-- irreversible happened until everything reversible had already succeeded.
--
-- A destroy withdraws its object now rather than ending it -- that is what lets
-- a history hold it against an undo -- so the roll back reaches the destroys
-- too and the order is no longer load bearing. It is kept because it is still
-- the order the operations mean: a transaction that creates an object and sets
-- a property on it reads that way round, and one that edits an object and then
-- destroys it should not have the edit land after the removal.

const PropertyTypes = require("../Properties/Types")
const Permissions = require("../Permissions/Server")
const Properties = require("../Properties/Server")
const ObjectTypes = require("../Objects/Types")
const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const ObjectShared = require("../Objects/Shared")
const Scenes = require("../Scenes/Server")
const Audience = require("../Scenes/Audience")
const Network = require("./Network")
const Shared = require("./Shared")
const Listeners = require("../Listeners")
const Logger = require("../Logger")
const Types = require("./Types")

export type Operation = Types.Operation
export type Transaction = Types.Transaction

-- A transaction that landed, as the thing that has to be able to reverse it
-- needs to see it: the list as the author wrote it, the objects it made, the
-- objects it took away -- suspended rather than destroyed, so they can be put
-- back -- and what each set overwrote, by operation.
export type ApplyRecord = {
    Operations: {Operation},
    Created: {ObjectTypes.Object},
    Removed: {ObjectTypes.Object},
    Before: {[number]: any},

    -- The object each set and destroy resolved to, by operation. Resolving them
    -- again afterwards would not work: an object this transaction destroyed is
    -- out of the workspace by the time anyone reads the record, and a set on an
    -- object the same transaction went on to destroy would find nothing.
    Targets: {[number]: ObjectTypes.Object},

    -- The copies it put in the world, and the ones it withdrew -- suspended
    -- rather than unloaded, so whatever takes this record takes them too.
    Loaded: {any},
    Withdrew: {any},
}

const Transactions = {}

-- Synchronous, and answers: taking the record means taking the suspended
-- objects in it, so the answer has to arrive before Apply decides whether to
-- dispose of them. A spawned listener could not say in time.
const Recorders: {(Plr: Player, Record: ApplyRecord) -> boolean} = {}

-- What a player's transaction did, offered to whatever records it -- History,
-- normally. Return true to take it; see ApplyRecord.
function Transactions.OnApplied(Callback: (Plr: Player, Record: ApplyRecord) -> boolean): () -> ()
    return Listeners.Watch(Recorders, Callback, "applied transactions")
end

-- A ceiling on one packet, not on how much work a role may do: the rate budget
-- is what actually bounds that, and at any sane rate it binds long before this
-- does. This is here so a decode loop cannot be handed a length that costs more
-- to walk than the packet cost to send.
const MAX_OPERATIONS = 1024

type PlannedCreate = {
    Object: ObjectTypes.ObjectIdentifier,

    -- The live scene copy the object goes in, or nil for the one Objects.new
    -- would have picked on its own.
    Instance: any,
    Properties: {[PropertyTypes.PropertyIdentifier]: any},

    -- Object properties pointing at something else this transaction creates,
    -- by the position of that object in the plan's own create list rather than
    -- by the operation index the packet named. Resolved to ids once the creates
    -- have run and the copy has minted them. A Table of references holds a list,
    -- zero for an item that keeps the id its value gives it.
    References: {[PropertyTypes.PropertyIdentifier]: number | {number}}?,
}

type PlannedSet = {
    Object: ObjectTypes.Object,
    Property: PropertyTypes.Property<any>,
    Value: any,

    -- Which operation asked for it, so what the set overwrote can be reported
    -- back against the list the author wrote rather than against the plan.
    Index: number,
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
    -- reference is going into, as the packet wrote it. A list for a Table of
    -- references, zero for an item naming no operation.
    Operation: number | {number},
    Instance: number,
}

type Plan = {
    Creates: {PlannedCreate},
    Sets: {PlannedSet},
    Destroys: {ObjectTypes.Object},
    Locks: {ObjectTypes.Object},
    Unlocks: {ObjectTypes.Object},
    Loads: {any},
    Unloads: {any},

    -- What each set and destroy operation resolved to, kept by operation so the
    -- record handed out afterwards can name them without looking them up in a
    -- world they may no longer be in.
    Targets: {[number]: ObjectTypes.Object},
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

    -- Holds taken and released, and copies coming and going. Gathered rather
    -- than applied one at a time: a lock is all or none, so every Lock in the
    -- list is one claim.
    const Locks: {ObjectTypes.Object} = {}
    const Unlocks: {ObjectTypes.Object} = {}
    const Loads: {any} = {}
    const Unloads: {any} = {}
    const Withdrawn: {[number]: true} = {}

    -- Objects already listed for destruction. Naming one twice is a redundant
    -- operation rather than an invalid one, and dropping the repeat here keeps
    -- it out of the packet that announces the removals.
    const Doomed: {[ObjectTypes.RuntimeId]: true} = {}
    const Targets: {[number]: ObjectTypes.Object} = {}

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
                Registry = Operation.Object,
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

                    -- A list of operations for a list of references, one for
                    -- one, and never the other way round.
                    const IsList = type(Names) == "table"
                    if not PropertyTypes.HoldsReferences(PropertyRegistry) or IsList ~= (PropertyRegistry.Type == "Table") then
                        return Refuse(Plr, `{PropertyRegistry.Name} is a {PropertyRegistry.Type}, which cannot hold {if IsList then "a list of references" else "a reference"}.`)
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

            -- And a list's items, which IsValid cannot tell apart where they
            -- are all numbers. An empty list has no item type to disagree.
            if Prop.Type == "Table" and Operation.ItemType and Operation.ItemType ~= Prop.Constraints.Of then
                return Refuse(Plr, `{Prop.Name} holds {Prop.Constraints.Of} and the operation carried {Operation.ItemType}.`)
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
            if PropertyTypes.HoldsReferences(Prop) then
                const Reference, Why = Objects.Reference(Obj.InstanceId, Prop, Value)
                if Reference == nil then
                    return Refuse(Plr, `{Obj.Name}.{Prop.Name} cannot point there: {Why}.`)
                end

                Value = Reference
            end

            Targets[OperationIndex] = Obj
            table.insert(Sets, {
                Object = Obj,
                Property = Prop,
                Value = Value,
                Index = OperationIndex,
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

            Targets[OperationIndex] = Obj

            if not Doomed[Obj.RuntimeId] then
                Doomed[Obj.RuntimeId] = true
                table.insert(Destroys, Obj)
            end
        elseif Operation.Kind == "Lock" or Operation.Kind == "Unlock" then
            const Obj = Objects:Get(Operation.Target)
            if not Obj or Obj.Destroyed or (Plr and not Audience.Sees(Plr, Obj.Scene)) then
                return Refuse(Plr, `object {Operation.Target} is not here.`)
            end

            Targets[OperationIndex] = Obj

            if Operation.Kind == "Lock" then
                -- The same right taking one through Objects:Lock needs: a hold
                -- is worth having only where an edit would be allowed, and
                -- holding what you may not change is a way to stop other people
                -- working rather than a way to work.
                if Plr and not Permissions:Can(Plr, "Edit", Obj) then
                    return Refuse(Plr, `not allowed to hold {Obj.Name}.`)
                end

                -- Held by somebody else, which Objects:Lock would refuse. Caught
                -- here so the whole transaction stops before the world moves
                -- rather than after the creates have run.
                if Plr and Objects.LockedAgainst(Obj, Plr) then
                    return Refuse(Plr, `{Obj.Name} is held by someone else.`)
                end

                table.insert(Locks, Obj)
            else
                -- Releasing needs no right, but releasing what is not yours does
                -- not happen: Objects:Unlock refuses the lot if any of them is
                -- somebody else's.
                if Plr and Objects.LockedAgainst(Obj, Plr) then
                    return Refuse(Plr, `{Obj.Name} is held by someone else.`)
                end

                table.insert(Unlocks, Obj)
            end
        elseif Operation.Kind == "Load" then
            const Scene = Scenes:GetById(Operation.Scene)
            if not Scene or (Plr and not Audience.Sees(Plr, Scene.Id)) then
                return Refuse(Plr, `scene {Operation.Scene} is not registered.`)
            end

            -- Loading a scene is making every object in it, so it asks for what
            -- making one asks for: the create verb on that scene.
            --
            -- The verb alone, and deliberately. A pack holds whatever it holds,
            -- so there is no type here to check the object lists against
            -- without reading the whole thing first -- which is why those lists
            -- govern what a role builds by hand and say nothing about this. A
            -- role that may create in a scene may put copies of it in the world.
            const Allowed = if Plr then Scene:GetRights(Plr) else nil
            if Plr and not (Allowed and Allowed.CanCreate) then
                return Refuse(Plr, `not allowed to load {Scene.Name}.`)
            end

            table.insert(Loads, Scene)
        elseif Operation.Kind == "Unload" then
            const Live = Scenes:GetInstance(Operation.Instance)
            if not Live or (Plr and not Audience.Sees(Plr, Live.Scene)) then
                return Refuse(Plr, `scene copy {Operation.Instance} is not live.`)
            end

            -- And taking a copy away is destroying every object in it, read the
            -- same way and for the same reason.
            const Owner = Scenes:GetById(Live.Scene)
            const Allowed = if Plr and Owner then Owner:GetRights(Plr) else nil
            if Plr and not (Allowed and Allowed.CanDestroy) then
                return Refuse(Plr, "not allowed to unload that copy.")
            end

            -- Named twice is one unload, like a destroy.
            if not Withdrawn[Live.Id] then
                Withdrawn[Live.Id] = true
                table.insert(Unloads, Live)
            end
        else
            return Refuse(Plr, `unknown operation kind {tostring((Operation :: any).Kind)}.`)
        end
    end

    -- Now that every operation has been read, the references can be answered.
    -- Where in Creates the operation a reference names ended up, or why it
    -- cannot be pointed at.
    const function Locate(Operation: number, Instance: number): (number?, string?)
        const Names = CreateAt[Operation]
        if not Names then
            return nil, `a reference names operation {Operation}, which is not a create in this transaction.`
        end

        -- Both creates have to land in the same copy, because a local id means
        -- nothing outside one. Compared as the packet wrote them: two creates
        -- of one group carry the same copy, and a caller mixing "this copy" and
        -- "wherever creates go" is told so rather than guessed at.
        const Other = Operations[Operation] :: Types.CreateOperation
        if Other.Instance ~= Instance then
            return nil, "a reference names a create going into another copy."
        end

        return Names
    end

    for _, Reference in Pending do
        local Names: number | {number}

        if type(Reference.Operation) == "table" then
            const Resolved = table.create(#Reference.Operation)
            for Index, Operation in Reference.Operation do
                if Operation == 0 then
                    Resolved[Index] = 0
                    continue
                end

                const At, Why = Locate(Operation, Reference.Instance)
                if not At then
                    return Refuse(Plr, Why :: string)
                end

                Resolved[Index] = At
            end

            Names = Resolved
        else
            const At, Why = Locate(Reference.Operation :: number, Reference.Instance)
            if not At then
                return Refuse(Plr, Why :: string)
            end

            Names = At
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
        Targets = Targets,
        Locks = Locks,
        Unlocks = Unlocks,
        Loads = Loads,
        Unloads = Unloads,
    }
end

-- Plr is who to check against, and nil means the server itself: it authored the
-- list, so there is no role to consult and no budget to spend.
--
-- Tracked is false for a transaction that must not become a step in the
-- author's history -- what History itself applies when it reverses one, and
-- what a client asks for by committing an Untracked transaction. It is not a
-- permission: an untracked edit is checked and charged exactly like any other.
function Transactions.Apply(
    Plr: Player?,
    Operations: {Operation},
    Tracked: boolean?
): (boolean, {ObjectTypes.RuntimeId})
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

    -- Copies this transaction put in the world and took out of it. Taken out
    -- means suspended: a copy a player asked to go is set aside whole, so an
    -- undo brings back what was in it rather than what its scene last saved.
    const Loaded: {any} = {}
    const Withdrew: {any} = {}

    -- Whether the holds were taken, so a roll back knows to let them go again.
    local Held = false

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

    -- The same values again, but by operation rather than by property, which is
    -- what reversing the list later reads. Two sets on one property both report
    -- what the property held before the transaction began, because that is what
    -- undoing the transaction has to put back.
    const Before: {[number]: any} = {}

    const Ok, Err = pcall(function()
        -- Holds first, because that is what they are for: everything below
        -- happens with them already taken. All or none, like Objects:Lock --
        -- and the plan has already refused any that somebody else is holding,
        -- so this failing is a race rather than the ordinary case.
        if #Planned.Locks > 0 then
            if not Objects:Lock(Planned.Locks, Plr) then
                error("could not take the holds it asked for")
            end

            Held = true
        end

        -- Then the copies it asks to appear, before anything that might name
        -- one: a create can land in a copy this same transaction loaded.
        for _, Scene in Planned.Loads do
            const Live = Scene:Load()
            if not Live then
                error(`could not load {Scene.Name}`)
            end

            table.insert(Loaded, Live)
        end

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
                if not Prop then
                    continue
                end

                -- A list is put together item by item: the object a create made
                -- where an entry names one, and the id the value already held
                -- where it does not.
                local Points: any
                if type(Names) == "table" then
                    const Held = if type(Prop.Value) == "table" then Prop.Value else {}
                    Points = table.create(#Names)

                    for Item, Entry in Names do
                        Points[Item] = if Entry == 0
                            then Held[Item] or ObjectShared.NO_TARGET
                            else Created[Entry] or ObjectShared.NO_TARGET
                    end
                else
                    Points = Created[Names]
                    if not Points then
                        continue
                    end
                end

                -- Through the same check a set makes, against the objects now
                -- that they are real. The plan compared what the packet said;
                -- this compares what was built, and a failure here throws into
                -- the rollback below rather than leaving half a wiring.
                const Target, Why = Objects.Reference(Obj.InstanceId, Prop, Points)
                if Target == nil then
                    error(`{Obj.Name}.{Prop.Name} cannot point there: {Why}.`)
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

            Before[Set.Index] = Previous[Prop]

            -- The property itself rather than the object's Set, which would
            -- fire a packet per operation. Links are property listeners, so
            -- they still run.
            const _, Changed = Prop:Set(Set.Value)
            if not Changed then
                continue
            end

            const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value, Prop.Constraints)
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
            -- Suspended, not destroyed. What becomes of it is decided below,
            -- once it is known whether anything is keeping this transaction:
            -- a player's history keeps the objects its destroys took away, so
            -- that an undo restores them rather than replacing them.
            Objects.Suspend(Obj, false)
            table.insert(Removed, Obj)
        end

        -- Copies out after the objects, for the same reason destroys come after
        -- sets: an edit to something in a copy this transaction also withdraws
        -- should land before the copy goes.
        for _, Live in Planned.Unloads do
            if Live:Suspend() then
                table.insert(Withdrew, Live)
            end
        end

        -- And the holds let go last, which is the order the words are in: hold
        -- these, do this, let go.
        if #Planned.Unlocks > 0 then
            Objects:Unlock(Planned.Unlocks)
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

        -- Including the destroys that had already run, which is new: a destroy
        -- withdraws an object rather than ending it, so the one operation that
        -- used to be beyond recall is recoverable too. They were never
        -- announced -- the removals go out in bulk below, and this path does
        -- not reach that -- so no client ever knew they had gone.
        for _, Obj in Removed do
            Objects.Revive(Obj, false)
        end

        -- Copies likewise, and the ones it loaded go again. A copy it made and
        -- is now taking back is not a withdrawal of anybody's work: nothing has
        -- had a chance to touch it, so it is unloaded outright.
        for _, Live in Withdrew do
            Live:Revive()
        end

        for _, Live in Loaded do
            Live:Unload()
        end

        if Held then
            Objects:Unlock(Planned.Locks)
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

    -- Offered whole, and only for a player's own tracked transactions: the
    -- server's belong to nobody and are nobody's to undo. A listener that
    -- answers true has taken the step, and with it every object suspended
    -- above -- they are its to revive on an undo and its to dispose of when the
    -- step falls off the stack.
    --
    -- Nothing answering means nothing is holding them, and a destroy that
    -- nobody can undo is a destroy: they end here, which is what they used to
    -- do the moment the loop above reached them.
    local Kept = false
    if Plr and Tracked ~= false then
        const Record: ApplyRecord = {
            Operations = Operations,
            Created = Created,
            Removed = Removed,
            Before = Before,
            Targets = Planned.Targets,
            Loaded = Loaded,
            Withdrew = Withdrew,
        }

        for _, Callback in Recorders do
            if Callback(Plr, Record) then
                Kept = true
                break
            end
        end
    end

    if not Kept then
        for _, Obj in Removed do
            Objects.Dispose(Obj)
        end

        for _, Live in Withdrew do
            Live:Dispose()
        end
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

Network.Apply.OnInvoke = function(Plr: Player, Compressed: buffer, Untracked: boolean): (boolean, {ObjectTypes.RuntimeId})
    -- Bytes a client authored: a malformed list is a dropped packet, not an
    -- error thrown out of the remote handler.
    const Ok, Operations = pcall(function()
        return Compressor:DecompressTransaction(Compressed)
    end)

    if not Ok or not Operations then
        return false, {}
    end

    return Transactions.Apply(Plr, Operations, not Untracked)
end

return Transactions
