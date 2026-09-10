--!strict
-- Requires are written out per branch rather than built from an interpolated
-- path. Require by string needs a literal, and routing every module through a
-- helper erased the types, so Prism.Properties used to resolve to any.
--
-- Properties also used to be server only here even though Properties/Client
-- existed and was fully written, which left the client with a nil field.

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
    Prism.Database = require("@self/Database/Server")

    -- Required for the side effect: it wires up the join replay.
    require("@self/Replication")
else
    Prism.Properties = require("@self/Properties/Client")
    Prism.Objects = require("@self/Objects/Client")
    Prism.Scenes = require("@self/Scenes/Client")
    Prism.Permissions = require("@self/Permissions/Client")
    Prism.Transactions = require("@self/Transactions/Client")

    -- Client only, and not as a policy: it reads Objects/Client directly, so
    -- requiring it on the server would pull the client half of the object
    -- pipeline into a server process.
    Prism.Selection = require("@self/Selection")
end

Prism.CustomEnum = require("@self/CustomEnum")
Prism.Compressor = require("@self/Compressor")
Prism.Networking = require("@self/Networking")
Prism.Handles = require("@self/Handles")
Prism.Encoding = require("@self/Encoding")
Prism.Varint = require("@self/Varint")
Prism.Codecs = require("@self/Codecs")
Prism.IdPool = require("@self/IdPool")
Prism.Logger = require("@self/Logger")
Prism.Try = require("@self/Try")

-- Announce only once every client module above has connected its handlers, then
-- keep asking until the server answers. The server's Replication module can
-- finish loading after this client does, and an unanswered announcement would
-- otherwise leave the client with an empty registry for the whole session.
--
-- Retried on a separate thread so requiring Prism never blocks on it.
if not IS_SERVER then
    const Ready = Prism.Networking:Get("Prism.Ready")

    task.spawn(function()
        const Acknowledged = Prism.Try(10, function()
            return Ready:Invoke()
        end)

        if not Acknowledged then
            Prism.Logger:Warn("Server never acknowledged readiness; is Prism required on the server?")
        end
    end)
end

return Prism
