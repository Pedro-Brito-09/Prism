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
    Lock = 4,
    Unlock = 5,
    Load = 6,
    Unload = 7,
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

    -- Object properties whose target is made by this same transaction, as the
    -- index of the create operation that makes it. They cannot be ordinary
    -- values: a reference stores the target's local id, and the id an object
    -- created here will answer to is minted by the copy at the far end -- after
    -- the packet was written. So the author names the operation instead and the
    -- receiver fills the id in once every create has run.
    --
    -- This is what lets a group of objects be duplicated together with the
    -- references between them following the copies, and it is also the only way
    -- to create two objects and wire them to each other in one transaction.
    References: {[PropertyTypes.PropertyIdentifier]: number}?,
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

-- Taking and releasing a hold on one object. In the list rather than on a
-- channel of their own so that claiming what an edit needs and making the edit
-- are one thing: locking three objects and moving them used to be two round
-- trips, with the lock able to come back refused after the edit was built.
--
-- Locks are taken before anything else in the transaction and released after,
-- which is the order the words are in: hold these, do this, let go.
export type LockOperation = {
    Kind: "Lock",
    Target: ObjectTypes.RuntimeId,
}

export type UnlockOperation = {
    Kind: "Unlock",
    Target: ObjectTypes.RuntimeId,
}

-- A copy of a scene appearing and going. Load names the scene to read, Unload
-- the live copy to withdraw -- and withdraw is the word: a copy a player asked
-- to go is set aside whole rather than unloaded, because loading it again would
-- read what the scene last committed rather than what was on screen.
--
-- The copy that a load makes is not in what Commit hands back. It arrives the
-- way created objects do, through the packet that announces it, which is what
-- Scenes:OnCopyAdded is for.
export type LoadOperation = {
    Kind: "Load",
    Scene: ObjectTypes.SceneIdentifier,
}

export type UnloadOperation = {
    Kind: "Unload",
    Instance: ObjectTypes.SceneInstanceId,
}

export type Operation =
    CreateOperation
    | SetOperation
    | DestroyOperation
    | LockOperation
    | UnlockOperation
    | LoadOperation
    | UnloadOperation

export type ObjectReference = ObjectTypes.Object | ObjectTypes.RuntimeId
export type TypeReference = ObjectTypes.ObjectRegistry | ObjectTypes.ObjectIdentifier

export type Transaction = {
    Operations: {Operation},

    -- Operations that could not be built at all -- an unknown property, a
    -- target that is not an object. Commit refuses while this is above zero
    -- rather than sending what is left: applying four of the five things the
    -- caller asked for is the one behaviour a transaction must not have.
    Rejected: number,

    -- Which side this transaction is about, decided by the first object or copy
    -- it touches: true for scenes the client owns, false for the server's, nil
    -- while it is still empty. Committing reads it to know whether that means
    -- sending a packet or doing the work here.
    --
    -- One or the other, never both. A mixed transaction would have to send half
    -- of itself and wait, with the other half already applied if the answer came
    -- back no, and a transaction that cannot be atomic is not one.
    Local: boolean?,

    -- Set by whoever commits it to keep it out of the author's undo history.
    -- It rides to the server, because for a scene the server owns that is where
    -- the history lives. Not a permission: an untracked edit is checked and
    -- charged exactly like any other.
    Untracked: boolean?,

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

    -- A Create of the target's type holding the target's values as they are
    -- when this is called, in the target's own copy unless another is named.
    Duplicate: (
        self: Transaction,
        Target: ObjectReference,
        Instance: ObjectTypes.SceneInstanceId?
    ) -> Transaction,

    -- The same, for several objects duplicated as one thing: references that
    -- point at another member of the group follow the copies, and references
    -- that point outside it are kept as they are. Duplicating the same objects
    -- one call at a time does not do this -- nothing there knows the calls
    -- belong together.
    DuplicateGroup: (
        self: Transaction,
        Targets: {ObjectReference},
        Instance: ObjectTypes.SceneInstanceId?
    ) -> Transaction,

    -- A saved pack placed into a live copy: one create per object in it, with
    -- the references inside the pack rewritten to name those creates. Checked
    -- as creates are, so placing a prefab needs create rights and nothing more,
    -- and undone as one step because it is one transaction.
    Place: (
        self: Transaction,
        Pack: buffer,
        Instance: ObjectTypes.SceneInstanceId?
    ) -> Transaction,

    -- Whether the whole list applied, and the runtime ids of what it created, in
    -- the order the creates were declared. On the client this yields until the
    -- server has answered: a created object has no local identity to hand back
    -- before the server has minted one.
    -- One object or a list, all or none, like Objects:Lock. Refused for objects
    -- in scenes the client owns, which are never locked -- nobody else can
    -- touch them.
    Lock: (self: Transaction, Targets: ObjectReference | {ObjectReference}) -> Transaction,
    Unlock: (self: Transaction, Targets: ObjectReference | {ObjectReference}) -> Transaction,

    -- A copy of a scene into the world, and a live copy out of it. Loading
    -- needs create rights on that scene and unloading needs destroy rights,
    -- because that is what they amount to: every object in it made, or every
    -- object in it taken away.
    Load: (self: Transaction, Scene: ObjectTypes.SceneIdentifier) -> Transaction,
    Unload: (self: Transaction, Instance: ObjectTypes.SceneInstanceId) -> Transaction,

    Commit: (self: Transaction) -> (boolean, {ObjectTypes.RuntimeId}),
}

-- A committed transaction as the client saw it go: what it created, the value
-- each set overwrote and what each destroy took away, by operation index. Read
-- before the packet went, because after the answer the old values are gone.
export type CommitRecord = {
    Transaction: Transaction,
    Created: {ObjectTypes.RuntimeId},
    Before: {[number]: any},
    Removed: {[number]: {
        Registry: ObjectTypes.ObjectIdentifier,
        Values: {[PropertyTypes.PropertyIdentifier]: any},
        Instance: ObjectTypes.SceneInstanceId,
    }},
}

return {
    Kinds = Kinds,
}
