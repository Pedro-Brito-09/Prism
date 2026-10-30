import { defineConfig } from "vitepress";

const REPOSITORY = "https://github.com/Pedro-Brito-09/Prism";

export default defineConfig({
  title: "Prism",
  description: "A framework for building level editors in Roblox games.",

  // A project page lives under the repository's name.
  base: "/Prism/",
  cleanUrls: true,
  lastUpdated: true,

  themeConfig: {
    nav: [
      { text: "Guide", link: "/start/introduction" },
      { text: "API", link: "/api/" },
      { text: "Internals", link: "/internals/storage-format" },
      { text: "Releases", link: `${REPOSITORY}/releases/latest` },
    ],

    sidebar: {
      "/api/": [
        {
          text: "API reference",
          items: [
            { text: "Overview", link: "/api/" },
            { text: "Properties", link: "/api/properties" },
            { text: "CustomEnum", link: "/api/custom-enum" },
            { text: "Objects", link: "/api/objects" },
            { text: "Scenes", link: "/api/scenes" },
            { text: "Transactions", link: "/api/transactions" },
            { text: "History", link: "/api/history" },
            { text: "Selection", link: "/api/selection" },
            { text: "Permissions", link: "/api/permissions" },
            { text: "Database", link: "/api/database" },
            { text: "Networking", link: "/api/networking" },
          ],
        },
      ],

      "/": [
        {
          text: "Getting started",
          items: [
            { text: "Introduction", link: "/start/introduction" },
            { text: "Installation", link: "/start/installation" },
            { text: "A first editor", link: "/start/first-editor" },
          ],
        },
        {
          text: "Concepts",
          items: [
            { text: "How Prism fits together", link: "/concepts/overview" },
            { text: "Two identities", link: "/concepts/identity" },
          ],
        },
        {
          text: "Objects and properties",
          items: [
            { text: "Properties", link: "/guides/properties" },
            { text: "Objects", link: "/guides/objects" },
            { text: "Locks", link: "/guides/locks" },
            { text: "Dragging", link: "/guides/dragging" },
            { text: "References", link: "/guides/references" },
            { text: "Local space", link: "/guides/local-space" },
          ],
        },
        {
          text: "Scenes",
          items: [
            { text: "Scenes and copies", link: "/guides/scenes" },
            { text: "Saving", link: "/guides/saving" },
            { text: "Who sees a scene", link: "/guides/visibility" },
            { text: "Scenes the client owns", link: "/guides/client-scenes" },
          ],
        },
        {
          text: "Editing",
          items: [
            { text: "Transactions", link: "/guides/transactions" },
            { text: "History", link: "/guides/history" },
            { text: "Selection", link: "/guides/selection" },
            { text: "Permissions", link: "/guides/permissions" },
          ],
        },
        {
          text: "Data and transport",
          items: [
            { text: "Database", link: "/guides/database" },
            { text: "Networking", link: "/guides/networking" },
          ],
        },
        {
          text: "Internals",
          items: [
            { text: "Storage format", link: "/internals/storage-format" },
            { text: "Performance", link: "/internals/performance" },
            { text: "Testing and checks", link: "/internals/testing" },
            { text: "Contributing", link: "/internals/contributing" },
          ],
        },
      ],
    },

    socialLinks: [{ icon: "github", link: REPOSITORY }],

    search: { provider: "local" },

    editLink: {
      pattern: `${REPOSITORY}/edit/main/docs/:path`,
      text: "Edit this page on GitHub",
    },

    footer: {
      message: "Released under the MIT License.",
    },
  },
});
