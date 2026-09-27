// "安全分享" (opt-in safety live-location). Off by default on every share; only when the sharer
// explicitly turns it on for a given link does the app start pushing real coordinates, and only
// that one link's row ever holds them — every other share still stores none at all.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "live-loc-share-")), "t.db");
delete process.env.DATABASE_URL;
const { sanitizeLiveLocation } = await import("../src/shares.mjs");
const { createShare, getShare, updateShareLocation } = await import("../src/db.mjs");

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

// ---- sanitizeLiveLocation ----
check("a real coordinate is accepted", JSON.stringify(sanitizeLiveLocation({ lat: 25.0478, lon: 121.517 })) === JSON.stringify({ lat: 25.0478, lon: 121.517 }));
check("garbage input is rejected, not thrown", sanitizeLiveLocation(null) === null && sanitizeLiveLocation("x") === null);
check("out-of-range latitude is rejected", sanitizeLiveLocation({ lat: 91, lon: 0 }) === null && sanitizeLiveLocation({ lat: -91, lon: 0 }) === null);
check("out-of-range longitude is rejected", sanitizeLiveLocation({ lat: 0, lon: 181 }) === null && sanitizeLiveLocation({ lat: 0, lon: -181 }) === null);
check("non-numeric coordinates are rejected, not coerced", sanitizeLiveLocation({ lat: "north", lon: 121 }) === null);
check("extra fields (e.g. deviceId) are simply not in the sanitized output", !("deviceId" in sanitizeLiveLocation({ lat: 1, lon: 1, deviceId: "ABC" })));

// ---- end to end against the DB layer ----
const now = Date.now();

// A trip share that opted in.
await createShare({
  token: "trip-share-live-loc-token-AA", title: "去新竹", kind: "trip", segments: [],
  liveLocationEnabled: true, nowMs: now, expiresAtMs: now + 3_600_000,
});
{
  const row = await getShare("trip-share-live-loc-token-AA");
  check("an opted-in trip share reports liveLocationEnabled and starts with no coordinate yet", row.liveLocationEnabled === true && row.liveLat === null && row.liveLon === null);
  const ok = await updateShareLocation("trip-share-live-loc-token-AA", { lat: 24.8, lon: 121.0 }, now + 1000);
  check("pushing a location to an opted-in trip share succeeds", ok === true);
  const row2 = await getShare("trip-share-live-loc-token-AA");
  check("...and is readable back exactly", row2.liveLat === 24.8 && row2.liveLon === 121.0 && row2.liveLocationAtMs === now + 1000);
}

// A nav share that opted in — the feature applies to both kinds, not just trip shares.
await createShare({
  token: "nav-share-live-loc-token-BB", title: "前往台北車站", kind: "nav",
  nav: { mode: "walking", destinationName: "台北車站" }, liveLocationEnabled: true, nowMs: now, expiresAtMs: now + 3_600_000,
});
{
  const ok = await updateShareLocation("nav-share-live-loc-token-BB", { lat: 25.0, lon: 121.5 }, now + 500);
  check("pushing a location to an opted-in nav share succeeds too", ok === true);
}

// A share that did NOT opt in — the default, and the far more common case.
await createShare({ token: "trip-share-no-live-loc-CC", title: "去台中", kind: "trip", segments: [], nowMs: now, expiresAtMs: now + 3_600_000 });
{
  const row = await getShare("trip-share-no-live-loc-CC");
  check("a share that never opted in reports liveLocationEnabled: false", row.liveLocationEnabled === false);
  const ok = await updateShareLocation("trip-share-no-live-loc-CC", { lat: 1, lon: 1 }, now);
  check("pushing a location to a share that never opted in is refused (can't be turned on after the fact via this endpoint)", ok === false);
  const row2 = await getShare("trip-share-no-live-loc-CC");
  check("...and no coordinate was written", row2.liveLat === null && row2.liveLon === null);
}

check("pushing a location to a token that doesn't exist is refused, not a crash", (await updateShareLocation("does-not-exist-at-all-live-loc", { lat: 1, lon: 1 }, now)) === false);

await createShare({
  token: "expired-live-loc-share-DD", title: "x", kind: "trip", segments: [],
  liveLocationEnabled: true, nowMs: now - 10_000, expiresAtMs: now - 1000,
});
{
  const ok = await updateShareLocation("expired-live-loc-share-DD", { lat: 1, lon: 1 }, now);
  check("pushing a location to an already-expired opted-in share is refused", ok === false);
}

process.exit(failed ? 1 : 0);
