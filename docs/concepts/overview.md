# How Prism fits together

Five words carry most of Prism: **property**, **object**, **scene**, **copy** and
**pack**. The rest of these pages assume them.

## The layers

| Word | What it is | Where it lives |
|---|---|---|
| Property type | A named, typed, constrained field, such as `Health` | A registry on the server, replicated to every client |
| Object type | A named set of properties, optionally with a template instance | The same |
| Scene | A document: the unit a level is saved and loaded as | Data, until something loads it |
| Copy | One live reading of a scene, holding objects in the world | The server, or the client that owns it |
| Object | One thing in a copy, holding a value for each of its properties | Its copy |
| Pack | A scene or copy as bytes | A buffer, a DataStore, or anywhere you put it |

Read it top to bottom and it is the order you build an editor in:

1. **Register** property types and object types on the server, once. They replicate
   to every client, including ones that join later.
2. **Make** a scene. That creates data and nothing else.
3. **Load** it. That reads the scene into a live copy, with objects and parts.
4. **Edit** the copy's objects, from the server or from a client.
5. **Commit** the copy back into its scene, then **save** the scene.

## A scene is not a copy

This is the idea most of the design hangs from. A scene is a document, and a copy
is a reading of it. `Load` called twice gives two copies, and neither is the real
one, so one saved room can stand in the world five times.

Objects live on the copy for the same reason: ask a scene loaded twice for "the
object with local id 4" and there is no answer. Ask a copy and there is.

It is also why saving is always explicit. `copy:Commit()` writes one copy back into
its scene, and unloading never does: with more than one copy live it would have to
pick one, and it cannot.

Three consequences show up all through the API:

- A `Create` names the copy it lands in, because a scene loaded twice has two
  equally good ones.
- A [reference](/guides/references) only ever names an object in the same copy, so
  each copy's button works that copy's own door.
- An object has [two identities](/concepts/identity): one for this live object, and
  one for the object in a pack.

## Server and client

`require` resolves the right half of each subsystem, so the same `Prism` table
means different modules on each side. Their calls overlap but are not identical;
the [API reference](/api/) marks each one.

| | Server | Client |
|---|---|---|
| Registries | Registers them | Receives them, and looks ids up by name |
| Edits | Applied at once, and final | A `Set` shows at once and is confirmed afterwards; a `Commit` yields for the answer |
| Rights | Enforced on every request | `Can` and `Has` answer, to grey out tools |
| Undo | Holds the steps of its scenes, per player | Holds the steps of scenes it owns, and the order of both |

Ids belong to the server, so a client looks up what it needs by name:

```luau
-- client
local function idOf(registered, name)
    for id, registry in registered do
        if registry.Name == name then return id end
    end
end

local Crate = idOf(Prism.Objects:GetRegistered(), "Crate")
```

The server re-checks everything a client asks for, whatever the client thinks.

## Three ways to change the world

| | Use it for | Cost |
|---|---|---|
| [`object:Set`](/guides/objects) | One value, shown immediately | One action |
| [`Set` with `ClientSided`](/guides/dragging) | A drag, shown every frame | One action, however long it runs |
| [A transaction](/guides/transactions) | Several operations that must land together, and any create in a server scene | One action per operation |

## Three ways to put a scene in the world

| | Parts built by | Who sees it |
|---|---|---|
| [`Load`](/guides/scenes) | The server | Everyone sees the parts; a type's `Replicate` decides who gets the data |
| [`Open`](/guides/visibility#opening-instead-of-loading) | Each admitted client | Only admitted players |
| [A scene the client owns](/guides/client-scenes) | That client | Only that client, until it pushes |

## Rights and admission are separate

[Admission](/guides/visibility) decides what a player is **sent**.
[Permissions](/guides/permissions) decide what they may **change**. A player needs
both to edit a private scene: someone who isn't admitted is refused as though its
objects didn't exist, and someone admitted with no rights can read but do nothing.
