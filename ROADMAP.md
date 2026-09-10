# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

## In design

- [ ] **Scenes + object identity.** One refactor, not two: objects cannot be
      keyed by a scene-scoped id until scenes exist, and keeping runtime ids
      through a scenes release would be work thrown away.

      *Scenes.* Objects are created into a named scene instead of one global
      workspace. Scenes are registered in code, with stable ids, the way
      property and object types already are. `Scene:Load()` rebuilds the scene
      from its pack, `Scene:Unload()` serialises it and destroys the objects,
      so an unloaded scene costs a buffer. A loaded server scene is visible to
      every player. An implicit always-loaded `Default` scene keeps plain
      `Objects.new` working. Replaces the case for an object hierarchy.

      *Identity.* `RuntimeId` -- session-local, minted fresh every load -- is
      replaced by a durable handle, `SceneId * 2^32 + ObjectId`, which stays a
      single exact number in Luau and so stays a single argument everywhere.
      The pack stores only the low half, the id within the scene, so a pack
      stays portable: loading the same prefab into two scenes yields two
      non-colliding sets of handles, and cross references inside a pack are
      remapped together. Ids are never recycled within a scene; the scene's
      `LastId` is saved in the pack exactly as `CompressMetadatas` already
      saves the metadata one. `FORMAT_VERSION` stays at 1 and the layout
      changes in place -- nothing has ever been written by a released build.

      *Load and unload are single packets.* Tearing down a 5000 object scene
      with one `ObjectRemoved` each is the flood `Replication` was written to
      avoid.

      *Then, separately:* client owned scenes, whose objects the server never
      sees -- a prefab preview, a local sandbox. Needs `Objects.new` on the
      client and a local authority path (apply on the spot, no invoke, no
      rollback). The client never receives a registry's template instance, so
      a local scene has to be handed one explicitly. Its natural finish --
      committing a local scene to the server -- is a transaction full of
      create operations, so transactions are worth doing in between.

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
      Identity stops being the open problem once handles land: a resurrected
      object can come back under the id it had.

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
