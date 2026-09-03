const MemoryStoreService = game:GetService("MemoryStoreService")
const DataStoreService = game:GetService("DataStoreService")

const PropertyTypes = require("../Properties/Types")
const Properties = require("../Properties/Server")
const Compressor = require("../Compressor")
const Logger = require("../Logger")
const Types = require("./Types")
const Try = require("../Try")

export type MetadataValue = Types.MetadataValue
export type ValueTransformer<T> = Types.ValueTransformer<T>
export type Fields<T> = Types.Fields<T>
export type Metadata = Types.Metadata
export type DatabaseConfig = Types.DatabaseConfig
export type Cache = Types.Cache
export type Database<T> = Types.Database<T>

const Database = {}

const CACHE_RADIUS = 3
const CACHE_PAGE_COUNT = CACHE_RADIUS * 2 + 1

const function GetCacheBlock(Page: number): number
	return (Page - 1) // CACHE_PAGE_COUNT
end

const function GetCacheKey(Cache: string, Page: number): string
	const Block = GetCacheBlock(Page)
	return `{Cache}:{Block}`
end

const function FetchMetadatas<T>(self: Database<T>)
    local Success, Metadatas = Try(5, self.DataStore.GetAsync, self.DataStore, "Metadatas")
    if not Success then
        return
    end

    return Metadatas
end

const function GetCacheStorage(Metadatas, Sort, Page, PageSize): buffer
    const Sorted = table.clone(Metadatas)
	table.sort(Sorted, Sort)

	const Block = GetCacheBlock(Page)

	const FirstPage = Block * CACHE_PAGE_COUNT + 1
	const LastPage = math.min(
		FirstPage + CACHE_PAGE_COUNT - 1,
		math.ceil(#Sorted / PageSize)
	)

	const Pages = {}
	for Index = FirstPage, LastPage do
		const StartIndex = (Index - 1) * PageSize + 1
		const EndIndex = math.min(Index * PageSize, #Sorted)

		Pages[Index] = table.move(
			Sorted,
			StartIndex,
			EndIndex,
			1, {}
		)
	end

	return Compressor:CompressMetadatas(0, Pages)
end

const function __register_cache<T>(self: Database<T>, Name: string, Sort: (A: Metadata, B: Metadata) -> boolean, Expiration: number?, PageSize: number?)
    if self.Caches[Name] then
        Logger:Error(`Cache {Name} is already registered.`)
    end

    self.Caches[Name] = {
        Expiration = Expiration or 300,
        PageSize = PageSize or 100,
        Sort = Sort,
    }
end

const function __update_cache<T>(self: Database<T>, Cache: string, Page: number)
    const Info = self.Caches[Cache]
	if not Info then
		return {}
	end

	const Packed = FetchMetadatas(self)
	if not Packed then
		return {}
	end

	const _, Metadatas = Compressor:DecompressMetadatas(Packed)
	const Pages = GetCacheStorage(Metadatas, Info.Sort, Page, Info.PageSize)
	Try(5, self.MemoryStore.SetAsync, self.MemoryStore, GetCacheKey(Cache, Page), Pages, Info.Expiration)
	return Pages
end

const function __get_cache<T>(self: Database<T>, Cache: string, Page: number)
    const Key = GetCacheKey(Cache, Page)
	local Success, Pages = Try(5, self.MemoryStore.GetAsync, self.MemoryStore, Key)
	if not Success then
		return {}
	end

	if not Pages then
		Pages = __update_cache(self, Cache, Page)
		if not Pages then
			return {}
		end
	end

    const Decompressed = Compressor:DecompressMetadatas(Pages)
	return Decompressed[Page] or {}
end

const function __get<T>(self: Database<T>, Cache: string, Page: number?)
    if not self.Caches[Cache] then
        Logger:Warn(`Cache {Cache} is not registered for {self.Key}.`)
        return {}
    end

    Page = Page or 1
    return __get_cache(self, Cache, Page :: number)
end

const function __create<T>(self: Database<T>): boolean
    const Success = Try(5, self.DataStore.UpdateAsync, self.DataStore, "Metadatas", function(Old)
        local LastId, Metadatas = 0, {}
        if Old then
            LastId, Metadatas = Compressor:DecompressMetadatas(Old)
        end

        LastId += 1

        const New = table.clone(self.InitialMetadata)
        New.Id = LastId
        New.SavedVersion = 0
        New.PublishedVersion = 0
        table.insert(Metadatas, New)

        return Compressor:CompressMetadatas(LastId, Metadatas) or Old
    end)

    return Success
end

const function __edit<T>(self: Database<T>, Id: number, ToChange: {[Properties.PropertyIdentifier]: any}): boolean
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

    local Found = false
    const Success = Try(5, self.DataStore.UpdateAsync, self.DataStore, "Metadatas", function(Old)
        local LastId, Metadatas = 0, {}
        if Old then
            LastId, Metadatas = Compressor:DecompressMetadatas(Old)
        end

        for _, Metadata in Metadatas do
            if Metadata.Id ~= Id then
                continue
            end

            for i, Prop in Metadata do
                if type(i) ~= "number" then
                    continue
                end

                if Valid[Prop.Id] ~= nil then
                    const Worked = Prop:Set(Valid[Prop.Id])
                    Valid[Prop.Id] = nil
                    
                    if Worked then
                        Found = true
                    end
                end

                -- New properties
                for Id, Value in Valid do
                    const NewProperty = Properties.new(Id)
                    const Worked = NewProperty:Set(Value)
                    Valid[Id] = nil

                    if Worked then
                        Found = true
                    end
                end
            end

            break
        end

        return Found and Compressor:CompressMetadatas(LastId, Metadatas) or Old
    end)

    return Found and Success
end

const function __delete<T>(self: Database<T>, Id: number): boolean
    if not Id then
        return false
    end

    const Success = Try(5, self.DataStore.UpdateAsync, self.DataStore, "Metadatas", function(Old)
        local LastId, Metadatas = 0, {}
        if Old then
            LastId, Metadatas = Compressor:DecompressMetadatas(Old)
        end

        local Found = false
        for i, Metadata in Metadatas do
            if Metadata.Id == Id then
                table.remove(Metadatas, i)
                Found = true
                break
            end
        end

        return Found and Compressor:CompressMetadatas(LastId, Metadatas) or Old
    end)

    return Success
end

function Database.new<T>(Config: DatabaseConfig): Database<T>
    const db = {}
    db.Key = Config.Key
    db.InitialMetadata = Config.InitialMetadata

    db.DataStore = DataStoreService:GetDataStore(db.Key)
    db.MemoryStore = MemoryStoreService:GetHashMap(db.Key)
    db.Caches = {}

    db.RegisterCache = __register_cache
    db.Create = __create
    db.Get = __get
    
    return db
end

return Database