/**
 * Two small facts that change once share links are opened through yayalin.com (a Cloudflare proxy in front of this server).
 */

/** The link a new share gets: on the public site when PUBLIC_SHARE_ORIGIN is set (e.g. https://yayalin.com/app), else this server. */
export function shareLinkUrl({ token, publicOrigin, requestOrigin }) {
  const base = (publicOrigin || requestOrigin || "").replace(/\/+$/, "");
  return `${base}/s/${token}`;
}

/** Only an https origin with no query/fragment counts as a usable PUBLIC_SHARE_ORIGIN; anything else is ignored. */
export function cleanPublicOrigin(v) {
  if (typeof v !== "string" || !v.trim()) return "";
  try {
    const u = new URL(v.trim());
    if (u.protocol !== "https:" || u.search || u.hash) return "";
    return (u.origin + u.pathname).replace(/\/+$/, "");
  } catch { return ""; }
}

/**
 * The visitor's address for rate limits and "one rating per viewer". Behind the yayalin.com proxy every request reaches
 * this server from the proxy, so the proxy passes the real address in X-Viewer-IP (Cloudflare's CF-Connecting-IP); without
 * it the first X-Forwarded-For entry (or the socket) is used as before. The header is not authenticated: someone calling
 * this server directly can claim any address, which only lets them dodge a per-address limit they could dodge anyway.
 */
export function viewerIp(headers, socketAddress) {
  const pick = (v) => (typeof v === "string" ? v.split(",")[0].trim() : "");
  const ip = (s) => (/^[0-9a-fA-F:.]{3,45}$/.test(s) ? s : "");
  return ip(pick(headers["x-viewer-ip"])) || pick(headers["x-forwarded-for"]) || (socketAddress || "").trim();
}
