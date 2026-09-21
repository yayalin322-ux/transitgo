// trainStatus (the share page's train position) through the real realtime service, with a fake TDX that serves the
// REAL data captured 2026-09-21 (train 2233's timetable and its live-board row). Plus the rating rules.
import { readFileSync } from "node:fs";
import { createRealtimeService } from "../src/realtime/service.mjs";
import { createRealtimeCache } from "../src/realtime/cache.mjs";
import { canRate, createRatingLedger, parseTrainTrip, isVehicle, RATING_GRACE_MS } from "../src/shares.mjs";

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

const fx = JSON.parse(readFileSync(new URL("./fixtures/tra_train_2233_real.json", import.meta.url), "utf8"));
const NOW = Date.parse("2026-09-21T20:23:30+08:00");
const calls = [];
function fakeTdx({ failBoard = false, failTimetable = false } = {}) {
  return async (path) => {
    calls.push(path);
    if (path.includes("TrainLiveBoard")) { if (failBoard) { const e = new Error("429"); e.status = 429; throw e; } return fx.liveBoard; }
    if (path.includes("Timetable")) { if (failTimetable) { const e = new Error("429"); e.status = 429; throw e; } return fx.timetable; }
    throw new Error("unexpected path " + path);
  };
}
const mk = (opts) => createRealtimeService({ tdxGet: fakeTdx(opts), cache: createRealtimeCache({ now: () => NOW }), now: () => NOW });

const stops = fx.timetable.TrainTimetables[0].StopTimes.map((s) => String(s.StationID));
const cur = stops.indexOf("3420");
const fromId = stops[cur - 3], toId = stops[cur + 4];

// ---- today: timetable + live board
{
  calls.length = 0;
  const svc = mk();
  const r = await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("today's train: available with a live position", r.available && r.liveAvailable && r.position?.stationName === "田中" && r.phase === "running");
  check("next station and stops left are reported", !!r.next?.name && r.stopsToTo === 4);
  check("the journey list is included and marks the next stop", r.stops.length === 8 && r.stops.filter((x) => x.status === "next").length === 1);
  check("uses today's timetable endpoint and the one all-trains board", calls.some((p) => p.includes("DailyTrainTimetable/Today/TrainNo/2233")) && calls.filter((p) => p.includes("TrainLiveBoard")).length === 1);
  check("train type and direction come from the timetable", r.trainType === "區間" && /嘉義/.test(r.towards ?? ""), `${r.trainType} ${r.towards}`);
  check("schedule source says 'today'", r.scheduleSource === "today");
  const before = calls.length;
  await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId: stops[cur - 1], toId: stops[cur + 2] });   // another viewer, same train
  check("more viewers cost nothing: 2 further requests, 0 further TDX reads (cached)", calls.length === before);
}

// ---- another day: general timetable, no live position
{
  calls.length = 0;
  const r = await mk().trainStatus({ trainNo: "2233", dateStr: "2026-09-25", fromId, toId });
  check("a future date uses the general timetable and never the live board", calls.every((p) => !p.includes("TrainLiveBoard")) && calls.some((p) => p.includes("GeneralTrainTimetable")));
  check("…so it claims no position, only the schedule", r.available && !r.liveAvailable && r.position === null && r.scheduleSource === "general");
}

// ---- failures degrade honestly
{
  const r = await mk({ failBoard: true }).trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("live board rate-limited: schedule still answers, no position invented, the reason is reported",
    r.available && !r.liveAvailable && r.position === null && r.reasons.live === "rate_limited" && r.stops.every((x) => x.status === "future"), JSON.stringify(r.reasons));
  const r2 = await mk({ failTimetable: true }).trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("timetable failed but live row exists: position only, no journey list", r2.available && r2.position?.stationName === "田中" && r2.stops.length === 0);
  const both = await createRealtimeService({ tdxGet: async () => { throw new Error("down"); }, cache: createRealtimeCache({ now: () => NOW }), now: () => NOW }).trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("everything down: available:false, no throw", both.available === false && both.phase === "unknown");
  const unknown = await mk().trainStatus({ trainNo: "9999", dateStr: "2026-09-21", fromId, toId });
  check("a train that is not on the board still returns the timetable's schedule (not running yet)", unknown.available && unknown.position === null);
}


// ---- stale-on-error: a failed refresh keeps the last good position for a few minutes, clearly labelled
{
  let t = NOW, failing = false;
  const svc = createRealtimeService({
    tdxGet: async (path) => {
      if (path.includes("TrainLiveBoard")) { if (failing) { const e = new Error("429"); e.status = 429; throw e; } return fx.liveBoard; }
      return fx.timetable;
    },
    cache: createRealtimeCache({ now: () => t }), now: () => t,
  });
  const ok = await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("fresh read: live, not stale", ok.liveAvailable && !ok.liveStale && ok.position?.stationName === "田中");
  failing = true; t += 40_000;   // past the 20 s TTL, TDX now says 429
  const stale = await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("refresh fails: the last position is still shown, marked stale and 40 s old", stale.liveAvailable && stale.liveStale && stale.liveAgeSeconds === 40 && stale.position?.stationName === "田中" && stale.phase === "running");
  t += 4 * 60_000;
  const gone = await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("still failing 4+ minutes later: it stops claiming a position (too old to trust)", !gone.liveAvailable && gone.position === null && gone.reasons.live === "rate_limited");
  failing = false; t += 60_000;
  const back = await svc.trainStatus({ trainNo: "2233", dateStr: "2026-09-21", fromId, toId });
  check("TDX recovers: live again, no longer stale", back.liveAvailable && !back.liveStale);
}

// ---- share helpers
check("parseTrainTrip reads the planner's trip id", JSON.stringify(parseTrainTrip("TRA_152_2026-09-21")) === '{"trainNo":"152","dateStr":"2026-09-21"}' && parseTrainTrip("HSR_1") === null && parseTrainTrip(null) === null);
check("only vehicle legs are vehicles", isVehicle({ mode: "TRA" }) && !isVehicle({ mode: "WALK" }) && !isVehicle({ mode: "BIKE" }) && !isVehicle(null));

// ---- rating rules
const segs = [
  { mode: "WALK", arrivalTime: "2026-09-21T08:00:00Z" },
  { mode: "TRA", arrivalTime: "2026-09-21T10:00:00Z" },
];
const arr = Date.parse(segs[1].arrivalTime);
check("cannot rate a walking leg", canRate(segs, 0, arr + 3600_000) === false);
check("cannot rate a ride that has not arrived (30 min before)", canRate(segs, 1, arr - 30 * 60_000) === false);
check("can rate once within the grace period before the scheduled arrival (an early train)", canRate(segs, 1, arr - RATING_GRACE_MS + 1000) === true);
check("can rate after arrival", canRate(segs, 1, arr + 60_000) === true);
check("a leg that does not exist / garbage input cannot be rated", canRate(segs, 5, arr) === false && canRate(null, 0, arr) === false && canRate(segs, -1, arr) === false);
const ledger = createRatingLedger();
check("first rating from a viewer is accepted, the second for the same leg is refused", ledger.claim("t", 1, "1.1.1.1", 0) === true && ledger.claim("t", 1, "1.1.1.1", 1) === false);
check("another viewer, another leg and another link are independent", ledger.claim("t", 1, "2.2.2.2", 2) && ledger.claim("t", 0, "1.1.1.1", 3) && ledger.claim("u", 1, "1.1.1.1", 4));
check("the ledger forgets after a day", createRatingLedger({ ttlMs: 1000 }).claim("x", 1, "v", 0) && (() => { const l = createRatingLedger({ ttlMs: 1000 }); l.claim("x", 1, "v", 0); return l.claim("x", 1, "v", 5000); })());

process.exit(failed ? 1 : 0);
