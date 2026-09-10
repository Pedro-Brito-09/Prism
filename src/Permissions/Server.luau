--!strict
-- Server side authorization for the object remotes.
--
-- Before this existed, Objects.SetProperty and Objects.Destroy accepted the
-- calling Player and ignored it, and runtime ids are sequential from 1, so any
-- client could walk the whole workspace and edit or delete all of it.

const Players = game:GetService("Players")

const Network = require("./Network")
const Logger = require("../Logger")
const Types = require("./Types")

export type Action = Types.Action
export type ObjectType = Types.ObjectType
export type PermissionConfig = Types.PermissionConfig
export type Permission = Types.Permission
export type PermissionPayload = Types.PermissionPayload

const DEFAULT_RATE = 60
const RATE_WINDOW = 1

const Permissions = {}
const Registered: {[string]: Permission} = {}
const Payloads: {[string]: PermissionPayload} = {}
const Assigned: {[Player]: string} = {}
const Budget: {[Player]: {Count: number, Window: number}} = {}

-- Built once per role rather than per send, and with Blacklist flattened to a
-- sequential array so it survives remote serialization.
const function ToPayload(Perm: Permission): PermissionPayload
    const List = {}
    for ObjectType in Perm.Blacklist do
        table.insert(List, ObjectType)
    end

    table.sort(List)

    return {
        Name = Perm.Name,
        Level = Perm.Level,
        CanCreate = Perm.CanCreate,
        CanEdit = Perm.CanEdit,
        CanDestroy = Perm.CanDestroy,
        Rate = Perm.Rate,
        Blacklist = List,
    }
end

-- Unassigned players get this. It denies everything, so forgetting to call
-- Assign fails closed instead of handing out edit rights.
const Fallback: Permission = {
    Name = "None",
    Level = 0,
    CanCreate = false,
    CanEdit = false,
    CanDestroy = false,
    Rate = 0,
    Blacklist = {},
}

local DefaultName: string? = nil

function Permissions:Register(Name: string, Config: PermissionConfig): Permission?
    if Registered[Name] then
        Logger:Warn(`Permission {Name} is already registered.`)
        return
    end

    const Blacklist: {[ObjectType]: true} = {}
    if Config.Blacklist then
        for _, ObjectType in Config.Blacklist do
            Blacklist[ObjectType] = true
        end
    end

    const Perm: Permission = {
        Name = Name,
        Level = Config.Level,
        CanCreate = Config.CanCreate == true,
        CanEdit = Config.CanEdit == true,
        CanDestroy = Config.CanDestroy == true,
        Rate = Config.Rate or DEFAULT_RATE,
        Blacklist = Blacklist,
    }

    Registered[Name] = Perm
    return Perm
end

-- The role handed to players who have not been assigned one. Leave it unset to
-- deny everything by default.
function Permissions:SetDefault(Name: string?)
    if Name and not Registered[Name] then
        Logger:Error(`Cannot default to unregistered permission {Name}.`)
    end

    DefaultName = Name

    for _, Plr in Players:GetPlayers() do
        if not Assigned[Plr] then
            Network.Assigned:Fire(Plr, Permissions:GetPayload(Plr))
        end
    end
end

function Permissions:Assign(Plr: Player, Name: string?): boolean
    if Name and not Registered[Name] then
        Logger:Warn(`Cannot assign unregistered permission {Name}.`)
        return false
    end

    Assigned[Plr] = Name
    Network.Assigned:Fire(Plr, Permissions:GetPayload(Plr))
    return true
end

function Permissions:Get(Plr: Player): Permission
    const Name = Assigned[Plr] or DefaultName
    return if Name then Registered[Name] or Fallback else Fallback
end

function Permissions:GetPayload(Plr: Player): PermissionPayload
    const Perm = Permissions:Get(Plr)
    local Payload = Payloads[Perm.Name]

    if not Payload then
        Payload = ToPayload(Perm)
        Payloads[Perm.Name] = Payload
    end

    return Payload
end

function Permissions:GetRegistered(): {[string]: Permission}
    return Registered
end

-- Verb plus blacklist. ObjectType is the registry id of the object being acted
-- on, and is optional for actions that do not target one yet.
function Permissions:Can(Plr: Player, Action: Action, ObjectType: ObjectType?): boolean
    const Perm = Permissions:Get(Plr)

    -- Resolved rather than chained, so an action string that matches none of
    -- the three denies. The chained form fell through to the allow path, and
    -- the union type only catches that when the verb is a literal.
    local Allowed: boolean
    if Action == "Create" then
        Allowed = Perm.CanCreate
    elseif Action == "Edit" then
        Allowed = Perm.CanEdit
    elseif Action == "Destroy" then
        Allowed = Perm.CanDestroy
    else
        Logger:Warn(`Unknown permission action {Action}. Denying.`)
        return false
    end

    if not Allowed then
        return false
    end

    if ObjectType and Perm.Blacklist[ObjectType] then
        return false
    end

    return true
end

-- Sliding one second window, budgeted per role so a trusted role is not held to
-- the same ceiling as an untrusted one.
--
-- Cost is what the request asks the server to do, not how many packets it
-- arrived in. A transaction charges one per operation: charging per call would
-- let a single packet carrying ten thousand operations spend one unit of a
-- sixty unit budget and walk straight past the limiter, which is the one flood
-- the limiter most needs to catch.
--
-- Clamped to at least one so no request is ever free, whatever it claims to
-- cost.
function Permissions:Consume(Plr: Player, Cost: number?): boolean
    const Charge = math.max(Cost or 1, 1)
    const Rate = Permissions:Get(Plr).Rate
    if Rate <= 0 then
        return false
    end

    const Now = os.clock()
    const Entry = Budget[Plr]

    -- A fresh window is not a free one. The old form returned true here without
    -- comparing, which was harmless while every call cost one and a rate below
    -- one denies anyway, and is not once a call can cost a thousand.
    if not Entry or Now - Entry.Window >= RATE_WINDOW then
        Budget[Plr] = {Count = Charge, Window = Now}
        return Charge <= Rate
    end

    Entry.Count += Charge
    return Entry.Count <= Rate
end

-- What the remote handlers call: one gate covering rate limit, verb and
-- blacklist.
function Permissions:Check(Plr: Player, Action: Action, ObjectType: ObjectType?): boolean
    return Permissions:Consume(Plr) and Permissions:Can(Plr, Action, ObjectType)
end

-- Called by Replication once the client has announced it is listening, rather
-- than on PlayerAdded. Firing at join meant the payload went out before the
-- client had finished requiring Prism and connecting its handlers, leaving it
-- stuck on the deny-everything fallback.
function Permissions:SendTo(Plr: Player)
    Network.Assigned:Fire(Plr, Permissions:GetPayload(Plr))
end

Players.PlayerRemoving:Connect(function(Plr: Player)
    Assigned[Plr] = nil
    Budget[Plr] = nil
end)

return Permissions
