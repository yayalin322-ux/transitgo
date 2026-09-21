// A rejecting async route must answer that one request with a 500 and leave the server running (it used to kill the
// process). Also pins the two SQL shapes Postgres could not type ("$n IS NULL" on a bare parameter, error 42P18).
import express from "express";
import { readFileSync } from "node:fs";
import { guardAsyncRoutes, errorResponder } from "../src/asyncGuard.mjs";

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

const rejections = [];
process.on("unhandledRejection", (e) => rejections.push(e));

const logs = [];
const app = guardAsyncRoutes(express());
app.get("/boom", async () => { throw new Error("could not determine data type of parameter $2"); });
app.get("/sync-boom", () => { throw new Error("sync failure"); });
app.get("/ok", async (_req, res) => { await null; res.json({ ok: true }); });
app.post("/post-boom", async () => { throw new Error("post failure"); });
app.get("/mw", (req, _res, next) => { req.x = 1; next(); }, async (req, res) => res.json({ x: req.x }));
app.use(errorResponder((m) => logs.push(m)));

const server = await new Promise((r) => { const s = app.listen(0, () => r(s)); });
const base = `http://127.0.0.1:${server.address().port}`;
const get = (p, o) => fetch(base + p, o);

let r = await get("/boom");
check("a rejecting async handler answers 500, not a dead process", r.status === 500 && (await r.json()).error === "internal_error");
check("…and the failure is logged with the route", logs.some((l) => l.includes("/boom") && l.includes("parameter $2")));
r = await get("/sync-boom");
check("a synchronous throw is a 500 too", r.status === 500);
r = await get("/post-boom", { method: "POST" });
check("POST handlers are guarded as well", r.status === 500);
r = await get("/ok");
check("the server still serves the next request", r.status === 200 && (await r.json()).ok === true);
r = await get("/mw");
check("several handlers on one route still chain with next()", (await r.json()).x === 1);
await new Promise((r) => setTimeout(r, 50));
check("no unhandled rejection escaped", rejections.length === 0, String(rejections[0]));
server.close();

// Postgres cannot type a parameter that only appears in "? IS NULL"; every such test must cast it.
const src = readFileSync(new URL("../src/db.mjs", import.meta.url), "utf8");
const bare = src.split("\n").filter((l) => /(\?|:[a-zA-Z_]+)\s+IS\s+(NOT\s+)?NULL/.test(l) && !/CAST\(\s*(\?|:[a-zA-Z_]+)\s+AS/.test(l));
check("no bare-parameter IS NULL left in db.mjs", bare.length === 0, bare.join("\n"));

process.exit(failed ? 1 : 0);
