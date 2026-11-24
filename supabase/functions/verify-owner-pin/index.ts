// SUKA TEA — Edge Function `verify-owner-pin`
// Verifikasi PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026): SATU PIN untuk
// semua gerai. Hash bcrypt di app_settings (key owner_pin_hash) SELALU
// dibaca dari baris outlet global (...0001); outlet_id dari client
// DIABAIKAN. Hash TIDAK PERNAH keluar dari server.
//
// Secret yang dibutuhkan (otomatis tersedia di Edge Functions):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// POST { pin } (outlet_id diterima tapi diabaikan — PIN global) -> { ok, reason? }
//   ok:true                  PIN cocok
//   ok:false reason:'wrong'  PIN salah
//   ok:false reason:'not_set'  PIN belum pernah diatur (setup pertama)
//   ok:false reason:'locked' terlalu banyak percobaan gagal (server)
//   ok:false error:...       input tidak valid / server error

import { createClient } from "jsr:@supabase/supabase-js@2";
// bcryptjs = modul CommonJS. `import * as bcrypt` di Deno memberi namespace
// yang fungsinya ada di `.default`, jadi `bcrypt.compare` = undefined
// (TypeError, 500 — bug laten yang sama dengan set-owner-pin, 23 Nov 2026:
// verify lolos selama ini hanya karena PIN belum pernah diatur, jadi
// kodenya balik `not_set` SEBELUM menyentuh bcrypt). Default import =
// module.exports, jadi `bcrypt.compare` jalan.
import bcrypt from "npm:bcryptjs@2.4.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_FAILURES = 10;
const WINDOW_MINUTES = 10;

// Baris PIN Owner GLOBAL — satu PIN untuk semua gerai (koreksi Sendy
// 24 Nov 2026). PIN yang dulu dibuat di Gerai 1 tersimpan di baris ini.
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
    // PIN Owner GLOBAL — outlet_id dari client diabaikan.
    const outletId = GLOBAL_OUTLET_ID;
    const pin = String(body.pin ?? "");
    if (!/^\d{6}$/.test(pin)) {
      return json({ ok: false, error: "PIN 6 digit wajib" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    // Rate limit server: >=10 gagal dalam 10 menit -> kunci.
    const since = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000).toISOString();
    const { count } = await supabase
      .from("pin_attempts")
      .select("id", { count: "exact", head: true })
      .eq("outlet_id", outletId)
      .eq("success", false)
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_FAILURES) {
      return json({ ok: false, reason: "locked" });
    }

    const { data: row, error: readError } = await supabase
      .from("app_settings")
      .select("value")
      .eq("outlet_id", outletId)
      .eq("key", "owner_pin_hash")
      .maybeSingle();
    // Jangan telan error baca: SELECT yang gagal (mis. GRANT belum ada)
    // harus terlihat sebagai 500, bukan disangka "PIN belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const hash = (row as { value?: string } | null)?.value;
    if (!hash) {
      return json({ ok: false, reason: "not_set" });
    }

    const match = await bcrypt.compare(pin, hash);
    await supabase.from("pin_attempts").insert({
      outlet_id: outletId,
      success: match,
    });
    if (!match) {
      return json({ ok: false, reason: "wrong" });
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
