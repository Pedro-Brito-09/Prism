# Locks

A client takes a lock when it starts on an object. While it holds one, nobody
else may edit or destroy that object, so two people cannot drag one part at
once.

```luau
-- client
if Prism.Objects:Lock(selected) then   -- one object or a list: all or none
    -- drag
    Prism.Objects:Unlock(selected)
end

Prism.Objects:IsLocked(object)         -- held by anyone at all
Prism.Objects:GetLock(object)          -- the holder's user id, or nil
Prism.Objects:OnLockChanged(function(runtimeId, userId, held) ... end)
```

Taking a lock needs edit rights on the object, costs one action per object, and
fails if anyone else holds any of the objects named. Releasing needs no rights.
`IsLocked` and `GetLock` answer for your own holds as soon as `Lock`, `Unlock`
or a transaction holding them returns.

On a client, `Set` and `Destroy` on an object someone else holds are refused on
the spot — `false`, and nothing shown — rather than applied and taken back when
the server says no. On the client `Permissions:Can` says no to
an edit or a destroy of an object someone else holds, so a tool greyed out by
it is greyed out for held objects too. Listen to `Objects:OnLockChanged` to
refresh it when a hold comes or goes.
A transaction can take and release them too, in the same list as the edit they
are for — see [Transactions](/guides/transactions#holds-and-copies).

**The server can hold a lock itself.** On the server, `Objects:Lock(objects,
holder)` takes one object or a list, and a holder: a Player, a user id, or any
other value naming who holds it — a string like `"DoorAnimator"`, a module, a table. That lets a system keep players
off an object while it works on it, such as animating a door open, with no
player involved:

```luau
-- server
Prism.Objects:Lock(door, "DoorAnimator")
-- animate the door; no player can edit it meanwhile
Prism.Objects:Unlock(door)
```

`GetHolder(object)` gives back whatever holds it. `GetLock(object)` gives only a
player's user id, and `nil` both when nothing holds the object and when the
holder isn't a player — so use `IsLocked(object)` to ask whether anything holds
it at all.

A lock is released when its object goes, or when its holder **leaves**, is
**evicted from the scene** or **loses edit rights on it** — any of those would
leave somebody holding objects they can no longer touch, and nobody else able to
touch them either.

The server's own edits ignore locks. The server can take locks on a player's
behalf with `Objects:Lock(list, player)`, which is refused the same way if
someone else holds any of them, and release anyone's with
`Objects:Unlock(list)`.

Who holds what is presence as well as a lock. It's told only to the players the
object's scene admits, because who is editing a private level is part of the
level. Objects in scenes a client owns are never locked; nobody else can touch
them.
