# Properties

`Prism.Properties`. See the [Properties guide](/guides/properties).

## Registry

| Call | Side | Returns | |
|---|---|---|---|
| `Properties:Register(config)` | S | `id?` | Registers a property type |
| `Properties:Unregister(id)` | S | `boolean` | Refused while an object type or a database is built on it. The id is never reused |
| `Properties:GetRegistered()` | S C | `{[id]: registry}` | Every property type |
| `Properties:GetRegistry(id)` | S C | `registry?` | One property type |
| `Properties.new(reference)` | S C | `Property` | A standalone property instance, as `Database.new` takes in `InitialMetadata` |
| `Properties:Layout(ids, includeHidden?)` | S C | `{Section}` | Groups properties by category, sorted by order. A section is `{Category, Properties}` |

## Config

| Field | Type | |
|---|---|---|
| `Name` | `string` | |
| `Type` | `string` | One of the types below |
| `DefaultValue` | that type's value | |
| `Constraints` | table? | Depends on the type |
| `Display` | table? | `{Category?, Order?, Description?, Hidden?, ReadOnly?}` |

## Types and constraints

| Type | Value | Constraints |
|---|---|---|
| `Text` | `string` | `MinLength`, `MaxLength` |
| `Number` | `number` | `MinValue`, `MaxValue`, `AllowDecimals`, `Precision` |
| `Bool` | `boolean` | None |
| `Color` | `Color3` | `R`, `G`, `B`, each a set of `Number` constraints on 0–255 |
| `Vector` | `Vector3` | `X`, `Y`, `Z`, each a set of `Number` constraints |
| `CFrame` | `CFrame` | None |
| `Enum` | `EnumItem` | `Enum` (required), `Whitelist`, `Blacklist` |
| `CustomEnum` | an option | `CustomEnum` (required), `Whitelist`, `Blacklist` |
| `Object` | an object | `Types` |
| `Table` | a frozen list | `Of` (required), `Item`, `MinItems`, `MaxItems` (at most 4096, the default) |

## A property

What `object:GetProperty` returns. On a property, `Value` is the raw stored value;
for an `Object` property that is the target's local id.

| Member | | |
|---|---|---|
| `.Value`, `.DefaultValue`, `.Constraints`, `.Name`, `.Type` | | Read through a table shared by the property's registry, except `Value` |
| `:Set(value)` | `accepted, changed` | `accepted` is false when the value failed validation; `changed` is false when it equalled the current one |
| `:SetDefault(value)` | `accepted, changed` | Gives this property a default of its own |
| `:OnChange(fn)` | disconnect | |
| `:Destroy()` | | |

To change a value on an object, use `object:Set`, which replicates and is checked;
a property's own `Set` does neither.
