--!strict
-- A transaction is a list of operations applied as a unit: one packet, one
-- permission pass, one entry in whatever history an editor keeps.
--
-- The unit matters more than the batching. A multi object edit sent as separate
-- packets is a sequence a client can be interrupted halfway through -- by a
-- refusal, by a disconnect, by another player's edit landing between two of its
-- own -- and there is no point at which the world holds either all of it or
-- none of it. Undo has the same problem from the other side: a history made of
-- individual sets cannot record "this was one action" without guessing.
--
-- Operations name their targets by runtime id, never by persistent id. A
-- persistent id names an object in every live copy of its scene at once, and a
-- transaction that names its target ambiguously is a transaction that edits the
-- wrong room.

const PropertyTypes = require("../Properties/Types")
const ObjectTypes = require("../Objects/Types")

-- What the wire calls each kind. The decoded form carries the name instead, so
-- reading an operation does not mean remembering that 2 means Set.
const Kinds = {
    Create = 1,
    Set = 2,
    Destroy = 3,
}

export type CreateOperation = {
    Kind: "Create",
    Object: ObjectTypes.ObjectIdentifier,

    -- Which live copy of a scene the object lands in. Zero means the one
    -- Objects.new would have picked on its own, which is the implicit default
    -- scene -- a copy has to be named explicitly because a scene loaded twice
    -- has two equally good ones.
    Instance: ObjectTypes.SceneInstanceId,

    -- Keyed by property id, like Objects.new takes them. A value for a property
    -- the object type does not carry is dropped rather than refused, matching
    -- what restoring a saved object does with one.
    Properties: {[PropertyTypes.PropertyIdentifier]: any},
}

export type SetOperation = {
    Kind: "Set",
    Target: ObjectTypes.RuntimeId,
    Property: PropertyTypes.PropertyIdentifier,
    Value: any,

    -- The semantic type the author wrote the value as, read back off the value's
    -- own tag rather than trusted from the registry. The receiver compares it
    -- against the property it is being set on, which is what stops a client
    -- sending a CFrame to a Number and having it applied.
    --
    -- Nil where this build has no name for the type the author used, which is
    -- itself a mismatch and refused as one.
    Type: PropertyTypes.PropertyType?,
}

export type DestroyOperation = {
    Kind: "Destroy",
    Target: ObjectTypes.RuntimeId,
}

export type Operation = CreateOperation | SetOperation | DestroyOperation

export type ObjectReference = ObjectTypes.Object | ObjectTypes.RuntimeId
export type TypeReference = ObjectTypes.ObjectRegistry | ObjectTypes.ObjectIdentifier

export type Transaction = {
    Operations: {Operation},

    -- Operations that could not be built at all -- an unknown property, a
    -- target that is not an object. Commit refuses while this is above zero
    -- rather than sending what is left: applying four of the five things the
    -- caller asked for is the one behaviour a transaction must not have.
    Rejected: number,

    -- Every builder call returns the transaction, so a whole edit reads as one
    -- expression.
    Create: (
        self: Transaction,
        Reference: TypeReference,
        Values: {[PropertyTypes.PropertyIdentifier]: any}?,
        Instance: ObjectTypes.SceneInstanceId?
    ) -> Transaction,

    Set: (
        self: Transaction,
        Target: ObjectReference,
        Property: ObjectTypes.PropertyReference,
        Value: any
    ) -> Transaction,

    Destroy: (self: Transaction, Target: ObjectReference) -> Transaction,

    -- Whether the whole list applied, and the runtime ids of what it created, in
    -- the order the creates were declared. On the client this yields until the
    -- server has answered: a created object has no local identity to hand back
    -- before the server has minted one.
    Commit: (self: Transaction) -> (boolean, {ObjectTypes.RuntimeId}),
}

return {
    Kinds = Kinds,
}
