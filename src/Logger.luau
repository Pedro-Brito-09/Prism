--!strict
const Logger = {}
const PREFIX = "[ PRISM ]"

function Logger:Log(Message: string)
    print(`{PREFIX} {Message}`)
end

function Logger:Warn(Message: string)
    warn(`{PREFIX} {Message}`)
end

-- Annotated never so the analyser knows control does not come back. Without it
-- every `if not X then Logger:Error(...) end` guard leaves X still nilable for
-- the rest of the function.
function Logger:Error(Message: string): never
    error(`{PREFIX} {Message}`, 2)
end

return Logger
