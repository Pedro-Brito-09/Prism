--!strict
-- Who hears about a scene.
--
-- Every packet about a scene used to go out with FireAll, so every player heard
-- about every scene. That is fine for a game with one level and wrong for a
-- place several people build in at once. A scene now admits players by user id,
-- and one that has admitted nobody is public -- which is what every scene that
-- existed before this already was.
--
-- Two questions, kept apart. Sees is admission: whether a player may be told
-- about a scene at all. Holds is what a player has actually been told, and it
-- is what every packet about the scene is addressed by. The two differ while a
-- player is joining -- admitted, but not yet sent the scene -- and for the
-- moment between an admission changing and the scene being revealed or
-- withdrawn to match. Addressing by what was told rather than by what is
-- allowed is what means a client is never sent an object for a copy it has not
-- been introduced to.

const Players = game:GetService("Players")

const Networking = require("../Networking")
const Registry = require("./Registry")

type Entry = Networking.Entry

-- Who has been told about a scene, and the token each was told under. Taken
-- once by anything that sends a scene's objects over several frames.
export type Hearing = {[Player]: number}

const Audience = {}

-- Per player, per scene, the token of the reveal that told them. Anything still
-- streaming a scene to someone checks the token between chunks, so a scene
-- withdrawn part way -- or withdrawn and revealed again -- stops the stale
-- stream rather than sending objects for a copy the client has just dropped.
const Told: {[Player]: {[number]: number}} = {}
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

-- Whether a player has been told about a scene, and, given a token, whether
-- they still hold it under that one.
function Audience.Holds(Plr: Player, Scene: number, Token: number?): boolean
    const Held = Told[Plr]
    const Current = if Held then Held[Scene] else nil

    if Current == nil then
        return false
    end

    return Token == nil or Current == Token
end

function Audience.Remember(Plr: Player, Scene: number): number
    local Held = Told[Plr]
    if not Held then
        Held = {}
        Told[Plr] = Held
    end

    Counter += 1
    Held[Scene] = Counter
    return Counter
end

function Audience.Forget(Plr: Player, Scene: number)
    const Held = Told[Plr]
    if Held then
        Held[Scene] = nil
    end
end

-- A scene that no longer exists is held by nobody.
function Audience.ForgetScene(Scene: number)
    for _, Held in Told do
        Held[Scene] = nil
    end
end

function Audience.Hearing(Scene: number): Hearing
    const Taken = {}
    for Plr, Held in Told do
        const Token = Held[Scene]
        if Token then
            Taken[Plr] = Token
        end
    end

    return Taken
end

-- To everyone in a hearing taken earlier who still holds the scene under the
-- same token. Someone told about the scene since then was handed its state by
-- that telling, and someone withdrawn from it has dropped everything it held.
function Audience.FireHearing(Channel: Entry, Scene: number, Taken: Hearing, ...: any)
    const Recipients = {}
    for Plr, Token in Taken do
        if Audience.Holds(Plr, Scene, Token) then
            table.insert(Recipients, Plr)
        end
    end

    if #Recipients > 0 then
        Channel:Fire(Recipients, ...)
    end
end

-- One packet about a scene, to whoever has been told about it.
function Audience.Fire(Channel: Entry, Scene: number, ...: any)
    Audience.FireHearing(Channel, Scene, Audience.Hearing(Scene), ...)
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

-- What a player was told goes with them. What they were admitted to does not:
-- that belongs to the scene.
Players.PlayerRemoving:Connect(function(Plr: Player)
    Told[Plr] = nil
    Synced[Plr] = nil
end)

return Audience
