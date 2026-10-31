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

-- The identity a scene is saved under, which none of the above is: a scene id
-- is claimed per server in registration order. 128 random bits as base64url
-- without padding. Scenes/Server makes them; this is what one looks like, for
-- every place that takes one back.
Handles.GUID_LENGTH = 22

-- Only Prism makes Guids, so anything else handed in as one is a mistake --
-- reading a key that does not hold a Prism scene would hand a scene an
-- identity Prism never gave it, and a record linking one would point at
-- nothing Prism could ever have saved.
function Handles.IsGuid(Text: any): boolean
    return type(Text) == "string" and #Text == Handles.GUID_LENGTH and string.match(Text, "^[%w%-_]+$") ~= nil
end

-- What a reference to an object in another scene stores. A local id alone means
-- nothing there, and a scene id means nothing on the next server, so it takes
-- the Guid: the one name for a scene that outlives the session. Text, so it
-- saves, compares and rides a packet as it is.
--
-- Every scene inserted into another shares its source's Guid, so an object in
-- one goes by the scene it was inserted into, and the insert ids down to it:
-- "<Guid>/<Insert>:<LocalId>", a slash each for scenes inserted inside scenes.
function Handles.Address(Guid: string, Local: LocalId, Path: {number}?): string
    if Path then
        return `{Guid}/{table.concat(Path, "/")}:{Local}`
    end

    return `{Guid}:{Local}`
end

-- The parts of an address, or nil for anything that is not exactly what Address
-- would have written: a second spelling of one target would read as a change of
-- target. Local id zero is refused for the same reason, since "points at
-- nothing" already has a spelling. Path is nil for an address with no inserts.
function Handles.ParseAddress(Text: any): (string?, LocalId?, {number}?)
    if type(Text) ~= "string" then
        return nil, nil, nil
    end

    const Guid, Inserts, Digits = string.match(Text, "^([^/:]*)([/%d]*):(%d+)$")
    if not Handles.IsGuid(Guid) then
        return nil, nil, nil
    end

    const Local = tonumber(Digits)
    if not Local or Local < 1 or Local > Handles.MAX_LOCAL then
        return nil, nil, nil
    end

    local Path: {number}? = nil
    if Inserts ~= "" then
        const Found = {}
        for Id in string.gmatch(Inserts :: string, "/(%d+)") do
            table.insert(Found, tonumber(Id) :: number)
        end

        -- A slash with no id after it finds nothing, and Address would write an
        -- empty path straight back as that slash.
        Path = if #Found > 0 then Found else nil
    end

    if Handles.Address(Guid :: string, Local, Path) ~= Text then
        return nil, nil, nil
    end

    return Guid, Local, Path
end

return Handles
