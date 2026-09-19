// The boot-time graph loader streams the artifact in chunks (a full read + JSON.parse used to peak at ~390 MB
// for a production-size graph, which OOM-killed Render's 512 MB instance on every restart).
import { mkdtempSync, writeFileSync, readFileSync, truncateSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { saveGraphToDisk, loadGraphFromDisk } from "../src/graph/persist.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }
const dir = mkdtempSync(join(tmpdir(), "graphload-"));

const nasty = [
  "捷運台北車站(1號出口)", 'He said "hi"', "back\\slash", "a},{b", "x}]y", "],\"edges\":[", "{\"nodes\":[", "emoji 🚇🚲 end", "line\nbreak", "  spaces  ",
];
function makeGraph(nodes, edges) {
  const g = new MultimodalGraph();
  g.builtAt = "2026-09-19T00:00:00.000Z"; g.dataVersion = "v-test"; g.warnings = ["注意: a},{b", "second", "tricky ,\"nodes\":[ inside a warning"];
  g.serviceCalendar = new Map([["TRA:svc1", { calendarRow: null, exceptions: new Map([["20260921", 1], ["20260922", 2]]) }]]);
  for (let i = 0; i < nodes; i++) g.addNode(new TransitNode({ id: `T:${i}`, type: NodeType.STOP, name: nasty[i % nasty.length] + i, lat: 25 + i / 1e5, lon: 121 + i / 1e5, parentStationId: i % 3 ? null : `T:P${i}` }));
  for (let i = 0; i < edges; i++) {
    const kind = i % 3;
    g.addEdge(new TransitEdge({
      id: `E_${i}_${nasty[i % nasty.length]}`, fromNodeId: `T:${i % Math.max(1, nodes)}`, toNodeId: `T:${(i * 7 + 1) % Math.max(1, nodes)}`,
      mode: [Mode.BUS, Mode.TRA, Mode.WALK][kind], routeId: kind === 2 ? null : `R${i % 50}`,
      ...(kind === 0 ? { headwaySeconds: 600, windowStartSeconds: 25200, windowEndSeconds: 32400, travelSeconds: 120, distanceMeters: 812.5 } : {}),
      ...(kind === 1 ? { departureSeconds: 36000 + i, arrivalSeconds: 36300 + i, travelSeconds: 300, serviceKey: "TRA:svc1" } : {}),
      ...(kind === 2 ? { travelSeconds: 60, distanceMeters: 80 } : {}),
      source: nasty[(i + 2) % nasty.length],
    }));
  }
  return g;
}
const dump = (g) => JSON.stringify({ n: [...g.nodes.values()], e: [...g.edgesByFrom.values()].flat(), w: g.warnings, b: g.builtAt, d: g.dataVersion, c: [...g.serviceCalendar].map(([k, v]) => [k, v.calendarRow, [...v.exceptions]]) });

// --- round trip, whatever the chunking ---
const g = makeGraph(60, 300);
const file = join(dir, "g.artifact");
await saveGraphToDisk(g, file);
const expected = dump(g);
for (const chunkBytes of [1, 3, 7, 64, 1000, 1 << 20]) {
  const loaded = loadGraphFromDisk(file, { chunkBytes });
  check(`chunk size ${chunkBytes} B: loaded graph is identical (names with quotes, backslashes, '},{', '}]', emoji, newline)`, loaded !== null && dump(loaded) === expected);
}
{
  const loaded = loadGraphFromDisk(file);
  check("counts and metadata survive", loaded.nodeCount === 60 && loaded.edgeCount === 300 && loaded.dataVersion === "v-test" && loaded.builtAt === g.builtAt);
  check("service calendar (nested Maps) survives", loaded.serviceCalendar.get("TRA:svc1").exceptions.get("20260922") === 2);
  check("edges are real TransitEdge objects (time-dependent / headway getters work)", [...loaded.edgesByFrom.values()].flat().some((e) => e.isTimeDependent) && [...loaded.edgesByFrom.values()].flat().some((e) => e.isHeadwayBased));
}

// --- degenerate graphs ---
{
  for (const [n, e] of [[0, 0], [5, 0]]) {
    const f = join(dir, `g${n}_${e}.artifact`);
    await saveGraphToDisk(makeGraph(n, e), f);
    const l = loadGraphFromDisk(f, { chunkBytes: 5 });
    check(`${n} nodes / ${e} edges loads`, l !== null && l.nodeCount === n && l.edgeCount === e);
  }
}

// --- corruption is refused (null), never a crash or a half graph ---
{
  const bytes = readFileSync(file);
  const flip = Buffer.from(bytes); flip[Math.floor(flip.length / 2)] ^= 0x01;
  const f1 = join(dir, "flip.artifact"); writeFileSync(f1, flip);
  check("a single flipped byte fails the checksum", loadGraphFromDisk(f1) === null);
  const f2 = join(dir, "trunc.artifact"); writeFileSync(f2, bytes); truncateSync(f2, bytes.length - 500);
  check("a truncated file is refused", loadGraphFromDisk(f2) === null);
  const f3 = join(dir, "notrailer.artifact"); writeFileSync(f3, bytes.subarray(0, bytes.length - 70));
  check("a file without the checksum trailer is refused", loadGraphFromDisk(f3) === null);
  const f4 = join(dir, "garbage.artifact"); writeFileSync(f4, "not a graph at all\n" + "0".repeat(64) + "\n");
  check("garbage with a well-formed trailer is refused", loadGraphFromDisk(f4) === null);
  check("a missing file is null", loadGraphFromDisk(join(dir, "nope.artifact")) === null);
  const f5 = join(dir, "empty.artifact"); writeFileSync(f5, "");
  check("an empty file is null", loadGraphFromDisk(f5) === null);
}

// --- memory stays bounded: the loader never holds more than a few chunks of text ---
{
  const big = makeGraph(4000, 30000);
  const f = join(dir, "big.artifact");
  await saveGraphToDisk(big, f);
  const fileBytes = readFileSync(f).length;
  const stats = {};
  const t = performance.now();
  const l = loadGraphFromDisk(f, { chunkBytes: 64 * 1024, stats });
  const ms = performance.now() - t;
  check(`big graph loads (${(fileBytes / 1048576).toFixed(1)} MB file)`, l !== null && l.edgeCount === 30000);
  check(`read in many chunks (${stats.chunks}), buffered text never exceeded ${stats.maxBufferedChars} chars vs a ${fileBytes}-byte file`, stats.chunks > 20 && stats.maxBufferedChars < 4 * 64 * 1024);
  check(`load time is linear, not quadratic (${Math.round(ms)} ms for 30k edges)`, ms < 5000);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
