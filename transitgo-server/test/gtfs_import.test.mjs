import AdmZip from "adm-zip";
import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { importGtfsZip } from "../src/gtfs/import.mjs";

const db = new DatabaseSync(":memory:");
ensureGtfsSchema(db);

const files = {
  "agency.txt": `agency_id,agency_name,agency_url,agency_timezone
HSINBUS,新竹客運,https://example.com,Asia/Taipei
`,
  "routes.txt": `route_id,agency_id,route_short_name,route_long_name,route_type
R5900,HSINBUS,5900,高鐵新竹站-竹北,3
`,
  "stops.txt": `stop_id,stop_name,stop_lat,stop_lon,parent_station,location_type
S1,高鐵新竹站,24.80430,121.03900,,0
S2,新竹縣政府,24.83540,121.22660,,0
S3,竹北火車站,24.83820,121.00790,,0
`,
  "trips.txt": `trip_id,route_id,service_id,direction_id,trip_headsign
T1,R5900,WEEKDAY,0,竹北火車站
`,
  "stop_times.txt": `trip_id,stop_id,arrival_time,departure_time,stop_sequence
T1,S1,08:00:00,08:00:00,1
T1,S2,08:15:00,08:16:00,2
T1,S3,08:30:00,08:30:00,3
`,
  "calendar.txt": `service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
WEEKDAY,1,1,1,1,1,0,0,20260101,20261231
`,
  "calendar_dates.txt": `service_id,date,exception_type
WEEKDAY,20260101,2
`,
};

const zip = new AdmZip();
for (const [name, content] of Object.entries(files)) {
  zip.addFile(name, Buffer.from(content, "utf8"));
}

const counts = importGtfsZip(db, "test-hsinbus", zip.toBuffer(), { name: "測試新竹客運", sourceUrl: "local-test" });
console.log("import counts:", counts);

const feed = db.prepare("SELECT * FROM gtfs_feeds WHERE feed_id = ?").get("test-hsinbus");
console.log("feed row:", feed);

const stops = db.prepare("SELECT stop_id, stop_name, stop_lat, stop_lon FROM gtfs_stops WHERE feed_id = ? ORDER BY stop_id").all("test-hsinbus");
console.log("stops:", stops);

const trip = db.prepare("SELECT * FROM gtfs_stop_times WHERE feed_id = ? AND trip_id = ? ORDER BY stop_sequence").all("test-hsinbus", "T1");
console.log("stop_times for T1:", trip);

// Re-import to prove the atomic-swap (old rows fully replaced, no duplication/leftovers).
importGtfsZip(db, "test-hsinbus", zip.toBuffer(), { name: "測試新竹客運 v2" });
const stopCountAfterReimport = db.prepare("SELECT COUNT(*) c FROM gtfs_stops WHERE feed_id = ?").get("test-hsinbus");
console.log("stop count after re-import (should still be 3, not 6):", stopCountAfterReimport.c);

if (stops.length === 3 && trip.length === 3 && stopCountAfterReimport.c === 3) {
  console.log("PASS");
} else {
  console.log("FAIL");
  process.exit(1);
}
