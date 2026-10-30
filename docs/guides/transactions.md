# Transactions

A list of operations — create, set, destroy — validated and applied as a unit.
One packet up, one permission pass, and one thing for an editor's history to
record.

```luau
-- client (or server, on a player's behalf)
local edit = Prism.Transactions.new()

edit:Create(Crate, {[Health] = 50}, room.Id)
    :Duplicate(original)             -- a create holding original's values
    :DuplicateGroup(selection)       -- the same, references between them remapped
    :Place(prefab, room.Id)          -- a saved pack, one create per object in it
    :Lock(selection)                 -- one object or a list, all or none
    :Set(other, "Health", 20)
    :Destroy(stale)
    :Unlock(selection)
    :Load(sceneId)                   -- a copy of a scene into the world
    :Unload(copyId)                  -- and a live copy out of it

local applied, created = edit:Commit()
```

`Commit` answers whether the whole list landed, and the runtime ids of what it
created, in the order the creates were declared. `Create` takes the copy the
object belongs in, because a scene loaded twice has two equally good ones;
leave it out and the object lands where `Objects.new` would have put it.

Nothing is applied unless everything passes. A single refused operation ends the
transaction while the world has not moved yet, and an operation that could not
even be built — an unknown property, a target that is not an object — makes
`Commit` refuse rather than send what is left.

This is also the only way a client creates an object in a scene the server
owns: `Objects.new` is server side, and a transaction's `Create` is what a
role's `CanCreate` governs.

## Not only for talking to the server

A transaction whose objects are all in scenes the client owns **applies on the
spot**. Same builder, same operations; `Commit` sees what it is about and either
sends it or does the work, and a local commit does not yield because there is
nobody to ask.

That is how a local edit is batched: every set, create and destroy in it is
one apply and one undo step, so undoing a pasted prefab takes it away whole
rather than one object at a time.

```luau
-- A whole prefab into a copy this client owns: one edit, one undo step.
Prism.Transactions.new():Place(prefab, sandbox.Id):Commit()
```

A transaction is **all local or all the server's**, never both. The second kind
to arrive is refused by name when it is added. That one is forced: half of a
mixed transaction needs a round trip that can come back refused, and by then the
local half has already applied — there is no atomicity to be had across that
line, and a transaction that cannot be atomic is not one.

Everything else is the same on both paths: the three phases in the same order,
a rollback if it throws partway, and one entry in the history.

## Holds, and copies

`Lock` and `Unlock` put taking a hold in the same list as the edit that needs
it. Locking three objects and moving them is one packet that either gets all
three and moves them or does neither, rather than a lock that can come back
refused after the edit was already built. Locks are taken
before everything else in the transaction and released after — hold these, do
this, let go. Refused for objects in scenes the client owns, which are never
held: nobody else can touch them.

`Load` names a scene and `Unload` a live copy, and they are the only way a
client asks for either — there is no channel of their own. Loading needs the
**create** verb on that scene and unloading needs **destroy**, because that is
what they amount to: every object in it made, or every object in it taken away.
The verb alone: a pack holds whatever it holds, so there is no type to check the
object lists against, and those lists govern what a role builds by hand.

The copy a load makes is not in what `Commit` hands back. It arrives the way
created objects do, through the packet announcing it — `Scenes:OnCopyAdded`.

An unload **withdraws** the copy rather than unloading it: out of the
registries, its folder out of the tree, every object in it suspended, the whole
thing kept. That is what makes it undoable. Loading it again would read what the
scene last committed, which is not what was on screen unless somebody had just
saved; withdrawing it means an undo brings back exactly what was there. The copy
ends when the step holding it does, the same way a destroyed object does.
`copy:Unload()` from server code is still final — nobody asked for that one.

## Ordering

Operations apply locks first, then loads, then creates, then sets, then
destroys, then unloads, then the releases — whatever order they were declared
in. That is what makes a transaction atomic rather than merely
batched: a create can be taken back by destroying what it made, and a set by
writing back what it overwrote, but a destroy cannot be taken back at all — so
nothing irreversible happens until everything reversible has already succeeded.

Two sets on one property are one change by the time it lands, and an object
destroyed by the same transaction that changed it is announced once, as gone.

## On the client

`Commit` yields until the server answers, and applies nothing early. A single
`Set` is optimistic because it has a local object to write to and a value to
roll back to; a create has neither, and no id at all until the server mints one.

The result comes back as one broadcast rather than one per operation: created
objects arrive down the same chunked path a scene load uses, and changes and
removals have bulk channels beside the single ones.

## Budget

Undo and redo spend one action each, whatever the step holds: a transaction is
one thing to take back however many operations it carried, and charging by the
entry would leave a player who committed an edit at their ceiling unable to undo
it. Loading a scene is one action for the same reason.

A transaction spends one action per operation rather than one per packet, so a
role with `Rate = 60` may commit sixty operations a second however they are
grouped. Charging per call would let one packet carrying ten thousand
operations walk straight past the limiter. A single transaction carries at most
1024 operations.
