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
const Network = require("./Network")
const Shared = require("./Shared")
const Logger = require("../Logger")
const Types = require("./Types")

export type Operation = Types.Operation
export type Transaction = Types.Transaction

const Transactions = {}

const New = Shared.factory(Objects, function(Transaction: Transaction)
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
    return Applied == true, Created or {}
end)

function Transactions.new(): Transaction
    return New()
end

return Transactions
