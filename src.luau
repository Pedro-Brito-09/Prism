const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const function GetSharedModule(Path: string)
    return require(`{Path}/{IS_SERVER and "Server" or "Client"}`)
end

const function GetServerModule(Path: string)
    return if IS_SERVER then require(Path) else nil
end

const function GetClientModule(Path: string)
    return if not IS_SERVER then require(Path) else nil
end

const Loom = {}

Loom.Properties = GetServerModule("./src/Properties/Server")
Loom.Objects = GetSharedModule("./src/Objects")

return Loom
