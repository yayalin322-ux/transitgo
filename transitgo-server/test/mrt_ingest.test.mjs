import { buildMrtDb, fixtureSource, realResponse } from "./mrtFixture.mjs";
import { normalizeMetroTravelTimes, normalizeMetroFrequencies, normalizeMetroTransfers } from "../src/tdx/normalizer.mjs";
import { ingestMetroOperator } from "../src/tdx/ingest.mjs";
import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}
const count = async (db, sql, ...args) => Number((await db.prepare(sql).get(...args)).c);

const { db, results } = await buildMrtDb(["TRTC", "TYMC", "NTMC", "KRTC", "KLRT"]);

// --- Real record counts (from the captured TDX responses) ---
check("TRTC: real 122 stations ingested", results.TRTC.stops === 122 && await count(db, "SELECT count(*) c FROM gtfs_stops WHERE feed_id='MRT_TRTC'") === 122);
check("TRTC: 11 published route directions become 22 routes (published + mirrored opposite)", results.TRTC.routes === 22);
check("TRTC: real hop times stored", await count(db, "SELECT count(*) c FROM transit_segment_times WHERE feed_id='MRT_TRTC'") === results.TRTC.segments && results.TRTC.segments > 300);
check("TRTC: real headway bands stored", results.TRTC.frequencies > 100);
check("TRTC: real interchange links stored", results.TRTC.transfers >= 29);
check("TYMC: 22 stations, express + all-stop routes, both directions", results.TYMC.stops === 22 && results.TYMC.routes === 4);
check("NTMC: ingested", results.NTMC.ingested === true && results.NTMC.stops === 26);
check("KRTC: ingested", results.KRTC.ingested === true && results.KRTC.stops === 39);

// --- KLRT: TDX's S2STravelTime for it is a mis-shaped loop table (an implied 88-minute hop) — must be refused, not turned into edges ---
check("KLRT: implausible S2STravelTime is refused (ingested:false), nothing stored", results.KLRT.ingested === false && await count(db, "SELECT count(*) c FROM gtfs_stops WHERE feed_id='MRT_KLRT'") === 0);
check("KLRT: the missing Frequency/LineTransfer endpoints are reported, not hidden", results.KLRT.missing.some((m) => m.startsWith("Frequency")) && results.KLRT.missing.some((m) => m.startsWith("LineTransfer")));

// --- Route naming comes from real data ---
const route = await db.prepare("SELECT route_short_name, route_long_name, route_type FROM gtfs_routes WHERE feed_id='MRT_TRTC' AND route_id='R-1-R'").get();
check("TRTC route R-1-R is a metro route (type 1) named from the real Line endpoint", route?.route_type === 1 && route.route_short_name === "淡水信義線");
check("Route direction label is derived from the route's own real last station (往淡水)", route?.route_long_name === "往淡水");

// --- Calendar + band normalization ---
const cal = await db.prepare("SELECT * FROM gtfs_calendar WHERE feed_id='MRT_TRTC' AND service_id='平日'").get();
check("Service calendar carries TDX's real weekday flags (平日 = Mon-Fri, not Sat/Sun)", cal.monday === 1 && cal.friday === 1 && cal.saturday === 0 && cal.sunday === 0);
const band = await db.prepare("SELECT end_time FROM transit_route_frequency WHERE feed_id='MRT_TRTC' AND route_id='BL-1' AND start_time='23:00' AND service_day_label='平日'").get();
check("A band ending at 00:00 is stored as 24:00 (stays usable, not a zero-length window)", band?.end_time === "24:00");

// --- TYMC: origin-to-station MATRIX — order recovered, real explicit hop rows used ---
const a1a2 = await db.prepare("SELECT run_seconds FROM transit_segment_times WHERE feed_id='MRT_TYMC' AND route_id='A-T1' AND from_stop_id='A1' AND to_stop_id='A2'").get();
check("TYMC: A1->A2 uses TDX's real explicit 300s row", a1a2?.run_seconds === 300);
const expressStops = await db.prepare("SELECT stop_id FROM gtfs_route_stops WHERE feed_id='MRT_TYMC' AND route_id='A-T2' ORDER BY stop_sequence").all();
check("TYMC: the express service keeps only its real stops (A1,A3,A8,A12,A13,A18,A21)", expressStops.map((r) => r.stop_id).join(",") === "A1,A3,A8,A12,A13,A18,A21");
check("TYMC: no Frequency band maps to these routes, so none is invented", await count(db, "SELECT count(*) c FROM transit_route_frequency WHERE feed_id='MRT_TYMC'") === 0);

// --- KRTC publishes BOTH directions itself -> nothing mirrored ---
const krtcRoutes = await db.prepare("SELECT route_id FROM gtfs_routes WHERE feed_id='MRT_KRTC' ORDER BY route_id").all();
check("KRTC: both real directions published by TDX, no '-R' mirror invented", krtcRoutes.length === 4 && !krtcRoutes.some((r) => r.route_id.endsWith("-R")));

// --- Cross-operator interchange references are kept (resolved later by the Graph Builder) ---
const crossFeed = await db.prepare("SELECT count(*) c FROM transit_transfers WHERE feed_id='MRT_NTMC'").get();
check("NTMC: interchanges naming another operator's stations are kept", Number(crossFeed.c) >= 6);

// --- Normalizer edge cases ---
check("Rows with no RunTime or FromStationID===ToStationID never produce a hop", normalizeMetroTravelTimes([{ RouteID: "X", TravelTimes: [{ Sequence: 1, FromStationID: "A", ToStationID: "A", RunTime: 100 }, { Sequence: 2, FromStationID: "A", ToStationID: "B" }] }]).segments.length === 0);
check("A transfer with no real TransferTime is dropped, not defaulted", normalizeMetroTransfers([{ FromStationID: "A", ToStationID: "B", TransferTime: null }, { FromStationID: "C", ToStationID: "D", TransferTime: 0 }]).length === 0);
const mirrored = normalizeMetroTransfers([{ FromStationID: "A", ToStationID: "B", TransferTime: 3 }]);
check("A one-way interchange is mirrored with the same real time", mirrored.length === 2 && mirrored.every((t) => t.transfer_seconds === 180));
const noMatch = normalizeMetroFrequencies(realResponse("TRTC", "Frequency"), []);
check("Headway bands with no matching route produce nothing", noMatch.frequencies.length === 0);

// --- Failure paths: nothing crashes ---
{
  const empty = new DatabaseSync(":memory:");
  await ensureGtfsSchema(empty);
  const r = await ingestMetroOperator(empty, "TRTC", { source: fixtureSource("TRTC", { Station: [], S2STravelTime: [], Frequency: [], LineTransfer: [], Line: [] }), retry: { attempts: 1 } });
  check("Empty MRT dataset: ingested:false, no throw, nothing written", r.ingested === false && await count(empty, "SELECT count(*) c FROM gtfs_stops") === 0);
}
{
  const bad = new DatabaseSync(":memory:");
  await ensureGtfsSchema(bad);
  const boom = () => { throw new Error("TDX 500"); };
  const r = await ingestMetroOperator(bad, "TRTC", { source: fixtureSource("TRTC", { Station: boom, S2STravelTime: boom, Frequency: boom, LineTransfer: boom, Line: boom }), retry: { attempts: 1 } });
  check("Every TDX endpoint failing: reported as ingested:false with the errors, no throw", r.ingested === false && r.missing.length === 5);
}
{
  const noFreq = new DatabaseSync(":memory:");
  await ensureGtfsSchema(noFreq);
  const r = await ingestMetroOperator(noFreq, "TRTC", { source: fixtureSource("TRTC", { Frequency: () => { throw new Error("TDX 400"); } }), retry: { attempts: 1 } });
  check("Frequency endpoint down: operator still ingested (stations + run times), zero headway rows", r.ingested === true && r.frequencies === 0 && r.segments > 0);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
