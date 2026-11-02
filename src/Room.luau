--!strict
-- Maps keyed by something every object has, that give their room back.
--
-- A Luau table keeps the room it grew to after its keys are gone, and only gives
-- it back when it rehashes, which only an insert into a full table does. A map
-- filled by a 34,918-object level and emptied by unloading it held 2 MB of room
-- on the server, for objects that no longer existed, until the next load filled
-- it again. There is no way to shrink a table in place, so a map that falls to a
-- quarter of the most it held is copied into a fresh one holding only what is
-- live, and the caller keeps the copy.
--
-- A quarter, so each copy costs at most a third of the removals that led to it,
-- and a map that fills and empties by a little either way is never copied twice
-- for it. Below MIN_PEAK the room is too small to be worth a copy.

const Room = {}

const MIN_PEAK = 1024

type Count = {Live: number, Peak: number}

-- Weak, so a map the caller replaced or dropped takes its count with it.
const Counts: {[any]: Count} = setmetatable({}, {__mode = "k"}) :: any

-- An empty map. Mode is a weak table's __mode, kept across every copy.
function Room.new(Mode: string?): any
    const Map = if Mode then setmetatable({}, {__mode = Mode}) else {}
    Counts[Map] = {Live = 0, Peak = 0}
    return Map
end

-- Map[Key] = Value, counted. Writing a key that is already there is not a new
-- entry, so a part streaming back in and tracked again is counted once.
function Room.Put(Map: any, Key: any, Value: any)
    const Count = Counts[Map]
    if Map[Key] == nil then
        Count.Live += 1
        if Count.Live > Count.Peak then
            Count.Peak = Count.Live
        end
    end

    Map[Key] = Value
end

-- Map[Key] = nil, and the map to keep using: Map itself, or a fresh copy of it
-- once it has emptied out far enough. A weak map may have lost entries to the
-- collector without being told, so its count can run high; a copy counts again.
function Room.Take(Map: any, Key: any): any
    if Map[Key] == nil then
        return Map
    end

    Map[Key] = nil

    const Count = Counts[Map]
    Count.Live = math.max(Count.Live - 1, 0)
    if Count.Peak < MIN_PEAK or Count.Live * 4 > Count.Peak then
        return Map
    end

    const Meta = getmetatable(Map)
    const Fresh = if Meta then setmetatable({}, {__mode = Meta.__mode}) else {}
    local Live = 0
    for K, V in Map do
        Fresh[K] = V
        Live += 1
    end

    Counts[Fresh] = {Live = Live, Peak = Live}
    return Fresh
end

-- How many entries a map holds and the most it has held since it was last
-- copied, for tests and for anyone checking what the room costs.
function Room.CountOf(Map: any): (number, number)
    const Count = Counts[Map]
    if not Count then
        return 0, 0
    end

    return Count.Live, Count.Peak
end

return Room
