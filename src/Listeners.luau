--!strict
-- Plain listener lists.
--
-- Change notification follows Properties and Selection: a list of callbacks and
-- a disconnect function, rather than a signal object standing there for the
-- many games that never listen. Each callback runs on a thread of its own, so
-- one that yields or throws holds up neither the rest nor the code that fired.

const Logger = require("./Logger")

const Listeners = {}

-- Adds a callback and hands back its disconnect, which is safe to call twice.
-- What names the thing being watched, for the error a non-function gets.
function Listeners.Watch(List: {any}, Callback: any, What: string): () -> ()
    if typeof(Callback) ~= "function" then
        Logger:Error(`Invalid callback. Tried watching {What} with a {typeof(Callback)}.`)
    end

    table.insert(List, Callback)

    local Disconnected = false
    return function()
        if Disconnected then
            return
        end

        Disconnected = true

        const Position = table.find(List, Callback)
        if Position then
            table.remove(List, Position)
        end
    end
end

-- Cloned first, so a callback that disconnects itself or connects another does
-- not change which ones this call reaches.
--
-- The firing thread is kept for the moment each callback starts, so a callback
-- can ask who it is running on behalf of before it yields. A spawned callback
-- is a thread of its own, and without this it could not tell an edit a custom
-- undo made from one the player made at the same time.
local Notifying: thread? = nil

function Listeners.Notify(List: {any}, ...: any)
    const Previous = Notifying
    Notifying = coroutine.running()

    for _, Callback in table.clone(List) do
        task.spawn(Callback, ...)
    end

    Notifying = Previous
end

-- The thread whose Notify started the callback now running, or the running
-- thread when it was not started by one. Only good until the callback first
-- yields.
function Listeners.Origin(): thread
    return Notifying or coroutine.running()
end

return Listeners
