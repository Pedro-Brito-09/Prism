--!strict
-- Registry id allocation.
--
-- The previous per module GetNextFreeId scanned the whole registry on every call
-- and could never hand out an id below the lowest one already taken, so a pool
-- holding only id 2 would allocate 3 and leak 1 forever. This keeps a counter
-- plus a free set instead: O(1), reuses released ids, and refuses to hand out
-- anything the wire format cannot carry.

const Logger = require("./Logger")

export type IdPool = {
    Counter: number,
    Max: number,
    Recycle: boolean,
    Used: {[number]: true},
    Free: {[number]: true},

    Claim: (self: IdPool) -> number?,
    Release: (self: IdPool, Id: number) -> (),
    IsUsed: (self: IdPool, Id: number) -> boolean,
}

const IdPool = {}

-- The pool hands out ids and is never told which one to hand out. It used to
-- take one, for registries that wanted to pin an id, and that was a way to
-- reuse a retired one: an explicit claim only checked whether the id was in use
-- now, not whether it had ever been. Unregister a Number property called Plays,
-- register a Number called Rating under its old id, and every saved record
-- applies its Plays value as a Rating -- the types match, so nothing detects
-- it. Not being able to ask is what makes that unreachable.
const function __claim(self: IdPool): number?
    const Reused = next(self.Free)
    if Reused then
        self.Free[Reused] = nil
        self.Used[Reused] = true
        return Reused
    end

    if self.Counter >= self.Max then
        Logger:Error(`Id pool exhausted (max {self.Max}).`)
    end

    self.Counter += 1
    self.Used[self.Counter] = true
    return self.Counter
end

const function __release(self: IdPool, Id: number)
    if not self.Used[Id] then
        return
    end

    self.Used[Id] = nil

    -- A recycled id is silent corruption for anything persisted. Unregister a
    -- Number property called Plays, register a Number called Rating, let it
    -- reuse the same id, and every saved record applies its old Plays value as
    -- a Rating -- the types match, so nothing detects it.
    if self.Recycle then
        self.Free[Id] = true
    end
end

const function __is_used(self: IdPool, Id: number): boolean
    return self.Used[Id] == true
end

-- Recycle defaults to true, which suits runtime ids. Pass false for anything
-- whose ids end up inside saved data, where handing the same id to a different
-- meaning later would misread every record that still carries the old one.
--
-- Max stays at 65535 because the network layer addresses property ids with a
-- u16, even though storage now varints them and no longer cares.
function IdPool.new(Max: number?, Recycle: boolean?): IdPool
    const self = {}
    self.Counter = 0
    self.Max = Max or 65535
    self.Recycle = Recycle ~= false
    self.Used = {}
    self.Free = {}

    self.Claim = __claim
    self.Release = __release
    self.IsUsed = __is_used
    return self :: IdPool
end

return IdPool
