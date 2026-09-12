const TOKEN_URL =
  "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token";
const BASE = "https://tdx.transportdata.tw/api/basic";

let cachedToken = null;
let cachedExp = 0;

export function tdxConfigured() {
  return !!(process.env.TDX_CLIENT_ID && process.env.TDX_CLIENT_SECRET);
}

async function token() {
  if (cachedToken && Date.now() < cachedExp - 60_000) return cachedToken;
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: process.env.TDX_CLIENT_ID,
    client_secret: process.env.TDX_CLIENT_SECRET,
  });
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) throw new Error(`TDX auth ${res.status}`);
  const json = await res.json();
  cachedToken = json.access_token;
  cachedExp = Date.now() + (json.expires_in ?? 86400) * 1000;
  return cachedToken;
}

async function get(path) {
  const t = await token();
  const res = await fetch(`${BASE}/${path}${path.includes("?") ? "&" : "?"}$format=JSON`, {
    headers: { authorization: `Bearer ${t}` },
  });
  if (!res.ok) throw new Error(`TDX ${path} ${res.status}`);
  return res.json();
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
