# Two identities

Objects carry both, and each has one job:

| | `RuntimeId` | `PersistentId` (`Scene` + `LocalId`) |
|---|---|---|
| names | one live object | one object in a pack |
| unique | across the server, right now | within a scene, forever |
| saved | never | always |
| on the wire | always | never |

`RuntimeId` is the only thing that crosses the wire and the only key the
workspace uses — a client naming an object with a persistent id would be
ambiguous the moment a scene is instanced twice, and client input is the last
place that should be. `PersistentId` is the only thing a pack contains.

There is exactly one crossing, `instance:Find(localId)`, and it is scoped to a
copy on purpose: a persistent id names an object in *every* live copy of its
scene, so the question only has an answer once you say which copy.

```
PersistentId = SceneId * 2^32 + LocalId
```

48 bits, well inside the 53 a Luau number holds exactly, so a saved reference is
one plain number rather than a pair. `Objects:Split(id)` gives back the halves.

Only the low half is written to a pack. The scene stamps its own id on at load,
which is what keeps a pack portable: load the same prefab under two scenes and
you get two distinct persistent identities, with the references inside the pack
remapped together.

A local id is never handed out twice within a scene, for the same reason a
property id is never recycled — a reference still holding it would name a
different object. The scene's counter rides along in the pack.

The scene id in the high half is the session's, not the saved scene's: a pack
never holds it. What names a saved scene across servers is its Guid; see
[Saving](/guides/saving). That is also what a reference into another scene
stores, an address of `<Guid>:<LocalId>`, and why such a reference needs the
scene to be live exactly once: see [References](/guides/references#into-another-scene).
