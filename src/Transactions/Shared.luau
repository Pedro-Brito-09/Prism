--!strict
-- Building a transaction, shared by the server and the client.
--
-- Only committing differs between the two: the client's sends a packet and
-- waits, the server's applies on the spot. Everything before that -- resolving
-- what the caller named, refusing what cannot be built -- is the same work
-- against the same registries, so it is written once and handed the side's own
-- Objects module.
--
-- An operation that cannot be built is not silently dropped. It counts against
-- the transaction and Commit refuses while that count is above zero: applying
-- four of the five things the caller asked for is the one behaviour a
-- transaction must not have, and it is far worse than refusing all five,
-- because nothing downstream can tell it happened.

const PropertyTypes = require("../Properties/Types")
const ObjectTypes = require("../Objects/Types")
const Logger = require("../Logger")
const Types = require("./Types")

export type Transaction = Types.Transaction
export type Operation = Types.Operation

const Shared = {}

const function Reject(Transaction: Transaction, Message: string)
    Transaction.Rejected += 1
    Logger:Warn(`{Message} The transaction will refuse to commit.`)
end

-- The side's Objects module, which is the one thing that differs and cannot be
-- named here: requiring either half would put this module on one side of the
-- wire. Both expose Get and GetRegistry with the same shape, which is all this
-- asks of it.
--
-- Built once per side rather than per transaction, so a transaction stays a
-- plain table with shared function fields, like an object.
function Shared.factory(
    Objects: any,
    Commit: (Transaction) -> (boolean, {ObjectTypes.RuntimeId})
): () -> Transaction
    const function Resolve(Target: Types.ObjectReference): ObjectTypes.Object?
        if type(Target) == "number" then
            return Objects:Get(Target)
        end

        if type(Target) == "table" and (Target :: any).RuntimeId then
            -- Looked up rather than trusted. A stale reference to an object
            -- destroyed since is still a table with a runtime id on it, and an
            -- operation naming one would be refused by the server anyway.
            return Objects:Get((Target :: any).RuntimeId)
        end

        return nil
    end

    const function __create(
        self: Transaction,
        Reference: Types.TypeReference,
        Values: {[PropertyTypes.PropertyIdentifier]: any}?,
        Live: ObjectTypes.SceneInstanceId?
    ): Transaction
        const Identifier = if type(Reference) == "table"
            then (Reference :: ObjectTypes.ObjectRegistry).Id
            else Reference

        const Registry = if type(Identifier) == "number" then Objects:GetRegistry(Identifier) else nil
        if not Registry or type(Identifier) ~= "number" then
            Reject(self, `Cannot create {tostring(Identifier)}: no object type is registered here with that id.`)
            return self
        end

        -- Only what the type actually carries. Objects.new ignores a value for
        -- a property the object does not have, and a transaction that carried
        -- one would spend bytes on the wire to have it ignored at the far end.
        const Carried = {}
        for _, PropertyId in Registry.Properties do
            Carried[PropertyId] = true
        end

        const Initial = {}
        if Values then
            for PropertyId, Value in Values do
                if not Carried[PropertyId] then
                    Logger:Warn(`{Registry.Name} does not carry property {PropertyId}, so that initial value was dropped.`)
                    continue
                end

                Initial[PropertyId] = Value
            end
        end

        table.insert(self.Operations, {
            Kind = "Create" :: "Create",
            Object = Identifier,
            Instance = Live or 0,
            Properties = Initial,
        })

        return self
    end

    const function __set(
        self: Transaction,
        Target: Types.ObjectReference,
        Property: ObjectTypes.PropertyReference,
        Value: any
    ): Transaction
        const Obj = Resolve(Target)
        if not Obj or Obj.Destroyed then
            Reject(self, "Cannot set a property on an object that is not here.")
            return self
        end

        const Prop = Obj:GetProperty(Property)
        if not Prop then
            Reject(self, `{Obj.Name} has no property {Property}.`)
            return self
        end

        -- Checked here as well as at the far end, and not because the far end
        -- might not: a value the receiver will refuse costs a round trip and
        -- comes back as a bare false, while this names the property and the
        -- value that could not be held.
        if not PropertyTypes:IsValid(Prop.Type, Value, Prop.Constraints) then
            Reject(self, `{Prop.Name} cannot hold {tostring(Value)}.`)
            return self
        end

        table.insert(self.Operations, {
            Kind = "Set" :: "Set",
            Target = Obj.RuntimeId,
            Property = Prop.Parent,
            Value = Value,
            Type = Prop.Type,
        })

        return self
    end

    const function __destroy(self: Transaction, Target: Types.ObjectReference): Transaction
        const Obj = Resolve(Target)
        if not Obj or Obj.Destroyed then
            Reject(self, "Cannot destroy an object that is not here.")
            return self
        end

        table.insert(self.Operations, {
            Kind = "Destroy" :: "Destroy",
            Target = Obj.RuntimeId,
        })

        return self
    end

    const function __commit(self: Transaction): (boolean, {ObjectTypes.RuntimeId})
        if self.Rejected > 0 then
            Logger:Warn(`Refusing to commit a transaction: {self.Rejected} of its operations could not be built.`)
            return false, {}
        end

        -- Nothing to do is not a failure, and it is not a packet either.
        if #self.Operations == 0 then
            return true, {}
        end

        return Commit(self)
    end

    return function(): Transaction
        const Transaction = {}
        Transaction.Operations = {}
        Transaction.Rejected = 0

        Transaction.Create = __create
        Transaction.Set = __set
        Transaction.Destroy = __destroy
        Transaction.Commit = __commit

        return Transaction :: any
    end
end

return Shared
