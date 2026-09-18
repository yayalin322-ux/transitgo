// The explicit failure matrix: upload failure, download failure, corrupted artifact,
// truncated artifact, and a restart-equivalent (download -> load -> "graph active").
// Every scenario must leave the server in a safe, non-crashed state.
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { insertTrips, insertStopTimes, insertStops } from "../src/tdx/ingest.mjs";
import { normalizeTRATimetable } from "../src/tdx/normalizer.mjs";
import { FakeS3Client } from "./fakeS3.mjs";
import { setCurrentArtifactId } from "../src/graph/graphStorage.mjs";
import { buildAndPublishGraph, downloadAndLoadGraph } from "../src/graph/graphPersistence.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

async function fixtureDb() {
  const db = new DatabaseSync(":memory:");
  await ensureGtfsSchema(db);
  await insertStops(db, "TRA", [
    { stop_id: "1000", stop_name: "臺北", stop_lat: 25.0478, stop_lon: 121.5171 },
    { stop_id: "3300", stop_name: "新竹", stop_lat: 24.8017, stop_lon: 120.9714 },
  ]);
  const raw = { TrainTimetables: [{
    TrainInfo: { TrainNo: "152", TrainTypeName: { Zh_tw: "自強" } },
    StopTimes: [
      { StationID: "1000", ArrivalTime: "08:00", DepartureTime: "08:00" },
      { StationID: "3300", ArrivalTime: "08:54", DepartureTime: "08:56" },
    ],
  }] };
  const tra = normalizeTRATimetable(raw.TrainTimetables, "2026-09-14");
  await insertTrips(db, "TRA", tra.trips);
  await insertStopTimes(db, "TRA", tra.stopTimes);
  return db;
}

const bucket = "test-bucket";

// --- Scenario A: build succeeds, upload fails -> current graph (if any) remains active ---
{
  const db = await fixtureDb();
  const client = new FakeS3Client();
  // Seed an already-active "old" graph via a prior successful publish.
  const first = await buildAndPublishGraph(db, { bucket, client });
  check("Setup: initial publish succeeds", first.nodeCount === 2);

  client.failNextPut = new Error("simulated upload failure");
  let threw = false;
  try {
    await buildAndPublishGraph(db, { bucket, client });
  } catch {
    threw = true;
  }
  check("A build-succeeds-but-upload-fails run rejects (caller keeps its old routingGraph)", threw === true);

  // The pointer must still reference the FIRST (old, still-valid) artifact — activation
  // never ran for the failed second attempt.
  const stillActive = await downloadAndLoadGraph({ bucket, client, maxAttempts: 1 });
  check("current pointer still resolves to the original artifact after a failed publish", stillActive?.artifactId === first.artifactId);
  check("The old graph's data is still fully intact and loadable", stillActive?.graph.nodeCount === 2);
}

// --- Scenario B: server startup, Storage temporarily unavailable ---
{
  const client = new FakeS3Client();
  // No pointer published at all — simulates "Storage reachable but nothing there yet"
  // as well as covers the "server must not crash" requirement generally.
  let threw = false;
  let result;
  try {
    result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 1 });
  } catch {
    threw = true;
  }
  check("Boot recovery with nothing in Storage never throws", threw === false);
  check("Boot recovery returns null (graph unavailable) rather than a partial object", result === null);
}

// --- Scenario C: corrupted artifact (wrong checksum) ---
{
  const db = await fixtureDb();
  const client = new FakeS3Client();
  const published = await buildAndPublishGraph(db, { bucket, client });

  const key = `routing-graph/production/${published.artifactId}.graph.gz`;
  const bytes = Buffer.from(client.objects.get(key));
  bytes[10] ^= 0xff; // corrupt a byte well inside the compressed payload
  client.objects.set(key, bytes);

  const result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 1 });
  check("A corrupted artifact is rejected (gunzip failure or checksum mismatch), not loaded as garbage", result === null);
}

// --- Scenario D: truncated artifact ---
{
  const db = await fixtureDb();
  const client = new FakeS3Client();
  const published = await buildAndPublishGraph(db, { bucket, client });

  const key = `routing-graph/production/${published.artifactId}.graph.gz`;
  const full = client.objects.get(key);
  client.objects.set(key, full.subarray(0, Math.floor(full.length / 2)));

  const result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 1 });
  check("A truncated artifact is rejected, not loaded or crashed on", result === null);
}

// --- Scenario E: restart-equivalent — publish, then a fresh downloadAndLoadGraph (as
// boot would do) recovers the exact same graph without any rebuild. This is the actual
// success bar for this whole feature. ---
{
  const db = await fixtureDb();
  const client = new FakeS3Client();
  const published = await buildAndPublishGraph(db, { bucket, client });

  // Simulate a fresh process: no local state carried over, only what's in "Storage".
  const recovered = await downloadAndLoadGraph({ bucket, client, maxAttempts: 3 });
  check("Restart-equivalent: graph recovers from Storage without a rebuild", recovered !== null);
  check("Recovered graph has the exact same node/edge counts as what was published", recovered.graph.nodeCount === published.nodeCount && recovered.graph.edgeCount === published.edgeCount);
  check("Recovered graph is the same artifact that was activated", recovered.artifactId === published.artifactId);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
