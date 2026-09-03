const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

const Logger = require("./Logger")

const ENTRY_NOT_FOUND = "NETWORKING_ENTRY_NOT_REGISTERED"
const IS_SERVER = RunService:IsServer()

const Networking = {}
const Registered = {}

local Event, Function; if IS_SERVER then
    Event = Instance.new("RemoteEvent")
    Event.Name = "__loom_event"
    Event.Parent = ReplicatedStorage

    Function = Instance.new("RemoteFunction")
    Function.Name = "__loom_function"
    Function.Parent = ReplicatedStorage

    Event.OnServerEvent:Connect(function(Plr: Player, Name: string, ...)
        const Entry = Registered[Name]
        if not Entry then
            return
        end

        for _, Connec in table.clone(Entry.Connections) do
            task.spawn(Connec, Plr, ...)
        end
    end)

    Function.OnServerInvoke = function(Plr: Player, Name: string, ...)
        const Entry = Registered[Name]
        if not Entry or not Entry.OnInvoke then
            return ENTRY_NOT_FOUND
        end

        return Entry.OnInvoke(Plr, ...)
    end
else
    Event = ReplicatedStorage:WaitForChild("__loom_event", 10)
    if not Event then
        Logger:Error("Failed to retrieve networking remote event.")
    end

    Function = ReplicatedStorage:WaitForChild("__loom_function", 10)
    if not Function then
        Logger:Error("Failed to retrieve networking remote function.")
    end

    Event.OnClientEvent:Connect(function(Name: string, ...)
        const Entry = Registered[Name]
        if not Entry then
            return
        end

        for _, Connec in table.clone(Entry.Connections) do
            task.spawn(Connec, ...)
        end
    end)

    Function.OnClientInvoke = function(Name: string, ...)
        const Entry = Registered[Name]
        if not Entry or not Entry.OnInvoke then
            return ENTRY_NOT_FOUND
        end

        return Entry.OnInvoke(...)
    end
end

const function __fire_all(self, ...)
    if not IS_SERVER then
        Event:FireServer(self.Name, ...)
        return
    end
    
    Event:FireAllClients(self.Name, ...)
end

const function __fire(self, First, ...)
    if IS_SERVER then
        if typeof(First) == "Instance" and First:IsA("Player") then
            Event:FireClient(First, self.Name, ...)
        elseif typeof(First) == "table" then
            local IsOnlyPlayers = true
            for _, v in First do
                if typeof(v) ~= "Instance" or not v:IsA("Player") then
                    IsOnlyPlayers = false
                    break
                end
            end

            if IsOnlyPlayers then
                for _, Plr in First do
                    Event:FireClient(Plr, self.Name, ...)
                end
            else
                Event:FireAllClients(self.Name, ...)
            end
        else
            Event:FireAllClients(self.Name, ...)
        end
    else
        Event:FireServer(self.Name, First, ...)
    end
end

const function __invoke(self, First, ...)
    local Result;
    if IS_SERVER then
        if typeof(First) ~= "Instance" or not First:IsA("Player") then
            Logger:Error(`Failed to invoke {self.Name}. No target client specified.`)
        end

        Result = {Function:InvokeClient(First, self.Name, ...)}
    else
        Result = {Function:InvokeServer(self.Name, First, ...)}
    end

    if Result[1] == ENTRY_NOT_FOUND then
        Logger:Error(`Failed to invoke {self.Name}. OnInvoke is not registered on the {IS_SERVER and "specified client" or "server"}.`)
    end

    return unpack(Result)
end

const function __connect(self, Callback: (...any) -> ())
    if typeof(Callback) ~= "function" then
        Logger:Error(`Invalid callback. Tried connecting a {typeof(Callback)}`)
    end

    table.insert(self.Connections, Callback)
    return function()
        local Position = table.find(self.Connections, Callback)
        if Position then
            table.remove(self.Connections, Position)
        end
    end
end

function Networking:Register(Name: string)
    const Net = {}
    Net.Name = Name
    Net.Connections = {}
    Net.Fire = __fire
    Net.FireAll = __fire_all
    Net.Invoke = __invoke
    Net.Connect = __connect
    Registered[Name] = Net
    return Net
end

return Networking