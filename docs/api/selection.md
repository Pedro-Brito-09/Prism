# Selection

`Prism.Selection`, client only. See the [Selection guide](/guides/selection).

A `reference` is an object or a runtime id.

| Call | Returns | |
|---|---|---|
| `Selection:Set(references)` | `number` | Replaces the selection. Returns how many were selected |
| `Selection:Add(reference)` | `boolean` | |
| `Selection:Remove(reference)` | `boolean` | |
| `Selection:Contains(reference)` | `boolean` | |
| `Selection:Clear()` | | |
| `Selection:Get()` | `{object}` | In the order added, so the active one is last |
| `Selection:Query(fn)` | `{object}` | Filters that list |
| `Selection:OnChange(fn)` | disconnect | `fn(selected)` |
