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
const Compressor = require("../Compressor")
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

    -- Which side a transaction belongs to, decided by the first thing it
    -- touches and held to for the rest of it.
    --
    -- A transaction is all of one or all of the other. Half of a mixed one
    -- would need a round trip that can come back refused, and by the time it
    -- did the local half would already have applied -- there is no atomicity to
    -- be had across that line, and a transaction that is not atomic is not a
    -- transaction. So the second kind to arrive is refused, by name, rather
    -- than quietly splitting the edit in two.
    const function Claim(self: Transaction, Local: boolean, What: string): boolean
        if self.Local == nil then
            self.Local = Local
            return true
        end

        if self.Local == Local then
            return true
        end

        Reject(self, `{What} belongs to {if Local then "a scene this client owns" else "the server"}, and this transaction is already about {if Local then "the server" else "a scene this client owns"}.`)
        return false
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

        -- Zero is the implicit default scene, which is the server's.
        if not Claim(self, Live ~= nil and Objects:IsLocalCopy(Live), Registry.Name) then
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

        return __create(self, Obj.Registry, ObjectShared.Snapshot(Obj), Live or Obj.InstanceId)
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

            table.insert(Sources, Obj)
        end

        -- Which operation makes the duplicate of each original. Read back from
        -- the list rather than counted, because a create the builder refused
        -- adds nothing to it and every index after would be wrong.
        const MadeBy: {[ObjectTypes.Object]: number} = {}

        for _, Obj in Sources do
            const Before = #self.Operations
            __create(self, Obj.Registry, ObjectShared.Snapshot(Obj), Live or Obj.InstanceId)

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

    -- A pack placed into a copy the server owns, as a list of creates: one per
    -- object in it, each asking for exactly what a create asks for, so placing a
    -- prefab is checked against create rights rather than needing a right of its
    -- own. One transaction, so it lands whole or not at all and undoes as one
    -- step.
    --
    -- The references are why this is not a loop over Create. A saved reference
    -- holds a local id from the scene the pack was written in, and the ids these
    -- objects will answer to are minted at the far end, after the packet is
    -- written -- so each one names the operation that makes its target instead,
    -- and the far end fills in the id once the creates have run. A reference to
    -- something the pack did not carry is dropped: the id would mean nothing
    -- there, or worse, would mean something.
    const function __place(
        self: Transaction,
        Pack: buffer,
        Live: ObjectTypes.SceneInstanceId?
    ): Transaction
        const Ok, _, Decompressed = pcall(function()
            return Compressor:DecompressScene(Pack)
        end)

        if not Ok or not Decompressed then
            Reject(self, "Cannot place a pack that could not be read.")
            return self
        end

        -- Which operation makes each object, by the id the pack knew it as.
        const Placed: {[number]: number} = {}
        const Pending: {{Index: number, References: {[number]: any}}} = {}

        for _, Saved in Decompressed :: {any} do
            const Values, References = ObjectShared.SplitReferences(Saved.Properties)

            const Before = #self.Operations
            __create(self, Saved.Registry, Values, Live)

            -- Rejected, and the transaction will refuse to commit; there is
            -- nothing to record an operation index against.
            if #self.Operations == Before then
                continue
            end

            Placed[Saved.LocalId] = #self.Operations
            if References then
                table.insert(Pending, {Index = #self.Operations, References = References})
            end
        end

        for _, Entry in Pending do
            const Operation = self.Operations[Entry.Index] :: Types.CreateOperation

            for PropertyId, Saved in Entry.References do
                const Names = Placed[Saved]
                if not Names then
                    continue
                end

                if not Operation.References then
                    Operation.References = {}
                end

                (Operation.References :: any)[PropertyId] = Names
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

        if not Claim(self, Obj.Local == true, Obj.Name) then
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

        if not Claim(self, Obj.Local == true, Obj.Name) then
            return self
        end

        table.insert(self.Operations, {
            Kind = "Destroy" :: "Destroy",
            Target = Obj.RuntimeId,
        })

        return self
    end

    -- Taking and releasing a hold, in the list with the edit that needs it.
    -- One object or several, and several is the point: a lock is all or none,
    -- so naming three of them in one transaction is the only way to be sure of
    -- getting all three before anything moves.
    --
    -- Refused for objects in scenes this client owns. Nothing there is anybody
    -- else's to touch, so there is no hold to take -- and a transaction that
    -- carried one would be asking the server about an object it has never
    -- heard of.
    const function Holding(
        self: Transaction,
        Targets: Types.ObjectReference | {Types.ObjectReference},
        Kind: "Lock" | "Unlock"
    ): Transaction
        const List = if type(Targets) == "table" and (Targets :: any).RuntimeId == nil
            then Targets :: {Types.ObjectReference}
            else {Targets :: Types.ObjectReference}

        for _, Target in List do
            const Obj = Resolve(Target)
            if not Obj or Obj.Destroyed then
                Reject(self, `Cannot {string.lower(Kind)} an object that is not here.`)
                continue
            end

            if Obj.Local then
                Reject(self, `{Obj.Name} belongs to a scene this client owns, which nobody else can touch and nothing can hold.`)
                continue
            end

            if not Claim(self, false, Obj.Name) then
                return self
            end

            table.insert(self.Operations, {
                Kind = Kind :: any,
                Target = Obj.RuntimeId,
            })
        end

        return self
    end

    const function __lock(self: Transaction, Targets: any): Transaction
        return Holding(self, Targets, "Lock")
    end

    const function __unlock(self: Transaction, Targets: any): Transaction
        return Holding(self, Targets, "Unlock")
    end

    -- A copy of a scene into the world. The scene is named, not the copy: the
    -- copy does not exist yet, and which one it turns out to be is the far
    -- end's to decide -- it arrives through the packet announcing it, the way
    -- a created object does.
    const function __load(self: Transaction, Scene: ObjectTypes.SceneIdentifier): Transaction
        if type(Scene) ~= "number" then
            Reject(self, `Cannot load {tostring(Scene)}: a scene is named by its id.`)
            return self
        end

        if not Claim(self, Objects:IsLocalScene(Scene), `scene {Scene}`) then
            return self
        end

        table.insert(self.Operations, {
            Kind = "Load" :: "Load",
            Scene = Scene,
        })

        return self
    end

    -- A live copy out of the world. Withdrawn rather than unloaded, so an undo
    -- brings back what was in it rather than what its scene last saved.
    const function __unload(self: Transaction, Instance_: ObjectTypes.SceneInstanceId): Transaction
        if type(Instance_) ~= "number" then
            Reject(self, `Cannot unload {tostring(Instance_)}: a copy is named by its id.`)
            return self
        end

        if not Claim(self, Objects:IsLocalCopy(Instance_), `copy {Instance_}`) then
            return self
        end

        table.insert(self.Operations, {
            Kind = "Unload" :: "Unload",
            Instance = Instance_,
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
        Transaction.Local = nil

        Transaction.Create = __create
        Transaction.Duplicate = __duplicate
        Transaction.DuplicateGroup = __duplicate_group
        Transaction.Place = __place
        Transaction.Lock = __lock
        Transaction.Unlock = __unlock
        Transaction.Load = __load
        Transaction.Unload = __unload
        Transaction.Set = __set
        Transaction.Destroy = __destroy
        Transaction.Commit = __commit

        return Transaction :: any
    end
end

return Shared
