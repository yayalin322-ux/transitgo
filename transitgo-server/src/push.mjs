import { readFileSync } from "node:fs";
import { allDeviceTokens, removeDevice } from "./appdata.mjs";

let provider = null;
let dryRun = true;

try {
  const { ApnsClient, Notification } = await import("apns2");
  const {
    APNS_KEY_PATH,
    APNS_KEY_CONTENT,
    APNS_KEY_ID,
    APNS_TEAM_ID,
    APNS_BUNDLE_ID,
    APNS_PRODUCTION,
  } = process.env;

  // Render (and other host-without-persistent-disk platforms) can't hold a .p8 file —
  // APNS_KEY_CONTENT (the .p8's PEM text, set as a normal env var) works there instead.
  const signingKey = APNS_KEY_CONTENT || (APNS_KEY_PATH ? readFileSync(APNS_KEY_PATH, "utf8") : null);

  if (signingKey && APNS_KEY_ID && APNS_TEAM_ID && APNS_BUNDLE_ID) {
    const client = new ApnsClient({
      team: APNS_TEAM_ID,
      keyId: APNS_KEY_ID,
      signingKey,
      defaultTopic: APNS_BUNDLE_ID,
      host: APNS_PRODUCTION === "true" ? "api.push.apple.com" : "api.sandbox.push.apple.com",
    });
    provider = { client, Notification, bundleId: APNS_BUNDLE_ID };
    dryRun = false;
    console.log("[push] APNs configured (%s)", APNS_PRODUCTION === "true" ? "production" : "sandbox");
  } else {
    console.log("[push] APNs not configured — DRY RUN (notifications logged only)");
  }
} catch (e) {
  console.log("[push] apns2 unavailable — DRY RUN:", e.message);
}

/**
 * Push an announcement to every registered device.
 * @param {{id:number, category:string, severity:string, title:string, body:string}} ann
 */
export async function pushAnnouncement(ann) {
  const tokens = await allDeviceTokens();
  const payload = {
    title: ann.title,
    body: ann.body || " ",
    data: { type: "announcement", id: ann.id, category: ann.category, severity: ann.severity },
  };

  if (dryRun || !provider) {
    console.log(
      "[push:dry] → %d devices | %s | %s / %s",
      tokens.length, ann.category, ann.title, ann.body
    );
    return { sent: 0, dryRun: true, devices: tokens.length };
  }

  let sent = 0;
  for (const token of tokens) {
    const note = new provider.Notification(token, {
      alert: { title: payload.title, body: payload.body },
      sound: "default",
      topic: provider.bundleId,
      data: payload.data,
    });
    try {
      await provider.client.send(note);
      sent++;
    } catch (err) {
      const reason = err?.reason || err?.body?.reason;
      if (reason === "BadDeviceToken" || reason === "Unregistered") {
        await removeDevice(token);
      } else {
        console.warn("[push] send failed:", reason || err.message);
      }
    }
  }
  return { sent, dryRun: false, devices: tokens.length };
}
