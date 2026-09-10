--!strict
-- Who hears about a scene.
--
-- Every packet about a scene used to go out with FireAll, so every player heard
-- about every scene. That is fine for a game with one level and wrong for a
-- place several people build in at once. A scene now admits players by user id,
-- and one that has admitted nobody is public -- which is what every scene that
-- existed before this already was.
--
-- A player holds a scene at one of two reaches, named for the Replicate field
-- on an object type. Everyone is what every player is owed of every scene the
-- server built: its copies, which say only that a copy of some scene exists,
-- and the objects whose types replicate to everyone. Admitted is the rest --
-- the scene's name and the objects kept for the players it admits -- and only
-- an admitted player holds it. Admitted is only ever held on top of Everyone.
--
-- Two questions, kept apart. Sees is admission: whether a player may hold a
-- scene at the Admitted reach. Holds is what a player has actually been sent,
-- and it is what every packet about the scene is addressed by. The two differ
-- while a player is joining and for the moment between an admission changing
-- and the scene being revealed or withdrawn to match. Addressing by what was
-- sent rather than what is allowed is what means a client is never sent an
-- object for a copy it has not been introduced to.

const Players = game:GetService("Players")

const Networking = require("../Networking")
const ObjectTypes = require("../Objects/Types")
const Registry = require("./Registry")

type Entry = Networking.Entry
type Reach = ObjectTypes.Reach

-- Who holds a scene at one reach, and the token each holds it under. Taken once
-- by anything that sends a scene's objects over several frames.
export type Hearing = {[Player]: number}

const Audience = {}

-- Per player, per scene, per reach, the token of the reveal that sent it.
-- Anything still streaming a scene to someone checks the token between chunks,
-- so a scene withdrawn part way -- or withdrawn and revealed again -- stops the
-- stale stream rather than sending objects the client has just dropped.
const Told: {[Player]: {[number]: {[string]: number}}} = {}
local Counter = 0

-- Players whose join replay has finished. An admission changing before then is
-- left for the end of their replay to settle: a scene revealed mid-replay could
-- reach them ahead of the object types its objects need.
const Synced: {[Player]: true} = {}

-- A Player or a user id, as a user id. Admission is keyed by user id so that it
-- can name someone who is not here yet, and so that it outlives someone who
-- has left.
function Audience.Resolve(Who: any): number?
    if typeof(Who) == "Instance" and Who:IsA("Player") then
        return (Who :: Player).UserId
    end

    if type(Who) == "number" and Who % 1 == 0 then
        return Who
    end

    return nil
end

function Audience.Sees(Plr: Player, Scene: number): boolean
    const Owner = Registry.ById[Scene]
    if not Owner then
        return false
    end

    return next(Owner.Admitted) == nil or Owner.Admitted[Plr.UserId] == true
end

-- Whether a player holds a scene at a reach, and, given a token, whether they
-- still hold it under that one.
function Audience.Holds(Plr: Player, Scene: number, Reach: Reach, Token: number?): boolean
    const Held = Told[Plr]
    const Reaches = if Held then Held[Scene] else nil
    const Current = if Reaches then Reaches[Reach] else nil

    if Current == nil then
        return false
    end

    return Token == nil or Current == Token
end

function Audience.Remember(Plr: Player, Scene: number, Reach: Reach): number
    local Held = Told[Plr]
    if not Held then
        Held = {}
        Told[Plr] = Held
    end

    local Reaches = Held[Scene]
    if not Reaches then
        Reaches = {}
        Held[Scene] = Reaches
    end

    Counter += 1
    Reaches[Reach] = Counter
    return Counter
end

-- Forgetting the Everyone reach forgets the scene outright, because Admitted
-- is only ever held on top of it.
function Audience.Forget(Plr: Player, Scene: number, Reach: Reach)
    const Held = Told[Plr]
    const Reaches = if Held then Held[Scene] else nil
    if not Held or not Reaches then
        return
    end

    if Reach == "Everyone" then
        Held[Scene] = nil
    else
        Reaches[Reach] = nil
    end
end

-- A scene that no longer exists is held by nobody.
function Audience.ForgetScene(Scene: number)
    for _, Held in Told do
        Held[Scene] = nil
    end
end

function Audience.Hearing(Scene: number, Reach: Reach): Hearing
    const Taken = {}
    for Plr, Held in Told do
        const Reaches = Held[Scene]
        const Token = if Reaches then Reaches[Reach] else nil
        if Token then
            Taken[Plr] = Token
        end
    end

    return Taken
end

-- To everyone in a hearing taken earlier who still holds the scene at the same
-- reach under the same token. Someone sent the scene since then was handed its
-- state by that sending, and someone withdrawn from it has dropped what it held.
function Audience.FireHearing(Channel: Entry, Scene: number, Reach: Reach, Taken: Hearing, ...: any)
    const Recipients = {}
    for Plr, Token in Taken do
        if Audience.Holds(Plr, Scene, Reach, Token) then
            table.insert(Recipients, Plr)
        end
    end

    if #Recipients > 0 then
        Channel:Fire(Recipients, ...)
    end
end

-- One packet about a scene, to whoever holds it at that reach.
function Audience.Fire(Channel: Entry, Scene: number, Reach: Reach, ...: any)
    Audience.FireHearing(Channel, Scene, Reach, Audience.Hearing(Scene, Reach), ...)
end

function Audience.MarkSynced(Plr: Player)
    Synced[Plr] = true
end

function Audience.GetSynced(): {Player}
    const List = {}
    for Plr in Synced do
        if Plr.Parent then
            table.insert(List, Plr)
        end
    end

    return List
end

-- What a player was sent goes with them. What they were admitted to does not:
-- that belongs to the scene.
Players.PlayerRemoving:Connect(function(Plr: Player)
    Told[Plr] = nil
    Synced[Plr] = nil
end)

return Audience
