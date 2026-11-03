--!strict
-- Requires are written out per branch rather than built from an interpolated
-- path. Require by string needs a literal, and routing every module through a
-- helper erases the types.
--
-- Only the documented modules are exposed. Everything else (the compressor,
-- codecs, id pools and the rest) is internal and reached by path when needed,
-- so it can change without breaking a game.

const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Prism = {}

if IS_SERVER then
    Prism.Properties = require("@self/Properties/Server")
    Prism.Objects = require("@self/Objects/Server")

    -- Before anything that creates an object: registering it is what puts the
    -- default scene in place, and an object cannot be built without one.
    Prism.Scenes = require("@self/Scenes/Server")
    Prism.Permissions = require("@self/Permissions/Server")

    -- After both: it applies through Objects, resolves scene copies through
    -- Scenes, and checks every operation against Permissions.
    Prism.Transactions = require("@self/Transactions/Server")

    -- After Transactions, which it records, and required whether or not a game
    -- ever calls it: a destroy is deferred on the way out and this is what
    -- takes hold of what was destroyed. Nothing claiming it is exactly how a
    -- destroy stays immediate -- but that decision has to be made by something
    -- that is there to make it.
    Prism.History = require("@self/History/Server")
    Prism.Database = require("@self/Database/Server")

    -- Required for the side effect: it wires up the join replay.
    require("@self/Replication")
else
    -- Through any: each field is typed by the server half, assigned first, and
    -- the client half is a different module type with fewer members. Prism
    -- reads as the server API on both sides, so autocomplete on the client
    -- offers server-only members. A known limitation: a union type breaks
    -- autocomplete on both sides, and separate entry points would change the
    -- API.
    Prism.Properties = require("@self/Properties/Client") :: any
    Prism.Objects = require("@self/Objects/Client") :: any
    Prism.Scenes = require("@self/Scenes/Client") :: any
    Prism.Permissions = require("@self/Permissions/Client") :: any
    Prism.Transactions = require("@self/Transactions/Client") :: any

    -- Client only, and not as a policy: it reads Objects/Client directly, so
    -- requiring it on the server would pull the client half of the object
    -- pipeline into a server process.
    Prism.Selection = require("@self/Selection")

    -- Client only, and only half the history: it keeps the steps of scenes this
    -- client owns and the order the two halves make together, and asks the
    -- server for the rest.
    Prism.History = require("@self/History/Client") :: any
end

Prism.CustomEnum = require("@self/CustomEnum")
Prism.Networking = require("@self/Networking")

const Logger = require("@self/Logger")
const Try = require("@self/Try")

-- Announce only once every client module above has connected its handlers, then
-- keep asking until the server answers. The server's Replication module can
-- finish loading after this client does, and an unanswered announcement would
-- otherwise leave the client with an empty registry for the whole session.
--
-- Retried on a separate thread so requiring Prism never blocks on it.
-- Not outside a running game, where there is no server to answer.
if not IS_SERVER and RunService:IsRunning() then
    const Ready = Prism.Networking:Get("Prism.Ready")

    task.spawn(function()
        const Acknowledged = Try(10, function()
            return Ready:Invoke()
        end)

        if not Acknowledged then
            Logger:Warn("Server never acknowledged readiness; is Prism required on the server?")
        end
    end)
end

return Prism
