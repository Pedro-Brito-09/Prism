# Networking

Channels are declared in `src/Channels.luau` with a codec per parameter, so a
packet is one byte of channel id plus exactly the bytes the values need. Ids come
from the manifest order, so they match on both sides.

```luau
{
    Name = "MyFeature.Move",
    Args = {Codecs.u32, Codecs.Vector},
    Returns = {Codecs.Bool},
}
```

```luau
-- server; a client fires and invokes the same channel object
local Move = Prism.Networking:Get("MyFeature.Move")
Move:Fire(player, runtimeId, Vector3.new(1, 2, 3))  -- server, targeted
Move:FireAll(runtimeId, Vector3.new(1, 2, 3))
Move.OnInvoke = function(player, runtimeId, position) return true end
```

Codecs: `u8`/`u16`/`u32`, `i8`/`i16`/`i32`, `f32`/`f64`, `Varint`,
`SignedVarint`, `Bool`, `String`, `LongString`, `Buffer`, `Vector`, `Color`,
`CFrame`, `Instance`, `Player`, `Any`, plus `Optional(codec)` and
`Array(codec)`.

Append new channels at the end of the manifest. Never reorder them, and never
reuse a removed channel's slot during a live rollout.

Invokes are client to server only. `InvokeClient` parks the calling server thread
until the client answers, and a client that never answers holds it forever.

## Loading and unloading are one packet

A copy going away fires a single message naming it, and the client drops
everything it holds for it. Loading sends the objects down the same chunked path
a joining player receives. One packet per object would put a five thousand
object scene into the remote queue in a single frame, which is the flood the
join replay exists to avoid.
