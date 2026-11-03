--!strict
-- Locks as this client knows them: who holds which object, as the server last
-- said, and the requests that take and release them. Objects/Client exposes
-- these as its own methods.

const Players = game:GetService("Players")

const Network = require("../Network")
const Listeners = require("../../Listeners")
const Permissions = require("../../Permissions/Client")
const Types = require("../Types")

type RuntimeId = Types.RuntimeId
type Object = Types.Object

const Locking = {}

-- The live object under a runtime id, handed over by Objects/Client, whose
-- workspace table is swapped for a fresh one as it empties out.
local Lookup: (Identifier: RuntimeId) -> Object?

function Locking.Bind(Find: (Identifier: RuntimeId) -> Object?)
    Lookup = Find
end

-- Which objects are held, and by whom where that is a person, as the server
-- last said and only for scenes this player is admitted to. A holder need not
-- be one -- the server can hold an object while it animates it -- so being held
-- and being held by somebody are two different questions and get two tables'
-- worth of answer: an entry here means held, and its value is the user id or
-- nil.
const Locks: {[RuntimeId]: true} = {}
const Holders: {[RuntimeId]: number} = {}
const LockChanged: {(RuntimeId: RuntimeId, UserId: number?, Held: boolean) -> ()} = {}

-- One object's hold as this client now knows it, from whichever of two places
-- says so first: the answer to its own Lock or Unlock, or the broadcast. Both
-- arrive for this client's own holds, so listeners hear a change once rather
-- than the same hold twice.
const function Record(Identifier: RuntimeId, IsHeld: boolean, UserId: number?)
    const Holder = if IsHeld then UserId else nil
    if (Locks[Identifier] == true) == IsHeld and Holders[Identifier] == Holder then
        return
    end

    Locks[Identifier] = if IsHeld then true else nil
    Holders[Identifier] = Holder

    Listeners.Notify(LockChanged, Identifier, Holder, IsHeld)
end

-- Whether someone other than this player holds an object, as far as this client
-- has been told. The server refuses an edit to it whatever this says; asking
-- here first is what keeps an edit that is bound to be refused from showing on
-- screen and then snapping back.
const function HeldByOther(RuntimeId: RuntimeId): boolean
    return Locks[RuntimeId] == true and Holders[RuntimeId] ~= Players.LocalPlayer.UserId
end

Permissions.WatchHolds(HeldByOther)

const function Named(Refs: Object | {Object}): {Object}
    return if (Refs :: any).RuntimeId ~= nil then {Refs :: Object} else Refs :: {Object}
end

-- The ids worth asking the server about. An object in a scene this client owns
-- is nobody else's to touch, so there is nothing to lock.
const function Remote(List: {Object}): {RuntimeId}
    const Ids = {}
    for _, Obj in List do
        if not Obj.Local and not Obj.Destroyed then
            table.insert(Ids, Obj.RuntimeId)
        end
    end

    return Ids
end

-- Takes an object, or several at once, all or none. Yields for the server's
-- answer: while this player holds them, nobody else may edit or destroy them.
function Locking.Lock(Refs: Object | {Object}): boolean
    const Ids = Remote(Named(Refs))
    if #Ids == 0 then
        return true
    end

    const Ok, Granted = pcall(function()
        return Network.Lock:Invoke(Ids)
    end)

    if not Ok or Granted ~= true then
        return false
    end

    -- Recorded from the answer rather than left to the broadcast. The answer
    -- comes back on the remote function and the broadcast on the remote event,
    -- and Roblox orders nothing across the two, so IsLocked would say free for
    -- a moment after Lock had said yes.
    const Me = Players.LocalPlayer.UserId
    for _, Identifier in Ids do
        Record(Identifier, true, Me)
    end

    return true
end

-- Lets go of what this player holds among the objects named. False if any of
-- them is held by someone else.
function Locking.Unlock(Refs: Object | {Object}): boolean
    const Ids = Remote(Named(Refs))
    if #Ids == 0 then
        return true
    end

    const Ok, Released = pcall(function()
        return Network.Unlock:Invoke(Ids)
    end)

    if not Ok or Released ~= true then
        return false
    end

    -- True means nobody else holds any of them, so every one named is free
    -- now: this player let go of it or nobody held it. A false answer released
    -- some and not others, and which is left to the broadcast.
    for _, Identifier in Ids do
        Record(Identifier, false, nil)
    end

    return true
end

-- The same, for a transaction the server applied: it takes and releases holds
-- in its own packet and has the same answer to record ahead of the broadcast.
function Locking.RecordHolds(Ids: {RuntimeId}, IsHeld: boolean)
    const Me = if IsHeld then Players.LocalPlayer.UserId else nil
    for _, Identifier in Ids do
        Record(Identifier, IsHeld, Me)
    end
end

-- The user id holding an object, or nil when it is free, when the holder is not
-- a person, or when this player is not admitted to its scene and so is not told.
-- IsLocked answers the other half: whether anything holds it at all.
function Locking.GetLock(Ref: Object | RuntimeId): number?
    return Holders[if type(Ref) == "number" then Ref else Ref.RuntimeId]
end

function Locking.IsLocked(Ref: Object | RuntimeId): boolean
    return Locks[if type(Ref) == "number" then Ref else Ref.RuntimeId] == true
end

-- Fired with a runtime id, the user id now holding it -- nil for nobody or for
-- a holder that is not a person -- and whether it is held at all.
function Locking.OnLockChanged(Callback: (RuntimeId: RuntimeId, UserId: number?, Held: boolean) -> ()): () -> ()
    return Listeners.Watch(LockChanged, Callback, "locks")
end

-- A scene this player is no longer admitted to stops telling them its locks,
-- so what they knew of them is dropped rather than left to go stale.
function Locking.ForgetLocks(Scene: Types.SceneIdentifier)
    for Identifier in table.clone(Locks) do
        const Obj = Lookup(Identifier)
        if not Obj or Obj.Scene == Scene then
            Locks[Identifier] = nil
            Holders[Identifier] = nil
            Listeners.Notify(LockChanged, Identifier, nil, false)
        end
    end
end

-- Gone with its object.
function Locking.Forget(Identifier: RuntimeId)
    Locks[Identifier] = nil
    Holders[Identifier] = nil
end

Locking.HeldByOther = HeldByOther

Network.LocksChanged:Connect(function(Ids: {RuntimeId}, Who: {number}, Held: {boolean})
    for Index, Identifier in Ids do
        const IsHeld = Held[Index] == true
        const UserId = Who[Index]

        -- Zero is nobody rather than free: Held is what says free.
        Record(Identifier, IsHeld, if UserId ~= 0 then UserId else nil)
    end
end)

return Locking
