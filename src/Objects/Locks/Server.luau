--!strict
-- Locks on the server: who holds which object, and the requests that take and
-- release them. Objects/Server exposes these as its own methods.

const Players = game:GetService("Players")

const Permissions = require("../../Permissions/Server")
const Audience = require("../../Scenes/Audience")
const Network = require("../Network")
const Types = require("../Types")

type RuntimeId = Types.RuntimeId
type Object = Types.Object

const Locking = {}

-- Who holds each locked object. The holder is whatever was handed in -- a
-- Player, a table standing in for one, a module, a string naming a tool -- and
-- UserId is filled in only where that resolves to a person, which is the part a
-- client can be told about.
--
-- A hold does not require a player, so the server can hold an object without
-- inventing a fake one. Nothing about a hold needs a person: it says this is
-- being worked on, leave it alone.
const Locks: {[RuntimeId]: {UserId: number?, Holder: any}} = {}

-- The live object under a runtime id, handed over by Objects/Server, whose
-- workspace table is swapped for a fresh one as it empties out.
local Lookup: (Identifier: RuntimeId) -> Object?

function Locking.Bind(Find: (Identifier: RuntimeId) -> Object?)
    Lookup = Find
end

-- Gone with its object.
function Locking.Forget(Identifier: RuntimeId)
    Locks[Identifier] = nil
end

-- A lock is explicit: a client takes one when it starts on an object, and while
-- it holds it nobody else may edit or destroy that object. Presence comes with
-- it -- who holds what is told to the players the object's scene admits, and
-- nobody else, because who is editing a private level is part of the level.

-- The most one request may name, for the same reason a transaction has a cap.
const MAX_LOCKS = 1024

-- The person a holder stands for, or nil where it stands for nobody. A bare
-- number is a user id, the way it is everywhere else a person is named -- Admit,
-- Evict and Grant all take a Player or a user id -- so releasing what somebody
-- holds works from either.
const function UserIdOf(Who: any): number?
    if typeof(Who) == "Instance" and (Who :: Instance):IsA("Player") then
        return (Who :: Player).UserId
    end

    if type(Who) == "number" then
        return Who
    end

    if type(Who) == "table" and type(Who.UserId) == "number" then
        return Who.UserId
    end

    return nil
end

-- Who holds what, to the players each object's scene admits. Zero means free.
const function AnnounceLocks(Changed: {Object})
    const ByScene: {[Types.SceneIdentifier]: {Ids: {RuntimeId}, Holders: {number}, Held: {boolean}}} = {}

    for _, Obj in Changed do
        local Batch = ByScene[Obj.Scene]
        if not Batch then
            Batch = {Ids = {}, Holders = {}, Held = {}}
            ByScene[Obj.Scene] = Batch
        end

        const Held = Locks[Obj.RuntimeId]
        table.insert(Batch.Ids, Obj.RuntimeId)

        -- Zero where the holder is not a person. Held is what says whether
        -- there is a hold, so zero is a user id nobody has rather than a way of
        -- saying free.
        table.insert(Batch.Holders, if Held then Held.UserId or 0 else 0)
        table.insert(Batch.Held, Held ~= nil)
    end

    for Scene, Batch in ByScene do
        Audience.Fire(Network.LocksChanged, Scene, "Admitted", Batch.Ids, Batch.Holders, Batch.Held)
    end
end

-- Takes every object named for Who, or none of them: an object someone else
-- holds refuses the lot, so a multi-object drag never ends up half held.
-- Taking one Who already holds is not a refusal.
-- Whether two holders are the same one. By user id where both resolve to a
-- person, so a Player and a table standing in for the same player are one
-- holder; by identity otherwise, which is what lets anything at all hold an
-- object.
const function SameHolder(Held: {UserId: number?, Holder: any}, Who: any): boolean
    const UserId = UserIdOf(Who)
    if UserId and Held.UserId then
        return Held.UserId == UserId
    end

    return Held.Holder == Who
end

-- One object or a list, as on the client and in a transaction.
const function Named(Refs: Object | {Object}): {Object}
    return if (Refs :: any).RuntimeId ~= nil then {Refs :: Object} else Refs :: {Object}
end

function Locking.Lock(Refs: Object | {Object}, Who: any): boolean
    if Who == nil then
        return false
    end

    const List = Named(Refs)
    for _, Obj in List do
        const Held = Locks[Obj.RuntimeId]
        if Obj.Destroyed or (Held and not SameHolder(Held, Who)) then
            return false
        end
    end

    const UserId = UserIdOf(Who)
    for _, Obj in List do
        Locks[Obj.RuntimeId] = {UserId = UserId, Holder = Who}
    end

    AnnounceLocks(List)
    return true
end

-- Releases what Who holds among the objects named. With no Who it is the
-- server releasing anyone's. Answers false if any named object is held by
-- someone else, which stays theirs; the rest are released regardless.
function Locking.Unlock(Refs: Object | {Object}, Who: any?): boolean
    const Released = {}
    local All = true

    for _, Obj in Named(Refs) do
        const Held = Locks[Obj.RuntimeId]
        if not Held then
            continue
        end

        if Who ~= nil and not SameHolder(Held, Who) then
            All = false
            continue
        end

        Locks[Obj.RuntimeId] = nil
        table.insert(Released, Obj)
    end

    if #Released > 0 then
        AnnounceLocks(Released)
    end

    return All
end

-- The user id holding an object, nil when it is free or held by something that
-- is not a person. GetHolder is the whole answer; this is the part a client can
-- be told and the part a game usually wants.
function Locking.GetLock(Obj: Object): number?
    const Held = Locks[Obj.RuntimeId]
    return if Held then Held.UserId else nil
end

function Locking.GetHolder(Obj: Object): any?
    const Held = Locks[Obj.RuntimeId]
    return if Held then Held.Holder else nil
end

function Locking.IsLocked(Obj: Object): boolean
    return Locks[Obj.RuntimeId] ~= nil
end

-- Everything one holder has, let go at once. What a player being evicted from a
-- scene comes down to, and what losing the right to edit one comes down to:
-- both leave somebody holding objects they may no longer touch, and nobody else
-- able to touch them either.
--
-- Scoped to a scene when one is named, because being shut out of one room is
-- not being shut out of the others.
function Locking.ReleaseFor(Who: any, Scene: Types.SceneIdentifier?)
    const Released = {}

    for Identifier, Held in Locks do
        if not SameHolder(Held, Who) then
            continue
        end

        const Obj = Lookup(Identifier)
        if Obj and (Scene == nil or Obj.Scene == Scene) then
            table.insert(Released, Obj)
        end
    end

    if #Released > 0 then
        Locking.Unlock(Released)
    end
end

-- Whether someone other than Plr holds the object, which is what every edit
-- path asks before it lets one through.
function Locking.LockedAgainst(Obj: Object, Who: any): boolean
    const Held = Locks[Obj.RuntimeId]
    return Held ~= nil and not SameHolder(Held, Who)
end

-- The locks among some objects, for a player a scene is being revealed to:
-- they are owed who holds what as well as the objects themselves.
function Locking.SendLocks(Plr: Player, List: {Object})
    const Ids = {}
    const Holders = {}
    const Flags = {}

    for _, Obj in List do
        const Held = Locks[Obj.RuntimeId]
        if Held and not Obj.Destroyed then
            table.insert(Ids, Obj.RuntimeId)

            -- Zero where the holder is not a person, exactly as AnnounceLocks
            -- sends it. UserId is nil for a holder that is a module or a
            -- string, and table.insert of a nil leaves a hole that shifts
            -- every later holder against its id.
            table.insert(Holders, Held.UserId or 0)
            table.insert(Flags, true)
        end
    end

    if #Ids > 0 then
        Network.LocksChanged:Fire(Plr, Ids, Holders, Flags)
    end
end

-- Resolves what a client named, refusing the whole request over one it may not
-- have: an object that is gone, in a scene it was never admitted to, or one it
-- may not edit. A lock on something you cannot change would only be a way to
-- stop others changing it.
const function Claimable(Plr: Player, Ids: {RuntimeId}): {Object}?
    if #Ids > MAX_LOCKS or not Permissions:Consume(Plr, #Ids) then
        return nil
    end

    const List = {}
    for _, Identifier in Ids do
        const Obj = Lookup(Identifier)
        if not Obj or Obj.Destroyed or not Audience.Sees(Plr, Obj.Scene) or not Permissions:Can(Plr, "Edit", Obj) then
            return nil
        end

        table.insert(List, Obj)
    end

    return List
end

Network.Lock.OnInvoke = function(Plr: Player, Ids: {RuntimeId}): boolean
    const List = Claimable(Plr, Ids)
    return List ~= nil and Locking.Lock(List, Plr)
end

-- Releasing needs no rights: a player who lost them since should still be able
-- to let go. Objects that are gone are simply skipped.
Network.Unlock.OnInvoke = function(Plr: Player, Ids: {RuntimeId}): boolean
    if #Ids > MAX_LOCKS or not Permissions:Consume(Plr) then
        return false
    end

    const List: {Object} = {}
    for _, Identifier in Ids do
        const Obj = Lookup(Identifier)
        if Obj and not Obj.Destroyed then
            table.insert(List, Obj)
        end
    end

    return Locking.Unlock(List, Plr)
end

-- A hold goes with whoever had it. Leaving is the obvious way to lose one;
-- Permissions below is the other, and Scenes calls ReleaseFor when it evicts
-- somebody.
Players.PlayerRemoving:Connect(function(Plr: Player)
    Locking.ReleaseFor(Plr)
end)

-- Rights over a scene changed for somebody. A hold is worth having only where
-- an edit would be allowed, so one held by a player who may no longer edit
-- there is a hold nobody benefits from and nobody else can take: they keep the
-- object to themselves without being able to do anything with it.
Permissions.OnSceneRights(function(UserId: number, Scene: Types.SceneIdentifier)
    -- By user id throughout. Asking Players for the person would answer nil for
    -- anybody not connected, and rights are granted to people who have not
    -- arrived yet -- Scenes.new takes a whole collaborator list.
    const Rights = Permissions:GetOn(Scene, UserId)
    if Rights and Rights.CanEdit then
        return
    end

    Locking.ReleaseFor(UserId, Scene)
end)

return Locking
