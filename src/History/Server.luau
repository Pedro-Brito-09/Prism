--!strict
-- Undo and redo for the scenes the server owns, kept per player, here.
--
-- It used to live entirely on the client, which could record what it had done
-- but could not hold on to what it had undone: the server destroyed an object
-- the moment a destroy landed, so undoing one built a new object in its place.
-- A new object gets a new local id, and every reference still naming the old
-- one was left pointing at nothing. An undo that loses the wiring is not an
-- undo.
--
-- So the stack lives where the objects do. A destroy suspends its object --
-- out of the world by every measure, but whole -- and the step that caused it
-- holds it. Undoing revives that same object, under its own runtime id and its
-- own local id, and everything that pointed at it is pointing at it again.
--
-- Three things can happen to a step, and each of them is spelled out below:
--
--   Undo    put the world back the way it was before the step
--   Redo    do it again
--   Clear   the step will never be applied again, so anything it was holding
--           against an undo can finally go
--
-- Clear is what makes the rest safe. A suspended object is a real object out
-- of sight, and something has to end it: a step is cleared when a new action
-- forks the redo stack it was sitting on, when it falls off the end of the
-- undo stack past the limit, and when the player it belongs to leaves. Those
-- are the only three ways a step stops being reachable, so they are the only
-- three ways an object can be kept and then quietly abandoned.
--
-- Scenes a client owns are not here. The client is the authority in those, so
-- it keeps its own half of the order and applies its own steps; History/Client
-- is where that lives and how the two halves are kept in one order.

const Players = game:GetService("Players")

const PropertyTypes = require("../Properties/Types")
const Permissions = require("../Permissions/Server")
const Transactions = require("../Transactions/Server")
const Compressor = require("../Compressor")
const ObjectTypes = require("../Objects/Types")
const Objects = require("../Objects/Server")
const Audience = require("../Scenes/Audience")
const Scenes = require("../Scenes/Server")
const Network = require("./Network")
const Logger = require("../Logger")

export type Object = ObjectTypes.Object

const History = {}

-- Steps kept on each stack, per player and across every scene the server owns.
-- One count, not one per scene: a player editing two rooms has done one
-- sequence of things and takes them back in the order they did them, so a limit
-- per scene would drop a step that is nowhere near the oldest thing they did.
--
-- The oldest goes when a new one arrives past this, and goes for good:
-- whatever it was holding is disposed.
local LIMIT = 100

-- Objects the kept steps may hold between them, alongside the count above. A
-- step can hold a whole withdrawn copy -- every object in it, and every part --
-- so a hundred steps was a limit on nothing: a hundred unloads of a large room
-- kept a hundred large rooms alive. The oldest steps go until what is left fits,
-- except the newest, which is kept however much it holds: an undo that cannot
-- take back the thing just done is worse than one room too many in memory.
local HELD_LIMIT = 10000

-- How long a run of single sets to one property may pause and still count as
-- one step. A drag sets every frame; two edits a few seconds apart are two
-- actions.
const MERGE_WINDOW = 1

-- An entry names an object rather than an id, and holds it. That is the whole
-- change: a destroy no longer has to describe the object well enough to build
-- another one, because it kept the one it took.
--
-- Create and Destroy carry the same thing and differ only in which direction
-- means "in the world" -- undoing a create and redoing a destroy are the same
-- act on the same object.
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
    Target: Object?,
    Copy: any?,

    Property: PropertyTypes.PropertyIdentifier?,
    Before: any,
    After: any,
}

-- A step the game wrote itself, for the things Prism does not model: a camera
-- bookmark, a layer renamed in a game's own data, anything an editor wants
-- Ctrl+Z to reach. Three verbs, the same three every step has, and the game
-- fills them in.
--
-- Clear is optional and is the one worth reading twice: it runs when the step
-- becomes unreachable -- forked off the redo stack, pushed past the limit, or
-- the player leaving -- and is where an action that was holding something of
-- its own lets go of it, exactly as Prism's own steps let go of the objects
-- they were keeping.
export type Action = {
    Undo: () -> (),
    Redo: () -> (),
    Clear: (() -> ())?,
}

-- Either the game's or Prism's, never both. Mixing them would mean deciding
-- what order a custom verb runs in among entries it knows nothing about, and
-- an editor that wants both can push two steps.
type Step = {
    Id: number,
    Entries: {Entry},
    Custom: Action?,

    -- The property a run of single sets is still building, while the step is
    -- on top and recent enough to keep merging into.
    Run: {Target: ObjectTypes.RuntimeId, Property: PropertyTypes.PropertyIdentifier, At: number}?,

    -- Objects the step keeps alive, counted against HELD_LIMIT. See Weigh.
    Weight: number?,
}

type Shelf = {
    Undo: {Step},
    Redo: {Step},

    -- One step at a time for this player. A step can yield: bringing back a
    -- copy announces its objects in chunks, a frame apiece, and a custom action
    -- is the game's code. A second undo starting meanwhile would reverse a step
    -- the first has not finished with.
    Busy: boolean?,

    -- Counted up whenever the redo stack is dropped (Forked: a new action, or
    -- a fork from the client) or both stacks are (Wiped: Clear). A step being
    -- applied is off its stack while it runs, and these are how it learns, once
    -- it is done, whether it still has anywhere to go back to.
    Forked: number,
    Wiped: number,

    -- Step ids are per player and only climb. The client names the step it
    -- believes is on top, and an id that has been reused would let a stale
    -- request undo something else entirely.
    Next: number,
}

-- Dropped when the player leaves, along with everything their steps were
-- holding. Keyed by the player rather than the user id on purpose: a step names
-- live objects, and someone rejoining comes back to a world whose objects have
-- moved on without them.
const Shelves: {[Player]: Shelf} = {}

-- The players whose custom action is running, so nothing it does is recorded
-- as a new action of theirs. A custom action is the game's code, free to use the
-- ordinary API, and every edit it made while undoing would otherwise land on the
-- stack on top of the step doing the undoing. Prism's own entries need no such
-- guard: they write to properties and objects directly and never reach a
-- recorder.
--
-- By the thread running the action, and only around it. This was one flag for
-- the whole server, held for every step, and a step can yield -- bringing a copy
-- back announces its objects a chunk a frame -- so nobody else's edits were
-- recorded while one player's undo ran. Then it was per player, which still
-- dropped that player's own edits if the action yielded and they made one in
-- the meantime. A recorder runs on the thread whose edit it records, so the
-- action's own edits are on its thread and nobody else's are. What the action
-- spawns runs on threads of its own and is recorded like anything else.
const Applying: {[thread]: true} = {}

const function ShelfFor(Plr: Player): Shelf
    const Existing = Shelves[Plr]
    if Existing then
        return Existing
    end

    const Made: Shelf = {Undo = {}, Redo = {}, Next = 1, Busy = false, Forked = 0, Wiped = 0}
    Shelves[Plr] = Made
    return Made
end

const function Ids(Steps: {Step}): {number}
    const List = table.create(#Steps) :: {number}
    for Index, Step in Steps do
        List[Index] = Step.Id
    end

    return List
end

-- The client keeps no copy of what a step does, only where it sits in the
-- order, so this is the whole of what it is told.
const function Announce(Plr: Player)
    const Shelf = Shelves[Plr]
    if not Shelf or not Plr.Parent then
        return
    end

    Network.Changed:Fire(Plr, Ids(Shelf.Undo), Ids(Shelf.Redo))
end

--=============================================================================
-- Clear
--=============================================================================

-- The end of a step. Anything it was holding against an undo that will now
-- never come is disposed, which is the point at which a destroy that has been
-- deferred all this time actually happens.
--
-- Only an entry that caused the suspension owns the object: a Set entry names
-- an object it did not remove, and disposing it would end something another
-- step is keeping. That leaves Create and Destroy, and at most one live step
-- can own any one object -- a second destroy of the same object can only be
-- recorded after an undo revived it, and that undo is what moved the first step
-- onto the redo stack, where the new action clears it.
const function Clear(Step: Step)
    const Custom = Step.Custom
    if Custom then
        -- The game's, so it is allowed to throw without taking the stack with
        -- it: this runs while a new action is being recorded or a player is
        -- leaving, and neither is a good moment to fail.
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

const function ClearAll(Steps: {Step})
    for _, Step in Steps do
        Clear(Step)
    end

    table.clear(Steps)
end

-- How many objects a step keeps alive: one per create or destroy -- whichever
-- way the step was last applied, one of the two is holding a suspended object
-- -- and every object in a copy it loaded or unloaded. Weighed once, when the
-- step is recorded; objects created in a loaded copy afterwards are steps of
-- their own and weigh there.
const function Weigh(Step: Step): number
    local Held = 0

    for _, Entry in Step.Entries do
        const Copy = Entry.Copy
        if Copy then
            if Copy.Suspended then
                Held += #Copy.Suspended
            else
                for _ in Copy.Objects do
                    Held += 1
                end
            end
        elseif Entry.Kind == "Create" or Entry.Kind == "Destroy" then
            Held += 1
        end
    end

    return Held
end

const function Push(Plr: Player, Shelf: Shelf, Step: Step)
    Step.Weight = Weigh(Step)
    table.insert(Shelf.Undo, Step)

    local Held = 0
    for _, Kept in Shelf.Undo do
        Held += Kept.Weight or 0
    end

    -- Past the end of what is kept, by count or by what the steps hold. The
    -- step is gone for good, so it lets go of what it was holding.
    while #Shelf.Undo > 1 and (#Shelf.Undo > LIMIT or Held > HELD_LIMIT) do
        const Oldest = table.remove(Shelf.Undo, 1)
        if not Oldest then
            break
        end

        Held -= Oldest.Weight or 0
        Clear(Oldest)
    end

    -- A new action forks the history: everything that was undone is now
    -- unreachable, and every object those steps were keeping alive against a
    -- redo that will never come goes with them.
    ClearAll(Shelf.Redo)
    Shelf.Forked += 1
    Announce(Plr)
end

--=============================================================================
-- Applying
--=============================================================================

-- Whether the entry's object should be in the world once this step has been
-- applied in this direction. Undoing a create takes it away; undoing a destroy
-- brings it back; redoing does the opposite of each.
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

    const Reversed = table.create(#Entries) :: {Entry}
    for Index = #Entries, 1, -1 do
        table.insert(Reversed, Entries[Index])
    end

    return Reversed
end

-- Everything the step would do, checked before any of it is done. A refusal
-- here leaves the step where it was, to be tried again once the lock is
-- released or the right is granted back; it is not skipped and not partly
-- applied.
--
-- A value someone else has changed since is the one thing that is skipped
-- rather than refused. Their edit is theirs, and an undo that would write over
-- it takes back what it still can and leaves the rest alone.
const function Allowed(Plr: Player, Step: Step, Forward: boolean): boolean
    for _, Entry in Step.Entries do
        const Copy = Entry.Copy
        if Copy then
            -- Putting a copy back is loading it and taking it away is
            -- unloading it, so each asks for what the operation asked for.
            const Owner = Scenes:GetById(Copy.Scene)
            const Rights = if Owner then Owner:GetRights(Plr) else nil
            if not Rights then
                return false
            end

            if Present(Entry, Forward) then
                if not Rights.CanCreate then
                    return false
                end
            elseif not Rights.CanDestroy then
                return false
            end

            continue
        end

        const Obj = Entry.Target :: Object

        if not Audience.Sees(Plr, Obj.Scene) then
            return false
        end

        if Entry.Kind == "Set" then
            -- Checked even while the object is suspended, which it can be when
            -- the same step revives it: it still knows its scene and its type,
            -- and a lock it cannot be under answers no on its own.
            if Objects.LockedAgainst(Obj, Plr) then
                return false
            end

            if not Permissions:Can(Plr, "Edit", Obj, Entry.Property) then
                return false
            end
        elseif Present(Entry, Forward) then
            -- Bringing it back is making it: the same right a create needs, on
            -- the scene it would come back into.
            if not Permissions:Can(Plr, "Create", {Scene = Obj.Scene, Registry = Obj.Registry}) then
                return false
            end
        else
            if Objects.LockedAgainst(Obj, Plr) then
                return false
            end

            if not Permissions:Can(Plr, "Destroy", Obj) then
                return false
            end
        end
    end

    return true
end

const function Apply(Plr: Player, Step: Step, Forward: boolean): boolean
    const Custom = Step.Custom
    if Custom then
        -- One action, so one unit of the budget: the game decides what it does,
        -- and this side has no way to weigh it.
        if not Permissions:Consume(Plr, 1) then
            return false
        end

        -- Recording is off for this player while it runs. A custom verb is
        -- free to move objects around through the ordinary API, and every one
        -- of those would otherwise be recorded as a fresh action on top of the
        -- step being reversed -- a stack that grows every time it is undone.
        const Thread = coroutine.running()
        Applying[Thread] = true
        -- Widened so pcall's error message is in the type: an action returns
        -- nothing, and pcall of one types as the boolean alone.
        const Ok, Err = pcall((if Forward then Custom.Redo else Custom.Undo) :: () -> ...any)
        Applying[Thread] = nil

        if not Ok then
            -- Left where it was, like any other refusal, so the player can try
            -- again once whatever the action needed is there.
            Logger:Warn(`A custom history action failed and was left on the stack: {Err}`)
            return false
        end

        return true
    end

    if not Allowed(Plr, Step, Forward) then
        return false
    end

    -- One action for the step, whatever is in it. A transaction is one thing to
    -- take back however many operations it carried, and charging by the entry
    -- would mean a player who committed an edit at their ceiling could not undo
    -- it -- which is the moment they most want to.
    --
    -- The same reasoning a load is charged by, and the same trade: what bounds
    -- how much work a player can ask for this way is how often they may ask,
    -- not how big each ask is.
    if not Permissions:Consume(Plr, 1) then
        return false
    end

    const Changes: {{Object: Object, Property: PropertyTypes.PropertyIdentifier, Value: buffer}} = {}

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

        const Obj = Entry.Target :: Object

        if Entry.Kind == "Set" then
            const Prop = if Obj.Suspended then nil else Obj.Properties[Entry.Property :: number]
            const From, To = Ends(Entry, Forward)

            -- Changed since by something other than this step: left alone.
            if not Prop or not PropertyTypes:Equals(Prop.Type, Prop.Value, From) then
                continue
            end

            -- The property rather than the object's Set, which would send a
            -- packet each. Links are property listeners, so they still run.
            const _, Altered = Prop:Set(if To == nil then Prop.DefaultValue else To)
            if not Altered then
                continue
            end

            const Compressed = Compressor:CompressValue(Prop.Type, Prop.Value, Prop.Constraints)
            if Compressed then
                table.insert(Changes, {Object = Obj, Property = Entry.Property :: number, Value = Compressed})
            end
        elseif Present(Entry, Forward) then
            -- Announces itself, as its own kind of packet: an object arriving
            -- is not a property changing.
            Objects.Revive(Obj)
        else
            Objects.Suspend(Obj)
        end
    end

    -- A property put back on an object the same step went on to withdraw is not
    -- worth a packet: the removal already says everything a client needs, and
    -- this is a step redoing "edit it, then destroy it".
    const Announced = {}
    for _, Change in Changes do
        if not Change.Object.Destroyed then
            table.insert(Announced, Change)
        end
    end

    if #Announced > 0 then
        Objects.AnnounceChanged(Announced)
    end

    return true
end

const function Move(Plr: Player, Shelf: Shelf, From: {Step}, To: {Step}, Forward: boolean, Named: number?): boolean
    const Step = From[#From]
    if not Step or Shelf.Busy then
        return false
    end

    -- The client names the step it means. The two halves of one order live on
    -- opposite sides of the wire, so a client whose picture has drifted asks
    -- for something that is no longer on top -- and is told no and resynced,
    -- rather than quietly undoing a step it did not mean.
    if Named and Step.Id ~= Named then
        Announce(Plr)
        return false
    end

    -- Off its stack while it runs. Applying can yield, and in that time this
    -- player can make a new action, fork or clear their history, or leave. Each
    -- of those used to reach the step mid-apply: a new action landed on top and
    -- was the one removed afterwards in its place, and a fork or a clear
    -- disposed of objects the step was in the middle of bringing back.
    table.remove(From)
    const Pushed = Shelf.Next
    const Forked = Shelf.Forked
    const Wiped = Shelf.Wiped

    -- Wrapped, and not only to answer the caller: a custom action turns its
    -- player's recording off while it runs, and an error escaping it would
    -- leave their edits going unrecorded for the rest of the session.
    Shelf.Busy = true
    const Ok, Result = pcall(Apply, Plr, Step, Forward)
    Shelf.Busy = false
    Applying[coroutine.running()] = nil

    if not Ok then
        Logger:Warn(`A history step failed to apply and was left on the stack: {Result}`)
    end

    const Moved = Ok and Result == true

    -- Somewhere the step can no longer be reached from: the player left, or
    -- cleared everything, or it would land on a redo stack a new action has
    -- forked since. It ends here and lets go of what it holds, as it would
    -- have had it still been on the stack when that happened.
    const Gone = Shelves[Plr] ~= Shelf or Shelf.Wiped ~= Wiped
    const Destination = if Moved then To else From
    const Unreachable = Gone or (Destination == Shelf.Redo and Shelf.Forked ~= Forked)

    if Unreachable then
        Clear(Step)
    elseif Moved then
        -- A step that has moved is finished; a later set starts a run of its own.
        Step.Run = nil
        table.insert(To, Step)
    else
        -- Refused, so back where it was: under whatever this player recorded
        -- while it was being tried, which happened after it.
        const Since = if From == Shelf.Undo then Shelf.Next - Pushed else 0
        table.insert(From, math.max(1, #From - Since + 1), Step)
    end

    if not Gone then
        Announce(Plr)
    end

    -- Whether the step was applied, which is what the caller asked for, even
    -- when what happened meanwhile left it nowhere to go afterwards.
    return Moved
end

--=============================================================================
-- The server's own handle on it
--=============================================================================

-- Takes back a player's most recent step in the scenes the server owns. What a
-- game would call from a button of its own; the client's History calls the
-- channel below, which lands here.
function History:Undo(Plr: Player): boolean
    const Shelf = Shelves[Plr]
    return if Shelf then Move(Plr, Shelf, Shelf.Undo, Shelf.Redo, false) else false
end

function History:Redo(Plr: Player): boolean
    const Shelf = Shelves[Plr]
    return if Shelf then Move(Plr, Shelf, Shelf.Redo, Shelf.Undo, true) else false
end

-- An action of the game's own, on this player's stack, in the order their own
-- edits are in: undoing reaches it exactly where it happened. For the things
-- Prism does not model -- a camera bookmark, a rename in a game's own data --
-- so that Ctrl+Z means one thing in an editor rather than two.
--
-- Push it as the action happens; Undo and Redo are how to take it back and do
-- it again, and Clear, if it holds anything, is where that goes when the step
-- can no longer be reached. It costs one action of the player's budget to
-- reverse, because there is no way from here to know what it does.
function History:Push(Plr: Player, Action: Action): boolean
    if type(Action) ~= "table" or type(Action.Undo) ~= "function" or type(Action.Redo) ~= "function" then
        Logger:Warn("A custom history action needs an Undo and a Redo function.")
        return false
    end

    const Shelf = ShelfFor(Plr)
    Push(Plr, Shelf, {Id = Shelf.Next, Entries = {}, Custom = Action})
    Shelf.Next += 1
    return true
end

function History:CanUndo(Plr: Player): boolean
    const Shelf = Shelves[Plr]
    return Shelf ~= nil and #Shelf.Undo > 0
end

-- How much each player's stack keeps: Steps by count, Objects by what the
-- steps hold between them. Either may be left out to keep what it was. Takes
-- effect at the next step recorded; nothing already kept is dropped by asking.
function History:SetLimits(Limits: {Steps: number?, Objects: number?})
    if Limits.Steps and Limits.Steps >= 1 then
        LIMIT = math.floor(Limits.Steps)
    end

    if Limits.Objects and Limits.Objects >= 0 then
        HELD_LIMIT = math.floor(Limits.Objects)
    end
end

function History:GetLimits(): {Steps: number, Objects: number}
    return {Steps = LIMIT, Objects = HELD_LIMIT}
end

function History:CanRedo(Plr: Player): boolean
    const Shelf = Shelves[Plr]
    return Shelf ~= nil and #Shelf.Redo > 0
end

-- Forgets everything this player could undo, and lets go of everything those
-- steps were holding. What a game calls when it hands the player a different
-- level to edit and the old one's steps would be nonsense.
function History:Clear(Plr: Player)
    const Shelf = Shelves[Plr]
    if not Shelf then
        return
    end

    ClearAll(Shelf.Undo)
    ClearAll(Shelf.Redo)
    Shelf.Wiped += 1
    Announce(Plr)
end

-- Just the redo stack. A new action forks the history, and this side forks its
-- own whenever it records one -- but the player's actions in a scene the client
-- owns are recorded over there, and they fork this half too. One order, one
-- fork.
function History:Fork(Plr: Player)
    const Shelf = Shelves[Plr]
    if not Shelf then
        return
    end

    -- Counted even with nothing on the redo stack: a redo being applied right
    -- now is off it, and has to learn it was forked.
    Shelf.Forked += 1
    if #Shelf.Redo == 0 then
        return
    end

    ClearAll(Shelf.Redo)
    Announce(Plr)
end

--=============================================================================
-- Recording
--=============================================================================

-- A whole transaction is one step, which is what a transaction is for: one
-- packet, one permission pass, one thing to take back. Taking the record means
-- taking the objects its destroys suspended, so this answers true.
Transactions.OnApplied(function(Plr: Player, Record): boolean
    if Applying[coroutine.running()] then
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

    const Shelf = ShelfFor(Plr)
    Push(Plr, Shelf, {Id = Shelf.Next, Entries = Entries})
    Shelf.Next += 1
    return true
end)

-- A single set, and a run of them to one property merged into one step, so a
-- drag undoes as the drag it was rather than as a hundred frames.
Objects.OnPlayerEdited(function(Plr, Obj, Property, Before, After)
    if Applying[coroutine.running()] then
        return
    end

    const Now = os.clock()
    const Shelf = ShelfFor(Plr)
    const Top = Shelf.Undo[#Shelf.Undo]
    const Run = if Top then Top.Run else nil

    if
        Run
        and Run.Target == Obj.RuntimeId
        and Run.Property == Property
        and Now - Run.At <= MERGE_WINDOW
    then
        -- Still the same drag: the step now ends where this set did, and still
        -- begins where the first set in it started.
        Top.Entries[1].After = After
        Run.At = Now

        -- The run began with a push, which forked the history then. Anything
        -- that has arrived on the redo stack since is a step this player can no
        -- longer reach past a drag in progress, so it goes -- but only if there
        -- is any, because this runs once a frame for as long as the drag lasts
        -- and a packet a frame saying nothing changed is worse than the drag.
        if #Shelf.Redo > 0 then
            ClearAll(Shelf.Redo)
            Announce(Plr)
        end

        return
    end

    Push(Plr, Shelf, {
        Id = Shelf.Next,
        Entries = {{Kind = "Set" :: "Set", Target = Obj, Property = Property, Before = Before, After = After}},
        Run = {Target = Obj.RuntimeId, Property = Property, At = Now},
    })

    Shelf.Next += 1
end)

-- A lone destroy, which used to be the one edit nothing could take back: it
-- went through neither a transaction nor a set, so the client's history never
-- saw it. Claiming it here is what keeps the object.
Objects.OnRetired(function(Plr, Obj): boolean
    -- Nothing is kept while a step is being applied. A custom action that
    -- destroys something as part of undoing is destroying it for good, because
    -- the step it is part of is the thing that would have to bring it back and
    -- that step is already busy being that.
    if not Plr or Applying[coroutine.running()] then
        return false
    end

    const Shelf = ShelfFor(Plr)
    Push(Plr, Shelf, {Id = Shelf.Next, Entries = {{Kind = "Destroy" :: "Destroy", Target = Obj}}})
    Shelf.Next += 1
    return true
end)

--=============================================================================
-- Channels
--=============================================================================

Network.Undo.OnInvoke = function(Plr: Player, Step: number): boolean
    const Shelf = Shelves[Plr]
    return if Shelf then Move(Plr, Shelf, Shelf.Undo, Shelf.Redo, false, Step) else false
end

Network.Redo.OnInvoke = function(Plr: Player, Step: number): boolean
    const Shelf = Shelves[Plr]
    return if Shelf then Move(Plr, Shelf, Shelf.Redo, Shelf.Undo, true, Step) else false
end

Network.Forget.OnInvoke = function(Plr: Player, RedoOnly: boolean): boolean
    if RedoOnly then
        History:Fork(Plr)
    else
        History:Clear(Plr)
    end

    return true
end

-- Their stacks go with them, and so does everything those stacks were holding.
-- Keeping them for a rejoin would mean keeping every object they had destroyed,
-- against a player who may never come back, in a world that has moved on.
Players.PlayerRemoving:Connect(function(Plr: Player)
    const Shelf = Shelves[Plr]
    if not Shelf then
        return
    end

    Shelves[Plr] = nil
    ClearAll(Shelf.Undo)
    ClearAll(Shelf.Redo)
end)

return History
