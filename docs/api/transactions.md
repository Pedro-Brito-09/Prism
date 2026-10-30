# Transactions

`Prism.Transactions`. See the [Transactions guide](/guides/transactions).

| Call | Side | Returns | |
|---|---|---|---|
| `Transactions.new()` | S C | transaction | |
| `Transactions:OnCommitted(fn)` | C | disconnect | `fn(record)` with `{Transaction, Created, Before, Removed}` |
| `Transactions.OnApplied(fn)` | S | disconnect | `fn(player, record) -> boolean`. Plain function: call it with `.` |

## A transaction

Every builder call returns the transaction, so an edit reads as one expression.
`object` below is an object or a runtime id, and `copyId` is optional wherever it
is shown with a `?`.

| Method | |
|---|---|
| `:Create(type, values?, copyId?)` | Values keyed by property id |
| `:Set(object, property, value)` | `property` is an id or a name |
| `:Destroy(object)` | |
| `:Duplicate(object, copyId?)` | A create holding the object's values as they are now |
| `:DuplicateGroup(objects, copyId?)` | The same, with references between them remapped |
| `:Place(pack, copyId?)` | One create per object in the pack |
| `:Lock(objects)`, `:Unlock(objects)` | One or a list, all or none |
| `:Load(sceneId)` | Needs create rights on that scene |
| `:Unload(copyId)` | Needs destroy rights. Withdraws the copy, so it can be undone |
| `:Commit()` | Returns `applied, {runtimeId}`. Yields for a server transaction |

| Field | |
|---|---|
| `.Operations` | The list so far. A create's `References` lives here |
| `.Rejected` | How many operations could not be built. Above zero, `Commit` refuses |
| `.Local` | `true` for scenes the client owns, `false` for the server's, `nil` while empty |
| `.Untracked` | Set to `true` to keep it out of the undo history |

## Limits

A transaction carries at most **1024** operations. It spends one action per
operation, and is all local or all the server's.

Operations apply in this order, whatever order they were declared in: locks, loads,
creates, sets, destroys, unloads, releases.
