// MANUAL live check (not part of `npm test`): hits the real TDX API through the same
// RealtimeService the server uses. Prints source / request / latency / result — never credentials.
//   node --env-file=.env test/live_realtime.mjs
import { getRouting, tdxRoutingConfigured } from "../src/tdx.mjs";
import { createRealtimeService } from "../src/realtime/service.mjs";
import { busStopsPath } from "../src/realtime/sources/bus.mjs";
import { traStationBoardPath } from "../src/realtime/sources/tra.mjs";

if (!tdxRoutingConfigured()) { console.log("no routing credentials in env — skipping"); process.exit(0); }
const ms = async (fn) => { const t = performance.now(); const r = await fn(); return [r, Math.round(performance.now() - t)]; };
const sleep = (n) => new Promise((r) => setTimeout(r, n));
// LIVE_FROM=<step 1-5> resumes later in the list (TDX's free key allows ~5 requests/minute)
const FROM = Number(process.env.LIVE_FROM ?? 1);

let upstream = 0;
const tdxGet = async (p) => { upstream++; return getRouting(p); };   // counts real network calls
const svc = createRealtimeService({ tdxGet });
const show = (label, o) => console.log(`\n== ${label}\n${JSON.stringify(o, null, 1)}`);

const busStop = "TPE153800";
if (FROM <= 1) {
const [b1, t1] = await ms(() => svc.busStopArrivals({ scopePath: "City/Taipei", stopUIDs: [busStop] }));
const calls1 = upstream;
const [b2, t2] = await ms(() => svc.busStopArrivals({ scopePath: "City/Taipei", stopUIDs: [busStop] }));
show("BUS stop TPE153800 (City/Taipei)", { request: decodeURIComponent(busStopsPath("City/Taipei", [busStop])), firstMs: t1, cachedMs: t2, upstreamCallsAfterFirst: calls1, upstreamCallsAfterSecond: upstream, available: b1.available, cachedFlagSecond: b2.cached, sample: (b1.stops[busStop] ?? []).slice(0, 3).map(({ routeName, state, etaSeconds, estimatedTime, delaySeconds }) => ({ routeName, state, etaSeconds, estimatedTime, delaySeconds })) });
await sleep(20_000);   // free key: ~5 req/min
}

const busSeg = { mode: "BUS", routeShortName: "307", routeId: "TPE16111", scopePath: "City/Taipei", from: `TPE:${busStop}`, to: "TPE:TPE0", departureTime: new Date().toISOString() };
if (FROM <= 2) {
const [r, tr] = await ms(() => svc.routeOverlay({ segments: [busSeg], arrivalTime: new Date(Date.now() + 1800e3).toISOString() }));
const l = r.legs[0];
show("BUS route 307", { firstMs: tr, available: l.available, reason: l.reason, etaSource: l.etaSource, state: l.status?.state, etaSeconds: l.status?.etaSeconds, alertsAvailable: l.alertsAvailable, alerts: l.alerts.length, upstreamCalls: upstream });
await sleep(20_000);
}

const mrtSeg = { mode: "MRT", from: "MRT_TYMC:A1", to: "MRT_TYMC:A13", routeId: "A" };
if (FROM <= 3) {
const [m, tm] = await ms(() => svc.routeOverlay({ segments: [mrtSeg] }));
show("MRT TYMC A1", { firstMs: tm, available: m.legs[0].available, reason: m.legs[0].reason, arrivals: m.legs[0].arrivals.map((a) => ({ state: a.state, etaSeconds: a.etaSeconds, towards: a.towards })), alerts: m.legs[0].alerts.length });
await sleep(20_000);
}
if (FROM <= 4) {
const mrtSeg2 = { mode: "MRT", from: "MRT_TRTC:R10", to: "MRT_TRTC:R28", routeId: "R" };
const [m2, tm2] = await ms(() => svc.routeOverlay({ segments: [mrtSeg2] }));
show("MRT TRTC R10 (台北車站)", { firstMs: tm2, available: m2.legs[0].available, reason: m2.legs[0].reason, arrivals: m2.legs[0].arrivals.length, note: "TRTC LiveBoard lists only trains arriving now" });
await sleep(20_000);
}

// 4) TRA station 臺北 (1000): pick a train from the live board itself, then ask the service for it
if (FROM <= 5) {
const board = await getRouting(traStationBoardPath("1000")); upstream++;
const train = (board.StationLiveBoards ?? board)[0];
await sleep(20_000);
if (train) {
  const day = new Date().toISOString().slice(0, 10);
  const traSeg = { mode: "TRA", from: "TRA:1000", to: "TRA:3300", tripId: `TRA_${train.TrainNo}_${day}`, departureTime: `${day}T${train.ScheduleDepartureTime}+08:00` };
  const [t, tt] = await ms(() => svc.routeOverlay({ segments: [traSeg], arrivalTime: `${day}T${train.ScheduleDepartureTime}+08:00` }));
  show("TRA 臺北 (1000)", { firstMs: tt, boardRows: (board.StationLiveBoards ?? board).length, train: train.TrainNo, available: t.legs[0].available, reason: t.legs[0].reason, state: t.legs[0].status?.state, delaySeconds: t.legs[0].status?.delaySeconds, etaSource: t.legs[0].etaSource });
}
}
await sleep(20_000);

// 5) HSR station — no realtime feed; alerts only
const [h, th] = await ms(() => svc.routeOverlay({ segments: [{ mode: "HSR", from: "THSR:1000", to: "THSR:1070", departureTime: new Date().toISOString() }] }));
show("HSR 台北 (1000)", { firstMs: th, available: h.legs[0].available, reason: h.legs[0].reason, alertsAvailable: h.legs[0].alertsAvailable, alerts: h.legs[0].alerts.length });

console.log(`\nTOTAL upstream TDX calls: ${upstream}; cache stats: ${JSON.stringify(svc.cache.stats)}`);
