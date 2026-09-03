const FALSE = {false}
return function<A..., B...>(Attempts: number, fn: (A...) -> B..., ...: A...): (boolean, B...)
    local Result = FALSE;
    local Delay = 0.125
    Attempts = math.max(1, Attempts)
    while Attempts > 0 do
        Result = {pcall(fn, ...)}
        if Result[1] then -- Success
            break
        end

        Attempts -= 1
        task.wait(Delay)
        Delay *= 2
    end

    return unpack(Result)
end