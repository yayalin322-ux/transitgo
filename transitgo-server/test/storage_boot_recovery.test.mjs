import { existsSync } from "node:fs";
import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { saveGraphToDisk } from "../src/graph/persist.mjs";
import { FakeS3Client } from "./fakeS3.mjs";
import { uploadArtifact, setCurrentArtifactId } from "../src/graph/graphStorage.mjs";
import { downloadAndLoadGraph } from "../src/graph/graphPersistence.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

function realSmallGraph() {
  const graph = new MultimodalGraph();
  graph.builtAt = new Date().toISOString();
  graph.warnings = [];
  graph.serviceCalendar = new Map();
  graph.addNode(new TransitNode({ id: "TRA:1000", type: NodeType.STOP, name: "臺北", lat: 25.0478, lon: 121.5171 }));
  graph.addNode(new TransitNode({ id: "TRA:3300", type: NodeType.STOP, name: "新竹", lat: 24.8017, lon: 120.9714 }));
  graph.addEdge(new TransitEdge({
    id: "e1", fromNodeId: "TRA:1000", toNodeId: "TRA:3300", mode: Mode.TRA, routeId: "152",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 54 * 60, travelSeconds: 54 * 60,
    source: "TDX real timetable",
  }));
  return graph;
}

async function publishFixture(client, bucket, artifactId) {
  const graph = realSmallGraph();
  const tmpPath = `/tmp/transitgo_boot_fixture_${artifactId}.artifact`;
  const meta = await saveGraphToDisk(graph, tmpPath);
  await uploadArtifact(client, { bucket, localPath: tmpPath, artifactId, meta });
  return meta;
}

const bucket = "test-bucket";

// --- Scenario 1: nothing published yet (fresh deploy, Storage configured but empty) ---
{
  const client = new FakeS3Client();
  const result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 1 });
  check("No current pointer yet -> returns null, not a throw", result === null);
}

// --- Scenario 2: a real published artifact exists and current points at it ---
{
  const client = new FakeS3Client();
  await publishFixture(client, bucket, "build-boot-1");
  await setCurrentArtifactId(client, { bucket, artifactId: "build-boot-1" });

  const result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 1 });
  check("A real published artifact is downloaded and loaded successfully", result !== null);
  check("Loaded graph has the real node count", result.graph.nodeCount === 2);
  check("Loaded graph has the real edge count", result.graph.edgeCount === 1);
  check("Loaded graph keeps real station names", result.graph.nodes.get("TRA:1000")?.name === "臺北");
  check("Returned artifactId matches the current pointer", result.artifactId === "build-boot-1");
}

// --- Scenario 3: current pointer references an artifact that was deleted/never uploaded ---
{
  const client = new FakeS3Client();
  await setCurrentArtifactId(client, { bucket, artifactId: "build-does-not-exist" });
  const result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 2, backoffMs: 5 });
  check("Pointer to a missing artifact -> returns null after retries, not a throw", result === null);
}

// --- Scenario 4: a transient failure on the first attempt, success on retry ---
{
  const client = new FakeS3Client();
  await publishFixture(client, bucket, "build-boot-2");
  await setCurrentArtifactId(client, { bucket, artifactId: "build-boot-2" });
  client.failNextGet = new Error("simulated transient network failure");

  const result = await downloadAndLoadGraph({ bucket, client, maxAttempts: 3, backoffMs: 5 });
  check("Recovers on retry after one transient failure", result !== null && result.graph.nodeCount === 2);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
