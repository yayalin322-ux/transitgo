import { writeFileSync, unlinkSync, existsSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { FakeS3Client } from "./fakeS3.mjs";
import { uploadArtifact, verifyArtifactUploaded } from "../src/graph/graphStorage.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const bucket = "test-bucket";
const localPath = "/tmp/transitgo_storage_upload_test.artifact";
const content = "x".repeat(500_000); // not tiny, but small enough to keep the test fast
writeFileSync(localPath, content);

const client = new FakeS3Client();

const { size, compressedSize } = await uploadArtifact(client, {
  bucket,
  localPath,
  artifactId: "build-test-1",
  meta: { version: 1, nodeCount: 10, edgeCount: 20, coverage: {}, checksum: "abc123" },
});
check("uploadArtifact reports the real raw file size", size === content.length);
check("uploadArtifact reports a real (smaller) compressed size for this highly-repetitive content", compressedSize > 0 && compressedSize < content.length);
check("Graph object was written to the fake bucket (as .graph.gz)", client.objects.has("routing-graph/production/build-test-1.graph.gz"));
check("Meta object was written to the fake bucket", client.objects.has("routing-graph/production/build-test-1.meta.json"));

const storedBytes = client.objects.get("routing-graph/production/build-test-1.graph.gz");
check("Stored object is really gzip-compressed (magic bytes 0x1f 0x8b)", storedBytes[0] === 0x1f && storedBytes[1] === 0x8b);
const uploadedGraph = gunzipSync(storedBytes).toString("utf8");
check("Decompressed uploaded graph content matches the local file exactly", uploadedGraph === content);

const uploadedMeta = JSON.parse(client.objects.get("routing-graph/production/build-test-1.meta.json").toString("utf8"));
check("Uploaded metadata carries the real node/edge counts", uploadedMeta.nodeCount === 10 && uploadedMeta.edgeCount === 20);
check("Uploaded metadata carries the artifactId", uploadedMeta.artifactId === "build-test-1");
check("Uploaded metadata carries the real raw sizeBytes", uploadedMeta.sizeBytes === content.length);
check("Uploaded metadata carries the real compressed size", uploadedMeta.compressedSizeBytes === compressedSize);

// verifyArtifactUploaded checks against the COMPRESSED size (what's actually stored)
const ok = await verifyArtifactUploaded(client, { bucket, artifactId: "build-test-1", expectedSizeBytes: compressedSize });
check("verifyArtifactUploaded succeeds when compressed size matches", ok === true);

let threw = false;
try {
  await verifyArtifactUploaded(client, { bucket, artifactId: "build-test-1", expectedSizeBytes: compressedSize + 1 });
} catch {
  threw = true;
}
check("verifyArtifactUploaded rejects a size mismatch (truncated-upload detection)", threw === true);

// Upload failure must not corrupt anything already in the bucket (e.g. a prior artifact)
client.failNextPut = new Error("simulated network failure during upload");
let uploadThrew = false;
try {
  await uploadArtifact(client, {
    bucket,
    localPath,
    artifactId: "build-test-2",
    meta: { version: 1, nodeCount: 1, edgeCount: 1, coverage: {}, checksum: "x" },
  });
} catch {
  uploadThrew = true;
}
check("A simulated upload failure propagates as a real rejection", uploadThrew === true);
check("The previously-uploaded artifact (build-test-1) is untouched by the failed second upload", client.objects.has("routing-graph/production/build-test-1.graph.gz"));
check("The failed upload did not leave a partial object behind", !client.objects.has("routing-graph/production/build-test-2.graph.gz"));

if (existsSync(localPath)) unlinkSync(localPath);

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
