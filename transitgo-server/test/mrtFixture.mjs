// Shared helper for the MRT tests: loads REAL TDX v2/Rail/Metro responses (captured
// 2026-09-19, test/fixtures/mrt_real_tdx.json — English/Japanese/Korean names and update
// metadata stripped to keep the file small) and serves them through the same provider
// interface ingestMetroOperator() uses in production. No test here talks to TDX.
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { ingestMetroOperator } from "../src/tdx/ingest.mjs";

const REAL = JSON.parse(readFileSync(new URL("./fixtures/mrt_real_tdx.json", import.meta.url), "utf8"));

/** Provider over the real fixture. `overrides[endpoint]` replaces a response (or a function
 * that throws, to simulate TDX returning an error for that endpoint). */
export function fixtureSource(operator, overrides = {}) {
  const get = (endpoint) => async () => {
    if (endpoint in overrides) {
      const o = overrides[endpoint];
      if (typeof o === "function") return o();
      return o;
    }
    const data = REAL[operator]?.[endpoint];
    if (data === undefined) throw new Error(`TDX ${endpoint}/${operator} 400`);
    return data;
  };
  return {
    getMetroStations: get("Station"),
    getMetroTravelTimes: get("S2STravelTime"),
    getMetroFrequency: get("Frequency"),
    getMetroLineTransfer: get("LineTransfer"),
    getMetroLines: get("Line"),
  };
}

export function realResponse(operator, endpoint) {
  return REAL[operator][endpoint];
}

/** A fresh in-memory DB with the requested operators ingested from the real fixture. */
export async function buildMrtDb(operators = ["TRTC"], overridesByOperator = {}) {
  const db = new DatabaseSync(":memory:");
  await ensureGtfsSchema(db);
  const results = {};
  for (const op of operators) {
    results[op] = await ingestMetroOperator(db, op, { source: fixtureSource(op, overridesByOperator[op] ?? {}), retry: { attempts: 1 } });
  }
  return { db, results };
}
