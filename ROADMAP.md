# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

Nothing here waits on Studio. The suites in `tests/` are written alongside the
work and left unrun on purpose — the framework gets played through in one pass
once it is structurally finished, so a ticked item means the work landed and
reads right, never that it was run with a player in it.

## Queued

- [ ] **Unregistering does not reach the client.** `Properties:Unregister` drops
      a registry on the server and tells nobody, so every client keeps serving
      the old one from its own copy. Scenes now announce it; properties predate
      that and still do not. Object types have no unregister at all.

- [ ] **Object added / removed signals on the client.** `AddObject` and
      `Teardown` are internal, so UI has to poll `GetWorkspace()` to notice
      anything appearing.
- [ ] **Per object locks and presence.** Two clients dragging the same object
      fight each other, and the optimistic-set rollback makes the loser's screen
      jump. Needs to know who has what selected.
- [ ] **Property display metadata.** `Display = {Category, Order, Description,
      Hidden, ReadOnly}` on the registry, which already replicates — enough for
      a property panel to be generated rather than written per property.
- [ ] **`Duplicate(object)`.** `Objects.new` already accepts initial values.
- [ ] **Scene history: diff, merge, revert.** Two properties the format already
      has make this reachable rather than speculative. A copy serialises
      deterministically — objects in local id order, properties in property id
      order — so two versions of a scene produce comparable bytes instead of
      whatever hash order gave. And persistent ids survive a save, so a diff can
      say "this object changed" rather than "an object went and another came".
      That is the whole basis of a three way merge. `Commit` is the point a
      version would be recorded at.

- [ ] **Undo / redo.** Transactions are the unit to record, and they already
      carry the reversal rules: a create is undone by destroying what it made, a
      set by writing back what it overwrote, and a destroy by neither, which is
      why it goes last. Identity is no longer the open problem: a resurrected
      object can come back under the id it had.

## Done

- [x] **Client owned scenes.** A scene whose objects the server never sees — a
      prefab preview, a sandbox, a room built before anyone else is shown it.
      The same document a server scene is, except that nothing in it replicates,
      so its objects apply their own edits: there is nobody to ask and nothing
      to roll back to. `Objects:Localize` hands over the half of a registry the
      wire cannot carry — the template and its links — once per object type, and
      the link machinery moved to `Objects/Shared` so a local object drives its
      instance through the same code a server one does. Local scene, copy and
      runtime ids count down from the top of each id space while the server's
      count up, so the two never collide, and no scene id is written into a pack
      in any case.

      It finishes by handing a scene over rather than by pushing operations:
      `Push` sends the committed pack in one packet and the server registers a
      scene of its own from it, refusing it unless it may create every object
      type in it, and re-encoding it so the pack it keeps is the one it wrote.
      It registers and does not load — putting a room in the world is the
      server's call. A commit costs one action and is bounded by size, where a
      transaction charges per operation: a transaction's operations each reach
      into the world as it stands, while a commit arrives whole and what bounds
      it is known before a byte of it is read.

- [x] **Transactions.** One channel carrying a list of operations — create, set,
      destroy — planned and applied as a unit, so a multi-object edit is one
      packet, one permission pass and one thing to record. A single refusal ends
      it before the world moves; a failure partway rolls the reversible part
      back, which is why the apply order is creates, then sets, then destroys
      whatever order they were declared in — a destroy is the one operation that
      cannot be taken back. Subsumes the missing create path: `Objects.new` is
      server side, and until this there was no channel that asked for a create,
      so `Permissions:Can(_, "Create", _)` was reached by nothing. The rate
      limiter now charges per operation rather than per call, and the result
      comes back as one broadcast rather than one per operation — created
      objects down the chunked path a scene load uses, changes and removals
      through bulk channels beside the single ones.

- [x] **Scenes and object identity.** A scene is a document: registering one
      creates data, `Load` reads it into a live copy, and loading twice gives
      two equal copies, so one saved room can stand in the world five times.
      Objects live on the copy, because a scene loaded twice cannot answer which
      object you mean. Identity split in two: `RuntimeId` names one live object
      and is the only thing on the wire or in the workspace key, `PersistentId`
      (`SceneId * 2^32 + LocalId`) names an object in a pack and is the only
      thing saved. One crossing, `instance:Find`, scoped to a copy. Only the low
      half is packed, so a pack is portable between scenes. `Commit` writes a
      copy back; unloading never saves on its own, because with several copies
      live it would have to pick one. `Objects.new` still works, in an implicit
      `Default` scene loaded on first use.

- [x] **Property access from the object.** `OnChange` and `GetProperty` beside
      `Get` and `Set`, all four taking an id or a name, with the name resolved
      through a map instead of a scan.
- [x] **Selection.** Was unreachable — not exported from `init.luau` — and its
      `Query` referenced an undefined type. Now exported on the client, strict,
      with `Contains` and an `OnChange` that fires with the whole selection.

## Owned elsewhere

- Saving and loading a level's contents. The database stores metadata records,
  not the object graph; `CompressObject` and `fromCompression` are the seam.
  Pedro is taking this one.
