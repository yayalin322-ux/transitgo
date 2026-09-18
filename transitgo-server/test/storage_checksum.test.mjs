// Integration test: a real (small) graph -> saveGraphToDisk (streaming, checksummed,
// unchanged from PR #2) -> upload to a fake S3 bucket -> download back -> loadGraphFromDisk
// (which validates the embedded checksum) -> confirm the loaded graph matches the
// original. This is the exact "fake local graph -> upload -> download -> checksum ->
// load" scenario requested, using the real persist.mjs (not a mock) alongside the fake
// S3 transport.
import { existsSync, unlinkSync, readFileSync, writeFileSync } from "node:fs";
import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { saveGraphToDisk, loadGraphFromDisk } from "../src/graph/persist.mjs";
import { FakeS3Client } from "./fakeS3.mjs";
import { uploadArtifact, downloadArtifact } from "../src/graph/graphStorage.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

function buildRealSmallGraph() {
  const graph = new MultimodalGraph();
  graph.builtAt = new Date().toISOString();
  graph.warnings = ["test warning"];
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

const bucket = "test-bucket";
const client = new FakeS3Client();
const artifactId = "build-checksum-1";
const localBuildPath = "/tmp/transitgo_checksum_build.artifact";
const localDownloadPath = "/tmp/transitgo_checksum_download.artifact";
for (const p of [localBuildPath, localDownloadPath]) if (existsSync(p)) unlinkSync(p);

const original = buildRealSmallGraph();
const saveResult = await saveGraphToDisk(original, localBuildPath);
check("Local save produces a real checksum", typeof saveResult.checksum === "string" && saveResult.checksum.length === 64);

await uploadArtifact(client, {
  bucket, localPath: localBuildPath, artifactId,
  meta: { version: 1, nodeCount: original.nodeCount, edgeCount: original.edgeCount, coverage: saveResult.coverage, checksum: saveResult.checksum },
});

await downloadArtifact(client, { bucket, artifactId, tmpPath: localDownloadPath });
check("Downloaded bytes are byte-for-byte identical to what was uploaded", readFileSync(localBuildPath).equals(readFileSync(localDownloadPath)));

const loaded = loadGraphFromDisk(localDownloadPath);
check("loadGraphFromDisk accepts the round-tripped artifact (checksum passes)", loaded !== null);
check("Round-tripped graph has the same node count", loaded.nodeCount === original.nodeCount);
check("Round-tripped graph has the same edge count", loaded.edgeCount === original.edgeCount);
check("Round-tripped node keeps its real name", loaded.nodes.get("TRA:1000")?.name === "臺北");
check("Round-tripped edge keeps its real departure time", loaded.neighbors("TRA:1000")[0]?.departureSeconds === 8 * 3600);

// Corruption after upload (simulating bit rot / a bad transfer) must be caught on load —
// tamper with the (gzip-compressed) bytes actually stored in the fake bucket, then
// download+load again. Storage always holds compressed bytes now (see graphStorage.mjs),
// so this corrupts the stored .graph.gz object directly, matching what a real bit-flip
// in transit or at rest would actually look like.
const storedKey = `routing-graph/production/${artifactId}.graph.gz`;
const corrupted = Buffer.from(client.objects.get(storedKey));
corrupted[Math.floor(corrupted.length / 2)] ^= 0xff; // flip a byte in the middle of the compressed payload
client.objects.set(storedKey, corrupted);
const corruptDownloadPath = "/tmp/transitgo_checksum_corrupt_download.artifact";
let corruptDownloadThrew = false;
try {
  await downloadArtifact(client, { bucket, artifactId, tmpPath: corruptDownloadPath });
} catch {
  // A flipped byte in gzip-compressed data most often breaks decompression itself
  // (invalid gzip stream) rather than producing corrupt-but-parseable output — either
  // failure mode is an acceptable rejection; downloadAndLoadGraph (the real caller)
  // treats a thrown download the same as a failed local validation: unavailable, not a
  // crash. See storage_failure.test.mjs for that higher-level behavior.
  corruptDownloadThrew = true;
}
const loadedCorrupt = corruptDownloadThrew ? null : loadGraphFromDisk(corruptDownloadPath);
check("A corrupted artifact (flipped byte) is rejected — either gunzip fails or checksum validation catches it, never silently loaded", loadedCorrupt === null);

for (const p of [localBuildPath, localDownloadPath, corruptDownloadPath]) if (existsSync(p)) unlinkSync(p);

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
