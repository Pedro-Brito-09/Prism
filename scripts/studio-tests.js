// Run the server suite on Roblox from CI: publish dist/PrismCI.rbxl to a
// dedicated test place, run the suite there through an Open Cloud Luau
// Execution, and fail unless it reports every test passed.
//
// A Luau Execution has no players, so the client suite and every server test
// that needs a player (they skip themselves) are still Studio only. What runs
// here is the rest of tests/Server.server.luau, the database section with it:
// the test place's data stores get the same two keys a Studio run uses, wiped
// before and after.
//
// Needs, from the repository's secrets and variables:
//   ROBLOX_API_KEY       universe-places write, and
//                        universe.place.luau-execution-session write
//   ROBLOX_UNIVERSE_ID   the test place's experience
//   ROBLOX_PLACE_ID      the test place, holding nothing anyone wants kept
//
// Usage:
//   node scripts/build.js && node scripts/studio-tests.js
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const PLACE = path.join(ROOT, "dist", "PrismCI.rbxl");
const API = "https://apis.roblox.com";

// What the execution runs. The suite is a module in the CI place; requiring it
// runs it, and it errors when a test failed.
const SCRIPT = `require(game:GetService("ServerStorage").PrismTests.Server)`;

// The longest an execution may run, which is also the most Open Cloud allows.
const TIMEOUT_SECONDS = 300;

// How often the task is asked whether it is done: well under the 200 reads a
// minute the API allows, and fine grained enough next to a run of minutes.
const POLL_MS = 5000;

// What Harness.Report prints.
const REPORT = /(\d+)\/(\d+) passed, (\d+) failed, (\d+) skipped/;

const env = (name) => {
    const value = process.env[name];
    if (!value) {
        console.error(`${name} is not set.`);
        process.exit(1);
    }
    return value;
};

const KEY = env("ROBLOX_API_KEY");
const UNIVERSE = env("ROBLOX_UNIVERSE_ID");
const PLACE_ID = env("ROBLOX_PLACE_ID");

const request = async (method, url, body, contentType) => {
    const response = await fetch(url, {
        method,
        headers: {"x-api-key": KEY, ...(contentType ? {"Content-Type": contentType} : {})},
        body,
    });

    const text = await response.text();
    if (!response.ok) {
        throw new Error(`${method} ${url} answered ${response.status}: ${text}`);
    }
    return JSON.parse(text);
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const main = async () => {
    // Published, not saved, so the execution runs the version just uploaded and
    // not whatever was there before. Two runs at once each get their own
    // version number and do not see each other's.
    const {versionNumber} = await request(
        "POST",
        `${API}/universes/v1/${UNIVERSE}/places/${PLACE_ID}/versions?versionType=Published`,
        fs.readFileSync(PLACE),
        "application/octet-stream",
    );
    console.log(`Published version ${versionNumber}.`);

    let task = await request(
        "POST",
        `${API}/cloud/v2/universes/${UNIVERSE}/places/${PLACE_ID}/versions/${versionNumber}/luau-execution-session-tasks`,
        JSON.stringify({script: SCRIPT, timeout: `${TIMEOUT_SECONDS}s`}),
        "application/json",
    );
    console.log(`Running ${task.path}.`);

    while (task.state === "QUEUED" || task.state === "PROCESSING") {
        await sleep(POLL_MS);
        task = await request("GET", `${API}/cloud/v2/${task.path}`);
    }

    // The log is the suite's whole output, failures and all. Open Cloud keeps
    // the last 450 KB of it, and the report is printed last.
    const lines = [];
    let pageToken;
    do {
        const query = pageToken ? `?pageToken=${encodeURIComponent(pageToken)}` : "";
        const page = await request("GET", `${API}/cloud/v2/${task.path}/logs${query}`);
        for (const log of page.luauExecutionSessionTaskLogs ?? []) {
            lines.push(...(log.messages ?? []));
        }
        pageToken = page.nextPageToken;
    } while (pageToken);

    console.log(lines.join("\n"));

    const report = lines.map((line) => line.match(REPORT)).filter(Boolean).pop();

    // A failed test errors the module, so FAILED with a report is the suite
    // saying so. FAILED without one is the run itself going wrong: the suite
    // threw before the end, or ran past the timeout.
    if (task.state !== "COMPLETE") {
        const error = task.error ?? {};
        console.error(`\nThe execution ended ${task.state}: ${error.code ?? "no code"} ${error.message ?? ""}`);
    }

    if (!report) {
        console.error("\nThe suite never reported. See the log above.");
        process.exit(1);
    }

    const [, passed, total, failed, skipped] = report.map(Number);
    console.log(`\nServer suite on Roblox: ${passed}/${total} passed, ${failed} failed, ${skipped} skipped.`);

    if (failed > 0 || task.state !== "COMPLETE") {
        process.exit(1);
    }
};

main().catch((error) => {
    console.error(error.message);
    process.exit(1);
});
