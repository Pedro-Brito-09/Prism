# CustomEnum

`Prism.CustomEnum`, the same module on both sides. Register an enum **on both
sides** under the same name. See the
[Properties guide](/guides/properties).

| Call | Side | Returns | |
|---|---|---|---|
| `CustomEnum:Register(name, options)` | S C | `enum?` | `options` maps each value to a whole-number id from 0 to 65535. `nil` if the name is taken |
| `CustomEnum:GetEnum(name)` | S C | `enum?` | |
| `CustomEnum:GetRegistered()` | S C | `{[name]: enum}` | |
| `CustomEnum:OnRegistered(fn)` | S C | disconnect | Fires for each enum registered from then on |

## An enum

| Member | Returns | |
|---|---|---|
| `.Name` | `string` | |
| `.Options` | `{option}` | Sorted by id |
| `:GetById(id)` | `option?` | |
| `:GetByValue(value)` | `option?` | |

## An option

| Field | |
|---|---|
| `Id` | What is saved. Never reuse one for a different option |
| `Value` | The value it stands for. Absent on a pending option |
| `Parent` | The enum's name |
| `Pending` | `true` for an option of an enum this side has not registered |

`CustomEnum.UNKNOWN` is what an id the registered enum no longer has reads as.
