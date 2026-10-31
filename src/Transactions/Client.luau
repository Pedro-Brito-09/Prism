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
                    Registry = Obj.Registry,
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

    -- The copies it put in the world and the ones it withdrew, suspended rather
    -- than unloaded, so whatever takes this record takes them too.
    Loaded: {any},
    Withdrew: {any},
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
    -- the builder wrote. A list for a Table of references, zero for an item
    -- keeping the id its value gives it.
    References: {[number]: number | {number}}?,
}

type LocalPlan = {
    Creates: {PlannedCreate},
    Sets: {{Index: number, Property: any, Value: any}},
    Destroys: {any},
    Targets: {[number]: any},
    Loads: {any},
    Unloads: {any},
}

-- Resolve and check everything, touching nothing. A transaction that cannot be
-- applied whole is not applied at all, and this is where that is settled.
const function Plan(Transaction: Transaction): LocalPlan?
    const Planned: LocalPlan = {Creates = {}, Sets = {}, Destroys = {}, Targets = {}, Loads = {}, Unloads = {}}
    const Doomed: {[number]: true} = {}
    const Withdrawn: {[number]: true} = {}
    const CreateAt: {[number]: number} = {}
    const Pending: {{At: number, References: {[number]: number | {number}}}} = {}

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
        elseif Op.Kind == "Load" then
            const Scene = Scenes:GetLocalById(Op.Scene)
            if not Scene then
                Logger:Warn(`A local transaction names scene {Op.Scene}, which is not one this client owns.`)
                return nil
            end

            table.insert(Planned.Loads, Scene)
        elseif Op.Kind == "Unload" then
            const Live = Scenes:GetLocalCopy(Op.Instance)
            if not Live then
                Logger:Warn(`A local transaction names copy {Op.Instance}, which is not a copy of a scene this client owns.`)
                return nil
            end

            if not Withdrawn[Op.Instance] then
                Withdrawn[Op.Instance] = true
                table.insert(Planned.Unloads, Live)
            end
        elseif Op.Kind == "Lock" or Op.Kind == "Unlock" then
            -- Cannot happen through the builder, which refuses a hold on a
            -- local object. Said plainly rather than left to the branch below,
            -- because the reason is a rule rather than a mistake: nothing in a
            -- scene this client owns is anybody else's to touch.
            Logger:Warn("A local transaction cannot hold objects: nothing in a scene this client owns is held.")
            return nil
        else
            Logger:Warn(`A local transaction carries an operation of unknown kind {tostring(Op.Kind)}.`)
            return nil
        end
    end

    -- A reference names the operation that makes its target, because the id it
    -- will hold is minted as the creates run. Answered here, against the whole
    -- list, since the create it names may be further down it.
    const function Locate(Names: number): number?
        const At = CreateAt[Names]
        if not At then
            Logger:Warn(`A local transaction has a reference naming operation {Names}, which is not a create in it.`)
        end

        return At
    end

    for _, Entry in Pending do
        const Resolved: {[number]: number | {number}} = {}

        for PropertyId, Names in Entry.References do
            if type(Names) == "table" then
                const List = table.create(#Names) :: {number}
                for Index, Operation in Names do
                    if Operation == 0 then
                        List[Index] = 0
                        continue
                    end

                    const At = Locate(Operation)
                    if not At then
                        return nil
                    end

                    List[Index] = At
                end

                Resolved[PropertyId] = List
                continue
            end

            const At = Locate(Names :: number)
            if not At then
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
    const Loaded: {any} = {}
    const Withdrew: {any} = {}

    -- What to write back if the apply throws partway. A list as well as a map,
    -- because a property whose value was nil leaves no entry in the map to
    -- iterate and would never be restored.
    const Touched: {any} = {}
    const Captured: {[any]: true} = {}
    const Previous: {[any]: any} = {}

    const Ok, Err = pcall(function()
        -- Copies first, before anything that might name one: a create can land
        -- in a copy this same transaction loaded.
        for _, Scene in Planned.Loads do
            const Live = Scene:LoadWhole()
            if not Live then
                error(`could not load {Scene.Name}`)
            end

            table.insert(Loaded, Live)
        end

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
                if not Prop then
                    continue
                end

                -- Item by item, as on the server: the made object's id where an
                -- entry names a create, the held id where it does not.
                if type(Names) == "table" then
                    const Held = if type(Prop.Value) == "table" then Prop.Value else {}
                    const List = table.create(#Names) :: {any}

                    for Item, Entry in Names do
                        const Points = if Entry ~= 0 then Created[Entry] else nil
                        List[Item] = if Points then Points.LocalId
                            elseif Entry == 0 then Held[Item] or ObjectShared.NO_TARGET
                            else ObjectShared.NO_TARGET
                    end

                    Prop:Set(table.freeze(List))
                    continue
                end

                const Points = Created[Names]
                if Points then
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

        -- Copies out after the objects, so an edit to something in a copy this
        -- transaction also withdraws lands before the copy goes.
        for _, Live in Planned.Unloads do
            if Live:Suspend() then
                table.insert(Withdrew, Live)
            end
        end
    end)

    if not Ok then
        Logger:Warn(`A local transaction failed partway through and was rolled back: {Err}`)

        for _, Live in Withdrew do
            Live:Revive()
        end

        for _, Obj in Removed do
            Objects.Revive(Obj)
        end

        for _, Prop in Touched do
            Prop:Set(Previous[Prop])
        end

        for _, Obj in Created do
            Objects.Retire(Obj)
        end

        -- A copy it made and is now taking back is not anybody's work being
        -- withdrawn: nothing has had a chance to touch it, so it goes outright.
        for _, Live in Loaded do
            Live:Unload()
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
            Loaded = Loaded,
            Withdrew = Withdrew,
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

        for _, Live in Withdrew do
            Live:Dispose()
        end
    end

    const Ids = table.create(#Created) :: {number}
    for Index, Obj in Created do
        Ids[Index] = Obj.RuntimeId
    end

    return true, Ids
end

-- The holds an applied transaction took and let go of, recorded from its answer
-- rather than left to the broadcast, which travels on the other remote and can
-- land after Commit has returned. Releases run last, so an object both locked
-- and unlocked ends free. A destroyed object's hold went with it, and recording
-- one would leave an entry for an id the removal may already have cleared.
const function RecordHolds(Operations: {any})
    const Gone: {[number]: true} = {}
    const Final: {[number]: boolean} = {}

    for _, Op in Operations do
        if Op.Kind == "Destroy" then
            Gone[Op.Target] = true
        elseif Op.Kind == "Lock" and Final[Op.Target] == nil then
            Final[Op.Target] = true
        elseif Op.Kind == "Unlock" then
            Final[Op.Target] = false
        end
    end

    const Taken, Released = {}, {}
    for Target, IsHeld in Final do
        if not Gone[Target] then
            table.insert(if IsHeld then Taken else Released, Target)
        end
    end

    Objects.RecordHolds(Taken, true)
    Objects.RecordHolds(Released, false)
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
        RecordHolds(Transaction.Operations)

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
