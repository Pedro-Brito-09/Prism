---
layout: home

hero:
  name: Prism
  text: Level editors for Roblox games
  tagline: Typed objects, scenes, multiplayer editing, undo and storage. The parts every editor needs and nobody wants to write twice.
  actions:
    - theme: brand
      text: Get started
      link: /start/introduction
    - theme: alt
      text: A first editor
      link: /start/first-editor
    - theme: alt
      text: API reference
      link: /api/

features:
  - title: Typed, constrained properties
    details: Ten property types with constraints, and object types built from them, with templates and links that drive the instances.
    link: /guides/properties
  - title: Scenes as documents
    details: Load, edit, save and load again, as many copies at once as you like, with references between objects that survive it.
    link: /guides/scenes
  - title: Multiplayer editing
    details: Replication, permissions per scene, locks and presence, and a rate limit the server enforces.
    link: /guides/permissions
  - title: Transactions and undo
    details: Edits land whole or not at all, and undo and redo work per player across the server's scenes and the client's own.
    link: /guides/transactions
  - title: Compact storage
    details: A binary format that survives schema changes. A real 34,918-object level packs to 129 KB.
    link: /internals/storage-format
  - title: A level database
    details: A sharded DataStore database for browsing and searching levels, with a cache shared across servers.
    link: /guides/database
---
