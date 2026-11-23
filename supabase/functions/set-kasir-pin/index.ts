// SUKA TEA — Edge Function `set-kasir-pin` (Batch C4, BELUM DI-DEPLOY)
// Atur / ubah PIN Kasir satu gerai (6 digit). Hash bcrypt disimpan di
// app_settings (key kasir_pin_hash). PIN lama TIDAK PERNAH dikirim kembali
// ke client. Pola sama dengan set-owner-pin (default import bcrypt —
// lihat catatan di bawah).
//
// Bukti yang diterima (salah satu wajib bila PIN Kasir SUDAH ada):
// - current_pin: PIN Kasir lama (kasir sendiri yang ubah), atau
// - owner_pin:   PIN Owner gerai itu (Owner yang ubah dari Ubah Gerai —
//                diverifikasi server terhadap owner_pin_hash).
// Bila PIN Kasir belum pernah diatur, tidak perlu bukti apa pun (setup
// pertama — halaman Ubah Gerai tetap minta PIN Owner dulu di sisi app).
//
// Secret yang dibutuhkan (otomatis tersedia di Edge Functions):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// POST { outlet_id, current_pin?, owner_pin?, new_pin } -> { ok, error? }
//
// DEPLOY (dashboard Supabase > Edge Functions > Deploy new function):
//   supabase functions deploy set-kasir-pin --no-verify-jwt

import { createClient } from "jsr:@supabase/supabase-js@2";
// bcryptjs = modul CommonJS. `import * as bcrypt` di Deno memberi namespace
// yang fungsinya ada di `.default`, jadi `bcrypt.hash` = undefined
// (TypeError, 500 — akar gagal buat PIN Owner 23 Nov 2026). Default
// import = module.exports, jadi `bcrypt.hash` / `bcrypt.compare` jalan.
import bcrypt from "npm:bcryptjs@2.4.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
    const currentPin = String(body.current_pin ?? "");
    const ownerPin = String(body.owner_pin ?? "");
    const newPin = String(body.new_pin ?? "");
    if (!outletId || !/^\d{6}$/.test(newPin)) {
      return json({ ok: false, error: "outlet_id + PIN baru 6 digit wajib" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: row, error: readError } = await supabase
      .from("app_settings")
      .select("value")
      .eq("outlet_id", outletId)
      .eq("key", "kasir_pin_hash")
      .maybeSingle();
    // Jangan telan error baca: SELECT yang gagal (mis. GRANT belum ada)
    // harus terlihat sebagai 500, bukan disangka "PIN belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const hash = (row as { value?: string } | null)?.value;

    if (hash) {
      // PIN Kasir sudah ada: salah satu bukti wajib cocok dulu.
      if (/^\d{6}$/.test(currentPin)) {
        const match = await bcrypt.compare(currentPin, hash);
        if (!match) {
          return json({ ok: false, error: "PIN Kasir lama salah" }, 403);
        }
      } else if (/^\d{6}$/.test(ownerPin)) {
        const { data: ownerRow, error: ownerReadError } = await supabase
          .from("app_settings")
          .select("value")
          .eq("outlet_id", outletId)
          .eq("key", "owner_pin_hash")
          .maybeSingle();
        if (ownerReadError) {
          return json({ ok: false, error: ownerReadError.message }, 500);
        }
        const ownerHash = (ownerRow as { value?: string } | null)?.value;
        if (!ownerHash) {
          return json({ ok: false, error: "PIN Owner belum diatur" }, 403);
        }
        const ownerMatch = await bcrypt.compare(ownerPin, ownerHash);
        if (!ownerMatch) {
          return json({ ok: false, error: "PIN Owner salah" }, 403);
        }
      } else {
        return json(
          { ok: false, error: "PIN Kasir lama / PIN Owner wajib diisi" },
          400,
        );
      }
    }

    const newHash = await bcrypt.hash(newPin, 10);
    const { error } = await supabase.from("app_settings").upsert(
      { outlet_id: outletId, key: "kasir_pin_hash", value: newHash },
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
