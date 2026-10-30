# History

`Prism.History`. See the [History guide](/guides/history).

| Client | Server | Returns | |
|---|---|---|---|
| `History:Undo()` | `History:Undo(player)` | `boolean` | Yields on the client while the server answers |
| `History:Redo()` | `History:Redo(player)` | `boolean` | |
| `History:CanUndo()` | `History:CanUndo(player)` | `boolean` | |
| `History:CanRedo()` | `History:CanRedo(player)` | `boolean` | |
| `History:Clear()` | `History:Clear(player)` | | Lets go of everything held |
| `History:Push(action)` | `History:Push(player, action)` | `boolean` | A step of your own |
| `History:SetLimits(limits)` | `History:SetLimits(limits)` | | `{Steps?, Objects?}`. On the server, applies to every player's stack |
| `History:GetLimits()` | `History:GetLimits()` | `{Steps, Objects}` | |
| `History:OnChange(fn)` | | disconnect | Client only. `fn()` |

An `action` is `{Undo = fn, Redo = fn, Clear = fn?}`.

## Limits

| | Default | |
|---|---|---|
| `Steps` | 100 | Per player across every scene. The server's and the client's halves count separately |
| `Objects` | 10,000 | Held by the steps of each half. The newest step is kept however much it holds |

Set calls to one property with no pause longer than a second merge into one step.
