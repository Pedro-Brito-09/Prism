--!strict
const Logger = {}
const PREFIX = "[ PRISM ]"

function Logger:Log(Message: string)
    print(`{PREFIX} {Message}`)
end

function Logger:Warn(Message: string)
    warn(`{PREFIX} {Message}`)
end

-- Annotated never so the analyser knows control does not come back. The new
-- solver only acts on that where the call is used as a value, so a guard is
-- written `const X = Find() or Logger:Error(...)`, or as `return
-- Logger:Error(...)`; a bare `if not X then Logger:Error(...) end` still leaves
-- X nilable for the rest of the function.
function Logger:Error(Message: string): never
    error(`{PREFIX} {Message}`, 2)
end

return Logger
