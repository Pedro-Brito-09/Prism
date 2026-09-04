--!strict
const PropertyTypes = require("../Properties/Types")
const CustomEnum = require("../CustomEnum")

export type MetadataValue = string | number | boolean | Color3 | Vector3 | CFrame | EnumItem | CustomEnum.RegisteredOption<any>

export type ValueTransformer<T> = (Value: T) -> MetadataValue
export type Fields<T> = {[string]: MetadataValue | ValueTransformer<T>}

export type Metadata = {
    Id: number,
    SavedVersion: number,
    PublishedVersion: number,

    [number]: PropertyTypes.Property<any>,
}

export type Sort = (A: Metadata, B: Metadata) -> boolean
export type Predicate = (Metadata: Metadata) -> boolean

-- Shard k covers ids in (Boundaries[k - 1], Boundaries[k]]. The last shard has
-- no upper boundary and is the only one new records are appended to.
export type Manifest = {
    Count: number,
    Boundaries: {number},
}

export type CacheConfig = {
    PageSize: number?,

    -- Declares that this cache's order matches shard order, which is the only
    -- case where paging may stop before reading every shard. Ids come from a
    -- monotonic counter, so "Asc" is oldest first and "Desc" is newest first.
    --
    -- Leave nil and supply Sort for any other order. A sort by plays or name
    -- can rank a record from the last shard first, so every shard has to be
    -- read before the page is correct.
    IdOrdered: ("Asc" | "Desc")?,
    Sort: Sort?,
}

export type Cache = {
    Name: string,
    PageSize: number,
    IdOrdered: ("Asc" | "Desc")?,
    Sort: Sort?,

    -- Sorted caches have to read every shard, so without memoising this a
    -- second page re-sorted the entire corpus. Epoch is the shard epoch the
    -- array was built at; a mismatch means a shard reloaded underneath it.
    Sorted: {Metadata}?,
    SortedEpoch: number?,
}

export type Page = {
    Records: {Metadata},
    HasMore: boolean,
}

export type ShardCache = {
    Records: {Metadata},
    LastId: number,
    Expiry: number,
}

export type Database<T> = {
    Key: string,
    InitialMetadata: {PropertyTypes.Property<T>},
    Expiration: number,
    ShardLimit: number,

    DataStore: GlobalDataStore,
    MemoryStore: MemoryStoreHashMap,

    Caches: {[string]: Cache},
    Shards: {[number]: ShardCache},
    Pages: {[string]: {Page: Page, Expiry: number}},

    -- Bumped whenever a shard is loaded or dropped, so a memoised sort knows
    -- its input changed without every cache having to be notified.
    ShardEpoch: number,

    Manifest: Manifest?,
    ManifestExpiry: number,
    -- Set after this server writes. Until it passes, reads skip the shared
    -- MemoryStore tier so the writer sees its own change instead of the stale
    -- page another server cached.
    BypassUntil: number,

    RegisterCache: (self: Database<T>, Name: string, Config: CacheConfig) -> (),
    Create: (self: Database<T>) -> (boolean, number?),
    Get: (self: Database<T>, Cache: string, Page: number?) -> Page,
    GetById: (self: Database<T>, Id: number) -> Metadata?,
    Find: (self: Database<T>, Predicate: Predicate, Limit: number?) -> {Metadata},
    Edit: (self: Database<T>, Id: number, ToChange: {[number]: any}) -> boolean,
    Delete: (self: Database<T>, Id: number) -> boolean,
    Refresh: (self: Database<T>) -> (),
}

return true
