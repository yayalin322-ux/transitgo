// TDX quota order: interactive (a person is waiting) never waits and may use everything; background pollers wait
// and never take the interactive reserve.
import { createBudget } from "../src/tdxBudget.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

function clock() {
  let t = 1_000_000;
  return { now: () => t, advance: (ms) => { t += ms; }, sleep: async (ms) => { t += ms; } };
}

{
  const c = clock();
  const b = createBudget({ perMinute: 5, reservedForInteractive: 3, now: c.now, sleep: c.sleep });
  const got = Array.from({ length: 7 }, () => b.tryAcquire("k"));
  check("interactive takes the whole quota (5 of 5) and then fails at once", got.slice(0, 5).every(Boolean) && !got[5] && !got[6]);
  c.advance(59_000);
  check("still exhausted 59 s later", !b.tryAcquire("k"));
  c.advance(2_000);
  check("a fresh window after 60 s", b.tryAcquire("k"));
}

{
  const c = clock();
  const b = createBudget({ perMinute: 5, reservedForInteractive: 3, now: c.now, sleep: c.sleep });
  await b.acquireBackground("k"); await b.acquireBackground("k");
  check("background used its 2 slots", b.used("k") === 2);
  check("the interactive reserve is untouched: 3 slots still free for a person", b.tryAcquire("k") && b.tryAcquire("k") && b.tryAcquire("k") && !b.tryAcquire("k"));
}

{
  const c = clock();
  const b = createBudget({ perMinute: 5, reservedForInteractive: 3, now: c.now, sleep: c.sleep });
  await b.acquireBackground("k"); await b.acquireBackground("k");
  const before = c.now();
  const ok = await b.acquireBackground("k");     // third background call must wait for the window to move
  check("a third background call waits (about a minute), then gets its slot", ok === true && c.now() - before >= 59_000 && c.now() - before < 65_000);
}

{
  const c = clock();
  const b = createBudget({ perMinute: 5, reservedForInteractive: 3, maxBackgroundWaitMs: 10_000, now: c.now, sleep: c.sleep });
  await b.acquireBackground("k"); await b.acquireBackground("k");
  const ok = await b.acquireBackground("k");
  check("background gives up (false) rather than waiting forever", ok === false);
}

{
  const c = clock();
  const b = createBudget({ perMinute: 5, reservedForInteractive: 3, now: c.now, sleep: c.sleep });
  for (let i = 0; i < 5; i++) b.tryAcquire("a");
  check("another key has its own quota", b.tryAcquire("b") && b.used("a") === 5 && b.used("b") === 1);
}

{
  const c = clock();
  const b = createBudget({ perMinute: 5, reservedForInteractive: 5, now: c.now, sleep: c.sleep });   // reserve everything
  await b.acquireBackground("k");
  check("background always keeps at least one slot so it can never starve completely", b.used("k") === 1);
}

process.exit(failed ? 1 : 0);
