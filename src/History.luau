--!strict
-- Undo and redo, per player, on the client.
--
-- Each client keeps its own stacks of what it did, so undoing only ever takes
-- back this player's own actions. A step is a committed transaction, or a run
-- of single sets to one property -- a drag, one Set per frame -- merged into
-- one. Undoing sends the reverse as a transaction of its own, through the same
-- rights and locks as any edit; for a scene this client owns it applies on the
-- spot, because there is nobody to ask.
--
-- The reversal rules are the ones transactions already carry: a create is
-- undone by destroying what it made, a set by writing back what it overwrote,
-- and a destroy by making the object again from what it held.
--
-- What another player changed since is theirs. An undo or redo that would put
-- a property back over someone else's later value skips that property and
-- applies the rest -- nobody's work is quietly discarded, and no undo is left
-- stuck behind someone else's edit.
--
-- An object made again comes back under a new runtime id, because the server
-- mints them. Steps recorded against the old id still find it, through an
-- alias kept here.
--
-- Not recorded: Object:Destroy on its own, and creates or destroys in a scene
-- this client owns. Destroy through a transaction to make it undoable.

const Objects = require("./Objects/Client")
const Transactions = require("./Transactions/Client")
const Listeners = require("./Listeners")

const History = {}

-- Steps kept on each stack; the oldest go first.
const LIMIT = 100

-- How long a run of sets to one property may pause and still be one step. A
-- drag sets every frame; two edits a few seconds apart are two actions.
const MERGE_WINDOW = 1

type Entry = {
    Kind: "Set" | "Create" | "Destroy",
    Target: number,

    -- A set's property and the values either side of it.
    Property: number?,
    Before: any,
    After: any,

    -- What an object needs to be made again: its type, its values and the
    -- copy it lived in. Zero is the copy Objects.new picks on its own.
    Parent: number?,
    Values: {[number]: any}?,
    Copy: number?,
}

type Step = {
    Entries: {Entry},

    -- Every entry is in a scene this client owns, so it applies here and now
    -- rather than through a transaction.
    Local: boolean,

    -- The property a run of single sets is building, while it is still open.
    Run: {Target: number, Property: number, At: number}?,
}

const UndoStack: {Step} = {}
const RedoStack: {Step} = {}
const Changed: {() -> ()} = {}

-- Runtime id recorded -> the id the same object answers to now.
const Aliases: {[number]: number} = {}

-- Set while History applies a local step, so its own sets are not recorded.
local Applying = false

-- One undo or redo at a time: a transaction yields, and a second one started
-- meanwhile would reverse a step the first has not finished with.
local Busy = false

const function Resolve(Identifier: number): number
    local Current = Identifier
    while Aliases[Current] do
        Current = Aliases[Current]
    end

    return Current
end

const function Live(Identifier: number): any
    const Obj = Objects:Get(Resolve(Identifier))
    return if Obj and not Obj.Destroyed then Obj else nil
end

const function Push(Step: Step)
    table.insert(UndoStack, Step)
    if #UndoStack > LIMIT then
        table.remove(UndoStack, 1)
    end

    -- A new action forks the history; what was undone before it is gone.
    table.clear(RedoStack)
    Listeners.Notify(Changed)
end

-- The value a set moves from and to, in the direction being applied. A
-- property that held nothing goes back to its default, which is what nothing
-- reads as.
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

    for _, Entry in Ordered(Step.Entries, Forward) do
        const Obj = Live(Entry.Target)
        const Prop = if Obj and Entry.Property then Obj.Properties[Entry.Property] else nil
        const From, To = Ends(Entry, Forward)

        -- Changed since by something other than this step: left alone.
        if Prop and Prop.Value == From then
            Obj:Set(Entry.Property, if To == nil then Prop.DefaultValue else To)
        end
    end

    Applying = false
    return true
end

const function ApplyRemote(Step: Step, Forward: boolean): boolean
    const Edit = Transactions.new()
    Edit.Untracked = true

    -- The entries whose object this transaction makes, in the order its
    -- creates are declared, which is the order their ids come back in.
    const Making: {Entry} = {}

    for _, Entry in Ordered(Step.Entries, Forward) do
        if Entry.Kind == "Set" then
            const Obj = Live(Entry.Target)
            const Prop = if Obj and Entry.Property then Obj.Properties[Entry.Property] else nil
            const From, To = Ends(Entry, Forward)

            if Prop and Prop.Value == From then
                Edit:Set(Obj, Entry.Property :: number, if To == nil then Prop.DefaultValue else To)
            end
        elseif (Entry.Kind == "Create") == Forward then
            -- Redoing a create, or undoing a destroy: make it again, if the
            -- copy it lived in is still here to hold it.
            const Copy = Entry.Copy or 0
            if Copy == 0 or Objects:GetInstanceScene(Copy) ~= nil then
                Edit:Create(Entry.Parent :: number, Entry.Values, if Copy ~= 0 then Copy else nil)
                table.insert(Making, Entry)
            end
        else
            -- Undoing a create, or redoing a destroy: take it away, if it has
            -- not gone already.
            const Obj = Live(Entry.Target)
            if Obj then
                Edit:Destroy(Obj)
            end
        end
    end

    if #Edit.Operations == 0 then
        return true
    end

    const Applied, Created = Edit:Commit()
    if not Applied then
        return false
    end

    for Index, Entry in Making do
        const Made = Created[Index]
        if Made then
            const Current = Resolve(Entry.Target)
            if Current ~= Made then
                Aliases[Current] = Made
            end
        end
    end

    return true
end

const function Move(From: {Step}, To: {Step}, Forward: boolean): boolean
    const Step = From[#From]
    if not Step or Busy then
        return false
    end

    Busy = true
    const Ok, Result = pcall(if Step.Local then ApplyLocal else ApplyRemote, Step, Forward)
    Busy = false
    Applying = false

    -- Refused -- rights, a lock, the server unreachable -- and so left where
    -- it was, to be tried again.
    if not Ok or not Result then
        return false
    end

    table.remove(From)

    -- A step that has moved is finished; a later set starts a run of its own.
    Step.Run = nil
    table.insert(To, Step)

    Listeners.Notify(Changed)
    return true
end

-- Takes back this player's most recent step. Yields while a transaction flies.
-- False if there is nothing to undo, another undo or redo is still going, or
-- the server refused it -- in which case the step stays.
function History:Undo(): boolean
    return Move(UndoStack, RedoStack, false)
end

function History:Redo(): boolean
    return Move(RedoStack, UndoStack, true)
end

function History:CanUndo(): boolean
    return #UndoStack > 0 and not Busy
end

function History:CanRedo(): boolean
    return #RedoStack > 0 and not Busy
end

function History:Clear()
    table.clear(UndoStack)
    table.clear(RedoStack)
    table.clear(Aliases)
    Listeners.Notify(Changed)
end

-- Fired whenever either stack changes, for an editor greying its buttons.
function History:OnChange(Callback: () -> ()): () -> ()
    return Listeners.Watch(Changed, Callback, "the history")
end

--=============================================================================
-- Recording
--=============================================================================

Transactions:OnCommitted(function(Record)
    if Record.Transaction.Untracked then
        return
    end

    const Entries: {Entry} = {}
    local Creates = 0

    for Index, Operation in Record.Transaction.Operations do
        const Op = Operation :: any

        if Op.Kind == "Create" then
            Creates += 1
            const Made = Record.Created[Creates]
            if Made then
                table.insert(Entries, {
                    Kind = "Create",
                    Target = Made,
                    Parent = Op.Object,
                    Values = Op.Properties,
                    Copy = Op.Instance,
                })
            end
        elseif Op.Kind == "Set" then
            table.insert(Entries, {
                Kind = "Set",
                Target = Op.Target,
                Property = Op.Property,
                Before = Record.Before[Index],
                After = Op.Value,
            })
        elseif Op.Kind == "Destroy" then
            const Removed = Record.Removed[Index]
            if Removed then
                table.insert(Entries, {
                    Kind = "Destroy",
                    Target = Op.Target,
                    Parent = Removed.Parent,
                    Values = Removed.Values,
                    Copy = Removed.Instance,
                })
            end
        end
    end

    if #Entries > 0 then
        Push({Entries = Entries, Local = false})
    end
end)

Objects:OnEdited(function(Obj, Property, Before, After)
    if Applying then
        return
    end

    const Now = os.clock()
    const Top = UndoStack[#UndoStack]
    const Run = if Top then Top.Run else nil

    -- Still the same drag: the run's step now ends where this set did, and
    -- still begins where the first set in it started.
    if Run and Run.Target == Obj.RuntimeId and Run.Property == Property and Now - Run.At <= MERGE_WINDOW then
        Top.Entries[1].After = After
        Run.At = Now
        table.clear(RedoStack)
        return
    end

    Push({
        Entries = {{
            Kind = "Set",
            Target = Obj.RuntimeId,
            Property = Property,
            Before = Before,
            After = After,
        }},
        Local = Obj.Local == true,
        Run = {Target = Obj.RuntimeId, Property = Property, At = Now},
    })
end)

return History
