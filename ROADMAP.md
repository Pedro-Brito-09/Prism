# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

Nothing here waits on Studio. The suites in `tests/` are written alongside the
work and left unrun on purpose — the framework gets played through in one pass
once it is structurally finished, so a ticked item means the work landed and
reads right, never that it was run with a player in it.

## In design

- [ ] **Permissions, scoped and stored.** A permission today is a role a player
      is assigned, global to the server, held in memory and gone when they
      leave. Two of those are wrong for an editor several people share. The
      third turns out to be right, and deliberately so.

      *Scope.* Rights over a level belong to that level. Two groups editing two
      scenes in one server means "may edit" has to mean "may edit **this**
      scene", or everyone present can touch everything. So permissions split:
      **global** ones — the rate budget, whether you may register a scene at
      all, capabilities that are about the session rather than a document — and
      **per scene** ones, which is where the verbs and the object and property
      restrictions live. Callers do not have to name the scene: every check
      site already holds the object, an object knows its copy and a copy knows
      its scene, so `Can` resolves it.

      This subsumes the audience idea rather than sitting beside it. A scene's
      audience is the set of players holding any right on it, so admitting
      someone is granting them one, and there is no second list to keep in
      step. What replicates to whom follows from that: a copy's objects go to
      its audience, and to nobody else unless the object type says otherwise.

      *Roles stop being live.* A role becomes a template. Granting one clears
      the player's set and copies its capabilities in; from then on the
      player's own set is the whole truth, and capabilities are granted and
      revoked one at a time. That removes the inheritance rules, the question
      of whether a per-player entry may widen or only narrow, and the payload
      cache keyed by role name. The price, taken knowingly: editing a role
      later does not reach anyone already holding it.

      *They stay session state.* Prism persists no rights at all, global or
      per scene, which leaves the whole subsystem the same shape the rate
      budget already has: granted while you are here, gone with the server.
      Who owns a level and who they invited is a question every game answers
      differently — group ranks, friends, a gamepass, a record in a service of
      its own — and a store built in here would be bypassed by half of them
      while the game keeps that record anyway to draw a menu. It is also the
      division the framework already makes: the database holds metadata, a
      pack holds contents, and saving a level's contents is somebody else's
      job. So rights are granted after a scene is loaded, out of whatever the
      game kept, and they live as long as the session does.

      Not saving them settles the prefab question too. A level published as a
      model would otherwise carry its collaborator list wherever it was
      inserted, and a pack that names people is no longer the portable thing
      the format works so hard to keep it.

      What that leaves to get right is that rights are granted at two moments:
      when the scene loads, and again for whoever arrives afterwards. Taking a
      user id as well as a Player removes it — the game hands over the
      collaborator list once at load, and a player who joins later binds
      themselves, rather than every game writing the same PlayerAdded hook.
      Rights drop when their scene is destroyed and when their player leaves,
      as the rate budget already does.

      Capabilities are plain strings — `Publish`, `Invite` — and exist by
      appearing in a role's grant list rather than by being registered, with a
      warning the first time something asks for one that nothing grants. They
      need no ids because nothing writes them into a pack. Prism's own three
      verbs stay separate from them: it enforces those, and only answers for
      the rest.

      Object and property restrictions stay per kind, each with a whitelist and
      a blacklist, a present whitelist being exhaustive and an absent one
      meaning no constraint — the same thing those two words already mean in
      enum constraints, and the direction that fails closed when a list is
      built wrong. Splitting them by kind is also what makes
      `[Tint] = {Crate, Barrel}` unambiguous: the field says which kind its
      keys are, so nothing has to be done about object and property ids sharing
      a number space.

      The blacklist governs writing only. Nothing in it is a reason to withhold
      data, which is what keeps replication out of the permission path: what a
      client holds is decided by the scene it has rights on, and what it may
      change is decided here.

      Open: whether a scene loaded twice can carry different rights per copy,
      and what a joining player is told about scenes it has no rights on --
      probably that they exist, since an object type marked for everyone has to
      be filable against a copy the client has heard of.

- [ ] **`Replicate` on an object type.** Whether an object's *data* reaches a
      client, as against its instance, which ordinary replication delivers on
      its own. Most objects are scenery: someone playing needs the part and
      never the property table, while a spinning part needs its speed on the
      client for the script driving it. One field on the registry — everyone,
      or only those with rights to the scene — defaulting to everyone, so
      nothing changes until it is used, and forgetting it costs bandwidth
      rather than breaking code.

      The win is the join. The replay walks every live object and ships it in
      chunks, so a five thousand object level costs every joining player five
      thousand compressed objects, nearly all of them scenery nobody will ever
      ask about. With this, a player pays for the handful of objects with
      client code behind them and the editing party pays for the rest.

      One invariant has to change with it: the client builds an object's
      property table from the registry's full list and fills in defaults, and a
      partially replicated object has to build only what the buffer actually
      carried. Otherwise a withheld property sits there holding its default and
      reads as real data, which is worse than not having it. The buffer already
      names exactly what it holds.

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
