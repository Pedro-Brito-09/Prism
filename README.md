this originally wasn't going to be vibe coded but it got too big and I lowkey didn't wanna spend much time debugging; a lot of stuff still made by hand by me :)

# Prism

Prism is a framework for building level editors in Roblox games. It handles the
parts every editor needs and nobody wants to write twice:

- **Typed, constrained properties** and object types built from them, with
  templates and links that drive the instances.
- **Scenes** — levels as documents you load, edit, save and load again, as many
  copies at once as you like, with references between objects that survive it.
- **Multiplayer editing** — replication, permissions per scene, locks and
  presence, and a rate limit the server enforces.
- **Transactions** that land whole or not at all, and **undo / redo** per
  player across the server's scenes and the client's own.
- **Storage** in a compact binary format that survives schema changes, and a
  sharded DataStore database for browsing and searching levels.

> **Status:** structurally complete, played through in Studio with up to
> three players, and stress tested under a poor network, with 5,000-object
> levels, with streaming, and with concurrent DataStore writes. Those passes
> found ten bugs, all fixed, and every suite in `tests/` runs green. It has
> not shipped in a live game yet — see `ROADMAP.md`.

## Documentation

**[pedro-brito-09.github.io/Prism](https://pedro-brito-09.github.io/Prism/)** has
the guides and the API reference.

- [Installation](https://pedro-brito-09.github.io/Prism/start/installation)
- [A first editor](https://pedro-brito-09.github.io/Prism/start/first-editor)
- [How Prism fits together](https://pedro-brito-09.github.io/Prism/concepts/overview)
- [API reference](https://pedro-brito-09.github.io/Prism/api/)

The site's source is `docs/`. To run it locally:

```bash
cd docs
npm ci
npm run dev
```

## Installing

Download `Prism.rbxmx` from the
[latest release](https://github.com/Pedro-Brito-09/Prism/releases/latest) and
insert it into ReplicatedStorage. Require it on the server before any client does:

```lua
local Prism = require(ReplicatedStorage.Prism)
```

## Contributing

Contributions are welcome. See
[Contributing](https://pedro-brito-09.github.io/Prism/internals/contributing).

## License

Prism is released under the [MIT License](LICENSE). Use it in any game, open or
closed source, free or paid; keep the copyright notice in the `LICENSE` file
with any copy of the code.
