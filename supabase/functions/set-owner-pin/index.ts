// SUKA TEA — Edge Function `set-owner-pin`
// Atur / ubah PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026): SATU PIN untuk
// semua gerai. Hash bcrypt disimpan di app_settings (key owner_pin_hash)
// SELALU di baris outlet global (...0001); outlet_id dari client
// DIABAIKAN. PIN lama TIDAK PERNAH dikirim kembali ke client.
//
// - Belum ada hash  -> atur langsung (setup pertama kali).
// - Sudah ada hash -> current_pin wajib dan harus cocok dulu.
// - PIN baru di-hash bcrypt (cost 10) sebelum disimpan.
//
// Secret yang dibutuhkan (otomatis tersedia di Edge Functions):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// POST { current_pin?, new_pin } (outlet_id diterima tapi diabaikan) -> { ok, error? }

import { createClient } from "jsr:@supabase/supabase-js@2";
// bcryptjs = modul CommonJS. `import * as bcrypt` di Deno memberi namespace
// yang fungsinya ada di `.default`, jadi `bcrypt.hash` = undefined
// (TypeError, 500 — akar gagal buat PIN 23 Nov 2026). Default import =
// module.exports, jadi `bcrypt.hash` / `bcrypt.compare` jalan.
import bcrypt from "npm:bcryptjs@2.4.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
    const currentPin = String(body.current_pin ?? "");
    const newPin = String(body.new_pin ?? "");
    if (!/^\d{6}$/.test(newPin)) {
      return json({ ok: false, error: "PIN baru 6 digit wajib" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);
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

    if (hash) {
      // PIN sudah ada: PIN lama wajib cocok dulu.
      if (!/^\d{6}$/.test(currentPin)) {
        return json({ ok: false, error: "PIN lama wajib diisi" }, 400);
      }
      const match = await bcrypt.compare(currentPin, hash);
      if (!match) {
        return json({ ok: false, error: "PIN lama salah" }, 403);
      }
    }

    const newHash = await bcrypt.hash(newPin, 10);
    const { error } = await supabase.from("app_settings").upsert(
      { outlet_id: outletId, key: "owner_pin_hash", value: newHash },
      { onConflict: "outlet_id,key" },
    );
    if (error) {
      return json({ ok: false, error: error.message }, 500);
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
