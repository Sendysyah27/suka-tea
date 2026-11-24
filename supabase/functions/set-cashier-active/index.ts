// SUKA TEA — Edge Function `set-cashier-active` (Batch C8.2)
// Nonaktifkan / aktifkan lagi satu kasir. Kasir nonaktif PIN-nya
// tidak bisa dipakai login (verify-cashier-pin hanya mencocokkan
// kasir aktif). Hanya Owner yang boleh (bukti = PIN Owner gerai
// itu, diverifikasi server-side).
//
// POST { outlet_id, owner_pin, cashier_id, active } -> { ok:true }
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:'cashier_not_found'|... }  (400/500/501)
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
    const outletId = String(body.outlet_id ?? "");
    const ownerPin = String(body.owner_pin ?? "");
    const cashierId = String(body.cashier_id ?? "");
    const active = body.active;
    if (
      !UUID_RE.test(outletId) ||
      !/^\d{6}$/.test(ownerPin) ||
      !UUID_RE.test(cashierId) ||
      typeof active !== "boolean"
    ) {
      return json(
        {
          ok: false,
          error: "outlet_id + cashier_id (UUID) + owner_pin 6 digit + active (bool) wajib",
        },
        400,
      );
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    // --- Bukti Owner: verifikasi PIN (pola set-qris-payload) ---
    const since = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000)
      .toISOString();
    const { count } = await supabase
      .from("pin_attempts")
      .select("id", { count: "exact", head: true })
      .eq("outlet_id", outletId)
      .eq("success", false)
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_FAILURES) {
      return json({ ok: false, reason: "locked" }, 403);
    }
    const { data: row, error: readError } = await supabase
      .from("app_settings")
      .select("value")
      .eq("outlet_id", outletId)
      .eq("key", "owner_pin_hash")
      .maybeSingle();
    // Jangan telan error baca: SELECT yang gagal harus terlihat
    // sebagai 500, bukan disangka "PIN belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const hash = (row as { value?: string } | null)?.value;
    if (!hash) {
      return json({ ok: false, reason: "not_set" }, 403);
    }
    const match = await bcrypt.compare(ownerPin, hash);
    await supabase.from("pin_attempts").insert({
      outlet_id: outletId,
      success: match,
    });
    if (!match) {
      return json({ ok: false, reason: "wrong" }, 403);
    }

    const { data: target, error: targetErr } = await supabase
      .from("cashiers")
      .select("id")
      .eq("id", cashierId)
      .maybeSingle();
    if (targetErr) {
      return json({ ok: false, error: targetErr.message }, 500);
    }
    if (target == null) {
      return json({ ok: false, error: "cashier_not_found" }, 400);
    }
    const { error: updErr } = await supabase
      .from("cashiers")
      .update({ active })
      .eq("id", cashierId);
    if (updErr) {
      return json({ ok: false, error: updErr.message }, 500);
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
