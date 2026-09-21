import { createHash } from "node:crypto";
import cron from "node-cron";
import { tdxConfigured, traAlerts, thsrAlerts } from "./tdx.mjs";
import {
  createAnnouncement,
  getAlertState,
  setAlertState,
} from "./appdata.mjs";
import { pushAnnouncement } from "./push.mjs";

const sig = (items) =>
  createHash("sha1")
    .update(items.map((i) => `${i.title}|${i.description}`).join("\n"))
    .digest("hex");

async function checkSource({ source, category, label, fetcher }) {
  let result;
  try {
    result = await fetcher();
  } catch (e) {
    console.warn(`[alerts] ${source} fetch failed:`, e.message);
    return;
  }
  const prev = await getAlertState(source);
  const signature = sig(result.items);
  if (prev && prev.signature === signature) return; // nothing changed

  const wasAbnormal = !!(prev && prev.abnormal);
  await setAlertState(source, signature, result.abnormal);

  if (result.abnormal) {
    const first = result.items.find(
      (i) => i.title && !/正常|normal/i.test(i.title)
    );
    const ann = await createAnnouncement({
      category,
      severity: "warning",
      title: `${label}營運異常`,
      body: [first?.title, first?.description].filter(Boolean).join("　").slice(0, 500),
      source,
    });
    console.log(`[alerts] ${source}: abnormal → announcement #${ann.id}`);
    await pushAnnouncement(ann);
  } else if (wasAbnormal && process.env.ANNOUNCE_RECOVERY !== "false") {
    const ann = await createAnnouncement({
      category,
      severity: "info",
      title: `${label}已恢復正常`,
      body: "",
      source,
      expiresAt: new Date(Date.now() + 3 * 3600_000).toISOString().replace("T", " ").slice(0, 19),
    });
    console.log(`[alerts] ${source}: recovered → announcement #${ann.id}`);
    await pushAnnouncement(ann);
  }
}

export function startAlertPoller() {
  if (!tdxConfigured()) {
    console.log("[alerts] TDX not configured — auto台鐵/高鐵公告停用");
    return;
  }
  const minutes = Math.max(1, parseInt(process.env.ALERT_POLL_MINUTES || "3", 10));
  let running = false;
  const run = async () => {
    if (running) return;
    running = true;
    try { await runOnce(); } finally { running = false; }
  };
  const runOnce = async () => {
    await checkSource({ source: "tra", category: "rail", label: "台鐵", fetcher: traAlerts });
    await checkSource({ source: "thsr", category: "rail", label: "高鐵", fetcher: thsrAlerts });
  };
  run();
  cron.schedule(`*/${minutes} * * * *`, run);
  console.log(`[alerts] polling TRA/THSR every ${minutes} min`);
}
