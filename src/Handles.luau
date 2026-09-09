--!strict
-- Object identity.
--
-- An object's id carries the scene it belongs to in its high bits:
--
--     Handle = SceneId * 2^32 + LocalId
--
-- The point is that identity survives being saved. The runtime id this replaces
-- was a counter reset every session, so unloading a scene and loading it back
-- handed every object a new name and quietly invalidated everything anyone had
-- kept a reference in -- a selection, an undo entry, one object pointing at
-- another.
--
-- Only the low half is ever written to a pack. The scene stamps its own id back
-- on at load, and that is what keeps a pack portable: the same prefab loaded
-- into two different scenes yields two non colliding sets of handles, and
-- references between objects inside one pack stay valid because they all move
-- by the same amount.
--
-- 48 bits in total, well inside the 53 a Luau number carries exactly, so a
-- handle is a plain number to pass, compare and use as a table key -- not a
-- pair every caller has to thread through.

const SCALE = 4294967296 -- 2^32

const Handles = {}

export type SceneIdentifier = number
export type LocalId = number
export type Handle = number

-- The scene half is bounded by the u16 registry ids everywhere else use, the
-- object half by what fits below the scene bits.
Handles.MAX_SCENE = 65535
Handles.MAX_LOCAL = 4294967295

function Handles.Join(Scene: SceneIdentifier, Local: LocalId): Handle
    return Scene * SCALE + Local
end

function Handles.Split(Handle: Handle): (SceneIdentifier, LocalId)
    const Local = Handle % SCALE
    return (Handle - Local) / SCALE, Local
end

function Handles.Scene(Handle: Handle): SceneIdentifier
    return (Handle - Handle % SCALE) / SCALE
end

function Handles.Local(Handle: Handle): LocalId
    return Handle % SCALE
end

return Handles
