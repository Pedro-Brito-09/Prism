--!strict
-- Undo and redo, as one order, from the client.
--
-- The steps themselves live on two sides now. Anything done to a scene the
-- server owns is recorded there, by History/Server, because that is where the
-- objects are: a destroy suspends its object and the step holds it, so undoing
-- brings back that object rather than building a lookalike. Anything done in a
-- scene this client owns is recorded here, for the same reason in reverse --
-- nobody else has a claim on those objects, so nothing about them needs asking.
--
-- What this module owns outright is the *order*. Ctrl+Z should take back the
-- last thing the player did, and the player does not know or care which side
-- recorded it, so the two halves are kept as one list of tokens: a step of this
-- client's own, or the id of one the server is holding. Undo looks at the top
-- token and either applies it here or asks the server for that exact step.
--
-- Naming the step matters. The two halves can drift -- the server drops the
-- oldest when a player's stack is full, and it does that without being asked --
-- so an undo says which step it means and is told no if that is not the one on
-- top. Being told no comes with a fresh picture of the server's stacks, which
-- is what this reconciles against.

const Objects = require("../Objects/Client")
const Transactions = require("../Transactions/Client")
const Network = require("./Network")
const Listeners = require("../Listeners")
const Logger = require("../Logger")
const Types = require("../Objects/Types")

const History = {}

-- Steps of this client's own kept on each stack, across every scene this client
-- owns. One count for all of them, for the reason the server keeps one for all
-- of its own: what a player takes back is one sequence of things they did, not
-- one per room.
--
-- The two halves count separately, which is the one line the order does not
-- draw: a step here and a step the server holds are the same kind of thing to
-- undo, but only this side can count them together, and a client that has gone
-- quiet must not be what decides how much the server holds. So each side keeps
-- its own hundred, and a player who edits only one kind of scene sees exactly
-- that many either way.
const LIMIT = 100

-- How long a run of sets to one property may pause and still be one step. A
-- drag sets every frame; two edits a few seconds apart are two actions.
const MERGE_WINDOW = 1

-- A copy appearing and going is a step like any other, and the same act in
-- opposite directions: undoing a load withdraws the copy it made, undoing an
-- unload puts back the one it took. Both are suspends, so what comes back is
-- what was there -- objects, values, ids and all -- rather than what the scene
-- last committed.
--
-- Holds are not here. A lock is not a change to the world, and an undo that
-- took somebody's hold back would be taking back something they may still be
-- using.
type Entry = {
    Kind: "Set" | "Create" | "Destroy" | "Load" | "Unload",

    -- One or the other: an object for the first three, a live copy for the two
    -- below them.
    Target: Types.Object?,
    Copy: any?,

    Property: number?,
    Before: any,
    After: any,
}

-- A step the game wrote itself, for the things Prism does not model. The
-- server's twin; see History/Server for what each verb is for.
export type Action = {
    Undo: () -> (),
    Redo: () -> (),
    Clear: (() -> ())?,
}

-- Either the game's or Prism's, never both.
type Step = {
    Entries: {Entry},
    Custom: Action?,
    Run: {Target: Types.RuntimeId, Property: number, At: number}?,
}

-- One place in the order. Exactly one of the two is set: a step this client
-- holds, or the id of one the server does.
type Token = {
    Step: Step?,
    Server: number?,
}

const UndoOrder: {Token} = {}
const RedoOrder: {Token} = {}
const Changed: {() -> ()} = {}

-- Set while this module applies a step of its own, so the edits it makes are
-- not recorded as new actions. Reviving an object fires the added signal like
-- any other object appearing, and without this an undone destroy would record
-- itself as a create.
local Applying = false

-- One undo or redo at a time: asking the server yields, and a second one
-- started meanwhile would reverse a step the first has not finished with.
local Busy = false

--=============================================================================
-- Clear
--=============================================================================

-- The end of a step of this client's own. Anything it was holding against an
-- undo that will now never come is disposed, which is the point at which a
-- deferred destroy finally happens.
--
-- Only an entry that caused the suspension owns the object: a Set names an
-- object it did not remove. See History/Server, which reasons the same way over
-- the same shape.
const function Clear(Step: Step)
    const Custom = Step.Custom
    if Custom then
        -- The game's, so it is allowed to throw without taking the stack with
        -- it: this runs while a new action is being recorded, which is no
        -- moment to fail.
        if Custom.Clear then
            const Ok, Err = pcall(Custom.Clear)
            if not Ok then
                Logger:Warn(`A custom history action failed to clear: {Err}`)
            end
        end

        Step.Custom = nil
        return
    end

    for _, Entry in Step.Entries do
        const Copy = Entry.Copy
        if Copy then
            -- A copy this step was holding against an undo that will now never
            -- come. Its objects end here, and the folder they were in.
            if Copy.Suspended then
                Copy:Dispose()
            end

            continue
        end

        const Target = Entry.Target
        if Target and Entry.Kind ~= "Set" and Target.Suspended then
            Objects.Dispose(Target)
        end
    end

    table.clear(Step.Entries)
end

const function ClearTokens(Order: {Token})
    for _, Token in Order do
        if Token.Step then
            Clear(Token.Step)
        end
    end

    table.clear(Order)
end

-- A step of this client's own joining the order. A server step arrives the
-- other way round -- the server records it and says so -- and is appended when
-- its id turns up in a picture this client has not seen before.
const function Push(Step: Step)
    table.insert(UndoOrder, {Step = Step})

    -- Past the end of what is kept, and gone for good, so it lets go of
    -- whatever it was holding. Only this client's own steps count against this
    -- limit; the server enforces the same one over its own.
    local Held = 0
    for Index = #UndoOrder, 1, -1 do
        const Token = UndoOrder[Index]
        if not Token.Step then
            continue
        end

        Held += 1
        if Held > LIMIT then
            Clear(Token.Step)
            table.remove(UndoOrder, Index)
        end
    end

    -- A new action forks the history: everything that was undone is unreachable
    -- now, on both sides. The server forks its own half when it records an
    -- action of its own, but this one happened here, so it has to be told --
    -- and told before its half is dropped from the order, or the steps it is
    -- still holding would have nothing left to reach them.
    local Theirs = false
    for _, Token in RedoOrder do
        if Token.Server then
            Theirs = true
            break
        end
    end

    if Theirs then
        Network.Forget:FireAll(true)
    end

    ClearTokens(RedoOrder)
    Listeners.Notify(Changed)
end

--=============================================================================
-- Applying a step of this client's own
--=============================================================================

const function Present(Entry: Entry, Forward: boolean): boolean
    return (Entry.Kind == "Create" or Entry.Kind == "Load") == Forward
end

const function Ends(Entry: Entry, Forward: boolean): (any, any)
    if Forward then
        return Entry.Before, Entry.After
    end

    return Entry.After, Entry.Before
end

const function Ordered(Entries: {Entry}, Forward: boolean): {Entry}
    if Forward then
        return Entries
    end

    const Reversed = table.create(#Entries)
    for Index = #Entries, 1, -1 do
        table.insert(Reversed, Entries[Index])
    end

    return Reversed
end

const function ApplyLocal(Step: Step, Forward: boolean): boolean
    Applying = true

    const Custom = Step.Custom
    if Custom then
        const Ok, Err = pcall(if Forward then Custom.Redo else Custom.Undo)
        Applying = false

        if not Ok then
            -- Left where it was, like any other refusal, so it can be tried
            -- again once whatever the action needed is there.
            Logger:Warn(`A custom history action failed and was left on the stack: {Err}`)
            return false
        end

        return true
    end

    for _, Entry in Ordered(Step.Entries, Forward) do
        const Copy = Entry.Copy
        if Copy then
            if Present(Entry, Forward) then
                Copy:Revive()
            else
                Copy:Suspend()
            end

            continue
        end

        const Obj = Entry.Target :: Types.Object

        if Entry.Kind == "Set" then
            const Prop = if Obj.Destroyed then nil else Obj.Properties[Entry.Property :: number]
            const From, To = Ends(Entry, Forward)

            -- Changed since by something other than this step: left alone.
            if Prop and Prop.Value == From then
                Obj:Set(Entry.Property :: number, if To == nil then Prop.DefaultValue else To)
            end
        elseif Present(Entry, Forward) then
            Objects.Revive(Obj)
        else
            Objects.Suspend(Obj)
        end
    end

    Applying = false
    return true
end

const function Move(From: {Token}, To: {Token}, Forward: boolean): boolean
    const Token = From[#From]
    if not Token or Busy then
        return false
    end

    Busy = true

    local Ok, Result
    if Token.Step then
        Ok, Result = pcall(ApplyLocal, Token.Step, Forward)
    else
        const Channel = if Forward then Network.Redo else Network.Undo
        Ok, Result = pcall(function()
            return Channel:Invoke(Token.Server)
        end)
    end

    Busy = false
    Applying = false

    -- Refused -- rights, a lock, a step the server no longer has on top -- and
    -- so left where it was, to be tried again. A server refusal comes with a
    -- fresh picture of its stacks, which reconciles the order whenever it
    -- lands.
    if not Ok or Result ~= true then
        return false
    end

    -- Not table.remove of the last: reconciling may have moved things while the
    -- invoke above was in flight.
    const At = table.find(From, Token)
    if At then
        table.remove(From, At)
    end

    if Token.Step then
        Token.Step.Run = nil
    end

    table.insert(To, Token)
    Listeners.Notify(Changed)
    return true
end

--=============================================================================
-- The order
--=============================================================================

-- Takes back the most recent step, whichever side is holding it. Yields while
-- the server answers for one of its own. False if there is nothing to undo,
-- another undo or redo is still going, or it was refused -- in which case the
-- step stays where it is.
function History:Undo(): boolean
    return Move(UndoOrder, RedoOrder, false)
end

function History:Redo(): boolean
    return Move(RedoOrder, UndoOrder, true)
end

-- An action of the game's own, in the order the player's own edits are in, so
-- undoing reaches it exactly where it happened. For the things Prism does not
-- model -- a tool's own state, a panel's own data -- so that Ctrl+Z means one
-- thing in an editor rather than two.
--
-- Push it as the action happens; Undo and Redo are how to take it back and do
-- it again, and Clear, if it holds anything, is where that goes when the step
-- can no longer be reached.
function History:Push(Action: Action): boolean
    if type(Action) ~= "table" or type(Action.Undo) ~= "function" or type(Action.Redo) ~= "function" then
        Logger:Warn("A custom history action needs an Undo and a Redo function.")
        return false
    end

    Push({Entries = {}, Custom = Action})
    return true
end

function History:CanUndo(): boolean
    return #UndoOrder > 0 and not Busy
end

function History:CanRedo(): boolean
    return #RedoOrder > 0 and not Busy
end

-- Forgets everything, on both sides. The server disposes of every object its
-- steps were holding for this player; this does the same for its own.
function History:Clear()
    ClearTokens(UndoOrder)
    ClearTokens(RedoOrder)
    Network.Forget:FireAll(false)
    Listeners.Notify(Changed)
end

-- Fired whenever either stack changes, for an editor greying its buttons.
function History:OnChange(Callback: () -> ()): () -> ()
    return Listeners.Watch(Changed, Callback, "the history")
end

-- The server's picture of its own two stacks, oldest first. Its steps are
-- appended in the order it reports them and dropped when it stops reporting
-- them, which is how a step it dropped past its own limit -- something this
-- side never asked for and would not otherwise hear about -- leaves the order.
Network.Changed:Connect(function(Undo: {number}, Redo: {number})
    const Live: {[number]: true} = {}
    for _, Id in Undo do
        Live[Id] = true
    end

    for _, Id in Redo do
        Live[Id] = true
    end

    const Known: {[number]: true} = {}

    const function Sweep(Order: {Token})
        for Index = #Order, 1, -1 do
            const Server = Order[Index].Server
            if not Server then
                continue
            end

            if Live[Server] then
                Known[Server] = true
            else
                table.remove(Order, Index)
            end
        end
    end

    Sweep(UndoOrder)
    Sweep(RedoOrder)

    -- Steps the server has and this side has never placed: its own recording of
    -- what this client just did, in the order it recorded them.
    local Fresh = false
    for _, Id in Undo do
        if not Known[Id] then
            table.insert(UndoOrder, {Server = Id})
            Fresh = true
        end
    end

    for _, Id in Redo do
        if not Known[Id] then
            table.insert(RedoOrder, {Server = Id})
        end
    end

    -- A step this side had never seen is a new action, and a new action forks
    -- the whole order. The server has already dropped its own half of the redo
    -- stack; this drops the rest, which is also where the local steps in it let
    -- go of what they were holding.
    if Fresh then
        ClearTokens(RedoOrder)
    end

    Listeners.Notify(Changed)
end)

--=============================================================================
-- Recording
--=============================================================================

-- Only scenes this client owns. What it does to the server's is recorded there,
-- where the objects are, and reaches this side as a step id and nothing else.

-- A local transaction is one step, which is what a transaction is for. The two
-- hooks are why it can be: the first stops the object by object recording below
-- from firing while the edit runs, and the second hands the whole thing over.
-- Without the first, a transaction creating three objects would land as three
-- steps and then a fourth.
Transactions.OnApplying(function()
    Applying = true
end)

Transactions.OnApplied(function(Record): boolean
    Applying = false

    -- Nil when the apply came apart and was rolled back: nothing happened, so
    -- there is nothing to take back.
    if not Record then
        return false
    end

    const Entries: {Entry} = {}
    local Creates = 0

    for Index, Operation in Record.Operations do
        const Op = Operation :: any

        if Op.Kind == "Create" then
            Creates += 1
            const Made = Record.Created[Creates]
            if Made then
                table.insert(Entries, {Kind = "Create" :: "Create", Target = Made})
            end
        elseif Op.Kind == "Set" then
            const Obj = Record.Targets[Index]
            if Obj then
                table.insert(Entries, {
                    Kind = "Set" :: "Set",
                    Target = Obj,
                    Property = Op.Property,
                    Before = Record.Before[Index],
                    After = Op.Value,
                })
            end
        elseif Op.Kind == "Destroy" then
            const Obj = Record.Targets[Index]

            -- Named twice in one transaction is one destroy by the time it
            -- lands, and the second naming has no object suspended of its own.
            if Obj and Obj.Suspended then
                table.insert(Entries, {Kind = "Destroy" :: "Destroy", Target = Obj})
            end
        end
    end

    for _, Live in Record.Loaded do
        table.insert(Entries, {Kind = "Load" :: "Load", Copy = Live})
    end

    for _, Live in Record.Withdrew do
        table.insert(Entries, {Kind = "Unload" :: "Unload", Copy = Live})
    end

    if #Entries == 0 then
        return false
    end

    Push({Entries = Entries})
    return true
end)

Objects:OnEdited(function(Obj, Property, Before, After)
    if Applying or not Obj.Local then
        return
    end

    const Now = os.clock()
    const Top = UndoOrder[#UndoOrder]
    const Step = if Top then Top.Step else nil
    const Run = if Step then Step.Run else nil

    if
        Run
        and Run.Target == Obj.RuntimeId
        and Run.Property == Property
        and Now - Run.At <= MERGE_WINDOW
    then
        -- Still the same drag: the step now ends where this set did, and still
        -- begins where the first set in it started.
        (Step :: Step).Entries[1].After = After
        Run.At = Now
        return
    end

    Push({
        Entries = {{Kind = "Set" :: "Set", Target = Obj, Property = Property, Before = Before, After = After}},
        Run = {Target = Obj.RuntimeId, Property = Property, At = Now},
    })
end)

-- A local object appearing, which in a scene this client owns is someone
-- creating one. Not a copy reading its own pack back -- that is Restored, and
-- loading a level is not an action anybody takes back a step at a time. Not a
-- revive either: that fires this like any other object appearing, and an undo
-- recording its own reversal would never let the stack empty.
Objects:OnAdded(function(Obj, Restored)
    if Applying or Restored or not Obj.Local then
        return
    end

    Push({Entries = {{Kind = "Create" :: "Create", Target = Obj}}})
end)

-- A local object going. Claimed, which is what keeps it whole: nothing else on
-- this side is holding it, so answering false here is what makes a destroy in a
-- client owned scene final.
Objects.OnRetired(function(Obj): boolean
    if Applying or not Obj.Local then
        return false
    end

    Push({Entries = {{Kind = "Destroy" :: "Destroy", Target = Obj}}})
    return true
end)

return History
