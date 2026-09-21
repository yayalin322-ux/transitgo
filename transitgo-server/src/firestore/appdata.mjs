/**
 * App data (devices, announcements, reports, ratings, observations, place reviews, landmarks, alert state, shared
 * trip links) on a document store. Same function names, arguments and return shapes as the SQL versions in db.mjs, so
 * index.mjs and the pollers need no change; `appdata.mjs` (the facade) picks which one runs.
 *
 * Rules that differ from SQL, all deliberate:
 *  - Row ids stay integers (the app and the admin page address rows by number): a counter per collection.
 *  - Timestamps are stored as ISO-8601 strings, so string order == time order.
 *  - Booleans stay 0/1, exactly like the SQL columns, so the serializers are unchanged.
 *  - YouBike and speed-camera caches are NOT stored: they are megabytes, rewritten every couple of minutes by a
 *    poller that also runs at boot. Keeping them in this process's memory costs no reads/writes.
 *  - "Approved landmarks near a point" read every approved landmark; that list is cached for a minute and dropped on
 *    any landmark write, so a busy map does not spend the free read quota.
 */

export const REPORT_REASONS = ["spam", "offensive", "sexual", "harassment", "other"];
export const LANDMARK_CATEGORIES = [
  "foodDrink", "medical", "shopping", "transportation", "education", "finance",
  "government", "recreation", "sports", "lodging", "religion", "personalServices", "other",
];

const clampStars = (v) => Math.max(1, Math.min(5, parseInt(v, 10) || 0));
const strip = ({ _id, ...rest }) => rest;
/** "2026-09-21 20:00:00" (SQL style) or ISO → ISO. */
function toIso(v) {
  if (v == null || v === "") return null;
  const s = String(v);
  const d = new Date(/^\d{4}-\d{2}-\d{2} /.test(s) ? s.replace(" ", "T") + "Z" : s);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
const round = (v, digits) => (v ? Number(Number(v).toFixed(digits)) : null);

export function createAppData(store, { now = () => new Date(), landmarkCacheMs = 60_000 } = {}) {
  const iso = () => now().toISOString();
  const bikeCaches = new Map();
  let speedcams = null;
  let approvedCache = null;   // { at, rows }
  const dropLandmarkCache = () => { approvedCache = null; };

  // ---- devices ----
  async function upsertDevice({ token, platform, appVersion }) {
    await store.set("devices", token, { token, platform: platform ?? null, app_version: appVersion ?? null, last_seen: iso() });
  }
  const allDeviceTokens = async () => (await store.list("devices")).map((r) => r.token);
  const removeDevice = async (token) => { await store.remove("devices", token); };

  // ---- announcements ----
  const serializeAnnouncement = (r) => r && ({
    id: r.id, category: r.category, severity: r.severity, title: r.title, body: r.body, source: r.source,
    active: !!r.active, createdAt: r.created_at, expiresAt: r.expires_at ?? null,
  });
  async function createAnnouncement(a) {
    const id = await store.nextId("announcements");
    await store.set("announcements", id, {
      id, category: a.category, severity: a.severity ?? "info", title: a.title, body: a.body ?? "",
      source: a.source ?? "admin", active: 1, created_at: iso(), expires_at: toIso(a.expiresAt),
    });
    return getAnnouncement(id);
  }
  async function getAnnouncement(id) { return serializeAnnouncement(await store.get("announcements", id)); }
  async function listAnnouncements({ since, includeInactive = false } = {}) {
    const rows = await store.list("announcements", {
      where: includeInactive ? [] : [["active", "==", 1]], orderBy: [["created_at", "desc"]], limit: 400,
    });
    const nowMs = now().getTime();
    const sinceMs = since ? Date.parse(toIso(since) ?? "") : null;
    return rows
      .filter((r) => !r.expires_at || Date.parse(r.expires_at) > nowMs)
      .filter((r) => sinceMs == null || Date.parse(r.created_at) > sinceMs)
      .slice(0, 200).map((r) => serializeAnnouncement(strip(r)));
  }
  const deactivateAnnouncement = async (id) => { await store.update("announcements", id, { active: 0 }); };

  // ---- reports / ratings / observations ----
  async function createReport(r) {
    const id = await store.nextId("reports");
    await store.set("reports", id, {
      id, type: r.type, message: r.message ?? "", context: r.context ? JSON.stringify(r.context) : null,
      app_version: r.appVersion ?? null, os: r.os ?? null, device: r.device ?? null, ip: r.ip ?? null, created_at: iso(),
    });
  }
  const listReports = async (limit = 100) => (await store.list("reports", { orderBy: [["created_at", "desc"]], limit })).map(strip);

  async function createRating(r) {
    const id = await store.nextId("ratings");
    await store.set("ratings", id, {
      id, stars: clampStars(r.stars), kind: r.kind ?? "bus", route: r.route ?? null, from_stop: r.from ?? null,
      to_stop: r.to ?? null, system: r.system ?? null, app_version: r.appVersion ?? null, device: r.device ?? null,
      ip: r.ip ?? null, created_at: iso(),
    });
  }
  const listRatings = async (limit = 100) => (await store.list("ratings", { orderBy: [["created_at", "desc"]], limit })).map(strip);
  async function routeRatingStats(kind, route, system) {
    const where = [["kind", "==", kind], ["route", "==", route]];
    if (system != null) where.push(["system", "==", system]);
    const a = await store.aggregate("ratings", where, "stars");
    return { count: a.count, avg: round(a.avg, 1) };
  }
  async function ratingStats() {
    const all = await store.aggregate("ratings", [], "stars");
    const byStar = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
    for (const s of [1, 2, 3, 4, 5]) byStar[s] = (await store.aggregate("ratings", [["stars", "==", s]])).count;
    return { count: all.count, avg: round(all.avg, 2), byStar };
  }

  async function createObservation(o) {
    const id = await store.nextId("observations");
    await store.set("observations", id, {
      id, route: o.route ?? null, plate: o.plate ?? null, stop_uid: o.stopUID ?? null, stop_name: o.stopName ?? null,
      kind: o.kind === "alight" ? "alight" : "board", system: o.system ?? null, ip: o.ip ?? null, created_at: iso(),
    });
  }
  async function listObservations({ route = null, limit = 100 } = {}) {
    return (await store.list("observations", { where: route ? [["route", "==", route]] : [], orderBy: [["created_at", "desc"]], limit })).map(strip);
  }

  // ---- shared caches: process memory (see header) ----
  async function setBikeCache(city, stations) { bikeCaches.set(city, { stations, updatedAt: iso() }); }
  async function getBikeCache(city) { return bikeCaches.get(city) ?? null; }
  async function allBikeCaches() { return [...bikeCaches.entries()].map(([city, v]) => ({ city, ...v })); }
  async function setSpeedcamCache(cams) { speedcams = { cams, updatedAt: iso() }; }
  async function getSpeedcamCache() { return speedcams; }

  // ---- place reviews ----
  async function createPlaceReview(r) {
    const stars = clampStars(r.stars);
    const comment = (r.comment ?? "").slice(0, 500);
    if (r.device) {
      // one review per (place, device): re-submitting updates it and clears its report count, as the SQL upsert did
      const [existing] = await store.list("place_reviews", { where: [["place_key", "==", r.placeKey], ["device", "==", r.device]], limit: 1 });
      if (existing) {
        await store.update("place_reviews", existing._id, {
          stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null, ip: r.ip ?? null, reported: 0, created_at: iso(),
        });
        return;
      }
    }
    const id = await store.nextId("place_reviews");
    await store.set("place_reviews", id, {
      id, place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null, stars, comment,
      photo: r.photo ?? null, app_version: r.appVersion ?? null, device: r.device ?? null, ip: r.ip ?? null, reported: 0, created_at: iso(),
    });
  }
  async function listPlaceReviews(placeKey, limit = 50) {
    const rows = await store.list("place_reviews", { where: [["place_key", "==", placeKey]], orderBy: [["created_at", "desc"]], limit });
    return rows.map((r) => ({ id: r.id, stars: r.stars, comment: r.comment, photo: r.photo, createdAt: r.created_at }));
  }
  async function reportPlaceReview(id, reason, ip) {
    if (!(await store.increment("place_reviews", id, "reported", 1))) return false;
    await store.set("place_review_reports", await store.nextId("place_review_reports"), {
      review_id: Number(id), reason: REPORT_REASONS.includes(reason) ? reason : "other", ip: ip ?? null, created_at: iso(),
    });
    return true;
  }
  async function deletePlaceReview(id) {
    const existed = await store.remove("place_reviews", id);
    await store.removeWhere("place_review_reports", [["review_id", "==", Number(id)]]);
    return existed;
  }
  async function reasonBreakdown(collection, field, id) {
    const out = {};
    for (const r of await store.list(collection, { where: [[field, "==", id]] })) out[r.reason] = (out[r.reason] ?? 0) + 1;
    return out;
  }
  async function listAllPlaceReviews(limit = 200) {
    const rows = await store.list("place_reviews", { orderBy: [["reported", "desc"], ["created_at", "desc"]], limit });
    return Promise.all(rows.map(async (r) => ({
      id: r.id, placeKey: r.place_key, placeName: r.place_name, stars: r.stars, comment: r.comment, reported: r.reported,
      reportReasons: r.reported > 0 ? await reasonBreakdown("place_review_reports", "review_id", r.id) : {},
      appVersion: r.app_version, createdAt: r.created_at,
    })));
  }
  async function placeReviewStats(placeKey) {
    const a = await store.aggregate("place_reviews", [["place_key", "==", placeKey]], "stars");
    return { count: a.count, avg: round(a.avg, 1) };
  }

  // ---- landmarks ----
  async function createUserLandmark(r) {
    const id = await store.nextId("user_landmarks");
    await store.set("user_landmarks", id, {
      id, name: r.name, description: (r.description ?? "").slice(0, 500),
      category: LANDMARK_CATEGORIES.includes(r.category) ? r.category : "other", lat: r.lat, lon: r.lon, photo: r.photo ?? null,
      is_business_claim: r.isBusinessClaim ? 1 : 0, business_verified: 0, business_hours: (r.businessHours ?? "").slice(0, 500) || null,
      phone: (r.phone ?? "").slice(0, 50) || null, app_version: r.appVersion ?? null, device: r.device ?? null, ip: r.ip ?? null,
      approved: 0, reported: 0, created_at: iso(),
    });
    dropLandmarkCache();
  }
  async function approvedLandmarks() {
    if (approvedCache && now().getTime() - approvedCache.at < landmarkCacheMs) return approvedCache.rows;
    const rows = (await store.list("user_landmarks", { where: [["approved", "==", 1]] })).map(strip);
    approvedCache = { at: now().getTime(), rows };
    return rows;
  }
  async function listApprovedLandmarksNear(lat, lon, radiusMeters = 1000) {
    const R = 6371000, p = Math.PI / 180;
    return (await approvedLandmarks()).filter((r) => {
      const x = 0.5 - Math.cos((r.lat - lat) * p) / 2 + (Math.cos(lat * p) * Math.cos(r.lat * p) * (1 - Math.cos((r.lon - lon) * p))) / 2;
      return 2 * R * Math.asin(Math.sqrt(x)) <= radiusMeters;
    }).map((r) => ({
      id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
      businessHours: r.business_verified ? r.business_hours : null, phone: r.business_verified ? r.phone : null,
      businessVerified: !!r.business_verified,
    }));
  }
  async function listAllUserLandmarks(limit = 200) {
    const rows = await store.list("user_landmarks", { orderBy: [["approved", "asc"], ["created_at", "desc"]], limit });
    return Promise.all(rows.map(async (r) => ({
      id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
      isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified, businessHours: r.business_hours, phone: r.phone,
      approved: !!r.approved, reported: r.reported,
      reportReasons: r.reported > 0 ? await reasonBreakdown("user_landmark_reports", "landmark_id", r.id) : {},
      appVersion: r.app_version, createdAt: r.created_at,
    })));
  }
  async function approveUserLandmark(id) { const ok = await store.update("user_landmarks", id, { approved: 1 }); dropLandmarkCache(); return ok; }
  async function verifyUserLandmarkBusiness(id) { const ok = await store.update("user_landmarks", id, { business_verified: 1 }); dropLandmarkCache(); return ok; }
  async function deleteUserLandmark(id) {
    const existed = await store.remove("user_landmarks", id);
    await store.removeWhere("user_landmark_reports", [["landmark_id", "==", Number(id)]]);
    dropLandmarkCache();
    return existed;
  }
  async function reportUserLandmark(id, reason, ip) {
    if (!(await store.increment("user_landmarks", id, "reported", 1))) return false;
    await store.set("user_landmark_reports", await store.nextId("user_landmark_reports"), {
      landmark_id: Number(id), reason: REPORT_REASONS.includes(reason) ? reason : "other", ip: ip ?? null, created_at: iso(),
    });
    return true;
  }
  async function listMyUserLandmarks(device) {
    const rows = await store.list("user_landmarks", { where: [["device", "==", device]], orderBy: [["created_at", "desc"]] });
    return rows.map((r) => ({
      id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
      isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified, businessHours: r.business_hours, phone: r.phone,
      approved: !!r.approved, createdAt: r.created_at,
    }));
  }
  async function updateMyUserLandmark(id, device, fields) {
    const row = await store.get("user_landmarks", id);
    if (!row || row.device !== device || !row.business_verified) return false;
    const patch = {};
    if (typeof fields.description === "string") patch.description = fields.description.slice(0, 500);
    if (typeof fields.businessHours === "string") patch.business_hours = fields.businessHours.slice(0, 500);
    if (typeof fields.photo === "string") patch.photo = fields.photo;
    if (typeof fields.phone === "string") patch.phone = fields.phone.slice(0, 50);
    if (typeof fields.lat === "number" && typeof fields.lon === "number") { patch.lat = fields.lat; patch.lon = fields.lon; }
    if (Object.keys(patch).length === 0) return false;
    await store.update("user_landmarks", id, patch);
    dropLandmarkCache();
    return true;
  }

  // ---- alert state ----
  async function getAlertState(source) { const r = await store.get("alert_state", source); return r ? r : undefined; }
  async function setAlertState(source, signature, abnormal) {
    await store.set("alert_state", source, { source, signature, abnormal: abnormal ? 1 : 0, updated_at: iso() });
  }

  // ---- shared trip links ----
  async function createShare({ token, title, segments, nowMs, expiresAtMs }) {
    await store.removeWhere("shares", [["expires_at_ms", "<=", nowMs]], 100);   // sweep expired ones on every create
    await store.set("shares", token, { token, title: title ?? null, segments_json: JSON.stringify(segments), created_at_ms: nowMs, expires_at_ms: expiresAtMs });
  }
  async function getShare(token) {
    const r = await store.get("shares", token);
    return r ? { token: r.token, title: r.title, segments: JSON.parse(r.segments_json), created_at_ms: Number(r.created_at_ms), expires_at_ms: Number(r.expires_at_ms) } : null;
  }
  const deleteShare = async (token) => { await store.remove("shares", token); };

  return {
    upsertDevice, allDeviceTokens, removeDevice,
    createAnnouncement, getAnnouncement, listAnnouncements, deactivateAnnouncement,
    createReport, listReports, createRating, listRatings, routeRatingStats, ratingStats,
    createObservation, listObservations,
    setBikeCache, getBikeCache, allBikeCaches, setSpeedcamCache, getSpeedcamCache,
    createPlaceReview, listPlaceReviews, reportPlaceReview, deletePlaceReview, listAllPlaceReviews, placeReviewStats,
    createUserLandmark, listApprovedLandmarksNear, listAllUserLandmarks, approveUserLandmark, verifyUserLandmarkBusiness,
    deleteUserLandmark, reportUserLandmark, listMyUserLandmarks, updateMyUserLandmark,
    getAlertState, setAlertState,
    createShare, getShare, deleteShare,
  };
}
