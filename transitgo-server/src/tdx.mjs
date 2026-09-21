/** An HTTP-level TDX failure with its status preserved (the message format is unchanged, so
 * every existing `e.message` consumer keeps working) — realtime needs the status itself to
 * tell a rate limit (429) from a credential problem (401/403) from a server error. */
export class TdxHttpError extends Error {
  constructor(message, status, kind = "http") {
    super(message);
    this.name = "TdxHttpError";
    this.status = status;
    this.kind = kind;   // "auth" for a token request, "http" for an API request
  }
}

import { createBudget } from "./tdxBudget.mjs";

const TOKEN_URL =
  "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token";
const BASE = "https://tdx.transportdata.tw/api/basic";

let cachedToken = null;
let cachedExp = 0;

// Separate credential set + token cache for the routing engine, so its TDX calls draw
// from their own account's 5 req/min quota instead of competing with the alert/bike
// pollers that already run on TDX_CLIENT_ID. Falls back to the main credentials if no
// routing-specific ones are configured.
let cachedRoutingToken = null;
let cachedRoutingExp = 0;

export function tdxConfigured() {
  return !!(process.env.TDX_CLIENT_ID && process.env.TDX_CLIENT_SECRET);
}

export function tdxRoutingConfigured() {
  return !!(process.env.TDX_ROUTING_CLIENT_ID && process.env.TDX_ROUTING_CLIENT_SECRET);
}

async function fetchToken(clientId, clientSecret) {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: clientId,
    client_secret: clientSecret,
  });
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new TdxHttpError(`TDX auth ${res.status}`, res.status, "auth");
  const json = await res.json();
  return { token: json.access_token, expiresInMs: (json.expires_in ?? 86400) * 1000 };
}

async function token() {
  if (cachedToken && Date.now() < cachedExp - 60_000) return cachedToken;
  const { token: t, expiresInMs } = await fetchToken(process.env.TDX_CLIENT_ID, process.env.TDX_CLIENT_SECRET);
  cachedToken = t;
  cachedExp = Date.now() + expiresInMs;
  return cachedToken;
}

async function routingToken() {
  if (!tdxRoutingConfigured()) return token();
  if (cachedRoutingToken && Date.now() < cachedRoutingExp - 60_000) return cachedRoutingToken;
  const { token: t, expiresInMs } = await fetchToken(process.env.TDX_ROUTING_CLIENT_ID, process.env.TDX_ROUTING_CLIENT_SECRET);
  cachedRoutingToken = t;
  cachedRoutingExp = Date.now() + expiresInMs;
  return cachedRoutingToken;
}

async function fetchWithToken(path, t) {
  const res = await fetch(`${BASE}/${path}${path.includes("?") ? "&" : "?"}$format=JSON`, {
    headers: { authorization: `Bearer ${t}` },
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new TdxHttpError(`TDX ${path} ${res.status}`, res.status);
  return res.json();
}

// One shared quota (see tdxBudget.mjs): background reads wait and leave room; interactive reads never wait.
export const tdxBudget = createBudget({
  perMinute: parseInt(process.env.TDX_RATE_PER_MIN || "5", 10),
  reservedForInteractive: parseInt(process.env.TDX_RESERVED_INTERACTIVE || "3", 10),
});

/** Background reads (pollers): waits its turn inside the quota, never takes the interactive reserve. */
export async function get(path) {
  const id = process.env.TDX_CLIENT_ID;
  if (!(await tdxBudget.acquireBackground(id))) throw new TdxHttpError(`TDX ${path} 429 (waited too long for a free slot)`, 429);
  const t = await token();
  return fetchWithToken(path, t);
}

/** Interactive reads (a person is waiting): a slot now, or an immediate 429 the caller can answer from cache. */
export async function getRouting(path) {
  const id = tdxRoutingConfigured() ? process.env.TDX_ROUTING_CLIENT_ID : process.env.TDX_CLIENT_ID;
  if (!tdxBudget.tryAcquire(id)) throw new TdxHttpError(`TDX ${path} 429 (local budget)`, 429);
  const t = await routingToken();
  return fetchWithToken(path, t);
}

/** Merged YouBike snapshot for one city: station meta + live availability. */
export async function bikeCity(city) {
  const [stations, avail] = await Promise.all([
    get(`v2/Bike/Station/City/${city}?$select=StationUID,StationName,StationPosition,StationAddress,BikesCapacity&$top=3000`),
    get(`v2/Bike/Availability/City/${city}?$top=3000`),
  ]);
  const byUID = new Map();
  for (const a of avail) byUID.set(a.StationUID, a);
  const out = [];
  for (const s of stations) {
    const a = byUID.get(s.StationUID);
    const lat = s.StationPosition?.PositionLat;
    const lon = s.StationPosition?.PositionLon;
    if (lat == null || lon == null) continue;
    out.push({
      uid: s.StationUID,
      name: (s.StationName?.Zh_tw || "").replace(/^YouBike\d\.\d_/, ""),
      city,
      lat, lon,
      address: s.StationAddress?.Zh_tw || "",
      capacity: s.BikesCapacity ?? null,
      rent: a?.AvailableRentBikes ?? 0,
      ret: a?.AvailableReturnBikes ?? 0,
      general: a?.AvailableRentBikesDetail?.GeneralBikes ?? null,
      electric: a?.AvailableRentBikesDetail?.ElectricBikes ?? null,
      status: a?.ServiceStatus ?? 0,
      src: a?.SrcUpdateTime || null,
    });
  }
  return out;
}

/** TRA alerts. Returns { abnormal, items: [{title, description?}] } */
export async function traAlerts() {
  const d = await get("v3/Rail/TRA/Alert");
  const list = Array.isArray(d) ? d : d.Alerts ?? [];
  const items = list.map((a) => ({
    title: a.Title ?? "",
    description: a.Description ?? "",
    status: a.Status,
  }));
  const abnormal = items.some(
    (i) => i.title && !/正常|normal/i.test(i.title) && i.status !== 1
  );
  return { abnormal, items };
}

/** THSR alerts. */
export async function thsrAlerts() {
  const list = await get("v2/Rail/THSR/AlertInfo");
  const items = (Array.isArray(list) ? list : []).map((a) => ({
    id: a.AlertID,
    title: a.Title ?? "",
    description: a.Description ?? "",
  }));
  const abnormal = items.some(
    (i) =>
      i.title &&
      !/正常|normal/i.test(i.title) &&
      i.id &&
      i.id !== "00000000-0000-0000-0000-000000000000"
  );
  return { abnormal, items };
}
