# Database

`Prism.Database`, server only. See the [Database guide](/guides/database).

## `Database.new(config)`

| Config field | Default | |
|---|---|---|
| `Key` | Required | The DataStore and MemoryStore name |
| `InitialMetadata` | Required | `{Property}`, from `Properties.new` |
| `Expiration` | 90 | Seconds both cache tiers live |
| `ShardLimit` | 1 MB | Measured before compression. Keep it under 3 MB |

## A database

| Method | Returns | |
|---|---|---|
| `:Create()` | `ok, id?` | |
| `:GetById(id)` | record? | Frozen |
| `:Edit(id, changes)` | `boolean` | `changes` is keyed by property id |
| `:Delete(id)` | `boolean` | |
| `:Link(id, guid)` | `boolean` | True when the record holds it. At most 64 a record |
| `:Unlink(id, guid)` | `boolean` | False when it was not linked |
| `:RegisterCache(name, config)` | | |
| `:Get(cache, page?)` | `{Records, HasMore}` | |
| `:Find(predicate, limit?)` | `{record}` | Stops once it has enough |
| `:Refresh()` | | |

## A record

| Member | |
|---|---|
| `.Id` | |
| `.Scenes` | Guids, in link order. `{}` when none |
| `[n]` | A property, by its position in the record. Read `.Value` from it |

## Cache config

| Field | Default | |
|---|---|---|
| `PageSize` | 50 | |
| `IdOrdered` | | `"Asc"` or `"Desc"`. Lets a page stop as soon as it is full |
| `Sort` | | `fn(a, b) -> boolean`, for any other order. Reads every shard |

A cache needs `IdOrdered` or `Sort`.
