import { createWriteStream, readFileSync, existsSync, renameSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { MultimodalGraph, TransitNode, TransitEdge } from "./model.mjs";
import { graphCoverage } from "../routing/api.mjs";
import { logMemory } from "./memlog.mjs";

/**
 * Persists the built graph to local disk so a restart can load it back in milliseconds
 * instead of re-running the full "query every gtfs_* table, rebuild every edge" pass
 * from Postgres. That rebuild is real, non-trivial CPU/memory work — on Render's
 * 512MB/0.15-CPU instance it was a genuine contributor to a boot crash-loop (see the
 * commit history around 2026-09-15). Render's disk is ephemeral across *deploys*, but
 * this doesn't need to survive a deploy — it only needs to survive the restarts a crash
 * or OOM kill causes *within* one deploy's lifetime, which a local file does fine.
 *
 * Explicit format version — bumped whenever the shape written here changes, so an old
 * cache file from a previous deploy (different field set, bug fixes in the builder,
 * etc.) is detected and ignored rather than loaded as if it were still correct.
 */
const FORMAT_VERSION = 2;

function serviceCalendarToJSON(serviceCalendar) {
  const out = [];
  for (const [key, entry] of serviceCalendar ?? []) {
    out.push([key, {
      calendarRow: entry.calendarRow ?? null,
      exceptions: [...(entry.exceptions ?? new Map())],
    }]);
  }
  return out;
}

function serviceCalendarFromJSON(json) {
  const map = new Map();
  for (const [key, entry] of json ?? []) {
    map.set(key, {
      calendarRow: entry.calendarRow ?? null,
      exceptions: new Map(entry.exceptions ?? []),
    });
  }
  return map;
}

/**
 * Streams the graph to disk instead of building one giant JSON.stringify(payload)
 * string. With ~76k nodes and ~310k edges, a single stringify call would hold the
 * entire serialized string (100+MB) in memory at the same moment the live graph
 * objects it was built from are still resident — real, avoidable peak-memory
 * duplication right after buildGraph() already used the most memory of the whole
 * request. Writing node-by-node/edge-by-edge keeps only one small string in flight
 * at a time; a trailing checksum is computed over the same bytes as they're written,
 * so no second pass over the data is needed to produce it.
 *
 * Still atomic: everything is written to `${filePath}.tmp` and only renamed to the
 * final path once the stream has fully flushed — a crash mid-write leaves the old
 * cache (if any) untouched.
 */
export async function saveGraphToDisk(graph, filePath) {
  const tmpPath = `${filePath}.tmp`;
  const coverage = graphCoverage(graph);
  const hash = createHash("sha256");
  const stream = createWriteStream(tmpPath);

  const write = (chunk) => {
    hash.update(chunk);
    if (!stream.write(chunk)) {
      return new Promise((resolve) => stream.once("drain", resolve));
    }
  };

  const header = {
    formatVersion: FORMAT_VERSION,
    builtAt: graph.builtAt,
    dataVersion: graph.dataVersion,
    warnings: graph.warnings ?? [],
    nodeCount: graph.nodeCount,
    edgeCount: graph.edgeCount,
    coverage,
    serviceCalendar: serviceCalendarToJSON(graph.serviceCalendar),
  };
  await write(`${JSON.stringify(header).slice(0, -1)},"nodes":[`);

  let first = true;
  for (const node of graph.nodes.values()) {
    await write((first ? "" : ",") + JSON.stringify(node));
    first = false;
  }
  await write(`],"edges":[`);

  first = true;
  for (const edgeList of graph.edgesByFrom.values()) {
    for (const edge of edgeList) {
      await write((first ? "" : ",") + JSON.stringify(edge));
      first = false;
    }
  }
  await write(`]}`);

  const checksum = hash.digest("hex");
  // Checksum trails the payload as its own line — loadGraphFromDisk reads the JSON
  // object first, then verifies this line separately, so the hash never has to cover
  // itself. Written directly to the stream (not through `write()`, which hashes) since
  // the hash object is already finalized above.
  const trailer = `\n${checksum}\n`;
  if (!stream.write(trailer)) {
    await new Promise((resolve) => stream.once("drain", resolve));
  }

  await new Promise((resolve, reject) => {
    stream.end((err) => (err ? reject(err) : resolve()));
  });
  renameSync(tmpPath, filePath);
  logMemory("persist_complete", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });
  return { checksum, nodeCount: graph.nodeCount, edgeCount: graph.edgeCount, coverage };
}

/** Returns null (never throws) on anything from "file doesn't exist" to "corrupt JSON"
 * to "written by an older, incompatible format version" to "checksum mismatch" — every
 * one of those just means "fall back to a real rebuild", not a boot failure. */
export function loadGraphFromDisk(filePath) {
  if (!existsSync(filePath)) return null;
  let raw;
  try {
    raw = readFileSync(filePath, "utf8");
  } catch {
    return null;
  }

  const trimmed = raw.trimEnd();
  const lastNewline = trimmed.lastIndexOf("\n");
  if (lastNewline === -1) return null;
  const jsonPart = trimmed.slice(0, lastNewline);
  const storedChecksum = trimmed.slice(lastNewline + 1).trim();
  if (!/^[0-9a-f]{64}$/.test(storedChecksum)) return null;

  const actualChecksum = createHash("sha256").update(jsonPart).digest("hex");
  if (actualChecksum !== storedChecksum) {
    console.warn("[routing] graph cache checksum mismatch — ignoring cache, staying empty until a rebuild");
    return null;
  }

  let payload;
  try {
    payload = JSON.parse(jsonPart);
  } catch {
    return null;
  }
  if (payload?.formatVersion !== FORMAT_VERSION) return null;
  if (typeof payload.nodeCount !== "number" || typeof payload.edgeCount !== "number") return null;
  if (!Array.isArray(payload.nodes) || !Array.isArray(payload.edges)) return null;
  if (payload.nodes.length !== payload.nodeCount || payload.edges.length !== payload.edgeCount) {
    console.warn("[routing] graph cache node/edge count mismatch — ignoring cache");
    return null;
  }

  const graph = new MultimodalGraph();
  graph.builtAt = payload.builtAt;
  graph.dataVersion = payload.dataVersion;
  graph.warnings = payload.warnings ?? [];
  graph.serviceCalendar = serviceCalendarFromJSON(payload.serviceCalendar);
  for (const n of payload.nodes) graph.addNode(new TransitNode(n));
  for (const e of payload.edges) graph.addEdge(new TransitEdge(e));
  return graph;
}

/** Cheap on-disk stat check for the admin rebuild-status endpoint — avoids re-reading
 * and re-hashing the whole cache file just to report its size. */
export function cacheFileInfo(filePath) {
  if (!existsSync(filePath)) return null;
  try {
    const st = statSync(filePath);
    return { sizeBytes: st.size, mtime: st.mtime.toISOString() };
  } catch {
    return null;
  }
}
