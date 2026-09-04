--!strict
-- Static channel manifest.
--
-- A channel's id is its index in this list, so the id must be identical on the
-- server and the client. Deriving ids from require order would be fragile, so
-- they live here instead. Append new channels at the end, never reorder, and
-- never reuse the slot of a removed channel during a live rollout.
--
-- Args/Returns are Codec lists. Anything not listed here cannot be sent.

const Codecs = require("./Codecs")

export type Channel = {
    Name: string,
    Args: {Codecs.Codec<any>},
    Returns: {Codecs.Codec<any>}?,
}

const Channels: {Channel} = {
    {
        Name = "Properties.PropertyRegistered",
        Args = {Codecs.Any}, -- PropertyRegistry: nested constraints, fires once per registration
    },

    {
        Name = "Objects.ObjectRegistered",
        Args = {Codecs.Any}, -- ObjectRegistry: same, fires once per registration
    },

    {
        Name = "Objects.ObjectAdded",
        -- RuntimeId, Compressor:CompressObject, the replicated instance if the
        -- object has one so the client can map a clicked part back to an object.
        Args = {Codecs.u32, Codecs.Buffer, Codecs.Optional(Codecs.Instance)},
    },

    {
        Name = "Objects.ObjectRemoved",
        Args = {Codecs.u32}, -- RuntimeId
    },

    {
        Name = "Objects.PropertyChanged",
        Args = {Codecs.u32, Codecs.u16, Codecs.Buffer}, -- RuntimeId, PropertyId, CompressValue
    },

    {
        Name = "Objects.SetProperty",
        Args = {Codecs.u32, Codecs.u16, Codecs.Buffer}, -- RuntimeId, PropertyId, CompressValue
        Returns = {Codecs.Bool},
    },

    {
        Name = "Objects.Destroy",
        Args = {Codecs.u32}, -- RuntimeId
        Returns = {Codecs.Bool},
    },

    {
        Name = "Permissions.Assigned",
        Args = {Codecs.Any}, -- the caller's own permission, so the editor UI can reflect it
    },

    {
        -- Client to server, once, after it has required Loom and connected its
        -- handlers. The server replays current state only then: firing at
        -- PlayerAdded raced the client's own module load, and a large registry
        -- could overflow the unhandled-event queue and lose entries outright.
        -- An invoke rather than an event so the client can tell whether anyone
        -- was listening. A fired event with no handler registered yet is
        -- dropped silently, and the server's Replication module can easily
        -- finish loading after a client has already announced itself.
        Name = "Loom.Ready",
        Args = {},
        Returns = {Codecs.Bool},
    },
}

const ById: {Channel} = Channels
const ByName: {[string]: number} = {}

for Id, Channel in Channels do
    if ByName[Channel.Name] then
        error(`[ LOOM ] Duplicate channel name in manifest: {Channel.Name}`)
    end

    ByName[Channel.Name] = Id
end

if #Channels > 255 then
    error("[ LOOM ] Channel manifest exceeds 255 entries; widen the channel id from u8.")
end

return {
    List = ById,
    Ids = ByName,
}
