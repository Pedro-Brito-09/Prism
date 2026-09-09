# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

## In design

- [ ] **Scenes.** Objects are created into a named scene instead of one global
      workspace. `Scene:Load()` materialises it, `Scene:Unload()` takes it back
      down. Scenes exist on the server and on the client. Authored in code; a
      game that wants players creating their own scenes builds that on top of
      the API. Replaces the case for an object hierarchy — grouping falls out of
      scenes rather than needing a parent field on every object.
      *Blocked on three decisions: who sees a loaded server scene, what Unload
      does to the objects, and what a client side scene actually owns.*

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
- [ ] **Undo / redo.** After transactions, which give it the unit to record.
      The open problem is identity: resurrecting a destroyed object mints a new
      runtime id, and every reference still points at the old one.

## Done

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
