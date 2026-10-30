# Introduction

Prism is a framework for building level editors in Roblox games. It handles the
parts every editor needs and nobody wants to write twice:

- **Typed, constrained properties** and object types built from them, with
  templates and links that drive the instances.
- **Scenes**: levels as documents you load, edit, save and load again, as many
  copies at once as you like, with references between objects that survive it.
- **Multiplayer editing**: replication, permissions per scene, locks and
  presence, and a rate limit the server enforces.
- **Transactions** that land whole or not at all, and **undo / redo** per
  player across the server's scenes and the client's own.
- **Storage** in a compact binary format that survives schema changes, and a
  sharded DataStore database for browsing and searching levels.

Prism gives you the model and the plumbing. It has no interface of its own: the
gizmos, panels and toolbars are yours, and it gives them what they need, such as
[`Properties:Layout`](/guides/properties) to generate a property panel from the
registry.

## Status

::: warning Not yet shipped in a live game
Prism is structurally complete, played through in Studio with up to three
players, and stress tested under a poor network, with 5,000-object levels, with
streaming, and with concurrent DataStore writes. Those passes found ten bugs, all
fixed, and every suite in `tests/` runs green. It has not shipped in a live game
yet; see the
[roadmap](https://github.com/Pedro-Brito-09/Prism/blob/main/ROADMAP.md).
:::

Two things are deliberately missing: object hierarchy and grouping, and anything
spatial (bounding boxes, region queries, box select). They should wait until an
editor written against Prism reaches for them, so their shape is observed rather
than guessed.

## Where to go next

- [Installation](/start/installation) gets the module into your place.
- [A first editor](/start/first-editor) goes end to end in about fifty lines.
- [How Prism fits together](/concepts/overview) explains the model the rest of
  these pages assume. Read it before the guides.
- The [API reference](/api/) lists every call and which side it runs on.
