/**
 * Routing graph artifact persistence in Supabase Storage (S3-compatible), replacing the
 * old `/tmp`-as-persistent-cache design — confirmed by a real production restart test
 * that `/tmp` on Render does NOT survive a restart, so every restart forced a full
 * rebuild. This module is the ONLY place that talks to S3; index.mjs orchestrates.
 *
 * Object layout under the configured bucket:
 *   {prefix}/current.json        - pointer: { "artifactId": "build-..." }
 *   {prefix}/{artifactId}.graph  - the graph artifact itself (same self-validating
 *                                  format persist.mjs already writes: streamed,
 *                                  checksummed, version-tagged — unchanged by this file)
 *   {prefix}/{artifactId}.meta.json - small metadata blob (nodeCount/edgeCount/coverage/
 *                                  checksum/sizeBytes/generatedAt) for cheap inspection
 *                                  (list/cleanup/status) without downloading the graph.
 *
 * Every credential (SUPABASE_S3_*) comes only from process.env — never hardcoded, never
 * logged, never returned from any function here.
 */
import { createReadStream, createWriteStream, statSync, unlinkSync, existsSync } from "node:fs";
import { pipeline } from "node:stream/promises";
import { createGzip, createGunzip } from "node:zlib";
import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";
import { logMemory } from "./memlog.mjs";

const PREFIX = process.env.GRAPH_STORAGE_PREFIX || "routing-graph/production";
const CURRENT_POINTER_KEY = `${PREFIX}/current.json`;

// Supabase Storage's free plan hard-caps every object at 50MB project-wide (confirmed
// live: a real ~137MB graph artifact upload failed with "The object exceeded the
// maximum allowed size"). The uncompressed artifact is well over that; gzip is applied
// purely as an S3-transport-layer concern — persist.mjs's file format, its embedded
// checksum, and loadGraphFromDisk()'s validation are completely unaware of and
// unaffected by this, since the artifact is always fully decompressed back to the exact
// original bytes on the local disk before anything reads it.
function graphKey(artifactId) {
  return `${PREFIX}/${artifactId}.graph.gz`;
}
function metaKey(artifactId) {
  return `${PREFIX}/${artifactId}.meta.json`;
}

/** True only when every required S3 credential/config is present — callers use this to
 * decide whether Storage-backed persistence is even attempted, so a deployment without
 * these env vars set still boots (empty graph, 503 on routing) instead of throwing. */
export function storageConfigured() {
  return !!(
    process.env.SUPABASE_S3_ENDPOINT &&
    process.env.SUPABASE_S3_ACCESS_KEY_ID &&
    process.env.SUPABASE_S3_SECRET_ACCESS_KEY &&
    process.env.SUPABASE_STORAGE_BUCKET
  );
}

/** Real S3 client, built once per call from env vars only — never accepts credentials
 * as an argument, so nothing calling this can accidentally pass a hardcoded secret. */
export function createStorageClient() {
  if (!storageConfigured()) {
    throw new Error("graphStorage: SUPABASE_S3_* / SUPABASE_STORAGE_BUCKET not fully configured");
  }
  return new S3Client({
    endpoint: process.env.SUPABASE_S3_ENDPOINT,
    region: process.env.SUPABASE_S3_REGION || "us-east-1",
    credentials: {
      accessKeyId: process.env.SUPABASE_S3_ACCESS_KEY_ID,
      secretAccessKey: process.env.SUPABASE_S3_SECRET_ACCESS_KEY,
    },
    forcePathStyle: true, // required by most S3-compatible services, Supabase Storage included
  });
}

/** Uploads a local artifact FILE (already written to disk by persist.mjs's streaming
 * saveGraphToDisk) — gzips it to a second local temp file first (streaming pipeline,
 * never buffers the whole file in memory), then uploads THAT via a read stream. Also
 * uploads the small metadata JSON (safe to buffer; it's a few hundred bytes). Does NOT
 * touch the current pointer — activation is a separate, explicit step so a failed or
 * partial upload can never make a half-written artifact "current".
 *
 * Returns `size` (the RAW, uncompressed artifact size — what `meta.sizeBytes` and every
 * other caller already expects) alongside `compressedSize` (what's actually stored in
 * S3, used by verifyArtifactUploaded's HEAD check). */
export async function uploadArtifact(client, { bucket, localPath, artifactId, meta }) {
  const { size } = statSync(localPath);
  const gzPath = `${localPath}.gz`;
  logMemory("storage_upload_start", { artifactId, sizeMB: Math.round(size / 1024 / 1024) });

  try {
    await pipeline(createReadStream(localPath), createGzip(), createWriteStream(gzPath));
    const { size: compressedSize } = statSync(gzPath);
    logMemory("storage_compress_complete", { artifactId, rawSizeMB: Math.round(size / 1024 / 1024), gzSizeMB: Math.round(compressedSize / 1024 / 1024) });

    // Held as a variable (not created inline in the command) so a failed send() can
    // still reach it to destroy it — an unconsumed read stream left dangling after a
    // failed upload will throw an unhandled 'error' event and crash the process the
    // moment its underlying file disappears, which is exactly what the caller's own
    // cleanup does right after an upload failure (see buildAndPublishGraph's finally).
    const bodyStream = createReadStream(gzPath);
    bodyStream.on("error", () => {}); // defensive: never let this stream crash the process on its own
    try {
      await client.send(new PutObjectCommand({
        Bucket: bucket,
        Key: graphKey(artifactId),
        Body: bodyStream,
        ContentLength: compressedSize,
      }));
    } catch (e) {
      bodyStream.destroy();
      throw e;
    }

    const metaBody = JSON.stringify({ ...meta, artifactId, sizeBytes: size, compressedSizeBytes: compressedSize });
    await client.send(new PutObjectCommand({
      Bucket: bucket,
      Key: metaKey(artifactId),
      Body: metaBody,
      ContentType: "application/json",
    }));

    logMemory("storage_upload_complete", { artifactId, gzSizeMB: Math.round(compressedSize / 1024 / 1024) });
    return { size, compressedSize };
  } finally {
    if (existsSync(gzPath)) unlinkSync(gzPath);
  }
}

/** Cheap post-upload check — confirms the object really landed with the expected byte
 * count, without downloading the (potentially 100MB+) body back down. Catches a
 * truncated/interrupted upload; full content correctness is still verified by the
 * embedded checksum the next time the artifact is actually downloaded and loaded. */
export async function verifyArtifactUploaded(client, { bucket, artifactId, expectedSizeBytes }) {
  const head = await client.send(new HeadObjectCommand({ Bucket: bucket, Key: graphKey(artifactId) }));
  // `expectedSizeBytes` here is the COMPRESSED size (what uploadArtifact's return value
  // reports as `compressedSize`) — that's what's actually stored under this key.
  if (head.ContentLength !== expectedSizeBytes) {
    throw new Error(`graphStorage: uploaded artifact size mismatch (expected ${expectedSizeBytes}, got ${head.ContentLength})`);
  }
  return true;
}

/** Streams the (gzip-compressed) artifact body straight through a gunzip transform to a
 * local temp file — never accumulates chunks into an in-memory array/Buffer at any
 * stage, which is exactly the kind of second-giant-buffer duplication PR #2's streaming
 * persist was written to eliminate; reintroducing it here on the download side would be
 * the same mistake in a different place. `tmpPath` ends up holding the exact original
 * (decompressed) bytes persist.mjs wrote — loadGraphFromDisk() needs no changes. */
export async function downloadArtifact(client, { bucket, artifactId, tmpPath }) {
  logMemory("storage_download_start", { artifactId });
  const res = await client.send(new GetObjectCommand({ Bucket: bucket, Key: graphKey(artifactId) }));
  await pipeline(res.Body, createGunzip(), createWriteStream(tmpPath));
  logMemory("storage_download_complete", { artifactId });
}

/** Returns the current pointer's artifactId, or null if there isn't one yet (first-ever
 * deploy with Storage configured but no rebuild has run against it). The pointer body
 * is a few bytes — safe to read into memory directly, unlike the graph artifact. */
export async function getCurrentArtifactId(client, { bucket }) {
  try {
    const res = await client.send(new GetObjectCommand({ Bucket: bucket, Key: CURRENT_POINTER_KEY }));
    const text = await streamToStringSmall(res.Body);
    return JSON.parse(text).artifactId ?? null;
  } catch (e) {
    if (isNotFound(e)) return null;
    throw e;
  }
}

/** Activation: the ONLY step that makes a newly-uploaded, already-verified artifact
 * "current". Never called until upload + verifyArtifactUploaded have both succeeded —
 * a failure anywhere before this point leaves the previous pointer (and therefore the
 * previously-active graph) completely untouched. */
export async function setCurrentArtifactId(client, { bucket, artifactId }) {
  await client.send(new PutObjectCommand({
    Bucket: bucket,
    Key: CURRENT_POINTER_KEY,
    Body: JSON.stringify({ artifactId }),
    ContentType: "application/json",
  }));
}

/** Lists every artifactId currently in the prefix, oldest-first (artifactIds are
 * sortable timestamps — see index.mjs's id generator), for the retention/cleanup step. */
export async function listArtifactIds(client, { bucket }) {
  const ids = new Set();
  let continuationToken;
  do {
    const res = await client.send(new ListObjectsV2Command({
      Bucket: bucket,
      Prefix: `${PREFIX}/`,
      ContinuationToken: continuationToken,
    }));
    for (const obj of res.Contents ?? []) {
      const m = obj.Key.match(/\/([^/]+)\.graph$/);
      if (m) ids.add(m[1]);
    }
    continuationToken = res.IsTruncated ? res.NextContinuationToken : undefined;
  } while (continuationToken);
  return [...ids].sort();
}

/** Deletes one artifact's .graph and .meta.json. Best-effort cleanup only — callers
 * must not let a delete failure fail the rebuild that triggered it (the new artifact is
 * already active by the time cleanup runs; an old, no-longer-current artifact lingering
 * an extra cycle costs storage, not correctness). */
export async function deleteArtifact(client, { bucket, artifactId }) {
  await Promise.all([
    client.send(new DeleteObjectCommand({ Bucket: bucket, Key: graphKey(artifactId) })).catch(() => {}),
    client.send(new DeleteObjectCommand({ Bucket: bucket, Key: metaKey(artifactId) })).catch(() => {}),
  ]);
}

function isNotFound(e) {
  return e?.name === "NoSuchKey" || e?.$metadata?.httpStatusCode === 404;
}

/** Only for the tiny pointer/metadata JSON objects (bytes, not the graph itself) —
 * never call this on a GetObjectCommand result for the .graph key. */
async function streamToStringSmall(body) {
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

export function localTmpPath(name) {
  return `/tmp/${name}`;
}

export { unlinkSync as unlinkLocal, existsSync as localExists };
