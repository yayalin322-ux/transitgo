/**
 * Orchestrates the full "build -> local temp artifact -> Supabase Storage -> activate"
 * and "boot -> download -> validate -> load" flows. graphStorage.mjs only knows how to
 * talk to S3; builder.mjs/persist.mjs only know how to build/serialize a graph. This is
 * the layer that wires them together the way index.mjs needs — kept separate from
 * index.mjs so it can be unit-tested with a mocked storage client and an in-memory db,
 * without needing a real Express server or real S3 credentials.
 */
import { randomUUID } from "node:crypto";
import { unlinkSync, existsSync, statSync } from "node:fs";
import { buildGraph } from "./builder.mjs";
import { saveGraphToDisk, loadGraphFromDisk } from "./persist.mjs";
import {
  storageConfigured,
  createStorageClient,
  uploadArtifact,
  verifyArtifactUploaded,
  downloadArtifact,
  getCurrentArtifactId,
  setCurrentArtifactId,
  listArtifactIds,
  deleteArtifact,
} from "./graphStorage.mjs";

/** How many recent artifacts to keep in Storage after a successful publish — a rollback
 * safety margin, not just the newest one, per the "at least 2-3 versions" requirement. */
const RETAIN_VERSIONS = 3;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Sortable-by-string, unique per build — lexical sort order matches build order, which
 * is what listArtifactIds()'s retention logic relies on. */
export function generateArtifactId() {
  const ts = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  return `build-${ts}-${randomUUID().slice(0, 8)}`;
}

/**
 * Build -> local temp artifact -> upload -> verify -> activate -> cleanup.
 *
 * Nothing before "activate" (setCurrentArtifactId) can affect what's currently live:
 * the previous `current` pointer, and therefore whatever graph a running server has
 * already loaded, is untouched by a build, an upload, or a verify failure. Only after
 * activation succeeds does the caller (index.mjs) swap its own in-memory `routingGraph`
 * reference — this function itself never touches that; it just returns the built graph.
 */
export async function buildAndPublishGraph(db, { onProgress = null, bucket = process.env.SUPABASE_STORAGE_BUCKET, client: injectedClient = null } = {}) {
  // `client` is injectable so tests can pass a fake S3 transport — production code
  // never passes it and always gets a real client built from env-only credentials.
  if (!injectedClient && !storageConfigured()) {
    throw new Error("graphPersistence: Supabase Storage is not configured (need SUPABASE_S3_ENDPOINT/SUPABASE_S3_ACCESS_KEY_ID/SUPABASE_S3_SECRET_ACCESS_KEY/SUPABASE_STORAGE_BUCKET) — cannot publish a rebuilt graph");
  }
  const client = injectedClient ?? createStorageClient();
  const artifactId = generateArtifactId();
  const tmpPath = `/tmp/transitgo_graph_build_${artifactId}.artifact`;

  try {
    const graph = await buildGraph(db, { onProgress });

    onProgress?.({ phase: "local_persist_start" });
    const localMeta = await saveGraphToDisk(graph, tmpPath);
    onProgress?.({ phase: "local_persist_complete", nodeCount: localMeta.nodeCount, edgeCount: localMeta.edgeCount });

    onProgress?.({ phase: "storage_upload_start" });
    const { compressedSize } = await uploadArtifact(client, {
      bucket,
      localPath: tmpPath,
      artifactId,
      meta: {
        version: 1,
        artifact: "routing-graph",
        environment: process.env.NODE_ENV || "production",
        generatedAt: graph.builtAt,
        nodeCount: localMeta.nodeCount,
        edgeCount: localMeta.edgeCount,
        coverage: localMeta.coverage,
        checksum: localMeta.checksum,
      },
    });
    onProgress?.({ phase: "storage_upload_complete" });

    // What's actually stored under the S3 key is the gzip-compressed artifact — verify
    // against that, not the raw local file's size.
    await verifyArtifactUploaded(client, { bucket, artifactId, expectedSizeBytes: compressedSize });
    onProgress?.({ phase: "storage_upload_verified" });

    await setCurrentArtifactId(client, { bucket, artifactId });
    onProgress?.({ phase: "storage_activated", artifactId });

    cleanupOldArtifacts(client, bucket, artifactId).catch((e) => {
      console.warn(`[routing] artifact cleanup failed (non-fatal, new artifact is already active): ${e.message}`);
    });

    return { graph, artifactId, nodeCount: localMeta.nodeCount, edgeCount: localMeta.edgeCount };
  } finally {
    if (existsSync(tmpPath)) unlinkSync(tmpPath);
  }
}

/** Best-effort retention — deletes everything except the newest RETAIN_VERSIONS
 * artifacts (the one just activated is always kept, by construction: it's the newest).
 * Runs after activation, so a failure here can never affect what's currently live. */
async function cleanupOldArtifacts(client, bucket, justActivatedId) {
  const ids = await listArtifactIds(client, { bucket });
  const toDelete = ids.slice(0, Math.max(0, ids.length - RETAIN_VERSIONS)).filter((id) => id !== justActivatedId);
  for (const id of toDelete) {
    await deleteArtifact(client, { bucket, artifactId: id });
  }
}

/**
 * Boot-time (or on-demand) recovery: current pointer -> download -> validate -> load.
 * Bounded retries (default 3, short backoff) — never infinite, never blocks the caller
 * beyond that bound. Returns `{ graph, artifactId }` on success, or `null` on ANY
 * failure (not configured, no pointer yet, network failure after all retries, corrupt/
 * truncated artifact) rather than throwing — callers must treat null as "graph
 * unavailable, not a crash."
 */
export async function downloadAndLoadGraph({ bucket = process.env.SUPABASE_STORAGE_BUCKET, maxAttempts = 3, backoffMs = 1000, client: injectedClient = null } = {}) {
  if (!injectedClient && !storageConfigured()) {
    console.log("[routing] Supabase Storage not configured — graph stays empty until a rebuild is triggered");
    return null;
  }

  let client = injectedClient;
  if (!client) {
    try {
      client = createStorageClient();
    } catch (e) {
      console.warn(`[routing] graph storage client init failed: ${e.message}`);
      return null;
    }
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const artifactId = await getCurrentArtifactId(client, { bucket }).catch((e) => {
      console.warn(`[routing] failed to read current-artifact pointer (attempt ${attempt}/${maxAttempts}): ${e.message}`);
      return undefined; // distinct from null ("no pointer yet") — undefined means the read itself failed
    });
    if (artifactId === null) {
      console.log("[routing] no current graph artifact in Storage yet — graph stays empty until a rebuild is triggered");
      return null;
    }
    if (artifactId !== undefined) {
      const tmpPath = `/tmp/transitgo_graph_boot_${artifactId}.artifact`;
      try {
        await downloadArtifact(client, { bucket, artifactId, tmpPath });
        const graph = loadGraphFromDisk(tmpPath); // same embedded-checksum/version/count validation as before
        if (!graph) {
          console.warn(`[routing] downloaded artifact ${artifactId} failed local validation (checksum/format/counts) — treating as unavailable`);
          return null;
        }
        console.log(`[routing] graph loaded from Supabase Storage: ${graph.nodeCount} nodes, ${graph.edgeCount} edges (artifact ${artifactId})`);
        return { graph, artifactId };
      } catch (e) {
        console.warn(`[routing] graph download attempt ${attempt}/${maxAttempts} failed: ${e.message}`);
      } finally {
        if (existsSync(tmpPath)) unlinkSync(tmpPath);
      }
    }
    if (attempt < maxAttempts) await sleep(attempt * backoffMs); // linear backoff
  }
  console.warn("[routing] all graph download attempts failed — graph stays empty until a rebuild is triggered");
  return null;
}
