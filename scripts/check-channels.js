// Check that every channel is fired with the number of arguments it declares.
//
// The roadmap has said from the start that the network layer errors on a wrong
// argument count, so a channel's callers matter most, and that the way to stay
// safe is to grep for every caller of anything whose signature changed. This
// does that grep, every time, and it catches what the type checker cannot:
// Fire and FireAll take `...: any`, so an arity mistake is invisible to it.
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

// 2. Each Network module's alias -> channel name, scoped to its directory.
const aliases = {};
for (const p of luauFiles("src").filter((f) => f.endsWith("Network.luau"))) {
    const map = {};
    for (const a of read(p).matchAll(/(\w+)\s*=\s*Networking:Get\("([^"]+)"\)/g)) map[a[1]] = a[2];
    aliases[path.dirname(p)] = map;
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
    const map = aliases[path.dirname(p)];
    if (!map) continue;
    const src = read(p);

    // Network.X:Fire(player, ...) / :FireAll(...) / :Invoke(...)
    for (const c of src.matchAll(/Network\.(\w+)[:.](Fire|FireAll|Invoke)\s*\(/g)) {
        const name = map[c[1]];
        if (!name || !channels[name]) continue;
        const body = balanced(src, c.index + c[0].length - 1, "(", ")");
        if (body === null) continue;
        const given = body.trim() === "" ? 0 : topSplit(body).length;
        // Fire addresses one player, so it carries a recipient the others do not.
        check(p, c.index, src, name, given, channels[name].args + (c[2] === "Fire" ? 1 : 0), `:${c[2]}`);
    }

    // Audience.Fire(Channel, Scene, Reach, ...) and FireHearing(..., Taken, ...)
    for (const c of src.matchAll(/Audience\.(Fire|FireHearing)\s*\(\s*Network\.(\w+)\s*,/g)) {
        const name = map[c[2]];
        if (!name || !channels[name]) continue;
        const body = balanced(src, src.indexOf("(", c.index), "(", ")");
        if (body === null) continue;
        const lead = c[1] === "Fire" ? 2 : 3;
        check(p, c.index, src, name, topSplit(body).length - 1 - lead, channels[name].args, `Audience.${c[1]}`);
    }

    // Server handlers are given the player before the channel's own arguments.
    for (const c of src.matchAll(/Network\.(\w+)\.OnInvoke\s*=\s*function\s*\(/g)) {
        const name = map[c[1]];
        if (!name || !channels[name]) continue;
        const body = balanced(src, c.index + c[0].length - 1, "(", ")");
        if (body === null) continue;
        const given = body.trim() === "" ? 0 : topSplit(body).length;
        check(p, c.index, src, name, given, channels[name].args + 1, "OnInvoke handler");
    }
}

for (const p of problems) console.log(`ARITY ${p}`);
console.log(`\nChecked ${checked} call sites across ${Object.keys(channels).length} channels.`);
if (problems.length > 0) {
    console.error(`${problems.length} channel(s) fired with the wrong number of arguments.`);
    process.exit(1);
}
