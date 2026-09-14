import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { normalizeTRAStations, normalizeTRATimetable, normalizeBusRouteStopSequence, normalizeBusSchedule } from "../src/tdx/normalizer.mjs";
import { insertStops, insertTrips, insertStopTimes, insertCalendarDates, insertRoutes, insertFrequencies } from "../src/tdx/ingest.mjs";

// Fixtures shaped exactly like the real TDX responses already verified working in the
// iOS app's RailModels.swift / BusModels.swift decoders — not live TDX calls (this
// account is rate-limited on every attempt), but the real field shapes, not guesses.

const rawTRAStations = {
  Stations: [
    { StationID: "1000", StationName: { Zh_tw: "臺北", En: "Taipei" }, StationPosition: { PositionLat: 25.0478, PositionLon: 121.5171 } },
    { StationID: "3300", StationName: { Zh_tw: "新竹", En: "Hsinchu" }, StationPosition: { PositionLat: 24.8017, PositionLon: 120.9714 } },
  ],
};

const rawTRATimetable = {
  TrainTimetables: [
    {
      TrainInfo: { TrainNo: "152", TrainTypeName: { Zh_tw: "自強" } },
      StopTimes: [
        { StationID: "1000", StationName: { Zh_tw: "臺北" }, ArrivalTime: "08:00", DepartureTime: "08:00" },
        { StationID: "3300", StationName: { Zh_tw: "新竹" }, ArrivalTime: "08:52", DepartureTime: "08:54" },
      ],
    },
  ],
};

// A route with a real published timetable (e.g. intercity coach) AND a route with only
// real headway bands (the norm for city bus) — both are legitimate TDX Frequencys/
// Timetables shapes, this is exactly the branch normalizeBusSchedule must split on.
const rawBusScheduleWithTimetable = [
  {
    Direction: 0,
    SubRouteName: { Zh_tw: "竹北→高鐵新竹站" },
    Timetables: [
      { DepartureTime: "07:00", ServiceDay: { Monday: 1, Tuesday: 1, Wednesday: 1, Thursday: 1, Friday: 1, Saturday: 0, Sunday: 0 } },
      { DepartureTime: "07:30", ServiceDay: { Monday: 1, Tuesday: 1, Wednesday: 1, Thursday: 1, Friday: 1, Saturday: 0, Sunday: 0 } },
    ],
  },
];

const rawBusScheduleWithFrequency = [
  {
    Direction: 0,
    SubRouteName: null,
    Frequencys: [
      { StartTime: "06:00", EndTime: "09:00", MinHeadwayMins: 8, MaxHeadwayMins: 12, ServiceDay: { Monday: 1, Tuesday: 1, Wednesday: 1, Thursday: 1, Friday: 1, Saturday: 0, Sunday: 0 } },
      { StartTime: "09:00", EndTime: "17:00", MinHeadwayMins: 15, MaxHeadwayMins: 20, ServiceDay: { Monday: 1, Tuesday: 1, Wednesday: 1, Thursday: 1, Friday: 1, Saturday: 0, Sunday: 0 } },
    ],
  },
];

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const db = new DatabaseSync(":memory:");
await ensureGtfsSchema(db);

// --- TRA stations ---
const stops = normalizeTRAStations(rawTRAStations.Stations);
await insertStops(db, "TRA", stops);
const hsinchu = db.prepare("SELECT * FROM gtfs_stops WHERE feed_id = 'TRA' AND stop_id = '3300'").get();
check("TRA station normalized with real lat/lon", hsinchu?.stop_name === "新竹" && Math.abs(hsinchu.stop_lat - 24.8017) < 0.001);

// --- TRA real timetable ---
const { trips: traTrips, stopTimes: traStopTimes, calendarDates: traCalDates } = normalizeTRATimetable(rawTRATimetable.TrainTimetables, "2026-09-14");
await insertTrips(db, "TRA", traTrips);
await insertStopTimes(db, "TRA", traStopTimes);
await insertCalendarDates(db, "TRA", traCalDates);
const storedTrip = db.prepare("SELECT * FROM gtfs_trips WHERE feed_id = 'TRA' AND trip_id = 'TRA_152_2026-09-14'").get();
const storedStopTimes = db.prepare("SELECT * FROM gtfs_stop_times WHERE feed_id = 'TRA' AND trip_id = 'TRA_152_2026-09-14' ORDER BY stop_sequence").all();
check("TRA trip inserted with real train number", storedTrip?.route_id === "TRA");
check("TRA stop_times has real departure 08:54 from 新竹", storedStopTimes[1]?.stop_id === "3300" && storedStopTimes[1]?.departure_time === "08:54");
const storedCalDate = db.prepare("SELECT * FROM gtfs_calendar_dates WHERE feed_id = 'TRA'").get();
check("TRA calendar_dates marks the exact real date queried, not an invented weekly pattern", storedCalDate?.date === "20260914" && storedCalDate?.exception_type === 1);

// --- Bus: real fixed timetable branch ---
const busTimetableResult = normalizeBusSchedule(rawBusScheduleWithTimetable, "5900", "2026-09-14");
await insertTrips(db, "BUS", busTimetableResult.trips);
await insertStopTimes(db, "BUS", busTimetableResult.stopTimes);
check("Bus route with real Timetables produces real gtfs_trips (2 departures)", busTimetableResult.trips.length === 2);
check("Bus route with real Timetables produces no fabricated frequency rows", busTimetableResult.frequencies.length === 0);

// --- Bus: real headway-only branch ---
const busFreqResult = normalizeBusSchedule(rawBusScheduleWithFrequency, "307", "2026-09-14");
await insertFrequencies(db, "BUS", busFreqResult.frequencies);
check("Bus route with only Frequencys produces zero fabricated trips", busFreqResult.trips.length === 0);
const storedFreq = db.prepare("SELECT * FROM transit_route_frequency WHERE feed_id = 'BUS' AND route_id = '307' ORDER BY start_time").all();
check("Real headway bands stored as-is (8-12 min, then 15-20 min), not averaged into one number", storedFreq.length === 2 && storedFreq[0].min_headway_mins === 8 && storedFreq[1].min_headway_mins === 15);
check("Headway source is clearly attributed, per the 'no fabricated data' requirement", storedFreq[0].source === "TDX v2/Bus/Schedule Frequencys");

// --- Bus: real per-stop times resolved to real stations via StopOfRoute's own order ---
const rawStopOfRoute5900 = [
  {
    Direction: 0,
    Stops: [
      { StopUID: "S1", StopName: { Zh_tw: "高鐵新竹站" }, StopSequence: 1 },
      { StopUID: "S2", StopName: { Zh_tw: "新竹縣政府" }, StopSequence: 2 },
      { StopUID: "S3", StopName: { Zh_tw: "竹北火車站" }, StopSequence: 3 },
    ],
  },
];
const rawScheduleWithStopTimes = [
  {
    Direction: 0,
    Timetables: [{
      DepartureTime: "08:00",
      StopTimes: [
        { ArrivalTime: "08:00", DepartureTime: "08:00" },
        { ArrivalTime: "08:15", DepartureTime: "08:16" },
        { ArrivalTime: "08:30", DepartureTime: "08:30" },
      ],
    }],
  },
];
const routeStops = normalizeBusRouteStopSequence(rawStopOfRoute5900, "5900");
check("StopOfRoute normalized with real sequence order", routeStops.length === 3 && routeStops[1].stop_id === "S2" && routeStops[1].stop_sequence === 2);

const seqMap = new Map([[0, ["S1", "S2", "S3"]]]);
const resolvedResult = normalizeBusSchedule(rawScheduleWithStopTimes, "5900", "2026-09-14", seqMap);
check("Bus per-trip stop times resolved to REAL station IDs by position (not null anymore)",
  resolvedResult.stopTimes.length === 3
  && resolvedResult.stopTimes[0].stop_id === "S1"
  && resolvedResult.stopTimes[1].stop_id === "S2"
  && resolvedResult.stopTimes[2].stop_id === "S3");

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
