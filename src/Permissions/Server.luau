--!strict
-- Server side authorization.
--
-- Before this existed, Objects.SetProperty and Objects.Destroy accepted the
-- calling Player and ignored it, and runtime ids are sequential from 1, so any
-- client could walk the whole workspace and edit or delete all of it.
--
-- Rights come in two kinds. Global rights are about the session rather than any
-- document: the action budget, whether a client may push a scene of its own,
-- and whatever capabilities a game hangs off them. Scene rights are about one
-- scene: Prism's three verbs, the object and property lists they reach, and the
-- scene's own capabilities. "May edit" has to mean "may edit this scene", or
-- two groups building two levels in one server can each touch the other's.
-- Nobody holds anything on a scene until it is granted to them.
--
-- A role is a template, not a live link. Granting one clears what the player
-- held and copies the role in, and from then on the player's own set is the
-- whole truth. Editing a role later would not reach anyone who already holds
-- it: the price, taken knowingly, of having no inheritance rules to get wrong.
--
-- Every grant is keyed by user id -- a Player is only a way of naming theirs --
-- so a grant can name someone who is not here yet and still holds when they
-- come back. Nothing is saved. Scene rights last as long as their scene and
-- global rights as long as the server; who owns a level is the game's own
-- record, and the game hands it over when the scene is made.

const Players = game:GetService("Players")

const SceneRegistry = require("../Scenes/Registry")
const Network = require("./Network")
const Shared = require("./Shared")
const Listeners = require("../Listeners")
const Logger = require("../Logger")
const Types = require("./Types")

export type Action = Types.Action
export type ObjectType = Types.ObjectType
export type Target = Types.Target
export type RoleConfig = Types.RoleConfig
export type Role = Types.Role
export type SceneRights = Types.SceneRights
export type GlobalRights = Types.GlobalRights

const RATE_WINDOW = 1

const Permissions = {}
const Roles: {[string]: Role} = {}

-- By user id, for the life of the server.
const Global: {[number]: GlobalRights} = {}

-- Spending is not a right, it is what a connection has done lately, so it is
-- keyed by the connection and goes with it.
const Budget: {[any]: {Count: number, Window: number}} = {}

-- Every capability something grants, so asking for one nothing grants can say
-- so -- once -- instead of quietly answering false forever.
const Known: {[string]: true} = {}
const Warned: {[string]: true} = {}

-- What a player with no global grant holds.
const Default: GlobalRights = Shared.GlobalRights(nil, nil)

-- A Player, a user id, or anything carrying a numeric UserId, which is what the
-- test suite passes for a player who is not connected.
const function UserIdOf(Who: any): number?
    if typeof(Who) == "Instance" and Who:IsA("Player") then
        return (Who :: Player).UserId
    end

    if type(Who) == "number" and Who % 1 == 0 then
        return Who
    end

    if type(Who) == "table" and type(Who.UserId) == "number" then
        return Who.UserId
    end

    return nil
end

-- A scene or its id, as the live scene. Nil once it has been destroyed.
const function SceneOf(Scene: any): any
    const Identifier = if type(Scene) == "table" then Scene.Id else Scene
    return SceneRegistry.ById[Identifier]
end

const function Learn(Capabilities: {[string]: true})
    for Name in Capabilities do
        Known[Name] = true
    end
end

--=============================================================================
-- Telling the client
--=============================================================================

const function SendGlobal(UserId: number)
    const Plr = Players:GetPlayerByUserId(UserId)
    if Plr then
        Network.Assigned:Fire(Plr, Shared.EncodeGlobal(Global[UserId] or Default))
    end
end

-- Anything that changes one player's rights over one scene. Objects listens,
-- because a hold is worth having only where an edit would be allowed: a player
-- stripped of the right to edit a scene would otherwise go on holding objects
-- there that nobody, themselves included, could do anything with.
--
-- Synchronous, so the release happens before whatever changed the rights
-- carries on. Permissions cannot ask Objects itself -- Objects requires
-- Permissions, and the pair would be a cycle -- so it says, and Objects listens.
const RightsChanged: {(UserId: number, Scene: number) -> ()} = {}

function Permissions.OnSceneRights(Callback: (UserId: number, Scene: number) -> ()): () -> ()
    return Listeners.Watch(RightsChanged, Callback, "scene rights")
end

-- Nil rights say the player holds nothing on the scene any more.
const function SendScene(Scene: any, UserId: number)
    for _, Callback in RightsChanged do
        Callback(UserId, Scene.Id)
    end

    const Plr = Players:GetPlayerByUserId(UserId)
    if not Plr then
        return
    end

    const Rights = Scene.Rights[UserId]
    Network.SceneAssigned:Fire(Plr, Scene.Id, if Rights then Shared.EncodeScene(Rights) else nil)
end

--=============================================================================
-- Roles
--=============================================================================

function Permissions:Register(Name: string, Config: RoleConfig): Role?
    if Roles[Name] then
        Logger:Warn(`Role {Name} is already registered.`)
        return nil
    end

    const Role: Role = {
        Name = Name,
        Global = Shared.GlobalRights(Config.Global, Name),
        Scene = Shared.SceneRights(Config.Scene, Name),
    }

    Learn(Role.Global.Capabilities)
    Learn(Role.Scene.Capabilities)

    Roles[Name] = Role
    return Role
end

function Permissions:GetRegistered(): {[string]: Role}
    return Roles
end

const function Resolve(Who: any, RoleName: string?): (number?, Role?)
    const UserId = UserIdOf(Who)
    if not UserId then
        Logger:Warn(`Rights are granted to a Player or a user id, not a {typeof(Who)}.`)
        return nil, nil
    end

    if RoleName == nil then
        return UserId, nil
    end

    const Role = Roles[RoleName]
    if not Role then
        Logger:Warn(`Cannot grant unregistered role {RoleName}.`)
        return nil, nil
    end

    return UserId, Role
end

--=============================================================================
-- Global rights
--=============================================================================

-- Clears what the player held globally and copies the role's global half in.
function Permissions:Grant(Who: Player | number, RoleName: string): boolean
    const UserId, Role = Resolve(Who, RoleName)
    if not UserId or not Role then
        return false
    end

    Global[UserId] = Shared.CopyGlobal(Role.Global)
    SendGlobal(UserId)
    return true
end

-- Back to what a player with no global grant holds.
function Permissions:Revoke(Who: Player | number)
    const UserId = Resolve(Who, nil)
    if not UserId then
        return
    end

    Global[UserId] = nil
    SendGlobal(UserId)
end

function Permissions:GrantCapability(Who: Player | number, Capability: string)
    const UserId = Resolve(Who, nil)
    if not UserId then
        return
    end

    local Rights = Global[UserId]
    if not Rights then
        Rights = Shared.CopyGlobal(Default)
        Global[UserId] = Rights
    end

    Rights.Capabilities[Capability] = true
    Known[Capability] = true
    SendGlobal(UserId)
end

function Permissions:RevokeCapability(Who: Player | number, Capability: string)
    const UserId = Resolve(Who, nil)
    const Rights = if UserId then Global[UserId] else nil
    if not UserId or not Rights then
        return
    end

    Rights.Capabilities[Capability] = nil
    SendGlobal(UserId)
end

function Permissions:Get(Who: Player | number): GlobalRights
    const UserId = UserIdOf(Who)
    return if UserId then Global[UserId] or Default else Default
end

function Permissions:CanPush(Plr: Player): boolean
    return Permissions:Get(Plr).CanPush
end

--=============================================================================
-- Scene rights
--=============================================================================

-- Clears what the player held on the scene and copies the role's scene half
-- in. Scene:Grant is this.
function Permissions:GrantOn(Scene: any, Who: Player | number, RoleName: string): boolean
    const Owner = SceneOf(Scene)
    if not Owner then
        Logger:Warn(`Cannot grant rights on a scene that does not exist.`)
        return false
    end

    const UserId, Role = Resolve(Who, RoleName)
    if not UserId or not Role then
        return false
    end

    Owner.Rights[UserId] = Shared.CopyScene(Role.Scene)
    SendScene(Owner, UserId)
    return true
end

function Permissions:RevokeOn(Scene: any, Who: Player | number)
    const Owner = SceneOf(Scene)
    const UserId = Resolve(Who, nil)
    if not Owner or not UserId or not Owner.Rights[UserId] then
        return
    end

    Owner.Rights[UserId] = nil
    SendScene(Owner, UserId)
end

-- On its own, without a role. A player who held nothing on the scene holds the
-- capability and no verbs.
function Permissions:GrantCapabilityOn(Scene: any, Who: Player | number, Capability: string)
    const Owner = SceneOf(Scene)
    const UserId = Resolve(Who, nil)
    if not Owner or not UserId then
        return
    end

    local Rights = Owner.Rights[UserId]
    if not Rights then
        Rights = Shared.SceneRights(nil, nil)
        Owner.Rights[UserId] = Rights
    end

    Rights.Capabilities[Capability] = true
    Known[Capability] = true
    SendScene(Owner, UserId)
end

function Permissions:RevokeCapabilityOn(Scene: any, Who: Player | number, Capability: string)
    const Owner = SceneOf(Scene)
    const UserId = Resolve(Who, nil)
    const Rights = if Owner and UserId then Owner.Rights[UserId] else nil
    if not Rights or not UserId then
        return
    end

    Rights.Capabilities[Capability] = nil
    SendScene(Owner, UserId)
end

function Permissions:GetOn(Scene: any, Who: Player | number): SceneRights?
    const Owner = SceneOf(Scene)
    const UserId = UserIdOf(Who)
    return if Owner and UserId then Owner.Rights[UserId] else nil
end

-- The wire form of one player's rights on one scene, as the client receives it.
function Permissions:GetPayloadOn(Scene: any, Who: Player | number): Types.SceneRightsPayload?
    const Rights = Permissions:GetOn(Scene, Who)
    return if Rights then Shared.EncodeScene(Rights) else nil
end

-- A scene going away takes its rights with it. Called by the scene as it is
-- destroyed, while it can still be found, so everyone present who held rights
-- on it is told they hold none.
function Permissions.DropScene(Scene: any)
    for UserId in table.clone(Scene.Rights) do
        Scene.Rights[UserId] = nil
        SendScene(Scene, UserId)
    end
end

--=============================================================================
-- Checks
--=============================================================================

-- Whether a player may do something to an object. Target is the object -- it
-- carries its scene and its type -- or, for a create, a table naming the scene
-- and the type it would make. Property is the one being written, for an edit
-- or a create's initial value.
function Permissions:Can(Plr: Player, Action: Action, Target: Target, Property: number?): boolean
    if Action ~= "Create" and Action ~= "Edit" and Action ~= "Destroy" then
        Logger:Warn(`Unknown permission action {Action}. Denying.`)
        return false
    end

    const UserId = UserIdOf(Plr)
    const Owner = SceneRegistry.ById[Target.Scene]
    if not UserId or not Owner then
        return false
    end

    const Rights = Owner.Rights[UserId]
    if not Rights then
        return false
    end

    return Shared.Allows(Rights, Action, Target.Registry, Property)
end

-- Whether a player holds a capability: globally with no scene named, or on
-- that scene. Prism answers for capabilities and enforces none of them.
function Permissions:Has(Plr: Player, Capability: string, Scene: number?): boolean
    if not Known[Capability] and not Warned[Capability] then
        Warned[Capability] = true
        Logger:Warn(`Nothing grants the capability {Capability}, so asking for it answers false until a role or a grant names it.`)
    end

    const UserId = UserIdOf(Plr)
    if not UserId then
        return false
    end

    if Scene == nil then
        return (Global[UserId] or Default).Capabilities[Capability] == true
    end

    const Owner = SceneRegistry.ById[Scene]
    const Rights = if Owner then Owner.Rights[UserId] else nil
    return Rights ~= nil and Rights.Capabilities[Capability] == true
end

-- Sliding one second window, budgeted by the player's global rights so a
-- trusted player is not held to the same ceiling as an untrusted one.
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

-- Called by Replication once the client has announced it is listening, rather
-- than on PlayerAdded. Firing at join meant the rights went out before the
-- client had finished requiring Prism and connecting its handlers. Global
-- rights, then the player's rights on every scene that has granted them any.
function Permissions:SendTo(Plr: Player)
    Network.Assigned:Fire(Plr, Shared.EncodeGlobal(Permissions:Get(Plr)))

    for _, Scene in SceneRegistry.ById do
        const Rights = Scene.Rights[Plr.UserId]
        if Rights then
            Network.SceneAssigned:Fire(Plr, Scene.Id, Shared.EncodeScene(Rights))
        end
    end
end

-- The budget goes with the connection. Rights do not: they are keyed by user
-- id and hold again when the player comes back.
Players.PlayerRemoving:Connect(function(Plr: Player)
    Budget[Plr] = nil
end)

return Permissions
