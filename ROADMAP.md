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
- **Run the checks before syncing into Studio.** `scripts/analyze.sh` type
  checks every file and `node scripts/check-channels.js` checks that each
  channel is fired with the number of arguments it declares. Both fetch what
  they need into `.tooling/`; nothing has to be installed. CI runs the same two.
  This used to read "there is no Luau tooling on this machine", and the way
  around it was to reread edited functions and grep for every caller of
  anything whose signature changed. That is what the two scripts now do, and
  they found three bugs the moment they were pointed at the code.
- **The analyser is a ratchet, not a clean bill of health.** It fails when a
  file grows a diagnostic it did not have before. What stands is mostly the
  default type solver reading code written for the new one; see the Type
  checking section of the README. Do not clear the baseline by weakening the
  code -- if a diagnostic is deliberate, run `--update-baseline` and say why.
- **New channels go at the end of `src/Channels.luau`, never reordered**, and
  never reuse the slot of a removed one during a live rollout.
- **Code style.** `--!strict`, `const` for anything not reassigned, PascalCase
  names, and comments that say why a thing is the way it is — usually what
  went wrong before, or what the obvious alternative would have broken.
  Match the density of the file being edited.
- **Commits** are `type(scope): what changed` with a body explaining why, and
  end with the co-author line the harness asks for.

## Queued

The playthrough still comes first: the framework gets played through in one
pass, with a player in it, and the suites in `tests/` are run for the first
time. That pass is Pedro's call. Three bugs that would have shown up in the
first minute of it are fixed below, but the pass is what the queue below waits
on -- every item here is better decided with the thing running.

New work goes here, described well enough to start without the conversation that
produced it, with anything that is a decision marked *Ask*.

- [ ] **The tests are not type checked.** `scripts/analyze.sh` cannot resolve
      `ReplicatedStorage.Prism.src` without a Rojo sourcemap, so every reference
      to Prism inside `tests/` is `any` and a typo in five and a half thousand
      lines of never-run test code would not be caught -- in the suite that is
      about to be run for the first time.

      `rojo sourcemap default.project.json` fixes it, and `--sourcemap` then
      reports 674 diagnostics in `tests/` and 77 rather than 91 in `src/`,
      because the requires resolve. Almost all of the 674 are nil safety:
      the tests call `Scene:Load()` and use the result without checking, and
      `Load` returns `SceneInstance?`.

      *Ask*: whether to take the sourcemap on. It means fetching Rojo in CI as
      well, and a baseline dominated by noise. It was left off because a CI that
      fails on its first run for a reason nobody trusts is worse than one that
      checks less, and because whether those nil checks belong in the tests is
      a style call that is not mine to make.

- [ ] **The history limit counts steps, not what they hold.** `LIMIT = 100` on
      both sides, by count only. A step can hold a withdrawn copy: every object
      in it and every part. A hundred of those is unbounded, and the whole point
      of the suspend-rather-than-destroy design is that a step keeps things
      alive. A byte or object budget alongside the count would cap it.

Deliberately not queued: object hierarchy and grouping, and anything spatial
(bounding boxes, region queries, box select). A level editor generally wants
both, and there is nothing in `src/` for either. They are also the two largest
things that could be built here and the two most likely to be built wrong in
the abstract. They should wait until an editor is being written against Prism
and actually reaches for a group or a box select, so the shape is observed
rather than guessed.

## Done

- [x] **What this build cannot read is kept, and written back.** Two items,
      one answer. An object of an unregistered type used to be dropped on
      restore, and committing the copy then wrote it out of the pack for good;
      a value for a property its type no longer lists was skipped by
      `Construct`, so removing a property from a type and re-saving erased
      every value it held. Both contradicted the storage format, whose wire
      shape exists so a reader can step over what it does not know and keep
      the rest.

      Decided: keep, not document-and-drop. A copy keeps the decoded record of
      an unknown-type object (`copy.Unknown`) and `Serialize` writes back the
      bytes it was read from, in place by local id; its local id stays spent.
      An object keeps values it cannot use (`object.Unknown`, tagged bytes by
      property id) -- both unregistered property ids, which the Compressor now
      slices out instead of dropping, and registered properties the type does
      not list. Saves write them; replication does not. A direct `Duplicate`
      carries them.

      Still dropped, on purpose: a registered property whose type changed, and
      unknown records in database metadata. A client's pushed pack is stripped
      before the server re-encodes it -- the server keeps what an older build
      of itself wrote, not unreadable bytes a client sent. Placement and a
      transaction's `Duplicate` build fresh objects from known values and carry
      nothing unknown.

- [x] **`Object.Parent` is `Object.Registry`.** The field holding an object's
      type id read as containment to anyone who knows Roblox, and would have
      had to mean containment if objects ever nest. Renamed to `Registry`,
      chosen over `Type` because `Property.Type` is already the value type
      (`"Number"`), and because `Objects:GetRegistry(object.Registry)` reads as
      what it does.

      Only that one meaning moved. `Property.Parent` (a property's registry
      id), `CustomEnum.Parent` (the enum's name) and every `Instance.Parent`
      are untouched. The decoded object shape the Compressor hands back moved
      with it, since the two are read interchangeably when a pack is written,
      and so did a permission target (`{Scene = ..., Registry = ...}`) and the
      record a client keeps of what a transaction removed. `Entry.Parent` in
      `CompressObject`, which is a property's id, stays. Saved packs are
      unaffected: the type id is written by position, never by name.

- [x] **A drag costs one action: `Object:Set(..., ClientSided)`.** On the
      client, `Set` takes a third argument. `true` shows the value here and
      sends nothing; the next `Set` without it sends the value it lands on,
      once. A drag at sixty frames a second used to be sixty actions against a
      default budget of sixty, refused half way through, with every refusal
      snapping the value back under the player's hand.

      Decided against coalescing on a timer, which is what this item proposed.
      The wire cannot tell where a drag ends and the game can, so the game says
      so; there is no flush rate to tune and no ordering hazard against a
      transaction, because nothing is left pending between frames.

      What a preview is and is not: `OnChange` and links fire, `OnEdited` does
      not -- the closing set fires it once, with `Before` from before the
      preview. The closing set is sent even when the last frame already put its
      value on screen, and compared against what the server holds rather than
      the last frame, so letting go where the drag began is a cancel that sends
      nothing. A refusal returns to the confirmed value. Somebody else's edit
      arriving mid-drag updates the confirmed value and leaves the preview
      alone. In a scene the client owns nothing is sent either way, but the
      history records the drag as one step however long it paused. Ignored on
      the server.

- [x] **The code is checked now.** `scripts/analyze.sh` type checks every file
      and `node scripts/check-channels.js` checks every channel's arity. Both
      fetch what they need into a gitignored `.tooling/`, so nothing has to be
      installed, and CI runs the same two scripts rather than a second
      description of them that could drift.

      "There is no Luau tooling on this machine" had been a standing rule here
      and was never a property of the code -- only of what happened to be
      installed. A pinned `luau-lsp` and the Roblox API definitions are a
      download.

      It found three bugs immediately, all of which would have stopped the
      playthrough in its first minute.

      **`Transactions.OnApplied` was written to a global.** The function sat
      ten lines above `const Transactions = {}`, so it indexed an undeclared
      global and threw on require: the whole server half of transactions failed
      to load. Past that, History reads `Transactions.OnApplied` to turn a
      committed transaction into an undo step, and it was reading a key that
      had been written to a different table -- so nothing a player committed
      would ever have been recorded.

      **Reviving a copy put its folder back by id.** `World.Place` takes
      `(Folder, Scene, Parent: Instance?)` and `Revive` passed `self.Id`, a
      number, in the parent slot. Place's first act is `if Parent and
      Parent.Parent ~= nil`, so it indexed a number and threw. That is the undo
      of an unload, the path the history was built around. Suspend already
      remembered the right value one field over.

      **`SendLocks` sent two arrays where the channel declares three.** The
      `Held` array -- whether there is a hold at all, which stopped being the
      same question as who holds it once a holder could be a module or a string
      -- was never added to this sender, so the network layer errored on the
      argument count while revealing any scene with something held in it. The
      same function inserted `Held.UserId` raw, which is nil for a holder that
      is not a person, and `table.insert` of a nil leaves a hole that shifts
      every later holder against its id.

      That last one is invisible to a type checker: `Fire`, `FireAll` and
      `Invoke` all take `...: any`. Hence the second script, which is the grep
      this file used to ask for by hand, run over all three call forms and the
      `Audience` paths -- 47 call sites across 32 channels -- and which also
      refuses an alias naming a channel that does not exist and a name declared
      twice.

      The analyser is a ratchet rather than a pass/fail: 112 diagnostics stand,
      recorded per file in `.analyze-baseline.txt`, and the build fails when a
      file grows one. Nearly all of them are the default type solver reading
      code written for the new one -- `type function` and `read` fields are
      new-solver features, `for _, X in List or {}` is a union it will not
      iterate, `pcall(fn)` binding two results is flagged whenever fn returns
      nothing. Switching solvers is not the answer either: the new one reports
      269 where the old one reports 91. Counts per file rather than line
      numbers, because line numbers move whenever anything above them is
      edited and every such edit would read as a new error.

      `read` on the `Page` type did come off, because under the default solver
      it broke the type outright and Database/Server reported `Records` and
      `HasMore` as missing keys on every read. `FreezePage` calls
      `table.freeze`, which is the real guarantee; the annotation restated it.

      `default.project.json` came with it -- a Rojo project that builds the
      layout the README's Tests section describes, so `rojo serve` is an
      alternative to syncing the files by hand, and `rojo sourcemap` is what a
      future item needs to type check the tests.

- [x] **The last three edges.** All of what was left under *Small edges*.

      **Custom ids are gone.** `CustomId` came off every config and the pool no
      longer takes an id at all. An explicit claim checked only whether an id
      was in use now, not whether it ever had been, so naming a retired one was
      a way to make every saved record still carrying it decode as something
      else. Not being able to ask is what makes that unreachable.

      **Privacy is a flag.** `Private` on the scene, rather than "has admitted
      somebody". Reading it off the list meant evicting the last player threw
      the scene open -- to everyone, including the person just shut out -- at
      the moment somebody was locking it down, and it left no way to say the one
      thing a level editor wants at the start: closed, with nobody in it yet.
      `SetPrivate` closes and opens one after the fact; an admitted list on a
      public scene is inert and warns.

      **A hold goes with whoever had it, and need not belong to a player.**
      Leaving already released them; being evicted from a scene or losing edit
      rights on it did not, so a player could sit there holding objects they
      could no longer touch and nobody else could either. Both release now --
      eviction directly, rights through a signal Permissions fires, since
      Objects requires Permissions and the pair cannot require each other.

      And a holder is now anything at all: a Player, a user id, a module, a
      string naming a tool. The server holding an object while it animates one
      used to mean inventing a player to hold it with. Two holders are the same
      one when they name the same person, and by identity otherwise. The
      presence packet carries whether a thing is held apart from who holds it,
      because those stopped being the same question.

- [x] **Holds and copies are operations.** `Lock`, `Unlock`, `Load` and
      `Unload` joined create, set and destroy, so the things a player does that
      a transaction could not carry now go in the list with everything else.

      Locks were two round trips: take them, then send the edit, with the hold
      able to come back refused after the edit was built. Now they are taken
      before everything else in the transaction and released after, and the plan
      refuses the lot if any of them is somebody else's -- so it either gets all
      three and moves them or does neither.

      Load and Unload were not player actions at all; no channel existed for
      either. Loading asks for the create verb on that scene and unloading for
      destroy, since that is what they amount to -- every object in it made, or
      every object in it taken away. The verb alone: a pack holds whatever it
      holds, so there is no type to check a role's object lists against, and
      those lists go on governing what it builds by hand. One action each,
      whatever the size of the scene.

      Unloading withdraws the copy rather than ending it -- out of the
      registries, folder out of the tree, every object in it suspended, the
      whole thing kept -- which is what makes it undoable. Loading it again
      would read what the scene last committed rather than what was on screen.
      So a copy suspends the way an object does, one level up, and `World.Place`
      exists to put a folder back where it was rather than where a new one would
      go. `copy:Unload` from server code stays final: nobody asked for that one.

      Holds are not recorded in the history. A lock is not a change to the
      world, and taking back somebody's hold is not an undo.

- [x] **A transaction is not only a way to talk to the server.** One whose
      objects are all in scenes the client owns applies on the spot: the same
      builder, the same operations, the same three phases and the same rollback,
      with nothing sent and nothing waited for. Committing reads what the
      transaction is about and does one or the other.

      Before it, a scene the client owned had no batching at all. Every set,
      create and destroy was its own apply and its own undo step, which is why
      placing a prefab into one came apart object by object on undo -- the edge
      this closes.

      A transaction is all local or all the server's, decided by the first thing
      it touches and refused by name when the second kind arrives. Half of a
      mixed one needs a round trip that can come back refused, by which point the
      local half has applied; there is no atomicity across that line. Duplicate
      and DuplicateGroup stopped refusing local objects, because now there is
      something for them to mean.

      It is one history step, which took two hooks: the client records local
      objects one at a time from the object signals, so the apply says when it
      starts -- stop that -- and says when it is done, handing over the whole
      edit. The second fires either way, with nothing to record when the apply
      rolled back, so what the first switched off is always switched back on.

- [x] **Placing a prefab into an existing copy.** `copy:Place(pack)` on both
      sides, and `Transaction:Place(pack, copy)` for a client. A load reads a
      pack as a whole new copy under the ids it was saved with; a placement
      reads one into a copy that already exists, so every object is created
      afresh and the target scene mints the ids. The pack's own LastId is
      ignored -- it belongs to the scene the pack was written in.

      References are the reason it is not a loop over Create. A saved reference
      holds a local id from that other scene, so the values are split before
      anything is built (`Objects/Shared.SplitReferences`) and written
      afterwards against what the placement actually made. One that points at
      another object in the pack follows it; one that points at anything else is
      dropped rather than carried, because in the target copy that id names
      nothing -- or, worse, names something.

      The transaction path expands into one create per object rather than
      adding an operation kind, so a client places through create rights and
      nothing more, and the references name the operations that make their
      targets -- the machinery object references already added for group
      duplication. One transaction, so a placement lands whole or not at all and
      undoes as a single step.

- [x] **Object added / removed signals on the server.** `Objects:OnAdded` and
      `OnRemoved`, mirroring the client's down to the `Restored` argument, so a
      server script driving objects no longer polls `GetWorkspace`. They hang
      off `Enter` and `Withdraw` rather than off `Construct` and `Teardown`,
      which is where the item expected them: those two are now the only places
      an object joins or leaves the world, so a revived object announces itself
      exactly as a newly built one does and a suspended one goes exactly as a
      destroyed one does -- which is the whole point of a signal about
      existing rather than about packets. A scene load still fires one per
      object while sending them in a single batch.

- [x] **A step holds what it took.** History moved to where the objects are:
      the server keeps per-player stacks for its own scenes, the client keeps
      its own for the scenes it owns, and the client keeps the single order the
      two make together so one undo takes back the last thing the player did
      whichever side recorded it. An undo of a server step names the step it
      means, and a server that disagrees about what is on top says no and sends
      back its stacks to be reconciled against.

      A destroy is now a *suspend*: the object is withdrawn from the world --
      unfiled, lock gone, part parented out of it, every client told -- while
      the table, the values, both ids and the part itself all survive. Undo
      revives that same object, which is the point: a reference stores a local
      id, so an object that comes back under its own is pointed at again by
      everything that pointed at it, where a rebuilt lookalike left every
      reference dangling. It comes back with the part it had rather than a clone
      of the template, so whatever the game hung on that part is still there.
      Undoing a create is the same act in reverse.

      So every step carries Undo, Redo and **Clear**, and Clear is what finally
      destroys anything the step was keeping. It runs in exactly three places:
      a new action forking the redo stack the step sat on, the step falling off
      the end past the limit, and the player leaving or clearing. A game that
      never requires History keeps nothing, so a destroy there is as immediate
      as it ever was.

      A step can also be the game's own: `History:Push` takes the same three
      verbs and puts them in the same order, so an editor's own actions -- a
      camera bookmark, a rename in data Prism knows nothing about -- are reached
      by the same Ctrl+Z, in the place they happened. Either the game's or
      Prism's, never both in one step. Nothing done inside a custom verb is
      recorded, or undoing would grow the stack it was shrinking.

      Two edges closed with it. A lone `Object:Destroy` is recorded now --
      the channel it comes down is on the side that keeps the stack -- and so
      are creates, destroys and sets in scenes the client owns. A copy reading
      its own pack back is not an action and is not recorded, which is what
      `Restored` on `Objects:OnAdded` is for. `Transaction.Untracked` rides to
      the server, because that is where the recording happens now.

      Falling out of it: a transaction that fails partway can roll its destroys
      back too, so the apply is atomic in the operation that used to be beyond
      recall.

- [x] **Object references.** A ninth property type, `Object`, holding the
      target's local id and nothing else, so a reference is written exactly as
      the pack's own ids are and survives a save without anything rewriting it.
      It resolves through the copy holding the object that points, never
      through a scene or the workspace: load one room twice and each copy's
      button works that copy's own door. `Get` hands back the live object,
      `Set` takes an object or an id, and the raw id stays readable through
      `GetProperty`. Nil covers three cases deliberately not told apart —
      nothing pointed at, target destroyed, target not built yet — because a
      copy builds its objects one at a time and a client can receive either
      half first. A reference only ever names an object in the same copy;
      anything else is refused, which is also why cross-scene references are
      out of scope.

      `Constraints = {Types = {Door}}` restricts what a property may point at,
      by type id or name. It is checked in `Objects/Shared` rather than in
      `Properties:IsValid`, because a property knows its value and not which
      object carries it, and what an id names depends on the copy asking.
      Checked only when the target resolves: a dangling id is always allowed,
      or a pack would be restorable in only one order. A `Links` entry naming
      a reference is dropped at registration — an `Object` is a Luau number, so
      the type check would have passed and driven a part with an id meaning
      nothing outside its copy.

      Duplicating one object copies the reference as it stands, which is right
      for a lever that should keep working its own door. `DuplicateGroup` on
      both sides, and on a transaction, duplicates several as one thing:
      references pointing inside the group follow the copies, references
      pointing outside it are left alone. Doing that through a transaction
      needed something new on the wire, because the ids of the new objects are
      minted at the far end after the packet was written — so a create can
      carry `References`, naming the operation whose object it points at
      instead of an id, resolved once every create has run and before any of
      them is announced. It is also the only way to create two objects already
      wired to each other in one transaction.

- [x] **Undo / redo.** `Prism.History`, per player. A step is a committed
      transaction, or a run of `Object:Set` calls to one property with no pause
      longer than a second, so a drag undoes as one. Undoing goes through the
      usual rights and locks; scenes the client owns revert on the spot. A
      property someone else changed since is skipped and the rest applies.

      The first version of this kept the stacks on the client and undid a
      destroy by building the object again from a snapshot, which is what the
      entry above replaced: a rebuilt object gets a new local id, and a
      reference to the original comes back pointing at nothing.

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
