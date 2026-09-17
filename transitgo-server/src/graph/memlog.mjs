/**
 * Build-time memory instrumentation — every claim about buildGraph()'s memory profile in
 * this codebase before this file existed was inferred, not measured on the actual boot
 * path. Logs real process.memoryUsage() at each phase boundary so a future OOM (or a
 * memory-optimization PR) has real numbers to work from instead of another guess.
 *
 * Deliberately logs only numbers — never anything from the request/response bodies or
 * environment, so this can't leak TDX/DB credentials into logs.
 */
export function logMemory(phase, extra = {}) {
  const m = process.memoryUsage();
  const mb = (n) => Math.round(n / 1024 / 1024);
  const parts = [`phase=${phase}`, `rss=${mb(m.rss)}MB`, `heapUsed=${mb(m.heapUsed)}MB`, `heapTotal=${mb(m.heapTotal)}MB`, `external=${mb(m.external)}MB`, `arrayBuffers=${mb(m.arrayBuffers)}MB`];
  for (const [k, v] of Object.entries(extra)) parts.push(`${k}=${v}`);
  console.log(`[GRAPH] ${parts.join(" ")}`);
  return { rss: mb(m.rss), heapUsed: mb(m.heapUsed) };
}
