// SUKA TEA — Edge Function `change-own-cashier-pin` (BARU, Batch v40)
// Kasir mengganti PIN-nya SENDIRI (alur Paksa ganti PIN, F7):
// PIN lama dibuktikan dulu, PIN baru tidak boleh sama dengan PIN
// kasir aktif LAIN (kasir ini dikecualikan — PIN lama boleh dipakai
// lagi, sama seperti set-cashier-pin). Sukses = `force_pin_change`
// dibersihkan (flag tidak lagi menahan login berikutnya).
// Rate limit GLOBAL purpose 'cashier' — sama seperti
// verify-cashier-pin (>=10 gagal dalam 10 menit -> locked).
//
// POST { outlet_id, cashier_pin, new_pin } ->
//   { ok:true }  (200, berhasil)
//   { ok:false, reason:'wrong'|'locked'|'not_found' }  (200, gagal)
//   { ok:false, error:'pin_taken'|... }  (400/500/501)
// JWT OFF — PIN adalah auth-nya (sama seperti EF PIN lain).
//
// Secret yang dibutuhkan (otomatis tersedia di Edge Functions):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "jsr:@supabase/supabase-js@2";
// bcryptjs = modul CommonJS — default import, JANGAN `import *`
// (fungsinya ada di `.default`, `bcrypt.compare` jadi undefined —
// bug 500 yang sama dengan set-owner-pin/verify-owner-pin, 23 Nov 2026).
import bcrypt from "npm:bcryptjs@2.4.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_FAILURES = 10;
const WINDOW_MINUTES = 10;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026, Batch C10.1): SATU
// PIN untuk semua gerai — audit kasir memakai outlet_id request
// bila valid, kalau tidak gerai global ...0001 (pola
// verify-cashier-pin).
const GLOBAL_OUTLET_ID = "00000000-0000-0000-0000-000000000001";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!supabaseUrl || !serviceKey) {
      return json({ ok: false, error: "Edge Function belum dikonfigurasi" }, 501);
    }
    const body = await req.json().catch(() => ({}));
    const outletIdRaw = String(body.outlet_id ?? "");
    const cashierPin = String(body.cashier_pin ?? "");
    const newPin = String(body.new_pin ?? "");
    if (!/^\d{6}$/.test(cashierPin) || !/^\d{6}$/.test(newPin)) {
      return json(
        { ok: false, error: "cashier_pin + new_pin 6 digit wajib" },
        400,
      );
    }
    const auditOutletId = UUID_RE.test(outletIdRaw)
      ? outletIdRaw
      : GLOBAL_OUTLET_ID;
    const supabase = createClient(supabaseUrl, serviceKey);

    // --- Rate limit GLOBAL (pola verify-cashier-pin) ---
    const since = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000)
      .toISOString();
    const { count } = await supabase
      .from("pin_attempts")
      .select("id", { count: "exact", head: true })
      .eq("success", false)
      .eq("purpose", "cashier")
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_FAILURES) {
      return json({ ok: false, reason: "locked" });
    }

    const { data: actives, error: readError } = await supabase
      .from("cashiers")
      .select("id, pin_hash")
      .eq("active", true);
    // Jangan telan error baca: SELECT yang gagal harus terlihat
    // sebagai 500, bukan disangka "belum ada kasir".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const list = (actives ?? []) as Record<string, unknown>[];
    if (list.length === 0) {
      await supabase.from("pin_attempts").insert({
        outlet_id: auditOutletId,
        success: false,
        purpose: "cashier",
      });
      return json({ ok: false, reason: "not_found" });
    }
    // PIN lama HARUS cocok dengan salah satu kasir aktif.
    let selfId = "";
    for (const c of list) {
      const hash = String(c["pin_hash"] ?? "");
      if (hash === "") continue;
      if (await bcrypt.compare(cashierPin, hash)) {
        selfId = String(c["id"] ?? "");
        break;
      }
    }
    if (selfId === "") {
      await supabase.from("pin_attempts").insert({
        outlet_id: auditOutletId,
        success: false,
        purpose: "cashier",
      });
      return json({ ok: false, reason: "wrong" });
    }
    // PIN baru tidak boleh dipakai kasir aktif LAIN.
    for (const c of list) {
      if (String(c["id"] ?? "") === selfId) continue;
      const otherHash = String(c["pin_hash"] ?? "");
      if (otherHash !== "" && (await bcrypt.compare(newPin, otherHash))) {
        return json({ ok: false, error: "pin_taken" }, 400);
      }
    }
    const newHash = await bcrypt.hash(newPin, 10);
    const { error: updErr } = await supabase
      .from("cashiers")
      .update({ pin_hash: newHash, force_pin_change: false })
      .eq("id", selfId);
    if (updErr) {
      return json({ ok: false, error: updErr.message }, 500);
    }
    await supabase.from("pin_attempts").insert({
      outlet_id: auditOutletId,
      success: true,
      purpose: "cashier",
    });
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
