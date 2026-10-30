# History

Undo and redo, per player. The client drives it:

```luau
-- client
Prism.History:Undo()      -- yields while the server answers for its half
Prism.History:Redo()
Prism.History:CanUndo()
Prism.History:OnChange(function() toolbar:Refresh() end)
```

A step is one committed transaction, one create or destroy, or a run of
`Object:Set` calls to one property with no pause longer than a second, so a drag
undoes as one. A drag written with `ClientSided` is one step however long it
paused, because only its closing set is an edit. A copy loaded or unloaded by a
transaction is part of its step: undoing a load withdraws the copy it made, and
undoing an unload puts back the one it took, objects and values and ids intact. Holds are not recorded — a lock
is not a change to the world, and taking somebody's hold back is not an undo.

Each stack keeps the last 100 steps. That count is **per player and across every
scene** — editing two rooms does not give you two hundred steps, because what
you take back is one sequence of things you did rather than one per room. The
server's half and the client's half do count separately, though: only the client
can see both, and a client that has gone quiet must not be what decides how much
the server holds on to.

Steps are also capped by **what they hold**: at most 10,000 objects kept alive
between them on each half. A step holds one object per create or destroy, and
every object in a copy it loaded or unloaded, so a hundred unloads of a large
room cannot keep a hundred large rooms in memory. The oldest steps go until the
rest fit, except the newest, which is kept however much it holds.

Both limits can be changed on each side, and take effect at the next step
recorded. Setting them on the server applies to every player's stack; setting
them on a client applies to that client's own half:

```luau
-- server or client
Prism.History:SetLimits({Steps = 50, Objects = 2000})
Prism.History:GetLimits()     -- {Steps = 50, Objects = 2000}
```

## A destroy is deferred, not undone

Undoing a destroy does not build a replacement. The object is **suspended**:
withdrawn from the world by every measure — `Destroyed` reads true, it is gone
from the workspace and from its copy, its part is parented out of the world and
every client has been told — while the table, its property values, its runtime
id and its local id all survive. Undo revives that same object, with the part it
had rather than a fresh clone of the template, so whatever the game hung on that
part is still hanging there. The part is destroyed by `Clear`, with the rest.

That is what keeps references working. A reference stores a local id, a scene
never issues one twice, and an object that comes back under its own is pointed
at again by everything that was pointing at it. Rebuilding a lookalike would get
a fresh id and leave every reference to the original dangling.

Undoing a create is the same act in reverse: the object is suspended, not
destroyed, because redo has to bring back *that* object.

So something has to decide when a destroy is finally a destroy. That is
`Clear`, and it runs in exactly three places: when a new action forks the redo
stack a step was sitting on, when a step falls off the end of the stack past
either limit — the step count or the object count — and when the player leaves
(or `History:Clear()` is called). A step with nothing holding it lets go of
whatever it was keeping, and only then are the values gone. With **nothing
keeping it at all** — a game that never requires `Prism.History` — a destroy is
immediate.

## Where the steps live

Split by who owns the scene, because a step has to hold objects and objects live
on one side or the other.

| | recorded | applied |
|---|---|---|
| the server's scenes | server, per player | server, through the same rights, locks and budget as any edit |
| scenes the client owns | client | client, on the spot |

The client keeps the **order** — one list where each place is either a step of
its own or the id of one the server holds — so a single undo takes back the last
thing the player did whichever side recorded it. An undo of a server step names
the step it means; if that is not the one on top, the server says no and sends
back its stacks, which the client reconciles against. A new action on either
side forks the redo stack on both. That fork, and `Clear`, reach the server in
the order they happened among the player's edits, so an edit made straight
after `Clear` is recorded and one made straight before it is cleared. Neither
yields.

Recorded server side: every transaction a player commits, every `Object:Set`
through the single channel, and every lone `Object:Destroy`. Commit a transaction with `Untracked = true`
to keep it out. Recorded client side: creates, destroys and sets in scenes the
client owns. A copy reading its own pack back is not an action and is not
recorded.

If someone else has changed a property since, undo and redo leave that property
alone and apply the rest of the step. A refused undo — a lock, a missing right —
stays on the stack to be tried again. An object whose copy has been unloaded
cannot come back, and that entry is skipped.

On the server, `Prism.History` takes the player: `History:Undo(player)`,
`Redo`, `CanUndo`, `CanRedo`, `Clear(player)`.

## Actions of your own

Not everything an editor does is an object. Push a step of your own and it sits
in the same order, so one Ctrl+Z reaches it where it happened:

```luau
-- client; on the server, History:Push(player, {...})
Prism.History:Push({
    Undo = function() camera:GoTo(before) end,
    Redo = function() camera:GoTo(after) end,
})
```

The same three verbs every step has. `Clear` is optional and is the one to read
twice: it runs when the step can no longer be reached — forked off the redo
stack, pushed past either limit, or the player leaving — and is where an action
holding something of its own lets go of it, exactly as Prism's own steps
finally destroy the objects they were keeping.

```luau
-- client
local snapshot = Terrain:CopyRegion(region)

Prism.History:Push({
    Undo = function() Terrain:PasteRegion(snapshot, corner, true) end,
    Redo = function() Terrain:Clear(region) end,
    Clear = function() snapshot:Destroy() end,
})
```

A step is either yours or Prism's, never both — mixing them would mean deciding
where your verb runs among entries it knows nothing about, and two pushes say it
plainly. Pushing one forks the redo stack like any other new action. An `Undo`
or `Redo` that throws leaves the step on the stack to be tried again, and
nothing you do inside either one is recorded as a new action. That covers
what runs on the action's own thread -- not threads it spawns -- and nothing
else: an edit the player makes while an action yields is recorded as usual.

On the server it takes the player — `History:Push(player, action)` — and costs
one action of their budget to reverse, since nothing here can weigh what it
does. A client-side push covers the client's half of the order; there is no way
to hand the server a function, so an action that has to run there is pushed
there.

The history is built on signals you can use yourself: `Objects:OnEdited(fn)` on
the client for its own `Object:Set` calls, `Objects.OnPlayerEdited(fn)` on the
server for a player's, `Transactions:OnCommitted(fn)` on the client and
`Transactions.OnApplied(fn)` on the server, and `Objects.OnRetired(fn)` on both
— which is the one that decides whether a destroyed object is kept.
