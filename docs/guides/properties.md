# Properties

A property is a typed, constrained field. Register it once on the server; the
registry replicates to every client, including late joiners.

```luau
-- server
local Health = Prism.Properties:Register({
    Name = "Health",
    Type = "Number",
    DefaultValue = 100,
    Constraints = {MinValue = 0, MaxValue = 100, AllowDecimals = false},
})
```

| Type | Value | Constraints |
|---|---|---|
| `Text` | `string` | `MinLength` (rejects), `MaxLength` (truncates) |
| `Number` | `number` | `MinValue`, `MaxValue` (clamp), `AllowDecimals` (rounds when `false`), `Precision` (snaps to steps of it from `MinValue`) |
| `Bool` | `boolean` | — |
| `Color` | `Color3` | `R`, `G`, `B`, each a set of `Number` constraints on 0–255 |
| `Vector` | `Vector3` | `X`, `Y`, `Z`, each a set of `Number` constraints |
| `CFrame` | `CFrame` | — |
| `Enum` | an `EnumItem` | `Enum` (required: which enum), `Whitelist`, `Blacklist` (items or names) |
| `CustomEnum` | an option of a custom enum | `CustomEnum` (required), `Whitelist`, `Blacklist` (options or option ids) |
| `Object` | another object | `Types` (object type ids or names) |
| `Table` | a list of values of one other type | `Of` (required: the item type, any but `Table`), `Item` (that type's constraints, applied to every item), `MinItems` (rejects), `MaxItems` (truncates; at most 4096, which is also the default) |

A `Color` is held and saved at 8 bits per channel, the 0–255 its constraints
are written in: each channel is scaled to 0–255, rounded to the nearest and
clamped, so `Color3.new(0.5, 0, 0)` reads back with a red of 128/255, about
0.502, and a channel past 1 is stored as 255. A color made with
`Color3.fromRGB` comes back exactly, and so does any color that has been
through a set once. Compare colors after a set, not the value passed in.

A value that fails a rejecting constraint is refused — `Set` returns `false` —
and one outside a clamping constraint is brought into range.

`Object` is a reference to another object — a button's door, a path node's next
node. It's stored as a local id, so it's saved and duplicated like one; see
[References](/guides/references) for what that buys you and what it rules out.

A `Table` is a list, every item one type and held to that type's constraints:

```luau
-- server
local Doors = Prism.Properties:Register({
    Name = "Doors",
    Type = "Table",
    DefaultValue = {},
    Constraints = {Of = "Object", MaxItems = 8},
})

lever:Set(Doors, {doorA, doorB})
lever:Get(Doors)    -- the objects it names, in order
```

A list is handed back frozen, and two lists holding the same items are the
same value, so setting an equal list is no change. A `Table` of `Object` reads
as the objects its items name; an item whose target isn't there is left out of
what `Get` returns but kept in the list, as a single reference keeps its id. A
`Table` cannot drive an instance member, so a `Links` entry naming one is
dropped at registration.

A custom enum is a named list of options with ids that are saved in place of the
values, so the values can be anything. Register it **on both sides** under the
same name — a client checks a `CustomEnum` constraint against its own copy. A
client may register it whenever it likes. Until it does, it warns once per
property and holds that property's values as **pending** options: the enum's
name and the option `Id`, `Pending = true`, and no `Value`. Registering the enum
swaps each one for the real option and fires `OnChange`. A save or a server
that meets an enum it has not registered keeps the option the same way, rather
than dropping which one it was.

```luau
-- server and client
local Material = Prism.CustomEnum:Register("Material", {Wood = 1, Stone = 2, Metal = 3})

-- server
local Surface = Prism.Properties:Register({
    Name = "Surface",
    Type = "CustomEnum",
    DefaultValue = Material:GetByValue("Wood"),
    Constraints = {CustomEnum = Material},
})

crate:Set(Surface, Material:GetById(2))   -- Stone
```

Option ids are whole numbers up to 65535 and, like property ids, should never be
reused for a different option: saved data holds the id.

`Display` says how a property presents itself in an editor, so a property panel
can be generated from the registry instead of written by hand for each property.
It replicates with the registry.

```luau
local Speed = Prism.Properties:Register({
    Name = "Speed",
    Type = "Number",
    DefaultValue = 1,
    Display = {Category = "Motion", Order = 2, Description = "Studs a second"},
})

-- Grouped by category, sorted by Order, hidden properties left out.
for _, section in Prism.Properties:Layout(Prism.Objects:GetRegistry(object.Registry).Properties) do
    panel:AddHeader(section.Category)
    for _, registry in section.Properties do
        panel:AddField(registry, registry.Display)
    end
end
```

Every field is optional. `Category` defaults to `"General"` and `Order` to 0;
properties with the same order keep the order the object type lists them in.
`Hidden` properties are left out of a layout unless you pass `true` as its
second argument. `ReadOnly` is presentation only: it greys a field out but
doesn't stop a write. To stop one, put the property in a role's
`Properties.Blacklist`. A field of the wrong type falls back to its default,
with a warning.

`Properties:Unregister(id)` drops a property on the server and on every client.
It's refused while an object type or a database is built on it. The id is never
handed out again, because saved data names it.
