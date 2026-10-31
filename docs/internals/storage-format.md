# Storage format

A buffer decodes with **zero reference to the registry**. The registry decides
how a decoded value is validated and applied, never how the bytes are read, so a
developer can change a constraint, change a type, or unregister a property and
existing data still decodes byte-exactly.

Every value carries a one-byte tag:

```
wwwttttt    w = wire shape (how to read it)
            t = semantic type (what it means)
```

The wire shape is what survives schema drift. A reader that has never heard of
semantic type 19 still knows it is length-prefixed, so it skips it precisely and
keeps reading the rest of the record. Shapes: varint, fixed 3/4/8/12/48, and
length-prefixed bytes.

Numbers pick their encoding from the **value**, not the schema — a whole number
becomes a varint, a fractional one that survives f32 becomes 4 bytes, anything
else 8. Exact to 2^53. That is why changing `AllowDecimals` cannot corrupt
anything, and why user ids and unix timestamps are not mangled by f32's 24-bit
mantissa. Setting `Precision` quantises values before they are encoded,
which makes them far more likely to fit the 4-byte form.

Ids, lengths and counts are LEB128 varints: one byte below 128, two below 16384.

## Scene packs

A scene's pack doesn't write its objects one record at a time. It groups them
by type and writes each type's properties once, as columns. Each column carries
a default: the value it holds most often **in that pack**. Each object then
spends one bit per column saying whether it holds something else, and writes
only those values.

The default belongs to the pack, not the registry. Changing a property's
`DefaultValue` later changes nothing about a level already saved: every object
reads back holding exactly what it was saved with, defaults included.

Each column is written whichever of these ways comes out smallest:

- **raw**: each value tagged, as above. Any column can fall back to it, and it
  keeps a pack readable with no registry.
- **bool**: nothing beyond the bit, which is the value.
- **palette**: the column's distinct values once, then an index per object.
  Materials, enums, mesh ids, colours.
- **grid**: a Vector as three small integers on a step such as half a stud.
  A Vector off the grid, `-0` included, is written as its twelve bytes instead.
  A value read back from the grid is always the same float, bit for bit.
- **delta**: the grid again, but each Vector as how far it moved from the one
  before it, every X step first, then every Y, then every Z. Blocks are placed
  near the last one, so the steps are smaller than the positions.
- **relative**: a reference as how far its target is from the object holding
  it. Something made right after the thing it points at -- an attribute after
  its block, a button after its door -- is one step back, every time.
- **list**: a `Table` of `Object` the same way, a count and then each item as
  how far its target is from the object holding the list. A wiring block made
  after the blocks it takes inputs from writes the same few small numbers on
  every row.

A reference into another scene is an `Object` value on the bytes wire shape,
holding `<Guid>:<LocalId>` as text, where a local id is a varint. The tag tells
them apart, so a pack without one is byte for byte what it was. A column holding
any address has no single distance to write, so it falls back to the column
encodings every other value can use. A build from before these existed reads an
`Object` as a varint and would misread one, so a pack holding an address needs a
build that knows them.

Everything is written column by column, bitmaps and values alike, so similar
bytes sit together. The pack is then compressed with zstd, at level 19 for
scenes and 9 for database shards, when that makes it smaller. A reader checks
how far a pack claims to unpack before unpacking it, and refuses anything past
64MB, because a client can push a pack.

Measured on a real building game's level of 20,287 blocks and 14,631 block
attributes (34,918 objects): 4.22MB written as one record per object, 353KB
in columns, and 129KB as stored after zstd. Writing references relative to
their object took 33KB off that, and position steps a little more. Positions
are most of what is left.

Reading that pack back takes about a third of a second. Loading it takes
longer, and not because of the pack: building 34,918 objects and 20,287 parts
takes about 4 seconds, which a load spreads over frames so the server keeps
running. See [Performance](/internals/performance#loading).

Property ids are **never recycled**, because they are written into saved data —
reusing one for a different property would silently reinterpret every record
still carrying it. Object registry ids are not recycled either, for the same
reason: a registry id is written into every saved object as its type. Nor are
scene ids, which live in the high bits of every persistent id, or an object's
local id within its scene. Runtime ids are the exception, and only because they
are never written down at all.

## What this build cannot read is kept

Skipping a record precisely is only half of it: a save that dropped what it
skipped would delete it at the next commit. So a loaded copy keeps what it
cannot use and writes it back unchanged.

- **An object of a type that is not registered** is not built — nothing finds,
  draws or replicates it — but the copy keeps it (`copy.Unknown`), and
  `Serialize` and `Commit` put it back in its place by local id, every value
  exactly as it was read.
  Its local id stays spent, so a new object never takes it.
- **A value for a property the object's type no longer lists**, or for a
  property id nobody registered, is not the object's: `Get` does not see it. It
  is kept on the object (`object.Unknown`, tagged bytes by property id) and
  written back by a save. Put the property back on the type and the value is
  read again at the next load. A direct `Duplicate` carries these values.
- **Replication never sends them**, and a pack a client pushes to the server
  keeps nothing the server cannot read: the server writes its own packs, and it
  does not store bytes it cannot read on a client's say-so.

What is still dropped: a registered property whose **type** changed since the
save (the registry saying something new about it, and the object carrying it
under the new type), anything unknown in database metadata, and anything a
**placement** or a transaction's `Duplicate` would have to carry — those build
fresh objects of known types from known values.

A scene's inserts sit in the pack's header, ahead of the payload and outside its
compression, under a flag: the last insert id, then each insert's id, Guid and
origin. Changing them rewrites the header and copies the payload across untouched.
Without the flag a pack is byte for byte what it was, and a build from before them
refuses one that has it, as it refuses any flag it doesn't know.

Objects and packs carry a format version, and readers refuse anything newer
than they understand rather than misreading it. Individual metadata records do
not — the version lives on the pack that contains them.
