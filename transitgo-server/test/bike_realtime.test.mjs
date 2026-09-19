// YouBike realtime availability: rent/return semantics, unknown handling, cache + de-duplication.
// Rows are REAL captured stations (test/fixtures/bike_real_taipei.json); availability is patched per test.
import { BIKE_REAL, bikeRows, bikeRealtimeOver, NOW } from "./bikeFixture.mjs";
import { mapBikeStation, parseSnapshotTime } from "../src/bike/realtime.mjs";
import { createRealtimeCache } from "../src/realtime/cache.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const base = BIKE_REAL.stations.find((r) => r.status === 1 && r.rent > 3 && r.ret > 3);
const id = `BIKE_Taipei:${base.uid}`;
const fetchedAtMs = NOW;

// --- static -> BikeStationRealtime mapping ---
{
  const m = mapBikeStation("Taipei", base, { fetchedAtMs });
  check("stationId is feed:uid, the same id the routing graph uses", m.stationId === id);
  check("availableBikes / availableDocks are the source's own numbers", m.availableBikes === base.rent && m.availableDocks === base.ret);
  check("in service with bikes and docks: rentable AND returnable", m.isRentable && m.isReturnable && m.inService);
  check("updatedAt is the source's own update time (Taipei local -> UTC), not 'now'", m.updatedAt === new Date(parseSnapshotTime(base.src)).toISOString() && m.updatedAt !== new Date(NOW).toISOString());
  check("bike available: 0 bikes -> not rentable, still returnable", (() => { const x = mapBikeStation("Taipei", { ...base, rent: 0 }, { fetchedAtMs }); return !x.isRentable && x.isReturnable; })());
  check("dock unavailable: 0 free docks -> not returnable, still rentable", (() => { const x = mapBikeStation("Taipei", { ...base, ret: 0 }, { fetchedAtMs }); return x.isRentable && !x.isReturnable; })());
  check("station out of service: neither rentable nor returnable even if counts look fine", (() => { const x = mapBikeStation("Taipei", { ...base, status: 0 }, { fetchedAtMs }); return !x.isRentable && !x.isReturnable && !x.inService; })());
  check("a missing count is null (unknown), not 0", (() => { const x = mapBikeStation("Taipei", { ...base, rent: undefined }, { fetchedAtMs }); return x.availableBikes === null && !x.isRentable; })());
}
check("time parsing: gov feed local time, TDX ISO offset, DB UTC", parseSnapshotTime("2026-09-19 17:15:52") === Date.parse("2026-09-19T17:15:52+08:00") && parseSnapshotTime("2026-09-19T09:15:52.000Z") === Date.parse("2026-09-19T09:15:52Z") && parseSnapshotTime("2026-09-19 09:15:52", { assume: "Z" }) === Date.parse("2026-09-19T09:15:52Z"));

// --- oracle over a real snapshot ---
{
  const rt = bikeRealtimeOver(bikeRows((r) => (r.uid === base.uid ? { ...r, rent: 0 } : r)));
  const snap = await rt.snapshot();
  const oracle = rt.oracleFor(snap);
  check("snapshot holds every real station under its routing id", snap.ok && snap.stations.size === BIKE_REAL.stations.length && snap.stations.has(id));
  check("oracle: empty station can't be rented from ('no')", oracle.check(id, "rent") === "no");
  check("oracle: same station can still take a return ('yes')", oracle.check(id, "return") === "yes");
  check("oracle: a station the snapshot doesn't have is 'unknown', never 'yes'", oracle.check("BIKE_Taipei:does-not-exist", "rent") === "unknown");
  check("oracle 'exclude' policy turns unknown into 'no'", rt.oracleFor(snap, { unknownPolicy: "exclude" }).check("BIKE_Taipei:does-not-exist", "rent") === "no");
}

// --- failures: never throw, always a reason, everything unknown ---
async function failing(loadCaches, opts = {}) {
  const rt = bikeRealtimeOver([], { loadCaches, ...opts });
  const snap = await rt.snapshot();
  return { snap, oracle: rt.oracleFor(snap) };
}
{
  const t = await failing(() => new Promise(() => {}));
  check("realtime timeout: snapshot not ok, reason timeout", !t.snap.ok && t.snap.reason === "timeout");
  check("realtime timeout: every station is 'unknown' (not 'no' — routing must not drop them silently)", t.oracle.check(id, "rent") === "unknown" && t.oracle.available === false);
  const e = await failing(async () => []);
  check("empty response: no_data", !e.snap.ok && e.snap.reason === "no_data");
  const e2 = await failing(async () => [{ city: "Taipei", stations: [], updatedAt: new Date(NOW).toISOString() }]);
  check("a city with zero stations is also no_data", !e2.snap.ok && e2.snap.reason === "no_data");
  const boom = await failing(async () => { throw Object.assign(new Error("db down"), { status: 500 }); });
  check("read error: unavailable", !boom.snap.ok && boom.snap.reason === "unavailable");
  const stale = await failing(async () => [{ city: "Taipei", stations: bikeRows(), updatedAt: new Date(NOW - 11 * 60_000).toISOString() }]);
  check("a city the poller hasn't refreshed for >10 min is treated as unknown, not as still true", !stale.snap.ok && stale.snap.reason === "no_data");
  const fresh = await failing(async () => [{ city: "Taipei", stations: bikeRows(), updatedAt: new Date(NOW - 3 * 60_000).toISOString() }]);
  check("3 minutes old is fine (poller runs every 2)", fresh.snap.ok);
}

// --- cache + in-flight de-duplication ---
{
  const rt = bikeRealtimeOver(bikeRows());
  await Promise.all(Array.from({ length: 25 }, () => rt.snapshot()));
  check("25 concurrent route queries -> ONE snapshot read", rt.calls.loads === 1);
  for (let i = 0; i < 10; i++) await rt.snapshot();
  check("further queries inside the TTL are cache hits (still 1 read)", rt.calls.loads === 1);
  const a = await rt.snapshot(), b = await rt.snapshot();
  check("the mapped snapshot is derived once per refresh, not per query", a.stations === b.stations);

  let clock = NOW;
  const cache = createRealtimeCache({ now: () => clock });
  const rt2 = bikeRealtimeOver(bikeRows(), { now: () => clock, cache });
  await rt2.snapshot(); clock += 16_000; await rt2.snapshot();
  check("after the 15 s TTL the next query re-reads (2 reads)", rt2.calls.loads === 2);

  let attempts = 0;
  const flaky = bikeRealtimeOver(bikeRows(), { loadCaches: async () => { attempts++; throw new Error("boom"); } });
  await flaky.snapshot(); await flaky.snapshot(); await flaky.snapshot();
  check("a failing source isn't hammered: failures are negatively cached briefly", attempts === 1);
}

// --- availability call (what the app asks) ---
{
  const rt = bikeRealtimeOver(bikeRows());
  const r = await rt.availability([id, "BIKE_Taipei:nope"]);
  check("availability returns BikeStationRealtime per requested id, null for unknown ids", r.available && r.stations[0].stationId === id && r.stations[1] === null);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
