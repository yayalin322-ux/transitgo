import { writeFileSync, readFileSync, existsSync, renameSync } from "node:fs";
import { MultimodalGraph, TransitNode, TransitEdge } from "./model.mjs";

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
const FORMAT_VERSION = 1;

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

export function saveGraphToDisk(graph, filePath) {
  const payload = {
    formatVersion: FORMAT_VERSION,
    builtAt: graph.builtAt,
    dataVersion: graph.dataVersion,
    warnings: graph.warnings ?? [],
    nodes: [...graph.nodes.values()],
    // Flattened, not the Map<fromId, Edge[]> shape — addEdge() rebuilds that index on
    // load, same as it does during a normal build; storing it pre-indexed would just be
    // a second copy of the same pointers for no benefit.
    edges: [...graph.edgesByFrom.values()].flat(),
    serviceCalendar: serviceCalendarToJSON(graph.serviceCalendar),
  };
  // Write to a temp path then rename — an atomic swap so a process that crashes mid-write
  // (the exact failure mode this cache exists to survive) can never leave a half-written,
  // unparseable cache file behind for the next boot to trip over.
  const tmpPath = `${filePath}.tmp`;
  writeFileSync(tmpPath, JSON.stringify(payload));
  renameSync(tmpPath, filePath);
}

/** Returns null (never throws) on anything from "file doesn't exist" to "corrupt JSON"
 * to "written by an older, incompatible format version" — every one of those just means
 * "fall back to a real rebuild", not a boot failure. */
export function loadGraphFromDisk(filePath) {
  if (!existsSync(filePath)) return null;
  let payload;
  try {
    payload = JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
  if (payload?.formatVersion !== FORMAT_VERSION) return null;

  const graph = new MultimodalGraph();
  graph.builtAt = payload.builtAt;
  graph.dataVersion = payload.dataVersion;
  graph.warnings = payload.warnings ?? [];
  graph.serviceCalendar = serviceCalendarFromJSON(payload.serviceCalendar);
  for (const n of payload.nodes ?? []) graph.addNode(new TransitNode(n));
  for (const e of payload.edges ?? []) graph.addEdge(new TransitEdge(e));
  return graph;
}
