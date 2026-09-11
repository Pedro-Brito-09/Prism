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

const New = Shared.factory(Objects, function(Transaction: Transaction)
    const Before, Removed = Capture(Transaction)

    -- Writing the packet is inside the pcall as well as sending it. An
    -- operation that cannot be encoded throws rather than being dropped, and
    -- the whole point is that a transaction is never sent four fifths written.
    const Ok, Applied, Created = pcall(function()
        return Network.Apply:Invoke(Compressor:CompressTransaction(Transaction.Operations))
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
