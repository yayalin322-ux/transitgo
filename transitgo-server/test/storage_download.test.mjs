import { unlinkSync, existsSync, readFileSync } from "node:fs";
import { FakeS3Client } from "./fakeS3.mjs";
import { downloadArtifact, getCurrentArtifactId, setCurrentArtifactId } from "../src/graph/graphStorage.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const bucket = "test-bucket";
const client = new FakeS3Client();
const content = "graph-artifact-content-".repeat(20_000); // a few hundred KB, enough to exercise real streaming
client.objects.set("routing-graph/production/build-dl-1.graph", Buffer.from(content));

const tmpPath = "/tmp/transitgo_storage_download_test.artifact";
if (existsSync(tmpPath)) unlinkSync(tmpPath);

await downloadArtifact(client, { bucket, artifactId: "build-dl-1", tmpPath });
check("Downloaded file exists on disk", existsSync(tmpPath));
check("Downloaded file content matches exactly what was in the bucket", readFileSync(tmpPath, "utf8") === content);

// current pointer round trip
check("getCurrentArtifactId returns null when no pointer has ever been set", (await getCurrentArtifactId(client, { bucket })) === null);
await setCurrentArtifactId(client, { bucket, artifactId: "build-dl-1" });
check("getCurrentArtifactId returns the artifactId after setCurrentArtifactId", (await getCurrentArtifactId(client, { bucket })) === "build-dl-1");

// download of a nonexistent artifact must reject, not hang or silently write an empty file
let threw = false;
const missingTmp = "/tmp/transitgo_storage_download_missing.artifact";
try {
  await downloadArtifact(client, { bucket, artifactId: "build-does-not-exist", tmpPath: missingTmp });
} catch {
  threw = true;
}
check("Downloading a nonexistent artifact rejects (NoSuchKey)", threw === true);

if (existsSync(tmpPath)) unlinkSync(tmpPath);
if (existsSync(missingTmp)) unlinkSync(missingTmp);

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
