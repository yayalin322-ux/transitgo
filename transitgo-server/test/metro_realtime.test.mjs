import { createMetroRealtime } from "../src/routing/metroRealtime.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// TDX's own "nothing wrong" entry (real response shape captured 2026-09-19) is not an alert
{
  const rt = createMetroRealtime({ fetchAlerts: async () => ({ Alerts: [{ AlertID: "0", Title: "正常營運", Description: "正常營運", Status: 1 }] }) });
  const s = await rt.metroStatus("TRTC");
  check("normal-operation entry (Status 1) is not reported as an alert", s && s.alerts.length === 0);
}
{
  const rt = createMetroRealtime({ fetchAlerts: async () => ({ Alerts: [{ Title: "文湖線列車延誤", Description: "訊號異常", Status: 2, UpdateTime: "2026-09-19T12:00:00+08:00" }] }) });
  const s = await rt.metroStatus("TRTC");
  check("a real notice is passed through verbatim", s.alerts.length === 1 && s.alerts[0].title === "文湖線列車延誤" && s.alerts[0].description === "訊號異常");
}
// caching: TDX's quota is ~5/min
{
  let calls = 0, t = 0;
  const rt = createMetroRealtime({ fetchAlerts: async () => { calls++; return { Alerts: [] }; }, ttlMs: 60_000, now: () => t });
  await rt.metroStatus("TRTC"); await rt.metroStatus("TRTC");
  check("a second lookup inside the TTL is served from cache (one TDX call)", calls === 1);
  t = 61_000; await rt.metroStatus("TRTC");
  check("after the TTL a fresh TDX call is made", calls === 2);
  await rt.metroStatus("KRTC");
  check("operators are cached independently", calls === 3);
}
// failure handling
{
  let calls = 0, t = 0;
  const rt = createMetroRealtime({ fetchAlerts: async () => { calls++; throw new Error("TDX 429"); }, failureTtlMs: 30_000, now: () => t });
  check("TDX error -> null (unavailable), never a throw", (await rt.metroStatus("TRTC")) === null);
  await rt.metroStatus("TRTC");
  check("a failure is negative-cached so a rate-limited operator is not hammered", calls === 1);
  t = 31_000; await rt.metroStatus("TRTC");
  check("the failure is retried after its (shorter) TTL", calls === 2);
}
{
  const rt = createMetroRealtime({ fetchAlerts: () => new Promise(() => {}), timeoutMs: 30 });
  const started = Date.now();
  const s = await rt.metroStatus("TRTC");
  check("a hung TDX call times out to null instead of hanging the route request", s === null && Date.now() - started < 1000);
}
{
  const rt = createMetroRealtime({ fetchAlerts: async () => ({}) });
  const s = await rt.metroStatus("TRTC");
  check("an empty/odd response body is treated as 'no alerts', not a crash", s && s.alerts.length === 0);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
