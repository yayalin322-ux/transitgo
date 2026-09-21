// Train position/progress from REAL TDX data captured 2026-09-21: the day timetable of train 2233 and its row on the
// live train board (last departed station 田中 3420, delay 0). Nothing here touches the network.
import { readFileSync } from "node:fs";
import { parseTimetable, parseLiveRow, summarizeTrain } from "../src/realtime/trainProgress.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const fx = JSON.parse(readFileSync(new URL("./fixtures/tra_train_2233_real.json", import.meta.url), "utf8"));
const DATE = "2026-09-21";
const tt = parseTimetable(fx.timetable, DATE);
const live = parseLiveRow(fx.liveBoard, "2233");

check("timetable parses: 74 stops in order, times strictly non-decreasing (after-midnight safe)",
  tt && tt.stops.length === 74 && tt.stops.every((s, i) => i === 0 || s.depMs >= tt.stops[i - 1].depMs));
check("live row parses: 田中 (3420), departed, delay 0", live && live.stationId === "3420" && live.status === "departed" && live.delayMinutes === 0 && live.stationName === "田中");
check("a train that is not on the board has no live row", parseLiveRow(fx.liveBoard, "9999") === null);

const idx = (id) => tt.stops.findIndex((s) => s.stationId === id);
const cur = idx("3420");
const fromStop = tt.stops[cur - 3], toStop = tt.stops[cur + 4];
const now = Date.parse("2026-09-21T20:23:30+08:00");

// ---- the train is between the sharer's boarding and alighting stations
let r = summarizeTrain({ timetable: tt, live, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
check("running: position is the station it just left", r.phase === "running" && r.position.stationName === "田中" && r.position.status === "departed");
check("next station is the one after 田中", r.next?.name === tt.stops[cur + 1].name);
check("stops left to the alighting station = 4 (it has left 田中, 4 stops ahead)", r.stopsToTo === 4);
check("boarding station is already behind: 0 stops left", r.stopsToFrom === 0);
check("arrival time is the timetable time (delay 0)", r.arrMs === toStop.arrMs && r.arrIsEstimate === true);

// ---- a delay shifts the estimate for stations not yet reached, by exactly the delay
const late = { ...live, delayMinutes: 7 };
r = summarizeTrain({ timetable: tt, live: late, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
check("7 min late → estimated arrival = timetable + 7 min", r.arrMs === toStop.arrMs + 7 * 60_000 && r.delayMinutes === 7);

// ---- the sharer has not boarded yet
const boardLater = tt.stops[cur + 2], alightLater = tt.stops[cur + 6];
r = summarizeTrain({ timetable: tt, live, fromId: boardLater.stationId, toId: alightLater.stationId, nowMs: now });
check("before boarding: it needs 2 more stops to reach the boarding station and 6 to the alighting one", r.phase === "beforeBoarding" && r.stopsToFrom === 2 && r.stopsToTo === 6);

// ---- arrived at the alighting station
const atTo = { ...live, stationId: toStop.stationId, stationName: toStop.name, status: "at_station" };
r = summarizeTrain({ timetable: tt, live: atTo, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
check("at the alighting station → arrived", r.phase === "arrived" && r.stopsToTo === 0);
const past = { ...live, stationId: tt.stops[idx(toStop.stationId) + 1].stationId, status: "departed" };
r = summarizeTrain({ timetable: tt, live: past, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
check("already left the alighting station → still arrived (not 'running')", r.phase === "arrived");
const approaching = { ...live, stationId: toStop.stationId, status: "approaching" };
r = summarizeTrain({ timetable: tt, live: approaching, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
check("approaching the alighting station → not arrived yet, 1 stop left", r.phase === "running" && r.stopsToTo === 1);

// ---- terminal station
const last = tt.stops[tt.stops.length - 1];
r = summarizeTrain({ timetable: tt, live: { ...live, stationId: last.stationId, status: "at_station" }, nowMs: now });
check("at the terminus with no personal stations → arrived", r.phase === "arrived");

// ---- no live row: only the schedule may be said
const first = tt.stops[0];
r = summarizeTrain({ timetable: tt, live: null, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: first.depMs - 30 * 60_000 });
check("30 min before it starts → notStarted, no position claimed", r.phase === "notStarted" && r.position === null);
r = summarizeTrain({ timetable: tt, live: null, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
check("in service but missing from the live board → noLiveData, no position claimed", r.phase === "noLiveData" && r.position === null && r.next === null);
r = summarizeTrain({ timetable: tt, live: null, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: last.arrMs + 60 * 60_000 });
check("an hour after the last arrival → ended", r.phase === "ended");

// ---- robustness
check("no timetable and no live row → unknown", summarizeTrain({ timetable: null, live: null, nowMs: now }).phase === "unknown");
check("live row but no timetable → position only", (() => { const x = summarizeTrain({ timetable: null, live, nowMs: now }); return x.phase === "running" && x.position.stationName === "田中" && x.next === null; })());
check("a live station not on this timetable is not placed (no invented position)", summarizeTrain({ timetable: tt, live: { ...live, stationId: "0000" }, nowMs: now }).position === null);
check("empty/garbage timetable parses to null", parseTimetable({}, DATE) === null && parseTimetable({ TrainTimetables: [{ StopTimes: [] }] }, DATE) === null);
check("unknown TrainStationStatus is reported as unknown, not guessed", parseLiveRow({ TrainLiveBoards: [{ TrainNo: "1", StationID: "1000", TrainStationStatus: 9, DelayTime: 0 }] }, "1").status === "unknown");

// after-midnight timetable: 23:50 → 00:10 must roll to the next day
const overnight = parseTimetable({ TrainTimetables: [{ TrainInfo: { TrainNo: "X" }, StopTimes: [
  { StopSequence: 1, StationID: "1", StationName: { Zh_tw: "甲" }, ArrivalTime: "23:50", DepartureTime: "23:50" },
  { StopSequence: 2, StationID: "2", StationName: { Zh_tw: "乙" }, ArrivalTime: "00:10", DepartureTime: "00:10" }] }] }, "2026-09-21");
check("a train past midnight: the second stop is 20 min after the first, on the next day", overnight.stops[1].arrMs - overnight.stops[0].depMs === 20 * 60_000);


// ---- the journey list the share page draws
{
  const r0 = summarizeTrain({ timetable: tt, live, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
  check("journey covers boarding → alighting inclusive (8 stops here)", r0.stops.length === 8 && r0.stops[0].isBoarding && r0.stops.at(-1).isAlighting);
  check("stops the train has left are 'passed', the next one is 'next', the rest 'future'",
    r0.stops.slice(0, 4).every((x) => x.status === "passed") && r0.stops[4].status === "next" && r0.stops.slice(5).every((x) => x.status === "future"));
  check("exactly one 'next' stop", r0.stops.filter((x) => x.status === "next").length === 1);
  check("the 'next' stop is the same one reported as r.next", r0.stops[4].name === r0.next.name);
  const rNoLive = summarizeTrain({ timetable: tt, live: null, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: first.depMs - 30 * 60_000 });
  check("without a live row every stop is 'future' (schedule only, nothing claimed)", rNoLive.stops.every((x) => x.status === "future"));
  const rApp = summarizeTrain({ timetable: tt, live: { ...live, stationId: toStop.stationId, status: "approaching" }, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
  check("approaching the alighting station: it is the 'next' one", rApp.stops.at(-1).status === "next");
  const rLate = summarizeTrain({ timetable: tt, live: { ...live, delayMinutes: 5 }, fromId: fromStop.stationId, toId: toStop.stationId, nowMs: now });
  check("delay shifts each stop's estimate but not its scheduled time", rLate.stops[6].estMs - rLate.stops[6].schedMs === 5 * 60_000);
}

process.exit(failed ? 1 : 0);
