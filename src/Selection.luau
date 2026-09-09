--!strict
-- Client side selection.
--
-- Editor state, not replicated state: the server never hears about it and no
-- other client sees it. Which is also why it lives here rather than inside
-- Objects/Client -- nothing in the object pipeline depends on it.
--
-- Change notification follows Properties: a plain listener list allocated on
-- the first OnChange call and dropped again when the last listener leaves,
-- rather than a signal object standing there for the many games that never
-- watch the selection at all.

const ObjectTypes = require("./Objects/Types")
const Objects = require("./Objects/Client")
const Logger = require("./Logger")

export type RuntimeId = ObjectTypes.RuntimeId
export type Object = ObjectTypes.Object

-- Everything here takes an object or its runtime id, the way Objects takes a
-- property by id or by name.
export type Reference = Object | RuntimeId

const Selection = {}
const Selected: {RuntimeId} = {}
local Listeners: {(Selected: {Object}) -> ()}? = nil

-- Only a reference the workspace still holds is accepted. Selecting an id that
-- never arrived, or one already gone, used to sit in the list until something
-- happened to walk past it.
const function Resolve(Reference: Reference): RuntimeId?
    const Identifier = if type(Reference) == "number"
        then Reference
        else Reference.RuntimeId

    const Obj = Objects:Get(Identifier)
    return if Obj and not Obj.Destroyed then Identifier else nil
end

-- Prunes as it collects. An object can leave at any moment -- destroyed by
-- another client, or removed with the scene it belonged to -- and nothing tells
-- the selection, so every read is also the cleanup pass. Order is preserved:
-- editors treat the most recently added entry as the active one.
const function Collect(): ({Object}, boolean)
    const Live = {}
    const Kept = {}

    for _, Identifier in Selected do
        const Obj = Objects:Get(Identifier)
        if Obj and not Obj.Destroyed then
            table.insert(Kept, Identifier)
            table.insert(Live, Obj)
        end
    end

    const Pruned = #Kept ~= #Selected
    if Pruned then
        table.clear(Selected)
        table.move(Kept, 1, #Kept, 1, Selected)
    end

    return Live, Pruned
end

const function Notify(Live: {Object})
    const Current = Listeners
    if not Current then
        return
    end

    for _, Callback in table.clone(Current) do
        task.spawn(Callback, Live)
    end
end

function Selection:Add(Reference: Reference): boolean
    const Identifier = Resolve(Reference)
    if not Identifier or table.find(Selected, Identifier) then
        return false
    end

    table.insert(Selected, Identifier)
    Notify(Collect())
    return true
end

function Selection:Remove(Reference: Reference): boolean
    -- Not Resolve: an object that has already left still has to be removable
    -- from the list, and Resolve refuses exactly those.
    const Identifier = if type(Reference) == "number"
        then Reference
        else Reference.RuntimeId

    const Position = table.find(Selected, Identifier)
    if not Position then
        return false
    end

    table.remove(Selected, Position)
    Notify(Collect())
    return true
end

-- Answers whether the reference is selected, without building the object list.
function Selection:Contains(Reference: Reference): boolean
    const Identifier = if type(Reference) == "number"
        then Reference
        else Reference.RuntimeId

    return table.find(Selected, Identifier) ~= nil
end

function Selection:Clear()
    if #Selected == 0 then
        return
    end

    table.clear(Selected)
    Notify({})
end

-- Replaces the selection wholesale and notifies once, rather than firing a
-- change per entry the way a Clear followed by N calls to Add would. Answers
-- how many references were accepted, which a boolean could not say.
function Selection:Set(References: {Reference}): number
    table.clear(Selected)

    for _, Reference in References do
        const Identifier = Resolve(Reference)
        if Identifier and not table.find(Selected, Identifier) then
            table.insert(Selected, Identifier)
        end
    end

    const Live = Collect()
    Notify(Live)
    return #Live
end

function Selection:Get(): {Object}
    const Live, Pruned = Collect()
    if Pruned then
        Notify(Live)
    end

    return Live
end

function Selection:Query(Comparator: (Obj: Object) -> boolean): {Object}
    const Matched = {}
    for _, Obj in Selection:Get() do
        if Comparator(Obj) then
            table.insert(Matched, Obj)
        end
    end

    return Matched
end

-- Fires with the whole selection rather than a delta: every use of this is a
-- panel or a handle that redraws from the current list anyway.
function Selection:OnChange(Callback: (Selected: {Object}) -> ()): () -> ()
    if typeof(Callback) ~= "function" then
        Logger:Error(`Invalid callback. Tried watching the selection with a {typeof(Callback)}.`)
    end

    local Current = Listeners
    if not Current then
        Current = {}
        Listeners = Current
    end

    table.insert(Current :: {any}, Callback)

    local Disconnected = false
    return function()
        if Disconnected then
            return
        end

        Disconnected = true

        const Live = Listeners
        if not Live then
            return
        end

        const Position = table.find(Live, Callback)
        if Position then
            table.remove(Live, Position)
        end

        if #Live == 0 then
            Listeners = nil
        end
    end
end

return Selection
