import { buildStatus, allowedOrigin } from "../src/status.mjs";
let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const s = buildStatus({ now: new Date("2026-09-26T00:00:00Z"), uptimeSeconds: 3600.4, routingLoaded: true });
check("reports ok, routing ready, rounded uptime", s.ok === true && s.routing === "ready" && s.uptimeSeconds === 3600 && s.time === "2026-09-26T00:00:00.000Z");
check("routing not loaded yet is 'loading', never claimed ready", buildStatus({ routingLoaded: false }).routing === "loading");
check("exposes nothing beyond those four fields (no memory / commit / db)", JSON.stringify(Object.keys(s).sort()) === JSON.stringify(["ok", "routing", "time", "uptimeSeconds"]));
check("negative uptime is clamped", buildStatus({ uptimeSeconds: -5 }).uptimeSeconds === 0);
check("only our own website origins may read it from a browser", allowedOrigin("https://yayalin.com") === "https://yayalin.com" && allowedOrigin("https://www.yayalin.com") === "https://www.yayalin.com");
check("any other origin (or none) gets no CORS header", allowedOrigin("https://evil.example") === null && allowedOrigin("http://yayalin.com") === null && allowedOrigin(undefined) === null && allowedOrigin("https://yayalin.com.evil.example") === null);
process.exit(failed ? 1 : 0);
