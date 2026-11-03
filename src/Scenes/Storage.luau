--!strict
-- Where a scene is stored: the keys it is written under, the writes and reads,
-- and the listings of its versions and backups. Nothing here knows what a
-- scene holds; Scenes/Server hands it the pack.

const Handles = require("../Handles")
const Logger = require("../Logger")
const Try = require("../Try")
const Types = require("./Types")

const Storage = {}

const SAVE_ATTEMPTS = 5

-- Every key a scene is stored under starts with its Guid. A draft and a
-- published pack are one key each, overwritten in place: their history is the
-- DataStore's own versions, which it keeps for thirty days. A backup is a key
-- of its own per call, so it outlives that, and nothing here ever deletes one.
function Storage.KeyOf(Guid: string, Which: string): string
    return `{Guid}:{Which}`
end

function Storage.BackupKey(Guid: string, Id: number): string
    return Storage.KeyOf(Guid, `Backup:{Id}`)
end

-- The buffer itself rather than buffer.tostring of it. A DataStore only takes
-- a string that is valid UTF-8, and a pack is binary through and through: any
-- byte past 127 that does not open a UTF-8 sequence makes the write fail.
function Storage.Write(Store: DataStore, Key: string, Pack: buffer, Name: string): boolean
    const Success = Try(SAVE_ATTEMPTS, Store.SetAsync, Store, Key, Pack)
    if not Success then
        Logger:Warn(`Failed to write scene {Name} to key {Key}.`)
    end

    return Success
end

-- Climbs within a server, so two backups in the same millisecond do not land on
-- one key and leave the first unreachable.
local LastBackup = 0

function Storage.NextBackupId(): number
    const Id = math.max(DateTime.now().UnixTimestampMillis, LastBackup + 1)
    LastBackup = Id
    return Id
end

-- Which stored pack fromDataStore reads, and how: the current draft or
-- published pack, one of the DataStore's own versions of either, or a backup.
-- Returns where it read from, or nil for a source that names no single pack --
-- a table naming two would otherwise read whichever was checked first.
function Storage.ReadStored(Store: DataStore, Guid: string, Source: Types.SceneSource): (boolean, any, string?)
    if Source == "Draft" or Source == "Published" then
        const Key = Storage.KeyOf(Guid, Source)
        const Success, Stored = Try(SAVE_ATTEMPTS, Store.GetAsync, Store, Key, nil)
        return Success, Stored, Key
    end

    if type(Source) ~= "table" then
        return false, nil, nil
    end

    -- Through any: SceneSource's table half has named fields and no indexer,
    -- and counting what is in it is exactly what has to be done to one.
    local Named = 0
    for _ in Source :: any do
        Named += 1
    end

    if Named ~= 1 then
        return false, nil, nil
    end

    if type(Source.Backup) == "number" then
        const Key = Storage.BackupKey(Guid, Source.Backup)
        const Success, Stored = Try(SAVE_ATTEMPTS, Store.GetAsync, Store, Key, nil)
        return Success, Stored, Key
    end

    const Which = if type(Source.Draft) == "string" then "Draft" elseif type(Source.Published) == "string" then "Published" else nil
    if not Which then
        return false, nil, nil
    end

    const Version = (Source.Draft or Source.Published) :: string
    const Key = Storage.KeyOf(Guid, Which)
    const Success, Stored = Try(SAVE_ATTEMPTS, Store.GetVersionAsync, Store, Key, Version)
    return Success, Stored, `{Key} at version {Version}`
end

-- How many entries a listing asks the DataStore for at once.
const LIST_PAGE_SIZE = 100

-- The DataStore's own history of a draft or a published pack, newest first:
-- every write in the last thirty days, which is as long as it keeps them. Nil
-- when the listing could not be read. Limit caps how many come back; a scene
-- saved on every edit has a great many.
function Storage.ListVersions(Store: DataStore, Guid: string, Which: "Draft" | "Published", Limit: number?): {Types.SceneVersion}?
    if not Handles.IsGuid(Guid) then
        Logger:Warn(`{Guid} is not a scene Guid.`)
        return nil
    end

    -- Anything else names a key nothing writes, and would list as no versions
    -- at all rather than as a mistake.
    if Which ~= "Draft" and Which ~= "Published" then
        Logger:Warn(`Versions are kept of "Draft" and "Published", not {Which}. Backups are listed by ListBackups.`)
        return nil
    end

    const Wanted = Limit or math.huge
    const Success, Versions = Try(SAVE_ATTEMPTS, function(): {Types.SceneVersion}
        const Found: {Types.SceneVersion} = {}
        const Pages = Store:ListVersionsAsync(Storage.KeyOf(Guid, Which), Enum.SortDirection.Descending, 0, 0, math.min(Wanted, LIST_PAGE_SIZE))

        while true do
            for _, Info in Pages:GetCurrentPage() do
                -- A version the key was removed at holds no pack to read.
                if Info.IsDeleted then
                    continue
                end

                table.insert(Found, {Version = Info.Version, Time = Info.CreatedTime})
                if #Found >= Wanted then
                    return Found
                end
            end

            if Pages.IsFinished then
                return Found
            end

            Pages:AdvanceToNextPageAsync()
        end
    end)

    if not Success then
        Logger:Warn(`Failed to list versions of scene {Guid}.`)
        return nil
    end

    return Versions
end

-- Every backup of a scene, newest first, shaped like a version: Backup is the
-- id fromDataStore takes back as {Backup = id}, as Version is for a version.
-- The id is the moment it was taken, so Time is the same number. Nil when the
-- listing could not be read.
--
-- Limit cuts the list after sorting rather than stopping the walk early: keys
-- list in name order, which is oldest first, so the newest are the last read.
function Storage.ListBackups(Store: DataStore, Guid: string, Limit: number?): {Types.SceneBackup}?
    if not Handles.IsGuid(Guid) then
        Logger:Warn(`{Guid} is not a scene Guid.`)
        return nil
    end

    const Prefix = Storage.KeyOf(Guid, "Backup:")
    const Success, Ids = Try(SAVE_ATTEMPTS, function(): {number}
        const Found: {number} = {}
        const Pages = Store:ListKeysAsync(Prefix, LIST_PAGE_SIZE, "", true)

        while true do
            for _, Key in Pages:GetCurrentPage() do
                const Id = tonumber(string.sub(Key.KeyName, #Prefix + 1))
                if Id then
                    table.insert(Found, Id)
                end
            end

            if Pages.IsFinished then
                return Found
            end

            Pages:AdvanceToNextPageAsync()
        end
    end)

    if not Success then
        Logger:Warn(`Failed to list backups of scene {Guid}.`)
        return nil
    end

    table.sort(Ids, function(A: number, B: number): boolean
        return A > B
    end)

    const Backups: {Types.SceneBackup} = {}
    for Index = 1, math.min(#Ids, Limit or math.huge) do
        table.insert(Backups, {Backup = Ids[Index], Time = Ids[Index]})
    end

    return Backups
end

return Storage
