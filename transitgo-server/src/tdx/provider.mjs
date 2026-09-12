/**
 * TransitDataProvider — the interface every real data source (TDX today, maybe a raw
 * GTFS feed or GTFS-Realtime later) implements. Normalizer and Graph Builder code
 * against this shape, never against a specific source's raw JSON — that's what keeps
 * TDX's field names and quirks out of the Routing Engine.
 *
 * Every method returns data already in TDX's raw shape (PascalCase fields etc.) — this
 * class only draws the *boundary*; src/tdx/normalizer.mjs does the actual field mapping
 * into the internal gtfs_* model. A future GTFSProvider would return GTFS-shaped rows
 * straight from a zip instead, and use a different (much thinner) normalizer.
 */
export class TransitDataProvider {
  /** @returns {Promise<object[]>} raw stop/station records */
  async getStops(_scope) { throw new Error("not implemented"); }
  /** @returns {Promise<object[]>} raw route records */
  async getRoutes(_scope) { throw new Error("not implemented"); }
  /** @returns {Promise<object[]>} raw trip + stop-time records for a route that has a real timetable */
  async getTimetable(_scope, _routeName, _date) { throw new Error("not implemented"); }
  /** @returns {Promise<object[]>} raw headway/frequency bands for a route with no fixed timetable */
  async getFrequencies(_scope, _routeName) { throw new Error("not implemented"); }
  /** @returns {Promise<object[]>} service calendar records, where the source has them */
  async getServices(_scope) { throw new Error("not implemented"); }
  /** @returns {Promise<object[]>} real-time delay/position data, where available */
  async getRealtimeData(_scope) { throw new Error("not implemented"); }
}
