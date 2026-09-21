import { Firestore } from "@google-cloud/firestore";

/**
 * Builds the Firestore client from the environment — never from anything in the repository.
 *
 *   FIREBASE_SERVICE_ACCOUNT_JSON   the service-account key as a JSON string (set as a secret in the host's env)
 *   GOOGLE_APPLICATION_CREDENTIALS  or a path to that key file (local runs)
 *   FIRESTORE_PROJECT_ID            defaults to the project inside the key
 *   FIRESTORE_EMULATOR_HOST         when set, the SDK talks to the local emulator and needs no credentials
 */
export function createFirestoreClient() {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (raw) {
    let key;
    try { key = JSON.parse(raw); } catch { throw new Error("FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON"); }
    return new Firestore({
      projectId: process.env.FIRESTORE_PROJECT_ID || key.project_id,
      credentials: { client_email: key.client_email, private_key: key.private_key },
      ignoreUndefinedProperties: true,
    });
  }
  return new Firestore({ projectId: process.env.FIRESTORE_PROJECT_ID || undefined, ignoreUndefinedProperties: true });
}
