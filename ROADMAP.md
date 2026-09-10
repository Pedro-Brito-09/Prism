# Roadmap

Agreed work, in the order it makes sense to build it. Ticked when it lands on
`main`.

Nothing here waits on Studio. The suites in `tests/` are written alongside the
work and left unrun on purpose — the framework gets played through in one pass
once it is structurally finished, so a ticked item means the work landed and
reads right, never that it was run with a player in it.

## In design

- [ ] **Admission, and where a copy lives.** Everything about a scene reaches
      everyone today, because every packet announcing one goes out with
      FireAll. That is fine for a game with one level and wrong for a place
      several people build in at once: two parties editing two levels in one
      server can each see the other's, and a player who only wants to play sees
      both.

      A scene admits players by name — `Scene:Admit`, taking a user id as
      readily as a Player, with `Evict` beside it — and **a scene that has
      admitted nobody is public**, which is what every scene that exists today
      already is. The list belongs to the scene and outlives whoever is
      connected: dropping an admission when its player disconnects would leave
      a private level with an empty list, and an empty list means public, so a
      room would let itself out.

      A player is told nothing about a scene they are not admitted to — not its
      contents, not its name, not that it exists. Admission is what moves data:
      being admitted means a targeted replay of that scene's copies, being
      evicted means a bulk removal, both of which the scene and transaction
      work already built.

      *Two ways to load one.* `Scene:Load()` builds the objects' instances on
      the server, so the parts replicate to everyone whether or not they are
      admitted — a level being played while it is built. `Scene:Open()` builds
      none: the server owns the copy and its data exactly as before, but clones
      no templates, and each admitted client draws the copy itself. That is the
      only way to keep a scene out of sight, because Roblox has no per-player
      workspace: a part in the world is a part for everybody.

      Clients render; they do not load. If every admitted client read the pack
      itself they would each mint their own ids, and two people would be
      editing two unrelated copies that happen to look alike. One copy, on the
      server, drawn in several places.

      *What a client needs to draw one.* The template and the links, which are
      stripped from a registry payload today. They stop being stripped: an
      instance reference resolves on a client exactly when that instance
      replicates to them, so a template in ReplicatedStorage arrives and one in
      ServerStorage arrives as nil — which registration warns about rather than
      leaving to be discovered at runtime. Links are plain data, and
      ValidateLinks already runs on both sides. That deletes Objects:Localize
      entirely, and with it the only awkward step in client owned scenes.

      *Where the parts go.* Not a Container field on three different configs,
      but one tree the framework owns:

          workspace.__prism.__scene_{SceneId}.__copy_{CopyId}

      keyed by the copy rather than the scene, because a scene loaded five
      times is five copies and they cannot share a folder. The copy's node is a
      **Model**, not a Folder, so placing a copy is still possible and becomes
      easier than it was — `copy.Instance:PivotTo(cf)` moves the whole room,
      where before you supplied a container to parent it into. Unloading
      destroys the model rather than walking objects to destroy each instance.
      A client rendering a copy builds the same tree locally, which is also
      what keeps two open sessions from drawing into the same folder; local
      scenes cannot collide with server ones there, because their ids count
      down from the top of the space while the server's count up.

      There is no "no scene" case to handle: since scenes landed, every object
      belongs to a copy, including one created with no scene named, which lands
      in the implicit Default.

- [ ] **`Replicate` on an object type.** Whether an object's *data* reaches a
      client, as against its instance, which ordinary replication delivers on
      its own when the server built it. Most objects are scenery: someone
      playing needs the part and never the property table, while a spinning
      part needs its speed on the client for the script driving it. One field
      on the registry — everyone, or only the admitted — defaulting to
      everyone, so nothing changes until it is used and forgetting it costs
      bandwidth rather than breaking code.

      It only means anything for a copy the server built. In an opened copy a
      player who is not admitted has no part to attach anything to, so sending
      them data would buy nothing.

      One thing necessarily leaks, and it is the interaction between this and
      admission: an object that replicates to everyone still belongs to a copy,
      and its arrival says that copy exists, because the client has nowhere
      else to file it and cannot otherwise work out the object's persistent
      identity. A copy id and a scene id, and nothing else.

      The win is the join. The replay walks every live object and ships it in
      chunks, so a five thousand object level costs every joining player five
      thousand compressed objects, nearly all of them scenery nobody will ever
      ask about. After this, a player pays for the objects with client code
      behind them and the people editing pay for the rest.

      One invariant has to change with it: the client builds an object's
      property table from the registry's full list and fills in defaults, and a
      partially replicated object has to build only what the buffer actually
      carried. Otherwise a withheld property sits there holding its default and
      reads as real data, which is worse than not having it. The buffer already
      names exactly what it holds.

- [ ] **Permissions, scoped and session-lived.** A permission today is a role a
      player is assigned, global to the server, held in memory and gone when
      they leave. Two of those are wrong for an editor several people share.
      The third turns out to be right, and deliberately so.

      *Scope.* Rights over a level belong to that level. Two groups editing two
      scenes in one server means "may edit" has to mean "may edit **this**
      scene", or everyone present can touch everything. So permissions split:
      **global** ones — the rate budget, whether you may register a scene at
      all, capabilities that are about the session rather than a document — and
      **per scene** ones, which is where the verbs and the object and property
      restrictions live. Callers do not have to name the scene: every check
      site already holds the object, an object knows its copy and a copy knows
      its scene, so `Can` resolves it.

      Rights are not admission. Admission decides what you receive, rights
      decide what you may change, and holding rights on a scene you were never
      admitted to is inert rather than clever. Keeping them apart is also what
      keeps things out of here that look like they belong: a moderator who may
      look into any level is a capability the game checks and an Admit it
      calls, not a feature Prism has to carry.

      *Roles stop being live.* A role becomes a template. Granting one clears
      the player's set and copies its capabilities in; from then on the
      player's own set is the whole truth, and capabilities are granted and
      revoked one at a time. That removes the inheritance rules, the question
      of whether a per-player entry may widen or only narrow, and the payload
      cache keyed by role name. The price, taken knowingly: editing a role
      later does not reach anyone already holding it.

      *They stay session state.* Prism persists no rights at all, global or per
      scene, which leaves the whole subsystem the same shape the rate budget
      already has: granted while you are here, gone with the server. Who owns a
      level and who they invited is a question every game answers differently —
      group ranks, friends, a gamepass, a record in a service of its own — and
      a store built in here would be bypassed by half of them while the game
      keeps that record anyway to draw a menu. It is also the division the
      framework already makes: the database holds metadata, a pack holds
      contents, and saving a level's contents is somebody else's job.

      Not saving them settles the prefab question too. A level published as a
      model would otherwise carry its collaborator list wherever it was
      inserted, and a pack that names people is no longer the portable thing the
      format works so hard to keep it.

      What that leaves to get right is that rights are granted at two moments:
      when the scene loads, and again for whoever arrives afterwards. So a
      grant takes a user id as well as a Player, and Prism binds it when that
      player turns up. The game hands its collaborator list over once, at load,
      out of the record it already keeps — rather than every game writing the
      same PlayerAdded hook and one of them forgetting, which costs an owner
      access to their own level the first time they rejoin. Rights drop when
      their scene is destroyed and when their player leaves, as the rate budget
      already does.

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
      client holds is decided by admission, and what it may change is decided
      here.

      Open: whether a scene loaded twice can carry different rights per copy.
      Admission does not have the question — it is the scene's, so every copy
      of it admits the same people.

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
