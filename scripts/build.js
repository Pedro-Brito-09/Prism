// Build the models a place inserts: one file each, dropped into
// ReplicatedStorage as is, with nothing to move and nothing to set afterwards.
//
//   dist/Prism.rbxmx          the framework: one ModuleScript called Prism
//   dist/PrismTests.rbxmx     the Studio test suite, with its own copy of Prism
//
// Studio is where Prism is used, so the model is the product and this file is
// the only thing that decides its layout. Every entry script is a Script with
// RunContext set, which runs from ReplicatedStorage on the side it names, so
// none of them has to live in ServerScriptService or StarterPlayerScripts. And
// every require inside a model is relative to the model, so the folder can sit
// anywhere a client can see.
//
// The mapping from files to instances:
//   init.luau            makes its directory a ModuleScript instead of a Folder
//   Name.server.luau     Script, RunContext Server
//   Name.client.luau     Script, RunContext Client
//   Name.luau            ModuleScript
//   anything else        left out (Markdown, tools, meta files)
//
// Usage:
//   node scripts/build.js
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const DIST = path.join(ROOT, "dist");

const RUN_CONTEXT = {Server: 1, Client: 2};

const read = (p) => fs.readFileSync(p, "utf8").replace(/\r\n/g, "\n");

//=============================================================================
// The tree
//=============================================================================

// A node is {Class, Name, Source?, RunContext?, Children}.

const fromFile = (file, name) => {
    const base = path.basename(file);
    const match = base.match(/^(.*?)(\.server|\.client)?\.luau$/);
    if (!match) {
        return null;
    }
    const side = match[2];
    return {
        Class: side ? "Script" : "ModuleScript",
        Name: name ?? match[1],
        Source: read(file),
        RunContext: side === ".server" ? RUN_CONTEXT.Server : side === ".client" ? RUN_CONTEXT.Client : undefined,
        Children: [],
    };
};

const fromDirectory = (dir, name) => {
    const entries = fs.readdirSync(dir, {withFileTypes: true})
        .sort((a, b) => a.name.localeCompare(b.name));

    const init = entries.find((e) => e.isFile() && e.name === "init.luau");
    const node = init
        ? fromFile(path.join(dir, init.name), name ?? path.basename(dir))
        : {Class: "Folder", Name: name ?? path.basename(dir), Children: []};

    for (const entry of entries) {
        if (entry === init) {
            continue;
        }
        const full = path.join(dir, entry.name);
        const child = entry.isDirectory() ? fromDirectory(full) : fromFile(full);
        if (child && !(child.Class === "Folder" && child.Children.length === 0)) {
            node.Children.push(child);
        }
    }
    return node;
};

const folder = (name, children) => ({Class: "Folder", Name: name, Children: children});

const prism = () => fromDirectory(path.join(ROOT, "src"), "Prism");

//=============================================================================
// rbxmx
//=============================================================================

const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// CDATA cannot hold "]]>", so a source containing it is split around the ">".
const cdata = (s) => `<![CDATA[${s.replace(/]]>/g, "]]]]><![CDATA[>")}]]>`;

const write = (node) => {
    let referent = 0;
    const lines = [];

    const item = (n, depth) => {
        const pad = "\t".repeat(depth);
        lines.push(`${pad}<Item class="${n.Class}" referent="RBX${referent++}">`);
        lines.push(`${pad}\t<Properties>`);
        lines.push(`${pad}\t\t<string name="Name">${escape(n.Name)}</string>`);
        if (n.Source !== undefined) {
            lines.push(`${pad}\t\t<ProtectedString name="Source">${cdata(n.Source)}</ProtectedString>`);
        }
        if (n.RunContext !== undefined) {
            lines.push(`${pad}\t\t<token name="RunContext">${n.RunContext}</token>`);
        }
        lines.push(`${pad}\t</Properties>`);
        for (const child of n.Children) {
            item(child, depth + 1);
        }
        lines.push(`${pad}</Item>`);
    };

    item(node, 1);
    return [
        `<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">`,
        ...lines,
        `</roblox>`,
        ``,
    ].join("\n");
};

//=============================================================================
// Models
//=============================================================================

const MODELS = {
    // require(ReplicatedStorage.Prism)
    "Prism.rbxmx": () => prism(),

    // PrismTests
    // ├── Prism
    // ├── Harness
    // ├── Server   (runs on the server)
    // └── Client   (runs on each client)
    //
    // Pure.luau is left out: it runs under the Luau CLI, not in Studio.
    "PrismTests.rbxmx": () => folder("PrismTests", [
        prism(),
        fromFile(path.join(ROOT, "tests", "Harness.luau")),
        fromFile(path.join(ROOT, "tests", "Server.server.luau")),
        fromFile(path.join(ROOT, "tests", "Client.client.luau")),
    ]),
};

fs.mkdirSync(DIST, {recursive: true});

for (const [file, build] of Object.entries(MODELS)) {
    const out = path.join(DIST, file);
    fs.writeFileSync(out, write(build()));
    console.log(`${path.relative(ROOT, out)}  ${(fs.statSync(out).size / 1024).toFixed(0)} KB`);
}
