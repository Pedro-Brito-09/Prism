// Check that every channel is fired with the number of arguments it declares.
//
// The roadmap has said from the start that the network layer errors on a wrong
// argument count, so a channel's callers matter most, and that the way to stay
// safe is to grep for every caller of anything whose signature changed. This
// does that grep, every time, and it catches what the type checker cannot:
// Fire, FireAll and Invoke all take `...: any`, so an arity mistake type checks
// cleanly and then throws at runtime.
//
// It found Objects.LocksChanged being sent two arrays where it declares three.
//
// Usage: node scripts/check-channels.js
"use strict";

const fs = require("fs");
const path = require("path");

const read = (p) => fs.readFileSync(p, "utf8").replace(/\r\n/g, "\n");

// Split a call or table body on the commas that are not inside a nested
// bracket, so Optional(Codecs.Instance) counts as one entry rather than two.
function topSplit(s) {
    const out = [];
    let depth = 0;
    let cur = "";
    for (const c of s) {
        if ("({[".includes(c)) depth++;
        if (")}]".includes(c)) depth--;
        if (c === "," && depth === 0) {
            out.push(cur.trim());
            cur = "";
            continue;
        }
        cur += c;
    }
    if (cur.trim()) out.push(cur.trim());
    return out;
}

function balanced(s, i, open, close) {
    let depth = 0;
    for (let j = i; j < s.length; j++) {
        if (s[j] === open) depth++;
        else if (s[j] === close) {
            depth--;
            if (depth === 0) return s.slice(i + 1, j);
        }
    }
    return null;
}

const luauFiles = (dir) =>
    fs
        .readdirSync(dir, { recursive: true })
        .map(String)
        .filter((f) => f.endsWith(".luau"))
        .map((f) => path.join(dir, f));

// 1. The manifest: channel name -> how many arguments it declares.
const manifest = read("src/Channels.luau");
const channels = {};
for (const m of manifest.matchAll(/Name\s*=\s*"([^"]+)"/g)) {
    const end = manifest.indexOf("\n    },", m.index);
    const entry = manifest.slice(m.index, end < 0 ? undefined : end);
    const at = entry.indexOf("Args = {");
    channels[m[1]] = { args: at < 0 ? 0 : topSplit(balanced(entry, at + 7, "{", "}")).length };
}

// 2. Each Network module's alias -> channel name, keyed by the module's path.
const modules = {};
for (const p of luauFiles("src").filter((f) => f.endsWith("Network.luau"))) {
    const map = {};
    for (const a of read(p).matchAll(/(\w+)\s*=\s*Networking:Get\("([^"]+)"\)/g)) map[a[1]] = a[2];
    modules[path.normalize(p)] = map;
}

let checked = 0;
const problems = [];

function check(file, index, source, name, given, expected, how) {
    checked++;
    if (given === expected) return;
    const line = source.slice(0, index).split("\n").length;
    problems.push(`${file}:${line}  ${name} via ${how}: given ${given}, declared ${expected}`);
}

for (const p of luauFiles("src")) {
    const src = read(p);

    // Which local names in this file are a Network module. Usually just
    // "Network" from a sibling, but Replication requires two of them under
    // names of its own, and those call sites went unchecked while the name was
    // assumed rather than the require resolved.
    const bindings = {};
    for (const r of src.matchAll(/(?:const|local)\s+(\w+)\s*=\s*require\("([^"]+)"\)/g)) {
        if (!r[2].endsWith("Network")) continue;
        const target = path.normalize(path.join(path.dirname(p), r[2] + ".luau"));
        if (modules[target]) bindings[r[1]] = modules[target];
    }
    const named = Object.keys(bindings);
    if (named.length === 0) continue;

    // X:Fire(player, ...) / X:FireAll(...) / X:Invoke(...)
    for (const c of src.matchAll(/\b(\w+)\.(\w+)[:.](Fire|FireAll|Invoke)\s*\(/g)) {
        if (!bindings[c[1]]) continue;
        const name = bindings[c[1]][c[2]];
        if (!name || !channels[name]) continue;
        const body = balanced(src, c.index + c[0].length - 1, "(", ")");
        if (body === null) continue;
        const given = body.trim() === "" ? 0 : topSplit(body).length;
        // Fire addresses one player, so it carries a recipient the others do not.
        check(p, c.index, src, name, given, channels[name].args + (c[3] === "Fire" ? 1 : 0), ":" + c[3]);
    }

    // Audience.Fire(Channel, Scene, Reach, ...) and FireHearing(..., Taken, ...)
    for (const c of src.matchAll(/Audience\.(Fire|FireHearing)\s*\(\s*(\w+)\.(\w+)\s*,/g)) {
        if (!bindings[c[2]]) continue;
        const name = bindings[c[2]][c[3]];
        if (!name || !channels[name]) continue;
        const body = balanced(src, src.indexOf("(", c.index), "(", ")");
        if (body === null) continue;
        const lead = c[1] === "Fire" ? 2 : 3;
        check(p, c.index, src, name, topSplit(body).length - 1 - lead, channels[name].args, "Audience." + c[1]);
    }

    // Server handlers are given the player before the channel's own arguments.
    for (const c of src.matchAll(/\b(\w+)\.(\w+)\.OnInvoke\s*=\s*function\s*\(/g)) {
        if (!bindings[c[1]]) continue;
        const name = bindings[c[1]][c[2]];
        if (!name || !channels[name]) continue;
        const body = balanced(src, c.index + c[0].length - 1, "(", ")");
        if (body === null) continue;
        const given = body.trim() === "" ? 0 : topSplit(body).length;
        check(p, c.index, src, name, given, channels[name].args + 1, "OnInvoke handler");
    }
}

// Names that never resolve to a channel are a typo that ends as a nil index.
const declared = Object.keys(channels);
for (const [p, map] of Object.entries(modules)) {
    for (const [alias, name] of Object.entries(map)) {
        if (!declared.includes(name)) problems.push(`${p}  ${alias} names "${name}", which is not in the manifest`);
    }
}
const seen = declared.filter((n, i) => declared.indexOf(n) !== i);
for (const n of seen) problems.push(`src/Channels.luau  "${n}" is declared twice; the later entry shadows the earlier id`);

for (const p of problems) console.log(`ARITY ${p}`);
console.log(`\nChecked ${checked} call sites across ${declared.length} channels.`);
if (problems.length > 0) {
    console.error(`${problems.length} problem(s).`);
    process.exit(1);
}
