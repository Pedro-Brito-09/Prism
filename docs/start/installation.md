# Installation

## Requirements

Prism is written in current Luau: it uses `const` and string requires
(`require("@self/...")`). It needs a Roblox Studio recent enough to run both;
an older one fails to parse the modules rather than failing at runtime.

## Installing

Download `Prism.rbxmx` from the
[latest release](https://github.com/Pedro-Brito-09/Prism/releases/latest) and
insert it into ReplicatedStorage: drag it into Studio, or right-click
ReplicatedStorage → **Insert from File**. It is one
ModuleScript called `Prism`, with nothing to move and nothing to set. Require it
from a server script and a client script; it resolves the server or client half
of each subsystem for you.

```luau
local Prism = require(ReplicatedStorage.Prism)
```

It can live anywhere **both sides can see**; ReplicatedStorage is the usual
place. To update, delete the old `Prism` and insert the new one.

The source is `src/` (`init.luau` is the module itself), and
`node scripts/build.js` builds the models into `dist/` from it, for trying a
change in Studio. `dist/` is not committed. Pushing a tag that starts with `v`
— `git tag v1.2.0 && git push origin v1.2.0` — runs the checks, builds both
models and publishes them as that release. Every push also keeps its built
models as a CI artifact, on the run's page under **Actions**.

Require it on the server before any client does: the client waits for the
server to say it is ready, and warns if it never does.

Next: [a first editor](/start/first-editor).
