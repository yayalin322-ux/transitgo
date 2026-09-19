// MANUAL dev tool (not part of npm test): a small local backend for driving the iOS app end to end
// when production is not available.
//   node --env-file=.env test/local_backend.mjs   (PORT=4600)
// Routing: the REAL TDX metro data captured in test/fixtures/mrt_real_tdx.json (TRTC/TYMC/NTMC/KRTC).
// Realtime: LIVE TDX through the same createRealtimeService the production server uses.
// It answers the three endpoints the app calls for planning + realtime; nothing else.
import express from "express";
import { buildMrtDb } from "./mrtFixture.mjs";
import { buildGraph } from "../src/graph/builder.mjs";
import { planRoute, graphCoverage } from "../src/routing/api.mjs";
import { createRealtimeService } from "../src/realtime/service.mjs";
import { getRouting, tdxRoutingConfigured } from "../src/tdx.mjs";

const { db } = await buildMrtDb(["TRTC", "TYMC", "NTMC", "KRTC"]);
const graph = await buildGraph(db);
const realtime = createRealtimeService({ tdxGet: tdxRoutingConfigured() ? getRouting : async () => { throw Object.assign(new Error("no credential"), { status: 401 }); }, db });
const log = [];
const app = express();
app.use(express.json({ limit: "1mb" }));
app.use((req, _res, next) => { log.push(`${new Date().toISOString()} ${req.method} ${req.path}`); console.log(log.at(-1)); next(); });
app.get("/v1/health", (_q, r) => r.json({ ok: true, local: true }));
app.get("/v1/routing/coverage", (_q, r) => r.json({ ok: true, ...graphCoverage(graph) }));
app.post("/api/v1/routes", async (q, r) => { const x = await planRoute(graph, q.body, db); r.status(x.status).json(x.body); });
app.post("/v1/realtime/route", async (q, r) => r.json({ ok: true, ...(await realtime.routeOverlay(q.body ?? {})) }));
app.get("/v1/log", (_q, r) => r.json(log));
const port = Number(process.env.PORT ?? 4600);
app.listen(port, () => console.log(`local backend on :${port} (graph ${graph.nodeCount} nodes / ${graph.edgeCount} edges, realtime ${tdxRoutingConfigured() ? "LIVE TDX" : "no credential"})`));
