# Dragging: `ClientSided`

On the client, `Set` takes a third argument. `true` shows the value on this
client and sends nothing; the next `Set` without it sends the value it lands on,
once. Pass it every frame of a drag and leave it off when the drag ends:

```luau
-- client, while the gizmo moves
crate:Set(Position, pointer, true)

-- on release
crate:Set(Position, pointer)
```

A plain `Set` per frame costs one action of the player's budget each, so a drag
at sixty frames a second sits exactly on the default `Rate` and starts being
refused, and a refusal snaps the value back mid-drag. With `ClientSided` the
drag costs one action and is one step of history however long the player
paused in it.

- **Nothing else sees the preview.** `OnChange` and links fire, so the part
  moves; `Objects:OnEdited` does not, because no edit has been made yet. The
  closing `Set` fires it once, with `Before` being the value from before the
  preview began. That holds for a part the server built too: a client drives
  its links on every part it can see, writing only its own view of the part,
  which the server's value replaces once the edit lands or is refused.
- **Cancelling** is ending the preview on the value it started from: that sends
  nothing and records nothing.
- **A refusal** of the closing `Set` rolls back to what the server holds, as any
  refused set does.
- **Someone else's edit** to the same property during a preview does not move
  it; it becomes the value a refusal or a cancel returns to.
- A preview left open on a server object is just a value shown on one client:
  the server and every other player never see it. In a scene the client owns
  the shown value is the value, so committing that scene saves it.

A gizmo works in the world and a value is relative to its copy, so in a copy that
has been moved, cross over first with
`Prism.Scenes:ToLocal(crate.InstanceId, pointer)`; see
[Local space](/guides/local-space#working-in-the-world).

The argument is ignored on the server, where every set is already the real one.
It works the same on an object in a scene the client owns, where nothing is sent
either way but the history still records the drag as one step.
