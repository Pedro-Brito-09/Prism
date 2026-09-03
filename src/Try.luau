return function<A..., B...>(Attempts: number, fn: (A...) -> B..., ...: A...): (boolean, B...)
    local Success, Result;
    while Attempts > 0 do
        Success, Result = pcall(fn, ...)
        if Success then
            break
        end

        Attempts -= 1
    end

    return Success, Result
end