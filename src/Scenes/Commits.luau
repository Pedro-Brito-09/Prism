--!strict
-- Commits from a client: a scene a player built locally, handed to the server
-- to register.

const Permissions = require("../Permissions/Server")
const Compressor = require("../Compressor")
const Objects = require("../Objects/Server")
const Registry = require("./Registry")
const Network = require("./Network")
const Logger = require("../Logger")
const Types = require("./Types")

type SceneIdentifier = Types.SceneIdentifier

const Commits = {}

-- Scenes.fromBuffer, handed over by Scenes/Server, which requires this module:
-- requiring it back would be a cycle.
local FromBuffer: (Config: Types.SceneConfig, Data: buffer) -> Types.ServerScene?

function Commits.Bind(Register: (Config: Types.SceneConfig, Data: buffer) -> Types.ServerScene?)
    FromBuffer = Register
end

-- What one commit may carry. The byte cap is what actually bounds the work --
-- decoding walks the buffer and does nothing else until it is through -- and
-- the object cap is what stops a well formed pack of a hundred thousand
-- objects becoming a scene nobody asked for. The name cap is only there so a
-- registry key cannot be a novel.
const MAX_COMMIT_BYTES = 524288
const MAX_COMMIT_OBJECTS = 4096
const MAX_NAME_LENGTH = 64

-- The role a player is granted on a scene they push, or nil for none. A pushed
-- scene admits only its author either way: it was built where nobody else could
-- see it, and registering it should not change that.
local PushRole: string? = nil

function Commits.SetPushRole(Role: string?)
    if Role and not Permissions:GetRegistered()[Role] then
        Logger:Warn(`Cannot grant unregistered role {Role} on pushed scenes.`)
        return
    end

    PushRole = Role
end

-- A client handing over a scene it built locally. Refusals are not logged,
-- like every other client facing handler here: a refusal that logs is a
-- refusal a client can spam to fill the server's output. They do say why to
-- the client that asked, which costs nothing and is the one thing a game needs
-- to tell its player.
const function Refuse(Reason: string): (boolean, SceneIdentifier, string)
    return false, 0, Reason
end

Network.Commit.OnInvoke = function(Plr: Player, Name: string, Data: buffer): (boolean, SceneIdentifier, string)
    -- One action for the packet rather than one per object in it. A transaction
    -- charges per operation because every operation reaches into the world as
    -- it stands; this arrives whole, and what bounds it is its size, which is
    -- known before a byte of it is read.
    if not Permissions:Consume(Plr) then
        return Refuse("Budget")
    end

    -- A global right rather than a check against the pack's types. The scene
    -- does not exist yet, so there are no rights over it to consult, and
    -- registering a scene at all is exactly the kind of thing that is about the
    -- session rather than a document.
    if not Permissions:CanPush(Plr) then
        return Refuse("NoPushRight")
    end

    if buffer.len(Data) > MAX_COMMIT_BYTES then
        return Refuse("TooLarge")
    end

    if #Name == 0 or #Name > MAX_NAME_LENGTH then
        return Refuse("BadName")
    end

    -- Names are how a scene is asked for, so the first one to take a name keeps
    -- it. Refused here as well as in Scenes.new so the pack is not decoded for
    -- a commit that cannot land anyway.
    if Registry.ByName[Name] then
        return Refuse("NameTaken")
    end

    const Ok, _, Decompressed = pcall(function()
        return Compressor:DecompressScene(Data)
    end)

    if not Ok or not Decompressed then
        return Refuse("Unreadable")
    end

    const Packed = Decompressed :: {any}
    if #Packed > MAX_COMMIT_OBJECTS then
        return Refuse("TooManyObjects")
    end

    -- Every object type in the pack has to be one the server knows, and the
    -- whole commit is refused if any is not. A scene arriving with half its
    -- objects dropped is not the scene that was sent, and the client would
    -- have no way to tell.
    local Highest = 0

    for _, Object in Packed do
        if not Objects:GetRegistry(Object.Registry) then
            return Refuse("UnknownType")
        end

        -- A client's pack keeps no bytes the server cannot read. A save of the
        -- server's own keeps what an older build wrote; a packet from a client
        -- is untrusted, and this is the server writing its own pack.
        Object.Unknown = nil

        Highest = math.max(Highest, Object.LocalId)
    end

    -- Re-encoded rather than kept as it arrived, so the pack the server holds
    -- is the one the server wrote. Its LastId is the highest id actually in it
    -- rather than whatever the client claimed -- a pack declaring an id space
    -- already spent would otherwise give the scene room for nothing.
    -- Private to its author from the packet that registers it, and theirs to
    -- edit if the game has said what a pusher holds.
    const Scene = FromBuffer({
        Name = Name,
        Private = true,
        Admitted = {Plr.UserId},
        Rights = if PushRole then {[Plr.UserId] = PushRole} else nil,
    }, Compressor:CompressScene(Highest, Packed))
    if not Scene then
        return Refuse("Failed")
    end

    return true, Scene.Id, ""
end

return Commits
