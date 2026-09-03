const PropertyTypes = require("../Properties/Types")
const CustomEnum = require("../CustomEnum")

export type MetadataValue = string | number | boolean | Color3 | Vector3 | CFrame | Enum | CustomEnum.CustomEnum<any>

export type ValueTransformer<T> = (Value: T) -> MetadataValue
export type Fields<T> = {[string]: MetadataValue | ValueTransformer<T>}

export type Metadata = {
    Id: number,
    SavedVersion: number,
    PublishedVersion: number,

    [number]: PropertyTypes.Property<any>,
}

export type DatabaseConfig = {
    Key: string,
    InitialMetadata: {[string]: MetadataValue},
}

export type Cache = {
    Expiration: number,
    PageSize: number,
    Sort: (A: Metadata, B: Metadata) -> boolean,
}

export type Database<T> = {
    Key: string,
    InitialMetadata: {PropertyTypes.Property<T>},

    DataStore: GlobalDataStore,
    MemoryStore: MemoryStoreHashMap,
    Caches: {[string]: Cache},
}

return true