import { shareLinkUrl, cleanPublicOrigin, viewerIp } from "../src/publicUrl.mjs";
let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

check("without PUBLIC_SHARE_ORIGIN the link is on this server, as before", shareLinkUrl({ token: "T", publicOrigin: "", requestOrigin: "https://macbook.ts.net" }) === "https://macbook.ts.net/s/T");
check("with it, the link is on the public site", shareLinkUrl({ token: "T", publicOrigin: "https://yayalin.com/app", requestOrigin: "https://macbook.ts.net" }) === "https://yayalin.com/app/s/T");
check("a trailing slash does not double up", shareLinkUrl({ token: "T", publicOrigin: "https://yayalin.com/app/", requestOrigin: "x" }) === "https://yayalin.com/app/s/T");

check("cleanPublicOrigin keeps a good https origin+path", cleanPublicOrigin(" https://yayalin.com/app/ ") === "https://yayalin.com/app" && cleanPublicOrigin("https://yayalin.com") === "https://yayalin.com");
check("cleanPublicOrigin ignores http, junk, queries and empty", cleanPublicOrigin("http://yayalin.com/app") === "" && cleanPublicOrigin("not a url") === "" && cleanPublicOrigin("https://x.com/?a=1") === "" && cleanPublicOrigin("") === "" && cleanPublicOrigin(undefined) === "");

check("X-Viewer-IP (set by the proxy) wins over X-Forwarded-For", viewerIp({ "x-viewer-ip": "203.0.113.9", "x-forwarded-for": "10.0.0.1, 10.0.0.2" }, "127.0.0.1") === "203.0.113.9");
check("without it, the first X-Forwarded-For entry is used", viewerIp({ "x-forwarded-for": "198.51.100.4, 10.0.0.2" }, "127.0.0.1") === "198.51.100.4");
check("without either, the socket address", viewerIp({}, " 127.0.0.1 ") === "127.0.0.1");
check("a junk X-Viewer-IP is ignored, not trusted", viewerIp({ "x-viewer-ip": "<script>", "x-forwarded-for": "198.51.100.4" }, "127.0.0.1") === "198.51.100.4");
check("IPv6 works", viewerIp({ "x-viewer-ip": "2001:db8::1" }, "127.0.0.1") === "2001:db8::1");
process.exit(failed ? 1 : 0);
