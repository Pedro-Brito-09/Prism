# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

Nothing here waits on Studio. The suites in `tests/` are written alongside the
work and left unrun on purpose — the framework gets played through in one pass
once it is structurally finished, so a ticked item means the work landed and
reads right, never that it was run with a player in it.

## Queued

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

- [x] **Object added / removed signals on the client.** `Objects:OnAdded` and
      `OnRemoved`, for every object however it arrived: replicated, built in a
      scene the client owns, or drawn for an opened copy. Added fires once the
      object is filed; removed fires after teardown, with the object still
      carrying its ids. UI no longer polls `GetWorkspace()`. The listener
      helpers moved out of `Scenes/Client` into `Listeners`, which both use.

- [x] **A pushed scene belongs to its author, and templates warn where they
      matter.** `Push` registers the scene admitting only the player who
      pushed it, and `Scenes:SetPushRole` grants them a role on it; it used
      to register public, with the author holding nothing. The warning about
      a template in ServerStorage moved from registration, where it fired for
      every such type in games whose clients never build anything, to the
      client, once per type, the first time it tries to build one and cannot
      see the template. The registry says whether it has one, so a client
      can tell "none" from "not here".

- [x] **Unregistering reaches the client.** `Properties:Unregister` used to
      drop a registry on the server and tell nobody; object types had no
      unregister at all. Both now announce it on a channel of their own, and
      both are refused while something is built on them: a property while an
      object type or a database holds it, counted in Properties because it
      cannot require either, and an object type while any object of it is
      live. Neither id is handed out again.

- [x] **Permissions, per scene and by user id.** Rights split in two. Global
      rights — the action budget, `CanPush`, global capabilities — are about the
      session. Scene rights — Prism's three verbs, object and property
      whitelists and blacklists, the scene's capabilities — are about one
      scene, and every copy of it shares them. `Can` resolves the scene from
      the object it is handed; a create names the scene and type it would make.
      No grant on a scene means nothing there. The budget is the one default:
      60 for anyone ungranted, because it is a ceiling rather than a right.

      A role is a template with a global half and a scene half. Granting one
      clears what the player held and copies the role in; capabilities are then
      granted and revoked one at a time, and editing a role later reaches
      nobody who already holds it. Every grant is keyed by user id, so an owner
      holds their rights again on rejoin. Scene rights go with their scene,
      global ones with the server, and nothing is saved — `Scenes.new` takes
      `Rights` so a game hands over the collaborator list it already keeps.
      Property lists take ids or `[Tint] = {Crate}` and govern writing only.
      Pushing a scene is the global `CanPush` and no longer checks the pack's
      types against a role.

- [x] **`Open`, and clients that draw.** `Scene:Open()` holds a copy's data on
      the server and builds no parts and no folder. Each admitted client draws
      the copy from the replicated template into a folder of its own, driving
      the parts through the registry's links. Whether a copy was opened rides
      on `InstanceAdded`, so a slow join cannot mistake "the server built no
      part" for "the reference did not survive" and draw a second one. An
      opened copy is kept for the admitted whatever `Replicate` says.
      `Scenes:OnCopyAdded`, `OnCopyRemoved` and `GetFolder` are the handle a
      game places a drawn copy with — into PlayerGui, for a scene of
      interfaces. `World` keeps its scene folders by reference, so a client
      never files into or destroys the server's folder of the same name.

- [x] **`Replicate` on an object type.** `"Everyone"`, the default as designed,
      or `"Admitted"`. A player holds a scene at two reaches: every player is
      owed a loaded copy and its objects that replicate to everyone, which
      leaks a copy id and a scene id and nothing else; an admitted player is
      owed the scene's name and the rest. Per type rather than per property, so
      an object goes whole or not at all and the client never builds a partial
      one. The default means a private scene built with `Load` still sends
      every player its copies and every type left at the default — privacy is
      something each type opts into. Anything but the two strings is kept to
      the admitted.

- [x] **Admission.** `Scene:Admit` and `Evict`, by Player or user id, and
      `Scenes.new({Admitted})` for a scene that is never public. A scene that
      has admitted nobody is public, and the list belongs to the scene rather
      than to whoever is connected. `Scenes/Audience` tracks what each player
      has actually been sent, and every packet about a scene is addressed by
      that rather than fired at everyone. The join replay sends types first and
      then reveals each scene through the same path an admission does. Edits to
      a scene a player is not admitted to are refused as if its objects were
      not there. Evicting the last player makes a scene public again, the
      evicted included.

- [x] **Registries replicate whole.** The template and the links ride with the
      registry, so a client builds from exactly what the server does. A
      reference resolves on a client exactly when the instance replicates to
      them: a template in ReplicatedStorage arrives, one in ServerStorage
      arrives as nil, and registration warns about the second.
      `Objects:Localize`, `GetLocalized` and `LocalRegistry` are gone.

- [x] **The world tree.** No Container field on three configs. A copy owns a
      folder, `Load(parent)` places it, and
      `workspace.__prism.__scene_N.__copy_N` is where it goes otherwise — by
      copy, because a scene loaded five times is five copies. A Folder rather
      than a Model, so a copy parents anywhere — PlayerGui, Lighting, a Model
      you pivot — and Prism never needs a table of which class belongs where.

- [x] **Client owned scenes.** A scene whose objects the server never sees — a
      prefab preview, a sandbox, a room built before anyone else is shown it.
      The same document a server scene is, except that nothing in it replicates,
      so its objects apply their own edits: there is nobody to ask and nothing
      to roll back to. The link machinery moved to `Objects/Shared` so a local
      object drives its instance through the same code a server one does. (It
      took its template from `Objects:Localize` until registries replicated
      whole.) Local scene, copy and runtime ids count down from the top of each
      id space while the server's count up, so the two never collide, and no
      scene id is written into a pack in any case.

      It finishes by handing a scene over rather than by pushing operations:
      `Push` sends the committed pack in one packet and the server registers a
      scene of its own from it, re-encoding it so the pack it keeps is the one
      it wrote. It registers and does not load — putting a room in the world is
      the server's call. A commit costs one action and is bounded by size,
      where a transaction charges per operation: a transaction's operations
      each reach into the world as it stands, while a commit arrives whole and
      what bounds it is known before a byte of it is read.

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
