--!strict
-- Retry with exponential backoff. Errors are swallowed by design: callers branch
-- on the boolean, they do not handle the failure.
return function<A..., B...>(Attempts: number, fn: (A...) -> B..., ...: A...): (boolean, B...)
    local Result = table.pack(false)
    local Delay = 0.125
    const Total = math.max(1, Attempts)

    for Attempt = 1, Total do
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
