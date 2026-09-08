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
    Prism.Properties = require("./Properties/Server")
    Prism.Objects = require("./Objects/Server")
    Prism.Permissions = require("./Permissions/Server")
    Prism.Database = require("./Database/Server")

    -- Required for the side effect: it wires up the join replay.
    require("./Replication")
else
    Prism.Properties = require("./Properties/Client")
    Prism.Objects = require("./Objects/Client")
    Prism.Permissions = require("./Permissions/Client")
end

Prism.CustomEnum = require("./CustomEnum")
Prism.Compressor = require("./Compressor")
Prism.Networking = require("./Networking")
Prism.Encoding = require("./Encoding")
Prism.Varint = require("./Varint")
Prism.Codecs = require("./Codecs")
Prism.IdPool = require("./IdPool")
Prism.Logger = require("./Logger")
Prism.Try = require("./Try")

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
