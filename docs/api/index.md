# API reference

Every public call, and which side it runs on. The guides explain why; these pages
are for looking things up.

| Module | What it is for |
|---|---|
| [`Prism.Properties`](/api/properties) | Property types and panel layout |
| [`Prism.CustomEnum`](/api/custom-enum) | Enums of your own |
| [`Prism.Objects`](/api/objects) | Object types, objects, locks and signals |
| [`Prism.Scenes`](/api/scenes) | Scenes, copies, saving and admission |
| [`Prism.Transactions`](/api/transactions) | Operations applied as a unit |
| [`Prism.History`](/api/history) | Undo and redo |
| [`Prism.Selection`](/api/selection) | The client's selection |
| [`Prism.Permissions`](/api/permissions) | Roles, rights and capabilities |
| [`Prism.Database`](/api/database) | Sharded level metadata |
| [`Prism.Networking`](/api/networking) | Typed channels |

## Reading these pages

**Side** says where a call exists: **S** for server, **C** for client, **S C** for
both.

**`:` or `.` matters.** `Objects:Get(id)` is a method and `Objects.new(type)` is a
plain function, and the two are not interchangeable: calling a plain function with
`:` passes the module as its first argument. Each call below is written the way it
has to be called.

**Signatures can differ by side.** Where they do, a call is listed once per side.
On the server, calls that act for a player generally take that player first.

A **signal** takes a callback and returns a function that disconnects it.
