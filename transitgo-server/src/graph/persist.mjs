import { createWriteStream, openSync, closeSync, readSync, existsSync, renameSync, statSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";
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
  logMemory("persist_start", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });
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

  // Sampled, not per-object — logs ~10 checkpoints across the write regardless of graph
  // size, enough resolution to see whether RSS climbs during the write (the giant-string
  // duplication this streaming approach exists to avoid) without flooding the log for a
  // ~310k-edge graph.
  const nodeSampleEvery = Math.max(1, Math.floor(graph.nodeCount / 10));
  const edgeSampleEvery = Math.max(1, Math.floor(graph.edgeCount / 10));

  let first = true;
  let nodesWritten = 0;
  for (const node of graph.nodes.values()) {
    await write((first ? "" : ",") + JSON.stringify(node));
    first = false;
    nodesWritten++;
    if (nodesWritten % nodeSampleEvery === 0) {
      logMemory("persist_progress", { section: "nodes", nodesWritten, nodeCount: graph.nodeCount });
    }
  }
  await write(`],"edges":[`);
  logMemory("persist_mid", { nodesWritten, nodeCount: graph.nodeCount });

  first = true;
  let edgesWritten = 0;
  for (const edgeList of graph.edgesByFrom.values()) {
    for (const edge of edgeList) {
      await write((first ? "" : ",") + JSON.stringify(edge));
      first = false;
      edgesWritten++;
      if (edgesWritten % edgeSampleEvery === 0) {
        logMemory("persist_progress", { section: "edges", edgesWritten, edgeCount: graph.edgeCount });
      }
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

const TRAILER = /\n([0-9a-f]{64})\s*$/;
const READ_CHUNK_BYTES = 1 << 20;   // 1 MiB

/**
 * Returns null (never throws) on anything from "file doesn't exist" to "corrupt JSON"
 * to "written by an older, incompatible format version" to "checksum mismatch" — every
 * one of those just means "fall back to a real rebuild", not a boot failure.
 *
 * STREAMS the file in 1 MiB chunks instead of `readFileSync` + one `JSON.parse`. That used to hold the
 * whole file as a JS string (two bytes per character once a Chinese name is in it — ~2x the file),
 * a second copy for hashing, and the fully parsed object tree, all at the same instant: ~390 MB of
 * peak for a 76k-node / 320k-edge graph, on top of the server itself — which is what pushed a 512 MB
 * Render instance over its limit on every restart. Now only the current chunk, the header and the
 * graph being built are resident; the sha256 is computed over the same bytes as they stream past.
 *
 * Repeated strings (an edge's `source`, `serviceKey`, `routeId`) are interned: JSON.parse gives every
 * edge its own copy of them, which a freshly built graph never had (it shares one constant).
 *
 * `options.chunkBytes` exists so tests can force many tiny chunks; `options.stats`, if given, receives
 * { chunks, maxBufferedChars } so a test can prove memory stays bounded.
 */
export function loadGraphFromDisk(filePath, { chunkBytes = READ_CHUNK_BYTES, stats = null } = {}) {
  if (!existsSync(filePath)) return null;
  let fd;
  try {
    fd = openSync(filePath, "r");
    return readGraph(fd, statSync(filePath).size, chunkBytes, stats);
  } catch (e) {
    if (!(e instanceof SyntaxError)) console.warn(`[routing] graph cache unreadable: ${e.message}`);
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function readGraph(fd, size, chunkBytes, stats) {
  // The trailing "\n<sha256>\n" line is not part of the checksummed payload.
  const tailLen = Math.min(size, 200);
  const tail = Buffer.alloc(tailLen);
  readSync(fd, tail, 0, tailLen, size - tailLen);
  const tailText = tail.toString("latin1");
  const m = TRAILER.exec(tailText);
  if (!m) return null;
  const storedChecksum = m[1];
  const payloadBytes = size - (tailText.length - m.index);

  const hash = createHash("sha256");
  const decoder = new StringDecoder("utf8");
  const buf = Buffer.alloc(chunkBytes);
  const graph = new MultimodalGraph();
  const intern = new Map();
  const shared = (v) => { if (typeof v !== "string") return v; const hit = intern.get(v); if (hit) return hit; intern.set(v, v); return v; };

  let header = null;
  let mode = "header";          // header -> nodes -> edges -> done
  let text = "";
  let nodes = 0, edges = 0, chunks = 0, maxBuffered = 0;

  const NODES_MARK = ',"nodes":[';
  const EDGES_MARK = '],"edges":[';

  // Consumes as much of `text` as forms complete elements; leaves the incomplete tail in `text`.
  const drain = (final) => {
    for (;;) {
      if (mode === "header") {
        // the first marker after which the text before it is a complete header object (a warning string
        // could, in principle, contain the marker itself)
        let i = text.indexOf(NODES_MARK), found = false;
        while (i >= 0) {
          try { header = JSON.parse(`${text.slice(0, i)}}`); found = true; break; }
          catch { i = text.indexOf(NODES_MARK, i + 1); }
        }
        if (!found) return;
        text = text.slice(i + NODES_MARK.length);
        mode = "nodes";
        continue;
      }
      if (mode === "done") return;
      // an array section: [ elem , elem ... ]  — elements are flat objects
      let pos = 0;
      let progressed = false;
      for (;;) {
        if (pos >= text.length) break;
        if (text[pos] === "]" ) {   // empty section, or the end after the last element
          const marker = mode === "nodes" ? EDGES_MARK : "]}";
          if (text.length - pos < marker.length) break;   // need more bytes to tell
          if (!text.startsWith(marker, pos)) throw new SyntaxError("unexpected array end");
          text = text.slice(pos + marker.length); pos = 0;
          mode = mode === "nodes" ? "edges" : "done";
          progressed = true;
          break;
        }
        // find the end of the next element: the nearest "},{" or "}]" that leaves a parseable object
        let from = pos, item = null, endAt = -1;
        for (;;) {
          // Nearest "},{" (between elements) or "}]" (end of section). Only look for "}]" in the stretch BEFORE
          // the next "},{" — scanning to the end of the buffer for every element would be quadratic.
          const a = text.indexOf("},{", from);
          let j;
          if (a < 0) j = text.indexOf("}]", from);
          else { const local = text.slice(from, a + 1).indexOf("}]"); j = local >= 0 ? from + local : a; }
          if (j < 0) break;
          try { item = JSON.parse(text.slice(pos, j + 1)); endAt = j + 1; break; }
          catch { from = j + 1; }   // that "},{" was inside a string: extend the element
        }
        if (item === null) break;   // element not complete in the buffer yet
        if (mode === "nodes") { graph.addNode(new TransitNode(item)); nodes++; }
        else {
          item.source = shared(item.source); item.serviceKey = shared(item.serviceKey); item.routeId = shared(item.routeId); item.mode = shared(item.mode);
          graph.addEdge(new TransitEdge(item)); edges++;
        }
        pos = endAt + (text[endAt] === "," ? 1 : 0);
        progressed = true;
      }
      if (pos > 0) text = text.slice(pos);
      if (!progressed || mode === "done") return;
      if (!final && mode !== "nodes" && mode !== "edges") return;
      if (text.length === 0) return;
    }
  };

  let readBytes = 0;
  while (readBytes < payloadBytes) {
    const want = Math.min(chunkBytes, payloadBytes - readBytes);
    const n = readSync(fd, buf, 0, want, readBytes);
    if (n <= 0) return null;
    readBytes += n;
    hash.update(buf.subarray(0, n));
    text += decoder.write(buf.subarray(0, n));
    chunks++;
    if (text.length > maxBuffered) maxBuffered = text.length;
    drain(false);
  }
  text += decoder.end();
  drain(true);
  if (stats) { stats.chunks = chunks; stats.maxBufferedChars = maxBuffered; }

  if (hash.digest("hex") !== storedChecksum) {
    console.warn("[routing] graph cache checksum mismatch — ignoring cache, staying empty until a rebuild");
    return null;
  }
  if (mode !== "done" || header?.formatVersion !== FORMAT_VERSION) return null;
  if (typeof header.nodeCount !== "number" || typeof header.edgeCount !== "number") return null;
  if (nodes !== header.nodeCount || edges !== header.edgeCount) {
    console.warn("[routing] graph cache node/edge count mismatch — ignoring cache");
    return null;
  }

  graph.builtAt = header.builtAt;
  graph.dataVersion = header.dataVersion;
  graph.warnings = header.warnings ?? [];
  graph.serviceCalendar = serviceCalendarFromJSON(header.serviceCalendar);
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
