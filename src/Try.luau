--!strict
-- Retry with exponential backoff. Errors are swallowed by design: callers branch
-- on the boolean, they do not handle the failure.
const function Try(Attempts: number, fn: (...any) -> ...any, ...: any): ...any
    local Result = table.pack(false)
    local Delay = 0.125
    const Total = math.max(1, Attempts)

    for Attempt = 1, Total do
        -- No `:: any` here. A type assertion on a call truncates it to one
        -- value exactly as parentheses would, so `table.pack(pcall(fn, ...) ::
        -- any)` packed pcall's boolean alone and threw away everything the
        -- wrapped call returned -- every `const Success, Stored = Try(...)` got
        -- nil for Stored. It was not buying anything either: the one diagnostic
        -- this file has is the same with it and without it.
        Result = table.pack(pcall(fn, ...))
        if Result[1] then
            break
        end

        -- The old loop waited after the final attempt too, so a run that was
        -- always going to fail still slept for the last (and longest) backoff.
        if Attempt < Total then
            task.wait(Delay)
            Delay *= 2
        end
    end

    -- table.pack/unpack rather than {pcall(...)} plus unpack, which drops
    -- trailing nils when the wrapped call returns them.
    return table.unpack(Result, 1, Result.n)
end

-- Typed from outside rather than inside. The body only moves packs from pcall
-- to table.unpack, which the solver sees as a list of booleans and anys and
-- cannot match back to B..., so it is written untyped and given its signature
-- here: callers still get fn's arguments checked and its results typed. That
-- includes an optional parameter at the end of fn, which still has to be
-- passed, as nil if need be: GetAsync's options are a slot in A... like any
-- other.
return (Try :: any) :: <A..., B...>(Attempts: number, fn: (A...) -> B..., A...) -> (boolean, B...)
