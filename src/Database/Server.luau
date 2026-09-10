--!strict
-- Sharded metadata storage with a three tier cache.
--
-- Layout
--
-- {Key}:Manifest  small table: shard count and the id boundary of each sealed
--                 shard. Boundaries only change when a shard seals.
-- {Key}:1..N      compressed records. Shard k covers ids in
--                 (Boundaries[k - 1], Boundaries[k]]. Only the last shard is
--                 appended to.
--
-- Ids come from a monotonic counter, so a record never changes shard: when the
-- tail shard approaches the value limit its boundary freezes and a new tail
-- opens. Nothing is moved, merged or rebalanced, and sealing is a single write
-- to the manifest, so there is no multi key transaction to get wrong.
--
-- This also removes the write contention of the old single key layout, where
-- every edit in the game did UpdateAsync against the same key: read the whole
-- corpus, decompress it, change one record, recompress, write it back. Edits to
-- different shards no longer contend at all.
--
-- Cache tiers
--
-- 1. In process pages and shards, 90s.
-- 2. MemoryStore pages, 90s. Absorbs cold servers so they do not all hit the
--    DataStore at once. Pages rather than shards because a MemoryStore value
--    caps at 32KB and a shard is measured in megabytes.
-- 3. DataStore, the source of truth.
--
-- There is no cross server invalidation: a write is visible elsewhere within the
-- expiration window. The writing server skips tier 2 for that window so it still
-- reads its own writes, and repopulates the shared page as it goes.

const MemoryStoreService = game:GetService("MemoryStoreService")
const DataStoreService = game:GetService("DataStoreService")

const PropertyTypes = require("../Properties/Types")
const Properties = require("../Properties/Server")
const Compressor = require("../Compressor")
const Encoding = require("../Encoding")
const Logger = require("../Logger")
const Types = require("./Types")
const Try = require("../Try")

export type MetadataValue = Types.MetadataValue
export type ValueTransformer<T> = Types.ValueTransformer<T>
export type Fields<T> = Types.Fields<T>
export type Metadata = Types.Metadata
export type Sort = Types.Sort
export type Predicate = Types.Predicate
export type Manifest = Types.Manifest
export type CacheConfig = Types.CacheConfig
export type Cache = Types.Cache
export type Page = Types.Page
export type Database<T> = Types.Database<T>

const MANIFEST_KEY = "Manifest"
const DEFAULT_EXPIRATION = 90
const DEFAULT_PAGE_SIZE = 50
const ATTEMPTS = 5

-- DataStore caps a value at 4MB. Sealing at 3MB leaves room for the record that
-- crosses the line to still fit.
const DEFAULT_SHARD_LIMIT = 3 * 1024 * 1024

-- MemoryStore caps a value at 32KB and base64 inflates by a third, so a page
-- past this cannot be shared however many times it is retried.
const MEMORYSTORE_VALUE_LIMIT = 31 * 1024

-- A fresh table each time: returning one shared constant would let a caller
-- mutating Records corrupt every later empty result.
const function EmptyPage(): Page
    return {Records = {}, HasMore = false}
end

-- FreezeRecords froze each record but not the array holding them, and Get hands
-- the same page table to every caller out of its cache. One table.insert or
-- table.remove on a returned page therefore rewrote what every other reader on
-- this server would see next.
const function FreezePage(Page: Page): Page
    if not table.isfrozen(Page.Records) then
        table.freeze(Page.Records)
    end

    if not table.isfrozen(Page) then
        table.freeze(Page)
    end

    return Page
end

const Database = {}

const function ShardKey<T>(self: Database<T>, Index: number): string
    return `{self.Key}:{Index}`
end

const function PageKey<T>(self: Database<T>, Cache: string, Page: number): string
    return `{self.Key}:{Cache}:{Page}`
end

--=============================================================================
-- Manifest
--=============================================================================

-- Force skips the cache. A caller about to write needs the current shard
-- layout; readers are fine with one up to Expiration old.
const function GetManifest<T>(self: Database<T>, Force: boolean?): Manifest
    if not Force and self.Manifest and os.clock() < self.ManifestExpiry then
        return self.Manifest
    end

    const Success, Stored = Try(ATTEMPTS, self.DataStore.GetAsync, self.DataStore, MANIFEST_KEY)
    if not Success then
        -- A stale manifest still addresses every existing shard correctly; only
        -- a very recent seal would be missing from it.
        return self.Manifest or {Count = 1, Boundaries = {}}
    end

    const Manifest: Manifest = if type(Stored) == "table"
        then {Count = math.max(1, Stored.Count or 1), Boundaries = Stored.Boundaries or {}}
        else {Count = 1, Boundaries = {}}

    self.Manifest = Manifest
    self.ManifestExpiry = os.clock() + self.Expiration
    return Manifest
end

-- Which shard owns an id. Boundaries are ascending, so this is a walk over a
-- handful of numbers and costs no request.
const function ShardForId(Manifest: Manifest, Id: number): number
    for Index, Boundary in Manifest.Boundaries do
        if Id <= Boundary then
            return Index
        end
    end

    return Manifest.Count
end

-- Freezes the tail shard at its current highest id and opens a new one. A single
-- manifest write, so a reader either sees the old shard set or the new one.
const function Seal<T>(self: Database<T>, LastId: number)
    const Success = Try(ATTEMPTS, self.DataStore.UpdateAsync, self.DataStore, MANIFEST_KEY, function(Old)
        const Count = if type(Old) == "table" then math.max(1, Old.Count or 1) else 1
        const Boundaries = if type(Old) == "table" then (Old.Boundaries or {}) else {}

        -- Idempotent: if the newest boundary already covers this id, another
        -- server sealed the same tail first and there is nothing to do.
        const Newest = Boundaries[#Boundaries]
        if Newest and Newest >= LastId then
            return nil
        end

        const Next = table.clone(Boundaries)
        table.insert(Next, LastId)
        return {Count = Count + 1, Boundaries = Next}
    end)

    if Success then
        self.Manifest = nil
        self.ManifestExpiry = 0
        Logger:Log(`Sealed shard for {self.Key} at id {LastId}.`)
    end
end

--=============================================================================
-- Shards
--=============================================================================

-- Returns Ok separately from an empty result. A shard that exists but fails to
-- decode must not be treated as empty: inside an UpdateAsync transform that
-- would write an empty shard back and destroy every record in it.
const function DecodeShard(Packed: any): ({Metadata}, number, boolean)
    if not Packed then
        return {}, 0, true
    end

    const Ok, LastId, Records = pcall(function()
        return Compressor:DecompressMetadatas(Packed)
    end)

    if not Ok then
        return {}, 0, false
    end

    return Records :: {Metadata}, LastId :: number, true
end

-- Get and Find hand cached record tables straight back to callers. Without this,
-- record[1]:Set(...) on a returned page silently rewrote the cache for every
-- other reader on this server, and the change never reached the DataStore.
-- Frozen, that mistake throws instead. Writes go through Edit, which decodes its
-- own copy inside the UpdateAsync transform and is unaffected.
--
-- Note this also makes OnChange unavailable on a cached record, which is correct:
-- these are read-only snapshots, not live objects.
const function FreezeRecords(Records: {Metadata})
    for _, Record in Records do
        for Key, Prop in Record do
            if type(Key) == "number" then
                table.freeze(Prop)
            end
        end

        table.freeze(Record)
    end
end

const function GetShard<T>(self: Database<T>, Index: number): ({Metadata}, number)
    const Cached = self.Shards[Index]
    if Cached and os.clock() < Cached.Expiry then
        return Cached.Records, Cached.LastId
    end

    const Success, Packed = Try(ATTEMPTS, self.DataStore.GetAsync, self.DataStore, ShardKey(self, Index))
    if not Success then
        if Cached then
            return Cached.Records, Cached.LastId
        end

        return {}, 0
    end

    const Records, LastId, Ok = DecodeShard(Packed)
    if not Ok then
        Logger:Warn(`Shard {Index} of {self.Key} failed to decode.`)
        if Cached then
            return Cached.Records, Cached.LastId
        end

        return {}, 0
    end

    FreezeRecords(Records)

    self.Shards[Index] = {
        Records = Records,
        LastId = LastId,
        Expiry = os.clock() + self.Expiration,
    }

    self.ShardEpoch += 1
    return Records, LastId
end

const function DropLocal<T>(self: Database<T>)
    table.clear(self.Shards)
    table.clear(self.Pages)

    -- The epoch alone would force a rebuild, but clearing releases the copy of
    -- the corpus a sorted cache is holding instead of retaining it until the
    -- next read.
    for _, Cache in self.Caches do
        Cache.Sorted = nil
        Cache.SortedEpoch = nil
    end

    self.ShardEpoch += 1
end

-- Called after any successful write. Local caches go immediately; the shared
-- MemoryStore tier is skipped for the expiration window rather than deleted,
-- because a write can shift every page and there is no cheap way to enumerate
-- them.
const function AfterWrite<T>(self: Database<T>)
    DropLocal(self)
    self.BypassUntil = os.clock() + self.Expiration
end

-- Which shard actually holds an id.
--
-- ShardForId answers from the manifest, and the manifest is cached for the
-- expiration window. If another server sealed the tail inside that window, this
-- server can have appended a record to the old tail whose id now falls past
-- that shard's frozen boundary, so the manifest points at the shard after the
-- one the record is really in. Listings walk every shard and still showed it,
-- while GetById, Edit and Delete looked only where the manifest said and came
-- back empty.
--
-- The expected shard is checked first, so the common path is still one read.
const function LocateShard<T>(self: Database<T>, Id: number): number
    const Manifest = GetManifest(self)
    const Expected = ShardForId(Manifest, Id)

    -- Assigned first rather than iterated inline: GetShard returns the records
    -- and the shard's last id, and feeding both into a generic for puts that
    -- second value in the loop's state slot. CollectOrdered already reads it
    -- this way; the rest of the file now matches.
    const Here = GetShard(self, Expected)
    for _, Record in Here do
        if Record.Id == Id then
            return Expected
        end
    end

    -- Only the shard immediately before it can hold a stranded record: the case
    -- is a record appended to a tail that another server sealed underneath this
    -- one, which leaves it exactly one shard behind where the boundary now
    -- points. Scanning the rest would pull the whole corpus into memory every
    -- time a caller passes an id that does not exist.
    const Previous = Expected - 1
    if Previous >= 1 then
        const Behind = GetShard(self, Previous)
        for _, Record in Behind do
            if Record.Id == Id then
                return Previous
            end
        end
    end

    -- Neither: keep the manifest's answer so a caller acting on an id that does
    -- not exist yet still targets the shard the layout says owns it.
    return Expected
end

--=============================================================================
-- Reading
--=============================================================================

const function __register_cache<T>(self: Database<T>, Name: string, Config: CacheConfig)
    if self.Caches[Name] then
        Logger:Error(`Cache {Name} is already registered.`)
    end

    if not Config.IdOrdered and not Config.Sort then
        Logger:Error(`Cache {Name} needs either IdOrdered or Sort.`)
    end

    self.Caches[Name] = {
        Name = Name,
        PageSize = math.max(1, Config.PageSize or DEFAULT_PAGE_SIZE),
        IdOrdered = Config.IdOrdered,
        Sort = Config.Sort,
    }
end

-- Id ordered paging. Shard order already matches result order, so shards are
-- read one at a time and the walk stops as soon as the page is full. Page 1 of
-- a "newest first" browse touches exactly one shard however many exist.
const function CollectOrdered<T>(self: Database<T>, Cache: Cache, Page: number): Page
    const Manifest = GetManifest(self)
    const Descending = Cache.IdOrdered == "Desc"
    const Skip = (Page - 1) * Cache.PageSize

    -- One past the page so HasMore is known without a second request.
    const Wanted = Cache.PageSize + 1
    const Collected = {}
    local Skipped = 0

    for Step = 1, Manifest.Count do
        const Index = if Descending then Manifest.Count - Step + 1 else Step
        const Records = GetShard(self, Index)
        const Count = #Records

        if Skipped + Count <= Skip then
            Skipped += Count
            continue
        end

        for Offset = 1, Count do
            const Record = if Descending then Records[Count - Offset + 1] else Records[Offset]
            if not Record then
                continue
            end

            if Skipped < Skip then
                Skipped += 1
                continue
            end

            table.insert(Collected, Record)
            if #Collected >= Wanted then
                break
            end
        end

        if #Collected >= Wanted then
            break
        end
    end

    const HasMore = #Collected > Cache.PageSize
    if HasMore then
        table.remove(Collected)
    end

    return {Records = Collected, HasMore = HasMore}
end

-- Any other order. A record in the last shard can rank first, so stopping early
-- would silently return the wrong page: every shard is read, then sorted.
const function CollectSorted<T>(self: Database<T>, Cache: Cache, Page: number): Page
    local All = Cache.Sorted

    -- Rebuilt only when a shard actually changed underneath it, so paging
    -- through a sorted browse sorts once rather than once per page.
    if not All or Cache.SortedEpoch ~= self.ShardEpoch then
        const Manifest = GetManifest(self)
        const Collected = {}

        for Index = 1, Manifest.Count do
            const Records = GetShard(self, Index)
            for _, Record in Records do
                table.insert(Collected, Record)
            end
        end

        table.sort(Collected, Cache.Sort :: Sort)

        All = Collected
        Cache.Sorted = Collected
        Cache.SortedEpoch = self.ShardEpoch
    end

    const Sorted = All :: {Metadata}
    const StartIndex = (Page - 1) * Cache.PageSize + 1
    const EndIndex = math.min(Page * Cache.PageSize, #Sorted)
    if StartIndex > EndIndex then
        return EmptyPage()
    end

    return {
        Records = table.move(Sorted, StartIndex, EndIndex, 1, {}),
        HasMore = EndIndex < #Sorted,
    }
end

const function __get<T>(self: Database<T>, CacheName: string, Page: number?): Page
    const Cache = self.Caches[CacheName]
    if not Cache then
        Logger:Warn(`Cache {CacheName} is not registered for {self.Key}.`)
        return FreezePage(EmptyPage())
    end

    const At = math.max(1, Page or 1)
    const Key = PageKey(self, CacheName, At)
    const Now = os.clock()

    const Local = self.Pages[Key]
    if Local and Now < Local.Expiry then
        return Local.Page
    end

    const Bypassing = Now < self.BypassUntil
    if not Bypassing then
        const Success, Stored = Try(ATTEMPTS, self.MemoryStore.GetAsync, self.MemoryStore, Key)
        if Success and type(Stored) == "table" and type(Stored.Data) == "string" then
            const Ok, Records = pcall(function()
                const _, Decoded = Compressor:DecompressMetadatas(Encoding.Decode(Stored.Data))
                return Decoded
            end)

            if Ok then
                FreezeRecords(Records :: {Metadata})
                const Result = FreezePage({Records = Records :: {Metadata}, HasMore = Stored.HasMore == true})
                self.Pages[Key] = {Page = Result, Expiry = Now + self.Expiration}
                return Result
            end
        end
    end

    const Collected = if Cache.IdOrdered
        then CollectOrdered(self, Cache, At)
        else CollectSorted(self, Cache, At)

    const Result = FreezePage(Collected)

    self.Pages[Key] = {Page = Result, Expiry = os.clock() + self.Expiration}

    -- Repopulate the shared tier, including on the bypass path: the data just
    -- came from the DataStore, so it is the freshest anyone has.
    const Ok, Encoded = pcall(function()
        return Encoding.Encode(Compressor:CompressMetadatas(0, Result.Records))
    end)

    -- An oversized page is skipped rather than attempted: SetAsync would refuse
    -- the value, and Try would spend three attempts with backoff on a failure
    -- that cannot succeed, on every single cache miss.
    if Ok and #(Encoded :: string) <= MEMORYSTORE_VALUE_LIMIT then
        Try(3, self.MemoryStore.SetAsync, self.MemoryStore, Key, {
            Data = Encoded,
            HasMore = Result.HasMore,
        }, self.Expiration)
    end

    return Result
end

-- One shard read rather than a scan of everything.
const function __get_by_id<T>(self: Database<T>, Id: number): Metadata?
    if not Id then
        return nil
    end

    const Records = GetShard(self, LocateShard(self, Id))
    for _, Record in Records do
        if Record.Id == Id then
            return Record
        end
    end

    return nil
end

-- Filtering with no global ordering, so it can stop as soon as it has enough.
-- Search by name and list by creator both land here.
const function __find<T>(self: Database<T>, Predicate: Predicate, Limit: number?): {Metadata}
    const Manifest = GetManifest(self)
    const Wanted = Limit or math.huge
    const Found = {}

    for Index = 1, Manifest.Count do
        const Records = GetShard(self, Index)
        for _, Record in Records do
            if Predicate(Record) then
                table.insert(Found, Record)
                if #Found >= Wanted then
                    return Found
                end
            end
        end
    end

    return Found
end

--=============================================================================
-- Writing
--=============================================================================

-- Every record gets its own Property instances. A shallow clone of
-- InitialMetadata gave every record in the database one shared set of property
-- tables, so editing any record rewrote all of them.
const function BuildMetadata<T>(self: Database<T>, Id: number): Metadata
    const New = {
        Id = Id,
        SavedVersion = 0,
        PublishedVersion = 0,
    }

    for _, Template in self.InitialMetadata do
        const Prop = Properties.new(Template.Parent)
        Prop:Set(Template.Value)
        table.insert(New, Prop)
    end

    return New :: any
end

const function __create<T>(self: Database<T>): (boolean, number?)
    -- Read through rather than trusting the cached copy. A stale manifest here
    -- means appending to a tail another server already sealed, stranding the new
    -- record in a shard whose boundary no longer covers its id. Creates are rare
    -- enough that the extra request does not matter.
    const Manifest = GetManifest(self, true)
    const Index = Manifest.Count

    -- A fresh tail shard has no records, so its id counter continues from the
    -- boundary the previous shard was sealed at.
    const Floor = Manifest.Boundaries[Index - 1] or 0

    local Created: number? = nil
    local Size = 0

    const Success = Try(ATTEMPTS, self.DataStore.UpdateAsync, self.DataStore, ShardKey(self, Index), function(Old)
        const Records, StoredLastId, Ok = DecodeShard(Old)
        if not Ok then
            return nil
        end

        const LastId = math.max(StoredLastId, Floor) + 1

        table.insert(Records, BuildMetadata(self, LastId))

        const Packed = Compressor:CompressMetadatas(LastId, Records)
        Created = LastId
        Size = buffer.len(Packed)
        return Packed
    end)

    if not Success then
        return false, nil
    end

    AfterWrite(self)

    -- Sealing is deliberately outside the transform: UpdateAsync may run its
    -- callback more than once, and a seal must happen exactly once per commit.
    if Size >= self.ShardLimit and Created then
        Seal(self, Created)
    end

    return true, Created
end

const function __edit<T>(self: Database<T>, Id: number, ToChange: {[PropertyTypes.PropertyIdentifier]: any}): boolean
    const Valid = {}
    local IsAnyValid = false

    for PropId, Value in ToChange do
        const Property = Properties:GetRegistry(PropId)
        if not Property then
            Logger:Warn(`Cannot set unregistered property {PropId}. Will be skipped`)
            continue
        end

        if not PropertyTypes:IsValid(Property.Type, Value, Property.Constraints) then
            Logger:Warn(`Value {Value} is not valid for property {Property.Name} (id {PropId}). Will be skipped`)
            continue
        end

        Valid[PropId] = Value
        IsAnyValid = true
    end

    if not IsAnyValid then
        return false
    end

    const Index = LocateShard(self, Id)
    local Found = false
    local Dirty = false

    const Success = Try(ATTEMPTS, self.DataStore.UpdateAsync, self.DataStore, ShardKey(self, Index), function(Old)
        -- Rebuilt from Old on every attempt: UpdateAsync can retry, and carrying
        -- state across attempts would apply an edit twice.
        Found = false
        Dirty = false
        if not Old then
            return nil
        end

        const Records, LastId, Ok = DecodeShard(Old)
        if not Ok then
            return nil
        end

        const Remaining = table.clone(Valid)

        for _, Record in Records do
            if Record.Id ~= Id then
                continue
            end

            for Key, Prop in Record do
                if type(Key) ~= "number" then
                    continue
                end

                if Remaining[Prop.Parent] ~= nil then
                    -- Accepted and Changed are separate: setting a property to
                    -- the value it already holds is a successful edit with
                    -- nothing to persist. Treating that as a write meant every
                    -- no-op edit cost a full shard rewrite.
                    const Accepted, Changed = Prop:Set(Remaining[Prop.Parent])
                    if Accepted then
                        Found = true
                        Dirty = Dirty or Changed
                    end

                    Remaining[Prop.Parent] = nil
                end
            end

            for PropId, Value in Remaining do
                const NewProperty = Properties.new(PropId)
                if NewProperty:Set(Value) then
                    Found = true
                    Dirty = true
                    table.insert(Record, NewProperty)
                end
            end

            break
        end

        if not Found or not Dirty then
            return nil
        end

        return Compressor:CompressMetadatas(LastId, Records)
    end)

    if Dirty and Success then
        AfterWrite(self)
    end

    return Found and Success
end

const function __delete<T>(self: Database<T>, Id: number): boolean
    if not Id then
        return false
    end

    const Index = LocateShard(self, Id)
    local Found = false

    const Success = Try(ATTEMPTS, self.DataStore.UpdateAsync, self.DataStore, ShardKey(self, Index), function(Old)
        Found = false
        if not Old then
            return nil
        end

        const Records, LastId, Ok = DecodeShard(Old)
        if not Ok then
            return nil
        end

        for Position, Record in Records do
            if Record.Id == Id then
                table.remove(Records, Position)
                Found = true
                break
            end
        end

        if not Found then
            return nil
        end

        -- LastId is preserved so a deleted id is never handed out again.
        return Compressor:CompressMetadatas(LastId, Records)
    end)

    if Found and Success then
        AfterWrite(self)
    end

    return Found and Success
end

const function __refresh<T>(self: Database<T>)
    DropLocal(self)
    self.Manifest = nil
    self.ManifestExpiry = 0
end

function Database.new<T>(Config: {
    Key: string,
    InitialMetadata: {PropertyTypes.Property<T>},
    Expiration: number?,
    ShardLimit: number?,
}): Database<T>
    const db = {}
    db.Key = Config.Key
    db.InitialMetadata = Config.InitialMetadata

    -- Every record reads and writes these, so none of them may be unregistered
    -- while the database stands.
    for _, Template in Config.InitialMetadata do
        Properties.Retain(Template.Parent)
    end
    db.Expiration = Config.Expiration or DEFAULT_EXPIRATION
    db.ShardLimit = Config.ShardLimit or DEFAULT_SHARD_LIMIT

    db.DataStore = DataStoreService:GetDataStore(Config.Key)
    db.MemoryStore = MemoryStoreService:GetHashMap(Config.Key)

    db.Caches = {}
    db.Shards = {}
    db.Pages = {}
    db.ShardEpoch = 0

    db.Manifest = nil
    db.ManifestExpiry = 0
    db.BypassUntil = 0

    db.RegisterCache = __register_cache
    db.Create = __create
    db.Get = __get
    db.GetById = __get_by_id
    db.Find = __find
    db.Edit = __edit
    db.Delete = __delete
    db.Refresh = __refresh

    return db :: any
end

return Database
