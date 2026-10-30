# Networking

`Prism.Networking`. See the [Networking guide](/guides/networking). Channels are
declared in `src/Channels.luau`.

| Call | Side | Returns | |
|---|---|---|---|
| `Networking:Get(name)` | S C | channel | |

## A channel

| Member | Side | |
|---|---|---|
| `:Fire(target, ...)` | S | `target` is a Player or a list of Players |
| `:FireAll(...)` | S | Every client |
| `:Fire(...)` | C | To the server |
| `:Invoke(...)` | C | Client to server only |
| `.OnInvoke` | S | Set to the handler. It receives the player first |
| `:Connect(fn)` | S C | Returns a disconnect. On the server, `fn` receives the player first |

## Declaring a channel

| Field | |
|---|---|
| `Name` | `string` |
| `Args` | `{codec}`, one per parameter |
| `Returns` | `{codec}?`, for an invoke |

Codecs: `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`, `f64`, `Varint`,
`SignedVarint`, `Bool`, `String`, `LongString`, `Buffer`, `Vector`, `Color`,
`CFrame`, `Instance`, `Player`, `Any`, `Optional(codec)` and `Array(codec)`.
