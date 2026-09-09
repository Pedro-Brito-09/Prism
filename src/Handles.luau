--!strict
-- The persistent half of an object's identity.
--
--     PersistentId = SceneId * 2^32 + LocalId
--
-- This is what a pack means by an object, and the only identity that outlives
-- the session. It is deliberately not unique among live objects: the same scene
-- can be instanced more than once, and every copy answers to the ids its pack
-- was written with. Telling two live copies apart is the runtime id's job.
--
-- Only the low half is ever written. The scene stamps its own id back on at
-- load, which is what keeps a pack portable: the same prefab loaded under two
-- scenes yields two distinct persistent identities, and references between
-- objects inside one pack stay valid because they all move by the same amount.
--
-- 48 bits in total, well inside the 53 a Luau number carries exactly, so a
-- saved reference is a plain number rather than a pair every caller has to
-- thread through.

const SCALE = 4294967296 -- 2^32

const Handles = {}

export type SceneIdentifier = number
export type LocalId = number
export type PersistentId = number

-- The scene half is bounded by the u16 registry ids everywhere else uses, the
-- object half by what fits below the scene bits.
Handles.MAX_SCENE = 65535
Handles.MAX_LOCAL = 4294967295

function Handles.Join(Scene: SceneIdentifier, Local: LocalId): PersistentId
    return Scene * SCALE + Local
end

function Handles.Split(Persistent: PersistentId): (SceneIdentifier, LocalId)
    const Local = Persistent % SCALE
    return (Persistent - Local) / SCALE, Local
end

function Handles.Scene(Persistent: PersistentId): SceneIdentifier
    return (Persistent - Persistent % SCALE) / SCALE
end

function Handles.Local(Persistent: PersistentId): LocalId
    return Persistent % SCALE
end

return Handles
