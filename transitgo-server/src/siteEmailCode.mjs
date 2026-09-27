// Email 驗證碼借用 yayalin.com 網站既有的機制（同一封「交通即時查 TransitGo」品牌信、同一套
// Resend 寄信基礎設施），這個後端完全不用自己接寄信服務。呼叫的是網站 Supabase 上兩支公開 RPC：
//   request_email_code(email, purpose)  — 寄信（purpose='app' 沿用 App 既有的信件外觀）
//   verify_email_code(email, purpose, code) — 這個後端專用的新函式（見 yayalin repo
//     supabase/add_verify_email_code_rpc.sql），只回傳「這組驗證碼對不對」，不會洩漏任何機密。
// 用的是網站本來就公開的 publishable key（不是機密，前端本來就會用到），可用環境變數覆寫。

const SUPABASE_URL = process.env.SITE_SUPABASE_URL || "https://lvxmefggedsozhrdjkqf.supabase.co";
const SUPABASE_ANON_KEY = process.env.SITE_SUPABASE_ANON_KEY || "sb_publishable_M30HHIufBozr-_BnGASdSQ_37nL5aWq";
const PURPOSE = "app";

async function rpc(name, body, fetchImpl = fetch) {
  const res = await fetchImpl(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: SUPABASE_ANON_KEY, authorization: `Bearer ${SUPABASE_ANON_KEY}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  return res;
}

/** Sends the 6-digit code. Returns true on success; false covers "too many requests" and any
 * other failure alike — callers should show the same generic "寄送失敗" either way. */
export async function requestSiteEmailCode(email, fetchImpl = fetch) {
  try {
    const res = await rpc("request_email_code", { p_email: email, p_purpose: PURPOSE }, fetchImpl);
    return res.ok;
  } catch {
    return false;
  }
}

/** Checks (and, on success, consumes) a code. `false` covers wrong code, expired, already used,
 * and any network/server failure — this is a yes/no gate, never a place to leak which. */
export async function verifySiteEmailCode(email, code, fetchImpl = fetch) {
  try {
    const res = await rpc("verify_email_code", { p_email: email, p_purpose: PURPOSE, p_code: code }, fetchImpl);
    if (!res.ok) return false;
    const body = await res.json().catch(() => null);
    return body === true;
  } catch {
    return false;
  }
}
