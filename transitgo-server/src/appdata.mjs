import * as sql from "./db.mjs";

/**
 * App data (devices, announcements, reports, ratings, observations, place reviews, landmarks, alert state, shared
 * trip links). One place decides where it lives:
 *
 *   DATA_BACKEND unset / "sql"   → Postgres (Supabase) or sqlite, as before
 *   DATA_BACKEND=firestore       → Firestore (FIRESTORE_PREFIX optionally namespaces the collections, e.g. "dev_")
 *
 * The routing tables (gtfs_*) and the graph build are NOT app data; they keep using the SQL handle from db.mjs.
 */
let impl = sql;
if (process.env.DATA_BACKEND === "firestore") {
  const { createFirestoreClient } = await import("./firestore/firestoreClient.mjs");
  const { createFirestoreAdapter } = await import("./firestore/firestoreAdapter.mjs");
  const { createAppData } = await import("./firestore/appdata.mjs");
  const adapter = createFirestoreAdapter(createFirestoreClient(), { prefix: process.env.FIRESTORE_PREFIX || "" });
  // Fail at boot, loudly, rather than start and then hang on the first request: without credentials the SDK spends a long
  // time looking for them. (A failed start leaves the previous deploy serving on Render.)
  try {
    await Promise.race([
      adapter.get("_meta", "ping"),
      new Promise((_, reject) => setTimeout(() => reject(new Error("no answer within 10 s")), 10_000)),
    ]);
  } catch (e) {
    throw new Error(`DATA_BACKEND=firestore but Firestore is not usable (${e.message}). Check FIREBASE_SERVICE_ACCOUNT_JSON / FIRESTORE_PROJECT_ID.`);
  }
  impl = createAppData(adapter);
  console.log(`[data] app data on Firestore${process.env.FIRESTORE_PREFIX ? ` (collections prefixed "${process.env.FIRESTORE_PREFIX}")` : ""}`);
}
export const dataBackend = impl === sql ? "sql" : "firestore";

export const REPORT_REASONS = sql.REPORT_REASONS;
export const LANDMARK_CATEGORIES = sql.LANDMARK_CATEGORIES;

const names = [
  "upsertDevice", "allDeviceTokens", "removeDevice",
  "createAnnouncement", "getAnnouncement", "listAnnouncements", "deactivateAnnouncement",
  "createReport", "listReports", "createRating", "listRatings", "routeRatingStats", "ratingStats",
  "createObservation", "listObservations",
  "setBikeCache", "getBikeCache", "allBikeCaches", "setSpeedcamCache", "getSpeedcamCache",
  "createPlaceReview", "listPlaceReviews", "reportPlaceReview", "deletePlaceReview", "listAllPlaceReviews", "placeReviewStats",
  "createUserLandmark", "listApprovedLandmarksNear", "listAllUserLandmarks", "approveUserLandmark", "verifyUserLandmarkBusiness",
  "deleteUserLandmark", "reportUserLandmark", "listMyUserLandmarks", "updateMyUserLandmark",
  "getAlertState", "setAlertState",
  "createShare", "getShare", "deleteShare",
];
for (const n of names) if (typeof impl[n] !== "function") throw new Error(`app data backend is missing ${n}`);

export const upsertDevice = (...a) => impl.upsertDevice(...a);
export const allDeviceTokens = (...a) => impl.allDeviceTokens(...a);
export const removeDevice = (...a) => impl.removeDevice(...a);
export const createAnnouncement = (...a) => impl.createAnnouncement(...a);
export const getAnnouncement = (...a) => impl.getAnnouncement(...a);
export const listAnnouncements = (...a) => impl.listAnnouncements(...a);
export const deactivateAnnouncement = (...a) => impl.deactivateAnnouncement(...a);
export const createReport = (...a) => impl.createReport(...a);
export const listReports = (...a) => impl.listReports(...a);
export const createRating = (...a) => impl.createRating(...a);
export const listRatings = (...a) => impl.listRatings(...a);
export const routeRatingStats = (...a) => impl.routeRatingStats(...a);
export const ratingStats = (...a) => impl.ratingStats(...a);
export const createObservation = (...a) => impl.createObservation(...a);
export const listObservations = (...a) => impl.listObservations(...a);
export const setBikeCache = (...a) => impl.setBikeCache(...a);
export const getBikeCache = (...a) => impl.getBikeCache(...a);
export const allBikeCaches = (...a) => impl.allBikeCaches(...a);
export const setSpeedcamCache = (...a) => impl.setSpeedcamCache(...a);
export const getSpeedcamCache = (...a) => impl.getSpeedcamCache(...a);
export const createPlaceReview = (...a) => impl.createPlaceReview(...a);
export const listPlaceReviews = (...a) => impl.listPlaceReviews(...a);
export const reportPlaceReview = (...a) => impl.reportPlaceReview(...a);
export const deletePlaceReview = (...a) => impl.deletePlaceReview(...a);
export const listAllPlaceReviews = (...a) => impl.listAllPlaceReviews(...a);
export const placeReviewStats = (...a) => impl.placeReviewStats(...a);
export const createUserLandmark = (...a) => impl.createUserLandmark(...a);
export const listApprovedLandmarksNear = (...a) => impl.listApprovedLandmarksNear(...a);
export const listAllUserLandmarks = (...a) => impl.listAllUserLandmarks(...a);
export const approveUserLandmark = (...a) => impl.approveUserLandmark(...a);
export const verifyUserLandmarkBusiness = (...a) => impl.verifyUserLandmarkBusiness(...a);
export const deleteUserLandmark = (...a) => impl.deleteUserLandmark(...a);
export const reportUserLandmark = (...a) => impl.reportUserLandmark(...a);
export const listMyUserLandmarks = (...a) => impl.listMyUserLandmarks(...a);
export const updateMyUserLandmark = (...a) => impl.updateMyUserLandmark(...a);
export const getAlertState = (...a) => impl.getAlertState(...a);
export const setAlertState = (...a) => impl.setAlertState(...a);
export const createShare = (...a) => impl.createShare(...a);
export const getShare = (...a) => impl.getShare(...a);
export const deleteShare = (...a) => impl.deleteShare(...a);
