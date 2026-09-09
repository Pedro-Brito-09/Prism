# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

## In design

- [ ] **Client owned scenes.** A scene whose objects the server never sees — a
      prefab preview, a local sandbox. Needs `Objects.new` on the client and a
      local authority path: apply on the spot, no invoke, no rollback. The
      client never receives a registry's template instance, so a local scene has
      to be handed one explicitly. Its natural finish — committing a local scene
      to the server — is a transaction full of create operations, so
      transactions are worth doing first.

- [ ] **Transactions.** One channel carrying a list of operations — create, set,
      destroy — validated and applied as a unit, so a multi-object edit is one
      packet, one permission pass and one entry in the undo history. Subsumes
      the missing create path: the client cannot create an object today because
      no channel asks for it, and `Permissions:Can(_, "Create", _)` is reached
      by nothing.
      *Note: the rate limiter has to charge per operation, not per call, or a
      single transaction with ten thousand operations walks past it.*

## Queued

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

- [ ] **Undo / redo.** After transactions, which give it the unit to record.
      Identity stops being the open problem once handles land: a resurrected
      object can come back under the id it had.

## Done

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
