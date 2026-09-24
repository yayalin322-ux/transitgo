/**
 * Express 4 does not catch a rejected promise from an `async` route handler, so one failing database query used to
 * become an unhandled rejection and take the whole process down (every user's request with it). `guardAsyncRoutes`
 * wraps every handler registered through app.get/post/put/patch/delete so a rejection is passed to `next(err)`
 * instead, and `errorResponder` turns that into a plain 500 for the one request that failed.
 */
const METHODS = ["get", "post", "put", "patch", "delete"];

function wrap(fn) {
  if (typeof fn !== "function" || fn.length === 4) return fn;   // arity 4 = an error handler, leave it alone
  const wrapped = function (req, res, next) {
    let out;
    try { out = fn.call(this, req, res, next); } catch (e) { return next(e); }
    if (out && typeof out.catch === "function") out.catch(next);
    return out;
  };
  Object.defineProperty(wrapped, "length", { value: fn.length });
  return wrapped;
}

export function guardAsyncRoutes(app) {
  for (const m of METHODS) {
    const original = app[m].bind(app);
    app[m] = (path, ...handlers) => {
      // app.get("setting") (one string argument) is Express's settings getter, not a route.
      if (m === "get" && handlers.length === 0) return original(path);
      return original(path, ...handlers.flat().map(wrap));
    };
  }
  return app;
}

export function errorResponder(log = console.error) {
  return (err, req, res, next) => {
    log(`[transitgo-server] ${req.method} ${req.path} failed: ${err?.message ?? err}`);
    if (res.headersSent) return next(err);
    res.status(500).json({ error: "internal_error" });
  };
}
