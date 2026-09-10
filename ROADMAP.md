# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

Nothing here waits on Studio. The suites in `tests/` are written alongside the
work and left unrun on purpose — the framework gets played through in one pass
once it is structurally finished, so a ticked item means the work landed and
reads right, never that it was run with a player in it.

## In design

- [ ] **Client owned scenes.** A scene whose objects the server never sees — a
      prefab preview, a local sandbox. Needs `Objects.new` on the client and a
      local authority path: apply on the spot, no invoke, no rollback. The
      client never receives a registry's template instance, so a local scene has
      to be handed one explicitly. Its natural finish — committing a local scene
      to the server — is a transaction full of create operations, which now
      exist; what it needs from them is a way past the per-operation budget, or
      a role allowed to spend it.

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
