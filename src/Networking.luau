--!strict
-- Schema driven transport.
--
-- Every channel declares the codec for each of its parameters in Channels.luau,
-- so a packet is a single buffer: one byte of channel id followed by the packed
-- arguments. Values that cannot be packed (Instances, registry tables) ride in a
-- side channel array next to the buffer.
--
-- Server to client invokes are deliberately absent: InvokeClient yields the
-- calling thread until the client answers, and a client that never answers holds
-- that thread forever. Push with Fire and let the client invoke back.

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

const Channels = require("./Channels")
const Codecs = require("./Codecs")
const Logger = require("./Logger")

const IS_SERVER = RunService:IsServer()

-- Whether a game is running at all. Required from a plugin or the command bar
-- there is no server to talk to and no client to tell, and Studio's edit mode
-- answers true to IsServer and IsClient alike: this used to wait ten seconds for
-- remotes that never come and then error, or would have built them into the
-- place being edited. Outside a running game nothing is created or waited for,
-- and a send goes nowhere with one warning per channel. Everything that needs
-- no network -- the compressor, a scene read into a plugin's own world --
-- works as it does anywhere else.
const RUNNING = RunService:IsRunning()
const WAIT_TIMEOUT = 10

export type Codec<T> = Codecs.Codec<T>

export type Entry = {
    Id: number,
    Name: string,
    Args: {Codec<any>},
    Returns: {Codec<any>}?,
    Connections: {(...any) -> ()},
    OnInvoke: ((...any) -> ...any)?,

    Fire: (self: Entry, ...any) -> (),
    FireAll: (self: Entry, ...any) -> (),
    Invoke: (self: Entry, ...any) -> ...any,
    Connect: (self: Entry, Callback: (...any) -> ()) -> () -> (),
}

const Networking = {}
const Registered: {Entry} = {}

local Event: RemoteEvent
local Function: RemoteFunction

const function Pack(Id: number, Schema: {Codec<any>}, Args: {any}, Count: number): (buffer, {any}?)
    -- Checked in both directions. Too few arguments used to fall through to a
    -- codec writing a nil, which surfaced as an opaque buffer error rather than
    -- naming the channel that was called wrongly.
    if Count ~= #Schema then
        Logger:Error(`Channel {Channels.List[Id].Name} takes {#Schema} argument(s), got {Count}.`)
    end

    const Extras = {}
    local Size = 1
    for Index = 1, #Schema do
        Size += Schema[Index].Measure(Args[Index])
    end

    const Buf = buffer.create(Size)
    buffer.writeu8(Buf, 0, Id)

    local Offset = 1
    for Index = 1, #Schema do
        Offset += Schema[Index].Write(Buf, Offset, Args[Index], Extras)
    end

    return Buf, if #Extras > 0 then Extras else nil
end

const function Unpack(Schema: {Codec<any>}, Buf: buffer, Extras: {any}?): {any}
    const Side = Extras or {}
    const Args = table.create(#Schema) :: {any}

    local Offset = 1
    for Index, Codec in Schema do
        const Value, Length = Codec.Read(Buf, Offset, Side)
        Args[Index] = Value
        Offset += Length
    end

    return Args
end

-- Everything past this point may be handling a packet a client authored, so a
-- malformed buffer has to fail as a dropped packet rather than a thrown error.
const function Decode(Buf: any, Extras: any): (Entry?, {any}?)
    if typeof(Buf) ~= "buffer" or buffer.len(Buf) < 1 then
        return nil, nil
    end

    if Extras ~= nil and typeof(Extras) ~= "table" then
        return nil, nil
    end

    const Entry = Registered[buffer.readu8(Buf, 0)]
    if not Entry then
        return nil, nil
    end

    const Ok, Args = pcall(Unpack, Entry.Args, Buf, Extras)
    if not Ok then
        return nil, nil
    end

    return Entry, Args :: {any}
end

const Idled: {[number]: true} = {}

const function Idle(self: Entry)
    if not Idled[self.Id] then
        Idled[self.Id] = true
        Logger:Warn(`{self.Name} went nowhere: no game is running, so there is nobody to send it to.`)
    end
end

const function __fire(self: Entry, ...)
    if not RUNNING then
        Idle(self)
        return
    end

    if not IS_SERVER then
        const Buf, Extras = Pack(self.Id, self.Args, table.pack(...), select("#", ...))
        Event:FireServer(Buf, Extras)
        return
    end

    const Target = ...
    const Args = table.pack(select(2, ...))
    const Buf, Extras = Pack(self.Id, self.Args, Args, Args.n)

    if typeof(Target) == "Instance" and (Target :: Instance):IsA("Player") then
        Event:FireClient(Target, Buf, Extras)
        return
    end

    if type(Target) == "table" then
        for _, Plr in Target do
            if typeof(Plr) == "Instance" and Plr:IsA("Player") then
                Event:FireClient(Plr, Buf, Extras)
            end
        end

        return
    end

    Logger:Error(`Fire on {self.Name} needs a Player or a list of Players as its first argument.`)
end

const function __fire_all(self: Entry, ...)
    if not RUNNING then
        Idle(self)
        return
    end

    const Buf, Extras = Pack(self.Id, self.Args, table.pack(...), select("#", ...))
    if IS_SERVER then
        Event:FireAllClients(Buf, Extras)
    else
        Event:FireServer(Buf, Extras)
    end
end

const function __invoke(self: Entry, ...): ...any
    if not RUNNING then
        Idle(self)
        return
    end

    if IS_SERVER then
        Logger:Error(`Invoke on {self.Name} is client to server only.`)
    end

    const Buf, Extras = Pack(self.Id, self.Args, table.pack(...), select("#", ...))
    const Ok, ReturnBuf, ReturnExtras = Function:InvokeServer(Buf, Extras)
    if not Ok then
        Logger:Error(`No handler is registered on the server for {self.Name}.`)
    end

    const Returns = self.Returns
    if not Returns then
        return
    end

    return table.unpack(Unpack(Returns, ReturnBuf, ReturnExtras), 1, #Returns)
end

const function __connect(self: Entry, Callback: (...any) -> ()): () -> ()
    if typeof(Callback) ~= "function" then
        Logger:Error(`Invalid callback. Tried connecting a {typeof(Callback)} to {self.Name}.`)
    end

    table.insert(self.Connections, Callback)
    return function()
        const Position = table.find(self.Connections, Callback)
        if Position then
            table.remove(self.Connections, Position)
        end
    end
end

for Id, Channel in Channels.List do
    Registered[Id] = {
        Id = Id,
        Name = Channel.Name,
        Args = Channel.Args,
        Returns = Channel.Returns,
        Connections = {},
        OnInvoke = nil,

        Fire = __fire,
        FireAll = __fire_all,
        Invoke = __invoke,
        Connect = __connect,
    } :: Entry
end

if not RUNNING then
    -- Nothing to set up; see RUNNING.
elseif IS_SERVER then
    Event = Instance.new("RemoteEvent")
    Event.Name = "__prism_event"
    Event.Parent = ReplicatedStorage

    Function = Instance.new("RemoteFunction")
    Function.Name = "__prism_function"
    Function.Parent = ReplicatedStorage

    Event.OnServerEvent:Connect(function(Plr: Player, Buf: any, Extras: any)
        const Entry, Args = Decode(Buf, Extras)
        if not Entry or not Args then
            return
        end

        for _, Callback in table.clone(Entry.Connections) do
            task.spawn(Callback, Plr, table.unpack(Args, 1, #Entry.Args))
        end
    end)

    Function.OnServerInvoke = function(Plr: Player, Buf: any, Extras: any): (boolean, buffer?, {any}?)
        const Entry, Args = Decode(Buf, Extras)
        if not Entry or not Args then
            return false, nil, nil
        end

        const Handler = Entry.OnInvoke
        if not Handler then
            return false, nil, nil
        end

        const Returns = Entry.Returns
        if not Returns then
            Handler(Plr, table.unpack(Args, 1, #Entry.Args))
            return true, nil, nil
        end

        const Results = table.pack(Handler(Plr, table.unpack(Args, 1, #Entry.Args)))
        const ReturnBuf, ReturnExtras = Pack(Entry.Id, Returns, Results, Results.n)
        return true, ReturnBuf, ReturnExtras
    end
else
    const FoundEvent = ReplicatedStorage:WaitForChild("__prism_event", WAIT_TIMEOUT)
    if not FoundEvent then
        Logger:Error("Failed to retrieve networking remote event.")
    end

    const FoundFunction = ReplicatedStorage:WaitForChild("__prism_function", WAIT_TIMEOUT)
    if not FoundFunction then
        Logger:Error("Failed to retrieve networking remote function.")
    end

    Event = FoundEvent :: RemoteEvent
    Function = FoundFunction :: RemoteFunction

    Event.OnClientEvent:Connect(function(Buf: any, Extras: any)
        const Entry, Args = Decode(Buf, Extras)
        if not Entry or not Args then
            return
        end

        for _, Callback in table.clone(Entry.Connections) do
            task.spawn(Callback, table.unpack(Args, 1, #Entry.Args))
        end
    end)
end

function Networking:Get(Name: string): Entry
    const Id = Channels.Ids[Name]
    if not Id then
        Logger:Error(`Unknown channel {Name}. Add it to Channels.luau.`)
    end

    return Registered[Id]
end

return Networking
