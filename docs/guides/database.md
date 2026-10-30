# Database

Sharded metadata storage. Records live in `{Key}:1..N`; ids come from a
monotonic counter, so when the tail shard reaches its limit its boundary
freezes and a new tail opens. Records never move between shards, and edits to
different shards do not contend with each other.

A shard is stored as the same packed format as a scene (see
[Storage format](/internals/storage-format#scene-packs)). On 20,000 typical level records (title,
creator, plays, likes, date, public flag, thumbnail) that came to 14 bytes a
record, down from 61. MemoryStore pages are packed the same way, so a 31 KB
page holds about 1,300 records.

The limit (`ShardLimit`, 1 MB by default) is measured **before** compression,
because it is a CPU budget rather than a storage one: every create decodes and
re-encodes the whole tail shard inside an `UpdateAsync` transform, which cannot
yield. 1 MB is about 30,000 records and about a second per create. What a shard
actually stores is a quarter to a third of that. Keep `ShardLimit` under 3 MB:
a DataStore counts a stored buffer at its base64 size, so no key holds much more
than 3 MiB of one.

```luau
-- server
local db = Prism.Database.new({
    Key = "Levels",
    InitialMetadata = {Prism.Properties.new(Title), Prism.Properties.new(Plays)},
})

local ok, id = db:Create()
db:Edit(id, {[Title] = "My Level"})
db:GetById(id)
db:Delete(id)
```

## Linking scenes

A record is about a level; the level itself is one or more scenes, saved under
their own Guids (see [Saving](/guides/saving)). A record keeps the Guids of the scenes
it is about.

```luau
db:Link(id, lobby.Guid)          -- true when the record holds it
db:Link(id, arena.Guid)
db:Unlink(id, lobby.Guid)        -- false when it was not linked

local record = db:GetById(id)
record.Scenes                    -- {guid, ...}, in link order; {} when none
Prism.Scenes.fromDataStore(DataStore, record.Scenes[1], {Name = "Arena"})
```

The Guids are a set: linking one already there writes nothing. A record links
at most **64**, because every create in a shard re-encodes the whole shard. Only
a Prism Guid is accepted; nothing checks that the scene was ever saved. Each
call is one shard write, like `Edit`, and `record.Scenes` is frozen like the
rest of a record you read.

## Browsing

A cache declares its order. `IdOrdered` says the order matches shard order,
which lets a page stop as soon as it is full — page 1 of a newest-first browse
reads one shard however many exist.

```luau
-- server
db:RegisterCache("Newest", {IdOrdered = "Desc", PageSize = 50})

local page = db:Get("Newest", 1)
print(page.Records, page.HasMore)
```

Any other order needs `Sort`, and correctness requires reading every shard: a
record in the last shard can rank first, so stopping early would return "the
most played level among the oldest 50,000" and look plausible while being wrong.

```luau
-- server
db:RegisterCache("Popular", {
    Sort = function(a, b) return a[2].Value > b[2].Value end,
    PageSize = 50,
})
```

## Searching

`Find` filters without a global ordering, so it stops as soon as it has enough.
Search by name and list by creator both go through it.

```luau
-- server
db:Find(function(record)
    return string.find(string.lower(record[1].Value), query, 1, true) ~= nil
end, 50)
```

## Caching

Three tiers: in-process, then a MemoryStore page cache shared across servers,
then the DataStore. Both cache tiers expire after 90 seconds (`Expiration`), so
a write from another server becomes visible within that window — there is no
cross-server invalidation. The writing server bypasses the shared tier for the
same window so it always reads its own writes.

Pages rather than shards are cached in MemoryStore because a MemoryStore value
caps at 32 KB while a shard is measured in megabytes.
