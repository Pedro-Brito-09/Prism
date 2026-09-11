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
const ObjectShared = require("../Objects/Shared")
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

    -- A create of the object's type holding the object's values, read now --
    -- when the builder is called, not when the transaction lands -- into the
    -- copy the original sits in unless another is named. Checked on the far
    -- end exactly as a create is, rights included.
    const function __duplicate(
        self: Transaction,
        Target: Types.ObjectReference,
        Live: ObjectTypes.SceneInstanceId?
    ): Transaction
        const Obj = Resolve(Target)
        if not Obj or Obj.Destroyed then
            Reject(self, "Cannot duplicate an object that is not here.")
            return self
        end

        -- A scene this client owns has no copy the server knows, so a create
        -- aimed at it would only be refused there.
        if Obj.Local then
            Reject(self, `{Obj.Name} belongs to a scene this client owns; duplicate it with Objects:Duplicate.`)
            return self
        end

        return __create(self, Obj.Parent, ObjectShared.Snapshot(Obj), Live or Obj.InstanceId)
    end

    -- Several objects duplicated as one thing. Each is a create, exactly as a
    -- single duplicate is, so the same rights are asked for -- and then the
    -- references between them are rewritten to name the creates rather than the
    -- originals, because the ids of the new objects do not exist yet on this
    -- side and will not until the far end has minted them.
    --
    -- A reference that points outside the group keeps its id: duplicating a
    -- lever without the door it works should leave it working that same door.
    const function __duplicate_group(
        self: Transaction,
        Targets: {Types.ObjectReference},
        Live: ObjectTypes.SceneInstanceId?
    ): Transaction
        const Sources: {ObjectTypes.Object} = {}

        for _, Target in Targets do
            const Obj = Resolve(Target)
            if not Obj or Obj.Destroyed then
                Reject(self, "Cannot duplicate an object that is not here.")
                continue
            end

            if Obj.Local then
                Reject(self, `{Obj.Name} belongs to a scene this client owns; duplicate it with Objects:DuplicateGroup.`)
                continue
            end

            table.insert(Sources, Obj)
        end

        -- Which operation makes the duplicate of each original. Read back from
        -- the list rather than counted, because a create the builder refused
        -- adds nothing to it and every index after would be wrong.
        const MadeBy: {[ObjectTypes.Object]: number} = {}

        for _, Obj in Sources do
            const Before = #self.Operations
            __create(self, Obj.Parent, ObjectShared.Snapshot(Obj), Live or Obj.InstanceId)

            if #self.Operations > Before then
                MadeBy[Obj] = #self.Operations
            end
        end

        for Source, Index in MadeBy do
            const Operation = self.Operations[Index] :: Types.CreateOperation

            for PropertyId, Value in Operation.Properties do
                const Prop = Source:GetProperty(PropertyId)
                if not Prop or Prop.Type ~= "Object" then
                    continue
                end

                -- Read against the original's copy, which is where the id it
                -- holds means what it was written to mean.
                const Pointed = Objects:Resolve(Source.InstanceId, Value)
                if not Pointed then
                    continue
                end

                const Instead = MadeBy[Pointed]
                if not Instead then
                    continue
                end

                if not Operation.References then
                    Operation.References = {}
                end

                (Operation.References :: any)[PropertyId] = Instead

                -- And not as a value as well. The id is the original target's,
                -- so sending it would put the wrong object in the property for
                -- as long as it took the fixup to overwrite it, and would cost
                -- the bytes to say something already being said.
                Operation.Properties[PropertyId] = nil
            end
        end

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

        -- A reference is stored as the target's local id, and a caller holding
        -- the target holds the object. Resolved here so Set takes the same
        -- thing Object:Set takes, and so pointing at an object in another copy
        -- is refused where the objects are still both in hand to be named.
        local Held = Value
        if Prop.Type == "Object" then
            const Target, Why = Objects.Reference(Obj.InstanceId, Prop, Value)
            if Target == nil then
                Reject(self, `{Obj.Name}.{Prop.Name} cannot point there: {Why}.`)
                return self
            end

            Held = Target
        end

        -- Checked here as well as at the far end, and not because the far end
        -- might not: a value the receiver will refuse costs a round trip and
        -- comes back as a bare false, while this names the property and the
        -- value that could not be held.
        if not PropertyTypes:IsValid(Prop.Type, Held, Prop.Constraints) then
            Reject(self, `{Prop.Name} cannot hold {tostring(Value)}.`)
            return self
        end

        table.insert(self.Operations, {
            Kind = "Set" :: "Set",
            Target = Obj.RuntimeId,
            Property = Prop.Parent,
            Value = Held,
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
        Transaction.Duplicate = __duplicate
        Transaction.DuplicateGroup = __duplicate_group
        Transaction.Set = __set
        Transaction.Destroy = __destroy
        Transaction.Commit = __commit

        return Transaction :: any
    end
end

return Shared
