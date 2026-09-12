# TransitGo on Firebase

This is `transitgo-server` ported to **Firebase Functions v2 + Firestore** — same
endpoints, same JSON shapes, so the app only needs `BACKEND_HOST` pointed at wherever
this ends up deployed. Nothing here is deployed yet; these are the steps to do it
yourself (creating the Firebase project is something only you can do — an account and
possibly billing are required).

## What's here

- `functions/index.js` — the HTTPS API (`api`, one Cloud Function running an Express
  app — identical routes to `transitgo-server/src/index.mjs`) plus two scheduled
  functions that replace the old server's `node-cron` loops:
  - `bikePoll` — refreshes the shared YouBike cache (every 2 min)
  - `alertPoll` — polls TRA/THSR service status → announcement + push (every 3 min)
- `functions/lib/` — `db.js` (Firestore, mirrors `transitgo-server/src/db.mjs`),
  `tdx.js` (unchanged), `push.js` (APNs, unchanged logic), `alerts.js`, `bikepoller.js`.
- `firestore.rules` — denies all direct client access; every read/write goes through
  the Functions API using the Admin SDK, which isn't subject to these rules.
- `public/admin.html` — the same admin dashboard, served by Firebase Hosting.

## One-time setup

1. **Create the Firebase project** (you do this — I can't create accounts for you):
   ```
   npm install -g firebase-tools
   firebase login
   firebase projects:create            # or use an existing GCP/Firebase project
   ```
   Put the resulting project ID into `.firebaserc` (replace the placeholder).

2. **Enable Firestore** for the project (Native mode) — either in the Firebase console
   or `firebase firestore:databases:create '(default)' --location=asia-east1`.

3. **Fill in secrets**: copy `functions/.env.example` to `functions/.env` and fill in
   your TDX key, admin token, etc. (same variable names as `transitgo-server/.env`).
   For APNs, Cloud Functions has no persistent disk for a `.p8` file — set
   `APNS_KEY_CONTENT` to the file's contents instead of `APNS_KEY_PATH`, ideally as a
   real secret rather than plain `.env`:
   ```
   firebase functions:secrets:set APNS_KEY_CONTENT
   ```
   (paste the `.p8` file's text when prompted), then reference it in `index.js`'s
   `setGlobalOptions`/function options as a secret if you want it out of plain `.env`.
   Push works in DRY_RUN (logged, not sent) until APNs is configured — announcements
   still get created and served either way.

4. **Install functions deps**:
   ```
   cd functions && npm install
   ```

## Deploy

```
cd firebase
firebase deploy --only functions,firestore,hosting
```

This gives you a Hosting URL (`https://<project-id>.web.app`) that rewrites `/v1/**`
and `/admin` to the `api` function (see `firebase.json`) — set that host (no
`https://`, no path) as `BACKEND_HOST` in the app's `Config/Secrets.xcconfig`.

## Local testing first (recommended)

```
firebase emulators:start --only functions,firestore,hosting
```

Emulator UI defaults to `http://localhost:4000`; the API is reachable at whatever port
it prints for the `hosting` emulator (usually `:5000`).

## Known gaps vs. the Node server

- **Rating/observation aggregates** read up to a few thousand recent docs and average
  in memory rather than using a running counter — fine at low volume, but if either
  collection gets large, switch to Firestore counter documents updated on write.
- **`listAnnouncements`** filters `expiresAt`/`since` in memory after an `active`-only
  Firestore query, because Firestore can't range-filter two different fields in one
  query without a composite index it doesn't have here. Not an issue unless the
  announcements collection gets huge (it's capped to the latest 200 either way).
- Nothing here migrates existing data from `transitgo-server`'s SQLite file — this is
  a fresh Firestore database. If you want history carried over, that's a separate
  one-off export/import script, not included.
