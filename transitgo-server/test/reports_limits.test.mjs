import { clampReport, REPORT_LIMITS } from "../src/reports.mjs";
let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

check("no type → rejected", clampReport({ message: "x" }) === null && clampReport({ type: "  " }) === null && clampReport({ type: 5 }) === null);
const r = clampReport({ type: "feedback", message: "路線 307 到站時間不準", appVersion: "0.1.0", os: "iOS 26.5", device: "ABC" });
check("a normal report passes through unchanged", r.type === "feedback" && r.message === "路線 307 到站時間不準" && r.appVersion === "0.1.0" && r.device === "ABC" && r.context === null);
check("an oversized message is cut, not rejected", clampReport({ type: "feedback", message: "a".repeat(50_000) }).message.length === REPORT_LIMITS.message);
check("an oversized type is cut", clampReport({ type: "t".repeat(500) }).type.length === REPORT_LIMITS.type);
check("small context is kept, huge context is replaced by a marker", JSON.stringify(clampReport({ type: "x", context: { a: 1 } }).context) === '{"a":1}' && clampReport({ type: "x", context: { a: "z".repeat(10_000) } }).context.truncated === true);
check("non-string message/os become safe empties", clampReport({ type: "x", message: { evil: 1 }, os: 7 }).message === "" && clampReport({ type: "x", os: 7 }).os === null);
process.exit(failed ? 1 : 0);
