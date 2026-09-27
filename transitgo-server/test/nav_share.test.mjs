// Sharing an in-app navigation trip (open/walk) — no TDX segment to poll, the sharer's own app
// pushes coarse progress (remaining distance/time), never a coordinate.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "nav-share-")), "t.db");
delete process.env.DATABASE_URL;
const { sanitizeNav, sanitizeNavProgress, NAV_MODES } = await import("../src/shares.mjs");
const { createShare, getShare, updateShareProgress } = await import("../src/db.mjs");

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

// ---- sanitizeNav ----
check("a real nav request is accepted", JSON.stringify(sanitizeNav({ mode: "automobile", destinationName: "台北車站" })) === JSON.stringify({ mode: "automobile", destinationName: "台北車站" }));
check("every declared mode is accepted", NAV_MODES.every((m) => sanitizeNav({ mode: m, destinationName: "x" }) !== null));
check("an unknown mode is rejected (never silently coerced)", sanitizeNav({ mode: "teleport", destinationName: "x" }) === null);
check("no destination name is rejected", sanitizeNav({ mode: "walking", destinationName: "" }) === null);
check("garbage input is rejected, not thrown", sanitizeNav(null) === null && sanitizeNav("x") === null);
check("a coordinate slipped into the body is simply not in the sanitized output", !("lat" in (sanitizeNav({ mode: "walking", destinationName: "x", lat: 24.8, lon: 121 }) ?? {})));

// ---- sanitizeNavProgress ----
{
  const p = sanitizeNavProgress({ remainingMeters: 1234.6, etaSeconds: 600.4, instruction: "前方右轉" });
  check("a real progress update rounds distance/time and keeps the instruction", p.remainingMeters === 1235 && p.etaSeconds === 600 && p.instruction === "前方右轉");
  check("no coordinate field ever survives even if the client sent one", !("lat" in p) && !("coordinate" in p));
}
check("negative remaining distance is rejected", sanitizeNavProgress({ remainingMeters: -1, etaSeconds: 0 }) === null);
check("a non-numeric eta is rejected, not coerced to 0", sanitizeNavProgress({ remainingMeters: 10, etaSeconds: "soon" }) === null);
check("an absurd distance is clamped, not stored raw", sanitizeNavProgress({ remainingMeters: 99_999_999, etaSeconds: 60 }).remainingMeters === 2_000_000);
check("arrived defaults to false and only becomes true from an explicit true", sanitizeNavProgress({ remainingMeters: 0, etaSeconds: 0 }).arrived === false && sanitizeNavProgress({ remainingMeters: 0, etaSeconds: 0, arrived: true }).arrived === true);

// ---- end to end against the DB layer ----
const now = Date.now();
await createShare({
  token: "nav-share-test-token-AA", title: "前往台北車站", kind: "nav",
  nav: { mode: "automobile", destinationName: "台北車站" }, nowMs: now, expiresAtMs: now + 3_600_000,
});
{
  const row = await getShare("nav-share-test-token-AA");
  check("a fresh nav share has no progress yet", row.kind === "nav" && row.nav.destinationName === "台北車站" && row.navProgress === null);
  check("segments is an empty array, never null, for a nav share (share.html/clients never have to null-check it)", Array.isArray(row.segments) && row.segments.length === 0);
}
{
  const ok = await updateShareProgress("nav-share-test-token-AA", { remainingMeters: 5000, etaSeconds: 420, instruction: "沿中山路直行", arrived: false }, now + 1000);
  check("pushing progress to a real nav share succeeds", ok === true);
  const row = await getShare("nav-share-test-token-AA");
  check("...and is readable back exactly", row.navProgress.remainingMeters === 5000 && row.navProgress.instruction === "沿中山路直行");
}
{
  await createShare({ token: "trip-share-test-token-BB", title: "前往新竹", kind: "trip", segments: [], nowMs: now, expiresAtMs: now + 3_600_000 });
  const ok = await updateShareProgress("trip-share-test-token-BB", { remainingMeters: 1, etaSeconds: 1 }, now);
  check("pushing 'progress' to an ordinary trip share (not nav) is refused", ok === false);
}
check("pushing progress to a token that doesn't exist is refused, not a crash", (await updateShareProgress("does-not-exist-at-all-XX", { remainingMeters: 1, etaSeconds: 1 }, now)) === false);
{
  await createShare({ token: "expired-nav-share-test-CC", title: "x", kind: "nav", nav: { mode: "walking", destinationName: "y" }, nowMs: now - 10_000, expiresAtMs: now - 1000 });
  const ok = await updateShareProgress("expired-nav-share-test-CC", { remainingMeters: 1, etaSeconds: 1 }, now);
  check("pushing progress to an already-expired nav share is refused", ok === false);
}

process.exit(failed ? 1 : 0);
