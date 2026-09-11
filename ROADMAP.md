# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

Nothing here waits on Studio. The suites in `tests/` are written alongside the
work and left unrun on purpose — the framework gets played through in one pass
once it is structurally finished, so a ticked item means the work landed and
reads right, never that it was run with a player in it. Do not suggest running
them; that pass is Pedro's call and comes after the queue below is empty.

## How the work is done

Read this before picking anything up. It is how every item under Done landed.

- **One branch per item, off `main`.** `feat/…` for features, `fix/…` for
  fixes, `docs/…` for roadmap-only changes. Merge back with `git merge --no-ff`
  and a message of `Merge branch '<branch>'`, then push `main` and the branch.
  Ask Pedro before merging or pushing.
- **Each item lands with its docs.** `README.md` is the API reference and is
  updated in the same commit as the code. On this file, the item moves from
  Queued to the top of Done, rewritten as what was built and the decisions
  taken, not what was planned.
- **Tests are written, not run.** `tests/Server.server.luau` holds server tests
  and the fixtures the client checks; `tests/Client.client.luau` holds the
  client half. A server change the client should observe gets a fixture on the
  server — the existing ones are triggered by the client writing a marker
  (`"EvictPulse"`, `"UnregisterPulse"`, ...) on the editable fixture.
- **There is no Luau tooling on this machine.** Nothing type checks or runs
  the code, so reread edited functions and grep for every caller of anything
  whose signature changed — the network layer errors on a wrong argument
  count, so a channel's callers matter most. New channels go at the end of
  `src/Channels.luau`, never reordered.
- **Code style.** `--!strict`, `const` for anything not reassigned, PascalCase
  names, and comments that say why a thing is the way it is — usually what
  went wrong before, or what the obvious alternative would have broken.
  Match the density of the file being edited.
- **Commits** are `type(scope): what changed` with a body explaining why, and
  end with the co-author line the harness asks for.

## Queued

In the order to build them. Each is described well enough to start without
the conversation that produced it; anything marked *Ask* is a decision that is
Pedro's to make before or while building.

- [ ] **Object references.** Next up. Nothing lets one object point at
      another: the property types are Text, Number, Bool, Color, Vector,
      CFrame, Enum and CustomEnum (`src/Properties/Types.luau`), so a button
      cannot be wired to a door or a path node to the next. The README
      already claims "the references inside the pack remapped together"
      under Scenes and object identity — it is wrong today and has to become
      true or be removed.

      The intended shape: a new property type, `Object`, whose stored value
      is the target's **local id** — the low half of its persistent id — so it
      survives a save exactly as the pack's own ids do (see `src/Handles.luau`
      and the `PersistentId` notes in `Objects/Types.luau`). It resolves
      through the copy holding the object (`copy:Find(localId)`), which is what
      makes two loaded copies of one room each point at their own door. A
      target that is destroyed reads as nil; the stored id stays, so an undo
      that brings the target back restores the link. `Get` on such a
      property should hand back the live object rather than the number, or
      there should be a separate resolving accessor — *Ask* which.

      Where it touches: value encoding for the new type (`Compressor`,
      `Codecs`, `Properties/Types` validation — `IsValid` and `FixValue`),
      replication of values (the id is plain data, so nothing new on the
      wire beyond the type tag), `Properties.Display`, and permissions (an
      `Object` property is written like any other). Links cannot drive an
      instance property from it; say so at registration.

      Duplicating has to remap: `Objects:Duplicate` and a transaction's
      `Duplicate` (`Objects/Shared.Snapshot`, `Transactions/Shared`) copy the
      stored id, so a duplicated button still points at the *original* door —
      correct for one object, wrong for a group duplicated together. A group
      duplicate should remap references that point inside the group and keep
      the rest. *Ask* whether group duplication belongs in this item or in
      prefab placement below.

      Constraints: a reference only names objects in the same copy.
      Cross-copy and cross-scene references are out of scope — the id would
      mean nothing after either scene is loaded somewhere else. *Ask* whether
      a type should be able to restrict what an `Object` property may point at
      (`Constraints = {Types = {Door}}`), which is the natural first
      constraint.

- [ ] **Object added / removed signals on the server.** The client has
      `Objects:OnAdded` / `OnRemoved` (`src/Objects/Client.luau`, built on
      `src/Listeners.luau`); the server has neither, so server scripts that
      drive objects — a spinner reading its speed — have to poll
      `GetWorkspace()`. Mirror the client: fire added at the end of
      `Construct` in `src/Objects/Server.luau` once the object is filed in the
      workspace and its copy, and removed at the end of `Teardown`. Note that
      a scene load builds objects with `Announce = false` and announces them
      in bulk; the signal is about the object existing, not about packets, so
      it fires either way. Small; README gets a line beside the client's.

- [ ] **Placing a prefab into an existing copy.** A pack loads only as a whole
      new copy today (`Read` in `src/Scenes/Server.luau`, which restores each
      object under its saved local id). Pasting a saved group of objects into
      a level being edited needs the opposite: fresh local ids minted by the
      target copy's scene, and — once object references exist — references
      inside the pack remapped to the new ids. Server side first
      (`copy:Place(pack)` or similar, returning the new objects), then a
      transaction step so a client can place one through create rights, then
      the client-owned-scene equivalent. Undo should see a placement as one
      step; recording it as a transaction gives that for free. Depends on
      object references for the remapping.

- [ ] **Small edges left open.** Each is a decision as much as a fix — *Ask*
      before doing any of them.
      - **A retired id can be claimed again by `CustomId`.** `IdPool` never
        hands a released id out on its own when recycling is off, but
        `Claim(id)` with an explicit id only checks `Used`, so unregistering a
        property and registering a new one with `CustomId` set to the old id
        reuses it — the corruption the comment in `src/IdPool.luau` warns
        about. Fix is a retired set checked by explicit claims; the question
        is whether re-registering the *same* thing under its old id is a
        legitimate workflow worth an escape hatch.
      - **Evicting a scene's last admitted player makes it public**, and
        reveals it to everyone including the player just evicted, because an
        empty list means public. Documented in the README; a private flag
        separate from the list would remove the edge.
      - **Locks outlive the rights that took them.** A player evicted or
        stripped of edit rights keeps their locks, and nobody else can edit
        those objects until they release, leave, or the server calls
        `Objects:Unlock`. Releasing a player's locks in a scene when they are
        withdrawn from it (`Withdraw` in `src/Scenes/Server.luau`) or lose edit
        rights on it (`Permissions:GrantOn` / `RevokeOn`) would close it.
      - **Creates and destroys in client-owned scenes are not undoable**, and
        neither is a lone `Object:Destroy`; `History` only records
        transactions and single sets. Local scene creates could be recorded
        from `Objects:OnAdded` / `OnRemoved` filtered to `Local` objects.

## Done

- [x] **Undo / redo.** `Prism.History` on the client, per player. A step is a
      committed transaction, or a run of `Object:Set` calls to one property
      with no pause longer than a second, so a drag undoes as one. Undoing
      sends the reverse as an untracked transaction through the usual rights
      and locks; local scenes revert on the spot. A property someone else
      changed since is skipped and the rest applies. A destroy is undone by
      making the object again from a snapshot taken as the transaction went,
      and later steps find it through an alias to its new runtime id. Built on
      `Objects:OnEdited` and `Transactions:OnCommitted`, both public.

- [x] **`Duplicate(object)`.** `Objects:Duplicate(object, copy?)` on the
      server, into the original's copy unless another is named, with a new
      local id and a part of its own. A transaction's `Duplicate` is a create
      holding the object's values as they are when it is built, so a client
      duplicates a server object through the same rights a create needs. On
      the client, `Objects:Duplicate` covers scenes the client owns.

- [x] **Property display metadata.** `Display = {Category, Order,
      Description, Hidden, ReadOnly}` on the registry, filled in at
      registration and replicated with it — including for custom enum
      properties, whose payload is built separately. `Properties:Layout(ids)`
      on either side groups a list by category and sorts it by order, ties
      kept in the object type's own order, so a panel is generated rather than
      written per property. `ReadOnly` is presentation only; a property
      blacklist in Permissions is what refuses the write.

- [x] **Per object locks and presence.** Explicit rather than tied to the
      selection: `Objects:Lock` and `Unlock`, one object or a list, all or
      none. While a player holds an object nobody else may edit or destroy
      it, through the single remotes and transactions alike; the server's own
      edits ignore locks. Taking one needs edit rights and admission and costs
      an action per object; releasing needs nothing. A lock goes with its
      object or its holder. Who holds what is the presence, told to the
      scene's admitted only and sent with a scene when it is revealed.

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
