// The 北上/南下 station board from REAL TDX rows captured 2026-09-19 (test/fixtures/realtime_real_tdx.json), with real
// station coordinates (rail_station_coords.json). Nothing touches the network.
import { readFileSync } from "node:fs";
import { buildRailBoard, headingOf, parseStationCoords } from "../src/realtime/railBoard.mjs";
import { createRealtimeService } from "../src/realtime/service.mjs";
import { createRealtimeCache } from "../src/realtime/cache.mjs";

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

const real = JSON.parse(readFileSync(new URL("./fixtures/realtime_real_tdx.json", import.meta.url), "utf8")).traStationLiveBoard;
const named = JSON.parse(readFileSync(new URL("./fixtures/rail_station_coords.json", import.meta.url), "utf8")).tra;
const byName = new Map(named.map((s) => [s.name, s]));
// id -> coords, built the way the server builds it from v3/Rail/TRA/Station (ids come from the board rows themselves).
const coords = new Map();
for (const r of real.StationLiveBoards) {
  for (const [id, name] of [[r.StationID, r.StationName.Zh_tw], [r.EndingStationID, r.EndingStationName.Zh_tw]]) {
    const c = byName.get(name); if (c) coords.set(String(id), { name, lat: c.lat, lon: c.lon });
  }
}
console.log(`(${real.StationLiveBoards.length} real rows, ${coords.size} stations with coordinates)`);

// ---- headings: TDX's Direction field is NOT north/south
{
  const r428 = real.StationLiveBoards.find((r) => r.TrainNo === "428");     // 臺北 -> 新左營, Direction 0
  const r6021 = real.StationLiveBoards.find((r) => r.TrainNo === "6021");    // 新營 -> 新左營, Direction 1
  check("real rows prove Direction is unreliable: both go south to 新左營 with different Direction", r428.Direction !== r6021.Direction && r428.EndingStationID === r6021.EndingStationID);
  const b1 = buildRailBoard(real, { stationId: r428.StationID, coords });
  const b2 = buildRailBoard(real, { stationId: r6021.StationID, coords });
  check("臺北 → 新左營 is 南下", b1.southbound.some((t) => t.trainNo === "428") && !b1.northbound.some((t) => t.trainNo === "428"));
  check("新營 → 新左營 is 南下 too (same heading despite the other Direction code)", b2.southbound.some((t) => t.trainNo === "6021"));
  check("楠梓 → 潮州 is 南下", buildRailBoard(real, { stationId: "4330", coords }).southbound.some((t) => t.trainNo === "3187"));
}
check("headingOf: clearly north / south / sideways / unknown", headingOf(24.8, 25.05) === "north" && headingOf(24.8, 22.7) === "south" && headingOf(24.80, 24.81) === "other" && headingOf(null, 24) === "unknown");

// ---- board content and ordering
{
  const b = buildRailBoard(real, { stationId: "1000", coords });
  const all = [...b.northbound, ...b.southbound, ...b.other];
  check("only this station's trains, each with type, destination, HH:mm, and real delay", all.length > 0 && all.every((t) => t.trainNo && t.dest && /^\d{2}:\d{2}$/.test(t.depart)) && all.some((t) => t.delayMinutes === 1));
  check("each column is in departure order", [b.northbound, b.southbound].every((c) => c.every((t, i) => i === 0 || c[i - 1].depart <= t.depart)));
  check("station name comes from the data", b.station.name === "臺北" && b.headingsKnown === true);
}

// ---- times: trains that already left are dropped, midnight wraps, delay counts
{
  const rows = { StationLiveBoards: [
    { StationID: "1000", StationName: { Zh_tw: "臺北" }, TrainNo: "1", TrainTypeName: { Zh_tw: "區間" }, EndingStationID: "4340", EndingStationName: { Zh_tw: "新左營" }, ScheduleDepartureTime: "13:00:00", DelayTime: 0 },
    { StationID: "1000", StationName: { Zh_tw: "臺北" }, TrainNo: "2", TrainTypeName: { Zh_tw: "區間" }, EndingStationID: "4340", EndingStationName: { Zh_tw: "新左營" }, ScheduleDepartureTime: "13:20:00", DelayTime: 0 },
    { StationID: "1000", StationName: { Zh_tw: "臺北" }, TrainNo: "3", TrainTypeName: { Zh_tw: "區間" }, EndingStationID: "4340", EndingStationName: { Zh_tw: "新左營" }, ScheduleDepartureTime: "13:05:00", DelayTime: 20 },
  ] };
  const c = new Map([["1000", { lat: 25.05, lon: 121.5 }], ["4340", { lat: 22.69, lon: 120.3 }]]);
  const b = buildRailBoard(rows, { stationId: "1000", coords: c, nowHm: "13:10" });
  check("a train that left 10 min ago is gone; a late one (13:05 + 20 min) is still coming", b.southbound.map((t) => t.trainNo).sort().join() === "2,3");
  const north = { StationLiveBoards: [{ ...rows.StationLiveBoards[1], TrainNo: "9", EndingStationID: "0900", EndingStationName: { Zh_tw: "基隆" } }] };
  const nb = buildRailBoard(north, { stationId: "1000", coords: new Map([...c, ["0900", { lat: 25.13, lon: 121.74 }]]), nowHm: "13:10" });
  check("a train ending at 基隆 is 北上 and appears only in that column", nb.northbound.length === 1 && nb.southbound.length === 0 && nb.northbound[0].dest === "基隆");
  const late = { StationLiveBoards: [{ ...rows.StationLiveBoards[1], ScheduleDepartureTime: "00:10:00" }] };
  check("just before midnight a 00:10 train is upcoming, not 23 h ago", buildRailBoard(late, { stationId: "1000", coords: c, nowHm: "23:55" }).southbound.length === 1);
  const gone = { StationLiveBoards: [{ ...rows.StationLiveBoards[0], ScheduleDepartureTime: "23:50:00" }] };
  check("just after midnight a 23:50 train is gone", buildRailBoard(gone, { stationId: "1000", coords: c, nowHm: "00:05" }).southbound.length === 0);
}

// ---- no coordinates: nothing is guessed
{
  const b = buildRailBoard(real, { stationId: "1000", coords: new Map() });
  check("without station coordinates every train is 'unknown' heading, listed under other, headingsKnown false", b.northbound.length === 0 && b.southbound.length === 0 && b.other.length > 0 && b.headingsKnown === false && b.other.every((t) => t.heading === "unknown"));
}

// ---- through the real service: one read serves everyone, failure is reported, stale board is labelled
{
  const NOW = Date.parse("2026-09-19T13:44:00+08:00");
  let boardCalls = 0, failBoard = false;
  const stationsRaw = { Stations: [...coords].map(([id, c]) => ({ StationID: id, StationName: { Zh_tw: c.name }, StationPosition: { PositionLat: c.lat, PositionLon: c.lon } })) };
  let t = NOW;
  const svc = createRealtimeService({
    tdxGet: async (path) => {
      if (path.includes("StationLiveBoard")) { boardCalls++; if (failBoard) { const e = new Error("429"); e.status = 429; throw e; } return real; }
      if (path.includes("TRA/Station")) return stationsRaw;
      throw new Error("unexpected " + path);
    },
    cache: createRealtimeCache({ now: () => t }), now: () => t,
  });
  const a = await svc.railBoard({ stationId: "1000" });
  const list = await svc.railStations();
  check("station list for pickers: ids and names from the cached TDX list, sorted by id", list.available && list.stations.length === coords.size && list.stations.every((x) => /^\d+$/.test(x.id) && x.name) && list.stations.every((x, i, a) => i === 0 || a[i - 1].id <= x.id));
  check("service: board available with 南下 trains and known headings", a.available && a.headingsKnown && a.southbound.length > 0);
  await svc.railBoard({ stationId: "1000" }); await svc.railBoard({ stationId: "1000" });
  check("three widgets asking within 30 s cost ONE upstream board read", boardCalls === 1);
  failBoard = true; t += 60_000;
  const stale = await svc.railBoard({ stationId: "1000" });
  check("refresh fails: the last board is still shown, marked stale", stale.available && stale.stale === true);
  t += 6 * 60_000;
  const gone = await svc.railBoard({ stationId: "1000" });
  check("still failing after 5+ minutes: says unavailable with the reason, no invented trains", gone.available === false && gone.reason === "rate_limited" && !gone.southbound);
}

process.exit(failed ? 1 : 0);
