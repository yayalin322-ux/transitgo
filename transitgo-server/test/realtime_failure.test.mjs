// Failure matrix: every way a realtime source can fail must (a) yield an unavailable overlay with
// the right reason, (b) never throw, (c) never touch the static schedule.
import { REAL_RT, T0, fakeTdx, httpError } from "./realtimeFixture.mjs";
import { createRealtimeService } from "../src/realtime/service.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const T = (hhmm) => `2026-09-19T${hhmm}:00+08:00`;
const seg = { mode: "BUS", routeShortName: "307", routeId: "TPE16111", scopePath: "City/Taipei", from: "TPE:TPE153800", to: "TPE:TPE1", departureTime: T("13:50"), arrivalTime: T("14:10") };
const run = (routes, opts = {}) => createRealtimeService({ tdxGet: fakeTdx(routes), now: () => T0, ...opts }).routeOverlay({ segments: [seg], arrivalTime: T("14:10") });
const never = () => new Promise(() => {});

const cases = [
  ["timeout", { "v2/Bus/EstimatedTimeOfArrival/": never, "v2/Bus/Alert/": []}, { timeoutMs: 30 }, "timeout"],
  ["429", { "v2/Bus/EstimatedTimeOfArrival/": () => { throw httpError(429); }, "v2/Bus/Alert/": []}, {}, "rate_limited"],
  ["401", { "v2/Bus/EstimatedTimeOfArrival/": () => { throw httpError(401); }, "v2/Bus/Alert/": []}, {}, "credential"],
  ["403", { "v2/Bus/EstimatedTimeOfArrival/": () => { throw httpError(403); }, "v2/Bus/Alert/": []}, {}, "credential"],
  ["500", { "v2/Bus/EstimatedTimeOfArrival/": () => { throw httpError(500); }, "v2/Bus/Alert/": []}, {}, "unavailable"],
  ["network error", { "v2/Bus/EstimatedTimeOfArrival/": () => { throw new Error("fetch failed"); }, "v2/Bus/Alert/": []}, {}, "unavailable"],
  ["empty array", { "v2/Bus/EstimatedTimeOfArrival/": [], "v2/Bus/Alert/": [] }, {}, "no_data"],
];
for (const [name, routes, opts, reason] of cases) {
  let o, threw = false;
  try { o = await run(routes, opts); } catch { threw = true; }
  check(`${name}: overlay resolves (never throws)`, !threw);
  const leg = o?.legs[0];
  check(`${name}: available=false, reason=${reason}`, leg && !leg.available && leg.reason === reason);
  check(`${name}: static schedule untouched, etaSource scheduled, no estimate`, leg.scheduledTime === seg.departureTime && leg.estimatedTime === null && leg.etaSource === "scheduled" && o.eta.etaSource === "scheduled" && o.eta.estimatedArrivalTime === null);
  check(`${name}: summary says nothing about route existence, only why realtime is missing`, o.summary.anyRealtime === false && o.summary.unavailableReasons.includes(reason));
}

// A failing ALERT feed must not hide working arrivals — and vice versa.
{
  const o = await run({ "v2/Bus/EstimatedTimeOfArrival/": REAL_RT.busEtaTaipei307, "v2/Bus/Alert/": () => { throw httpError(429); } });
  check("alerts failing does not block arrivals; alertsAvailable=false marks the gap", o.legs[0].available && o.legs[0].alertsAvailable === false);
}
{
  const o = await run({ "v2/Bus/EstimatedTimeOfArrival/": () => { throw httpError(401); }, "v2/Bus/Alert/": REAL_RT.busAlertTaipei });
  check("arrivals failing does not drop alerts", !o.legs[0].available && o.legs[0].alertsAvailable === true);
}

// Failures are negatively cached briefly: a 429 storm must not become more 429s.
{
  const t = fakeTdx({ "v2/Bus/EstimatedTimeOfArrival/": () => { throw httpError(429); }, "v2/Bus/Alert/": [] });
  const s = createRealtimeService({ tdxGet: t, now: () => T0 });
  await s.routeOverlay({ segments: [seg] }); await s.routeOverlay({ segments: [seg] }); await s.routeOverlay({ segments: [seg] });
  check("a rate-limited source is not re-hit on every request", t.calls.filter((p) => p.includes("EstimatedTimeOfArrival")).length === 1);
}

// Unknown mode / malformed input: ignored, not an error.
{
  const s = createRealtimeService({ tdxGet: fakeTdx({}), now: () => T0 });
  const o = await s.routeOverlay({ segments: [{ mode: "FERRY" }, { mode: "BUS" }] });
  check("unsupported mode skipped; malformed bus segment -> no_data, no throw", o.legs.length === 1 && o.legs[0].reason === "no_data");
  const empty = await s.routeOverlay({});
  check("no segments -> empty overlay", empty.legs.length === 0 && empty.summary.anyRealtime === false);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
