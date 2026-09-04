--!strict
-- Requires are written out per branch rather than built from an interpolated
-- path. Require by string needs a literal, and routing every module through a
-- helper erased the types, so Loom.Properties used to resolve to any.
--
-- Properties also used to be server only here even though Properties/Client
-- existed and was fully written, which left the client with a nil field.

const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Loom = {}

if IS_SERVER then
    Loom.Properties = require("./Properties/Server")
    Loom.Objects = require("./Objects/Server")
    Loom.Permissions = require("./Permissions/Server")
    Loom.Database = require("./Database/Server")

    -- Required for the side effect: it wires up the join replay.
    require("./Replication")
else
    Loom.Properties = require("./Properties/Client")
    Loom.Objects = require("./Objects/Client")
    Loom.Permissions = require("./Permissions/Client")
end

Loom.CustomEnum = require("./CustomEnum")
Loom.Compressor = require("./Compressor")
Loom.Networking = require("./Networking")
Loom.Encoding = require("./Encoding")
Loom.Varint = require("./Varint")
Loom.Codecs = require("./Codecs")
Loom.IdPool = require("./IdPool")
Loom.Logger = require("./Logger")
Loom.Try = require("./Try")

-- Announce only once every client module above has connected its handlers, then
-- keep asking until the server answers. The server's Replication module can
-- finish loading after this client does, and an unanswered announcement would
-- otherwise leave the client with an empty registry for the whole session.
--
-- Retried on a separate thread so requiring Loom never blocks on it.
if not IS_SERVER then
    const Ready = Loom.Networking:Get("Loom.Ready")

    task.spawn(function()
        const Acknowledged = Loom.Try(10, function()
            return Ready:Invoke()
        end)

        if not Acknowledged then
            Loom.Logger:Warn("Server never acknowledged readiness; is Loom required on the server?")
        end
    end)
end

return Loom
