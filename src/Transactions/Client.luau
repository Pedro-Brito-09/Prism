--!strict
-- The client's half: build the list, send it as one packet, wait for the
-- answer.
--
-- Deliberately not optimistic, which a single Set is. A set has a local object
-- to write to and a value to roll back to if the server says no. A create has
-- neither: the object does not exist on this side, and its runtime id is the
-- server's to mint, so there is nothing to apply on the spot and nothing to
-- hand back until the answer comes. Applying the sets optimistically and
-- leaving the creates until later would also break the one property the whole
-- feature is for -- that the edit lands as a unit.
--
-- Commit therefore yields until the server answers, and a caller that wants to
-- keep painting frames while it flies should spawn it.

const Compressor = require("../Compressor")
const Objects = require("../Objects/Client")
const ObjectShared = require("../Objects/Shared")
const Scenes = require("../Scenes/Client")
const Network = require("./Network")
const Shared = require("./Shared")
const Listeners = require("../Listeners")
const Logger = require("../Logger")
const Types = require("./Types")

export type Operation = Types.Operation
export type Transaction = Types.Transaction
export type CommitRecord = Types.CommitRecord

const Transactions = {}
const Committed: {(Record: CommitRecord) -> ()} = {}

-- What reversing the transaction later needs and only now can be read: the
-- value each set is about to overwrite, and everything each destroy is about to
-- take away. Once the answer comes, the old values are gone.
const function Capture(Transaction: Transaction): ({[number]: any}, {[number]: any})
    const Before = {}
    const Removed = {}

    for Index, Operation in Transaction.Operations do
        const Op = Operation :: any

        if Op.Kind == "Set" then
            const Obj = Objects:Get(Op.Target)
            const Prop = if Obj then Obj.Properties[Op.Property] else nil
            Before[Index] = if Prop then Prop.Value else nil
        elseif Op.Kind == "Destroy" then
            const Obj = Objects:Get(Op.Target)
            if Obj then
                Removed[Index] = {
                    Parent = Obj.Parent,
                    Values = ObjectShared.Snapshot(Obj),
                    Instance = Obj.InstanceId,
                }
            end
        end
    end

    return Before, Removed
end

--=============================================================================
-- Scenes this client owns
--=============================================================================

-- A transaction whose objects are all in scenes this client owns applies here
-- rather than being sent: there is nobody to ask, nothing to refuse it, and
-- nothing to roll back to but itself. It is the same list of operations, built
-- by the same builder and applied in the same three phases the server uses, so
-- an editor writes one kind of edit whichever kind of scene it is working in.
--
-- What it is for is what a transaction has always been for: the edit lands
-- whole or not at all, and it is one thing to take back. Before this a local
-- scene had no batching at all -- every set, create and destroy was its own
-- apply and its own undo step, so undoing a pasted prefab took it apart one
-- object at a time.

export type ApplyRecord = {
    Operations: {Operation},
    Created: {any},
    Removed: {any},
    Before: {[number]: any},
    Targets: {[number]: any},
}

-- Fired before a local apply begins and after it lands. History listens to
-- both: the first tells it to stop recording object by object, the second hands
-- it the whole edit as one step. Synchronous and in that order, because the
-- signals a local object fires as it is built or withdrawn would otherwise
-- reach the history before the record does.
--
-- Answering true to the second means taking the record, and with it the objects
-- its destroys suspended; nothing answering means they are disposed here.
const Starting: {() -> ()} = {}
-- Nil where the apply came apart and was rolled back. Every Applying is
-- followed by exactly one of these, whichever way it went, so a listener that
-- turned something off on the first can turn it back on here without having to
-- wonder.
const Recorders: {(Record: ApplyRecord?) -> boolean} = {}

function Transactions.OnApplying(Callback: () -> ()): () -> ()
    return Listeners.Watch(Starting, Callback, "local applies beginning")
end

function Transactions.OnApplied(Callback: (Record: ApplyRecord?) -> boolean): () -> ()
    return Listeners.Watch(Recorders, Callback, "local applies")
end

type PlannedCreate = {
    Object: number,
    Live: any,
    Properties: {[number]: any},

    -- By position in this plan's own create list, not by the operation index
    -- the builder wrote.
    References: {[number]: number}?,
}

type LocalPlan = {
    Creates: {PlannedCreate},
    Sets: {{Index: number, Property: any, Value: any}},
    Destroys: {any},
    Targets: {[number]: any},
}

-- Resolve and check everything, touching nothing. A transaction that cannot be
-- applied whole is not applied at all, and this is where that is settled.
const function Plan(Transaction: Transaction): LocalPlan?
    const Planned: LocalPlan = {Creates = {}, Sets = {}, Destroys = {}, Targets = {}}
    const Doomed: {[number]: true} = {}
    const CreateAt: {[number]: number} = {}
    const Pending: {{At: number, References: {[number]: number}}} = {}

    for Index, Operation in Transaction.Operations do
        const Op = Operation :: any

        if Op.Kind == "Create" then
            const Live = Scenes:GetLocalCopy(Op.Instance)
            if not Live then
                Logger:Warn(`A local transaction names copy {Op.Instance}, which is not a copy of a scene this client owns.`)
                return nil
            end

            table.insert(Planned.Creates, {
                Object = Op.Object,
                Live = Live,
                Properties = Op.Properties,
            })

            CreateAt[Index] = #Planned.Creates

            if Op.References then
                table.insert(Pending, {At = #Planned.Creates, References = Op.References})
            end
        elseif Op.Kind == "Set" then
            const Obj = Objects:Get(Op.Target)
            if not Obj or Obj.Destroyed then
                Logger:Warn("A local transaction names an object that is not here.")
                return nil
            end

            const Prop = Obj.Properties[Op.Property]
            if not Prop then
                Logger:Warn(`A local transaction sets property {Op.Property}, which {Obj.Name} does not carry.`)
                return nil
            end

            Planned.Targets[Index] = Obj
            table.insert(Planned.Sets, {Index = Index, Property = Prop, Value = Op.Value})
        elseif Op.Kind == "Destroy" then
            const Obj = Objects:Get(Op.Target)
            if not Obj or Obj.Destroyed then
                Logger:Warn("A local transaction names an object that is not here.")
                return nil
            end

            Planned.Targets[Index] = Obj

            if not Doomed[Obj.RuntimeId] then
                Doomed[Obj.RuntimeId] = true
                table.insert(Planned.Destroys, Obj)
            end
        else
            Logger:Warn(`A local transaction carries an operation of unknown kind {tostring(Op.Kind)}.`)
            return nil
        end
    end

    -- A reference names the operation that makes its target, because the id it
    -- will hold is minted as the creates run. Answered here, against the whole
    -- list, since the create it names may be further down it.
    for _, Entry in Pending do
        const Resolved: {[number]: number} = {}

        for PropertyId, Names in Entry.References do
            const At = CreateAt[Names]
            if not At then
                Logger:Warn(`A local transaction has a reference naming operation {Names}, which is not a create in it.`)
                return nil
            end

            Resolved[PropertyId] = At
        end

        Planned.Creates[Entry.At].References = Resolved
    end

    return Planned
end

const function ApplyLocal(Transaction: Transaction): (boolean, {number})
    const Planned = Plan(Transaction)
    if not Planned then
        return false, {}
    end

    Listeners.Notify(Starting)

    const Created: {any} = {}
    const Removed: {any} = {}
    const Before: {[number]: any} = {}

    -- What to write back if the apply throws partway. A list as well as a map,
    -- because a property whose value was nil leaves no entry in the map to
    -- iterate and would never be restored.
    const Touched: {any} = {}
    const Captured: {[any]: true} = {}
    const Previous: {[any]: any} = {}

    const Ok, Err = pcall(function()
        for _, Create in Planned.Creates do
            table.insert(Created, Objects.new(Create.Object, Create.Properties, Create.Live))
        end

        -- Every create has run, so every id a reference was waiting on exists.
        for Index, Create in Planned.Creates do
            if not Create.References then
                continue
            end

            const Obj = Created[Index]
            for PropertyId, Names in Create.References do
                const Prop = Obj.Properties[PropertyId]
                const Points = Created[Names]
                if Prop and Points then
                    Prop:Set(Points.LocalId)
                end
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

            -- The property rather than the object's Set, which would record an
            -- edit of its own: the whole transaction is one step, and this is
            -- inside it. Links are property listeners, so they still run.
            Prop:Set(Set.Value)
        end

        for _, Obj in Planned.Destroys do
            -- Suspended, not ended: what becomes of it is decided below, once
            -- it is known whether anything is keeping this edit.
            Objects.Suspend(Obj)
            table.insert(Removed, Obj)
        end
    end)

    if not Ok then
        Logger:Warn(`A local transaction failed partway through and was rolled back: {Err}`)

        for _, Obj in Removed do
            Objects.Revive(Obj)
        end

        for _, Prop in Touched do
            Prop:Set(Previous[Prop])
        end

        for _, Obj in Created do
            Objects.Retire(Obj)
        end

        -- Said even though there is nothing to record, because something is
        -- waiting to hear that the apply is over.
        for _, Callback in Recorders do
            Callback(nil)
        end

        return false, {}
    end

    -- Offered whole, and taken or not: a listener answering true has the record
    -- and the objects suspended above, to revive on an undo and to dispose of
    -- when the step holding them falls off the stack. Nothing answering means
    -- nothing is keeping them, and the destroys were as final as they looked.
    local Kept = false
    if not Transaction.Untracked then
        const Record: ApplyRecord = {
            Operations = Transaction.Operations,
            Created = Created,
            Removed = Removed,
            Before = Before,
            Targets = Planned.Targets,
        }

        for _, Callback in Recorders do
            if Callback(Record) then
                Kept = true
                break
            end
        end
    end

    if not Kept then
        for _, Obj in Removed do
            Objects.Dispose(Obj)
        end
    end

    const Ids = table.create(#Created)
    for Index, Obj in Created do
        Ids[Index] = Obj.RuntimeId
    end

    return true, Ids
end

const New = Shared.factory(Objects, function(Transaction: Transaction)
    -- A scene this client owns is this client's to edit, so there is nothing
    -- to send and nothing to wait for: this returns having already done it.
    if Transaction.Local then
        return ApplyLocal(Transaction)
    end

    const Before, Removed = Capture(Transaction)

    -- Writing the packet is inside the pcall as well as sending it. An
    -- operation that cannot be encoded throws rather than being dropped, and
    -- the whole point is that a transaction is never sent four fifths written.
    const Ok, Applied, Created = pcall(function()
        return Network.Apply:Invoke(
            Compressor:CompressTransaction(Transaction.Operations),
            Transaction.Untracked == true
        )
    end)

    if not Ok then
        Logger:Warn(`A transaction was not applied: {Applied}`)
        return false, {}
    end

    -- The objects themselves arrive on their own, through the same broadcast
    -- every other client receives. These are their ids, in the order the
    -- creates were declared, so the caller can find them once they land.
    const Ids = Created or {}

    if Applied == true then
        Listeners.Notify(Committed, {
            Transaction = Transaction,
            Created = Ids,
            Before = Before,
            Removed = Removed,
        })
    end

    return Applied == true, Ids
end)

function Transactions.new(): Transaction
    return New()
end

-- Every transaction this client commits that the server applied, with what it
-- overwrote and took away. History is built on this.
function Transactions:OnCommitted(Callback: (Record: CommitRecord) -> ()): () -> ()
    return Listeners.Watch(Committed, Callback, "commits")
end

return Transactions
