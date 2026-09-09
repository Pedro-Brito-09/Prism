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
        -- Handle, Compressor:CompressObject, the replicated instance if the
        -- object has one so the client can map a clicked part back to an object.
        Args = {Codecs.Handle, Codecs.Buffer, Codecs.Optional(Codecs.Instance)},
    },

    {
        Name = "Objects.ObjectRemoved",
        Args = {Codecs.Handle},
    },

    {
        Name = "Objects.PropertyChanged",
        Args = {Codecs.Handle, Codecs.u16, Codecs.Buffer}, -- Handle, PropertyId, CompressValue
    },

    {
        Name = "Objects.SetProperty",
        Args = {Codecs.Handle, Codecs.u16, Codecs.Buffer}, -- Handle, PropertyId, CompressValue
        Returns = {Codecs.Bool},
    },

    {
        Name = "Objects.Destroy",
        Args = {Codecs.Handle},
        Returns = {Codecs.Bool},
    },

    {
        Name = "Permissions.Assigned",
        Args = {Codecs.Any}, -- the caller's own permission, so the editor UI can reflect it
    },

    {
        -- Client to server, once, after it has required Prism and connected its
        -- handlers. The server replays current state only then: firing at
        -- PlayerAdded raced the client's own module load, and a large registry
        -- could overflow the unhandled-event queue and lose entries outright.
        -- An invoke rather than an event so the client can tell whether anyone
        -- was listening. A fired event with no handler registered yet is
        -- dropped silently, and the server's Replication module can easily
        -- finish loading after a client has already announced itself.
        Name = "Prism.Ready",
        Args = {},
        Returns = {Codecs.Bool},
    },

    {
        -- Bulk replay of the property registry to a joining client. The replay
        -- used to fire once per registry and once per live object, so a join
        -- cost hundreds of packets in a single frame and blocked the server
        -- thread that was building them.
        Name = "Properties.RegistriesReplayed",
        Args = {Codecs.Array(Codecs.Any)},
    },

    {
        Name = "Objects.RegistriesReplayed",
        Args = {Codecs.Array(Codecs.Any)},
    },

    {
        -- Parallel arrays rather than one array of records: Codecs.Array needs
        -- a codec per element, and the three parts each have their own. The
        -- instance list carries false where an object has no instance, because
        -- a nil entry would leave a hole and shift every later index.
        Name = "Objects.ObjectsReplayed",
        Args = {
            Codecs.Array(Codecs.Handle),
            Codecs.Array(Codecs.Buffer),
            Codecs.Array(Codecs.Any),
        },
    },

    {
        -- Scene registries replicate like property and object ones, and have to
        -- land before any object does: a handle names its scene, so an object
        -- arriving for a scene the client has never heard of cannot be filed.
        Name = "Scenes.SceneRegistered",
        Args = {Codecs.Any},
    },

    {
        Name = "Scenes.RegistriesReplayed",
        Args = {Codecs.Array(Codecs.Any)},
    },

    {
        -- One packet for the whole scene. Unloading is a mass destroy, and
        -- sending an ObjectRemoved per object is precisely the flood the
        -- chunked join replay exists to avoid -- a five thousand object scene
        -- would cost five thousand packets in a frame.
        --
        -- Loading has no counterpart here because it already has one: the
        -- objects go out through ObjectsReplayed, the same chunked path a
        -- joining player receives, only fired at everyone.
        Name = "Scenes.SceneUnloaded",
        Args = {Codecs.Varint}, -- SceneId
    },
}

const ById: {Channel} = Channels
const ByName: {[string]: number} = {}

for Id, Channel in Channels do
    if ByName[Channel.Name] then
        error(`[ PRISM ] Duplicate channel name in manifest: {Channel.Name}`)
    end

    ByName[Channel.Name] = Id
end

if #Channels > 255 then
    error("[ PRISM ] Channel manifest exceeds 255 entries; widen the channel id from u8.")
end

return {
    List = ById,
    Ids = ByName,
}
