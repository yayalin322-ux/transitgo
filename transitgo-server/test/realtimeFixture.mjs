// REAL TDX realtime responses captured 2026-09-19 ~13:40 (English/Japanese/Korean names
// stripped) plus a tiny fake TDX transport for service-level tests. Nothing here calls TDX.
import { readFileSync } from "node:fs";
export const REAL_RT = JSON.parse(readFileSync(new URL("./fixtures/realtime_real_tdx.json", import.meta.url), "utf8"));

export const T0 = Date.parse("2026-09-19T13:40:00+08:00");

/** A fake `tdxGet(path)`: `routes` maps a path PREFIX to a value or a function; counts calls per path. */
export function fakeTdx(routes) {
  const calls = [];
  const tdxGet = async (path) => {
    calls.push(path);
    const key = Object.keys(routes).find((k) => path.startsWith(k));
    if (!key) throw Object.assign(new Error(`TDX ${path} 404`), { status: 404 });
    const v = routes[key];
    return typeof v === "function" ? v(path) : v;
  };
  tdxGet.calls = calls;
  return tdxGet;
}
export const httpError = (status, path = "x") => Object.assign(new Error(`TDX ${path} ${status}`), { status, name: "TdxHttpError" });
