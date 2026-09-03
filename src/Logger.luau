const Logger = {}
const PREFIX = "[ LOOM ]"

function Logger:Log(Message: string)
    print(`{PREFIX} {Message}`)
end

function Logger:Warn(Message: string)
    warn(`{PREFIX} {Message}`)
end

function Logger:Error(Message: string)
    error(`{PREFIX} {Message}`, 2)
end

return Logger