// Build the models a place inserts: one file each, dropped into
// ReplicatedStorage as is, with nothing to move and nothing to set afterwards.
//
//   dist/Prism.rbxmx          the framework: one ModuleScript called Prism
//   dist/PrismTests.rbxmx     the Studio test suite, with its own copy of Prism
//   dist/PrismCI.rbxl         a place CI publishes to run the server suite in;
//                             see scripts/studio-tests.js
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
// rbxl
//=============================================================================

// A place for Open Cloud, which refuses an XML place this small ("Invalid
// Content stream") though Studio opens it. The binary format is what Studio
// itself saves, written here uncompressed, which the format allows: a chunk
// whose compressed length is 0 holds its data as is.
//
// Only what the nodes above can hold is written: Name and Source, both
// strings, on services, Folders and ModuleScripts.

const SERVICES = new Set(["ServerStorage"]);

const u8 = (n) => Buffer.from([n]);

const u32 = (n) => {
    const b = Buffer.alloc(4);
    b.writeUInt32LE(n);
    return b;
};

const str = (s) => {
    const bytes = Buffer.from(s, "utf8");
    return Buffer.concat([u32(bytes.length), bytes]);
};

// Referents are stored as differences from the one before, each zigzagged and
// the whole array split into byte planes, most significant byte first.
const referents = (ids) => {
    const out = Buffer.alloc(ids.length * 4);
    let previous = 0;
    ids.forEach((id, index) => {
        const value = ((id - previous) << 1 ^ (id - previous) >> 31) >>> 0;
        previous = id;
        for (let plane = 0; plane < 4; plane++) {
            out[plane * ids.length + index] = value >>> (24 - plane * 8) & 0xff;
        }
    });
    return out;
};

const chunk = (name, data) => Buffer.concat([
    Buffer.from(name, "latin1"), u32(0), u32(data.length), u32(0), data,
]);

const writeBinary = (services) => {
    const instances = [];
    const visit = (node, parent) => {
        const id = instances.length;
        instances.push({node, id, parent});
        for (const child of node.Children) {
            visit(child, id);
        }
    };
    for (const service of services) {
        visit(service, -1);
    }

    const classes = [...new Set(instances.map((i) => i.node.Class))].sort();
    const chunks = [];

    classes.forEach((className, classId) => {
        const members = instances.filter((i) => i.node.Class === className);
        const service = SERVICES.has(className);

        chunks.push(chunk("INST", Buffer.concat([
            u32(classId), str(className), u8(service ? 1 : 0), u32(members.length),
            referents(members.map((i) => i.id)),
            service ? Buffer.alloc(members.length, 1) : Buffer.alloc(0),
        ])));

        // 0x01 is String, which is also how a ProtectedString is stored.
        const property = (name, values) => chunks.push(chunk("PROP", Buffer.concat([
            u32(classId), str(name), u8(0x01), ...values.map(str),
        ])));

        property("Name", members.map((i) => i.node.Name));
        if (members.every((i) => i.node.Source !== undefined)) {
            property("Source", members.map((i) => i.node.Source));
        }
    });

    chunks.push(chunk("PRNT", Buffer.concat([
        u8(0), u32(instances.length),
        referents(instances.map((i) => i.id)),
        referents(instances.map((i) => i.parent)),
    ])));
    chunks.push(chunk("END\0", Buffer.from("</roblox>", "latin1")));

    const header = Buffer.alloc(32);
    header.write("<roblox!", 0, "latin1");
    Buffer.from([0x89, 0xff, 0x0d, 0x0a, 0x1a, 0x0a]).copy(header, 8);
    header.writeUInt16LE(0, 14);
    header.writeInt32LE(classes.length, 16);
    header.writeInt32LE(instances.length, 20);
    return Buffer.concat([header, ...chunks]);
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

    // ServerStorage
    // └── PrismTests
    //     ├── Prism
    //     ├── Harness
    //     └── Server   (a ModuleScript)
    //
    // An Open Cloud Luau Execution runs only the script it is handed -- the
    // place's own Scripts do not start -- and there is no player, so no client
    // half. The server suite becomes a module that script requires; a module
    // has to return a value, and the suite returns nothing of its own.
    "PrismCI.rbxl": () => {
        const server = fromFile(path.join(ROOT, "tests", "Server.server.luau"), "Server");
        server.Class = "ModuleScript";
        server.RunContext = undefined;
        server.Source += "\nreturn true\n";

        return [{
            Class: "ServerStorage",
            Name: "ServerStorage",
            Children: [folder("PrismTests", [
                prism(),
                fromFile(path.join(ROOT, "tests", "Harness.luau")),
                server,
            ])],
        }];
    },
};

fs.mkdirSync(DIST, {recursive: true});

for (const [file, build] of Object.entries(MODELS)) {
    const out = path.join(DIST, file);
    fs.writeFileSync(out, file.endsWith(".rbxl") ? writeBinary(build()) : write(build()));
    console.log(`${path.relative(ROOT, out)}  ${(fs.statSync(out).size / 1024).toFixed(0)} KB`);
}
