// SUKA TEA — Edge Function `set-qris-payload` (Batch C8.2 — QRIS GLOBAL)
// Simpan payload QRIS statis merchant (PLAINTEXT) ke Supabase.
//
// Kenapa lewat Edge Function, bukan upsert langsung dari app:
// `app_settings` (migrasi 002) RLS-nya nyala dengan SATU policy
// "owner kelola pengaturan" (is_outlet_owner via auth.uid()) —
// sedangkan app TIDAK PERNAH login Supabase Auth, jadi upsert/select
// langsung pakai anon key SELALU ditolak server. Buktinya 24 Nov 2026:
// app_settings cuma berisi owner_pin_hash + kasir_pin_hash, TIDAK ADA
// baris qris_static_payload — payload cuma hidup di memori HP dan
// hilang tiap restart. Di sini bukti Owner adalah PIN Owner gerai itu
// (dibuktikan server-side dengan bcrypt, sama seperti
// upload-product-photo) + tulis dilakukan service_role yang melewati
// RLS. JWT OFF — PIN adalah auth-nya (sama seperti EF PIN lain).
//
// Batch C8.2: payload kini SATU untuk SEMUA gerai + SEMUA device.
// Nilai disimpan PLAINTEXT, SELALU di baris outlet global ...0001
// (outlet_id pemanggil DIABAIKAN untuk baris tulis DAN verifikasi
// PIN — PIN Owner GLOBAL, selalu baris ...0001, Batch C10.1).
// Enkripsi per-perangkat (Batch C2/C8, format `enc:v1:`) DIHAPUS:
// kunci cuma ada di satu HP, jadi payload yang disimpan di POVA
// tidak bisa dipakai POCO ("belum di setting", 24 Nov 2026).
// Trade-off jujur (disetujui Sendy 24 Nov 13:54): siapa pun yang
// memegang anon key bisa membaca payload ini lewat get-qris-payload;
// praktis risikonya rendah — payload statis hanya bisa membuat QR
// yang membayar KE rekening merchant, tidak bisa mengalihkan uang.
//
// POST { outlet_id, pin, value } -> { ok:true }  (200)
// POST { outlet_id, pin, delete:true } -> { ok:true }  (200, hapus baris)
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:... }  (400/500/501)
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
// Payload QRIS statis ~500 karakter; batas menahan junk raksasa
// yang tak sengaja.
const MAX_VALUE_CHARS = 8192;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Baris GLOBAL: satu payload untuk semua gerai + semua device.
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
    const pin = String(body.pin ?? "");
    const value = String(body.value ?? "");
    const isDelete = body.delete === true;
    if (!UUID_RE.test(outletIdRaw) || !/^\d{6}$/.test(pin)) {
      return json(
        { ok: false, error: "outlet_id (UUID) + pin Owner 6 digit wajib" },
        400,
      );
    }
    if (!isDelete) {
      // Fail closed: HANYA plaintext QRIS statis yang boleh disimpan
      // (diawali "000201" = Payload Format Indicator "01").
      if (!value.startsWith("000201") || value.length > MAX_VALUE_CHARS) {
        return json(
          {
            ok: false,
            error: "value harus payload QRIS statis (diawali 000201, maks 8192 karakter)",
          },
          400,
        );
      }
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    // PIN Owner GLOBAL (Batch C10.1) — outlet_id pemanggil
    // diabaikan untuk verifikasi PIN + rate limit.
    const outletId = GLOBAL_OUTLET_ID;

    // --- Bukti Owner: verifikasi PIN (pola upload-product-photo) ---
    const since = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000)
      .toISOString();
    const { count } = await supabase
      .from("pin_attempts")
      .select("id", { count: "exact", head: true })
      .eq("outlet_id", outletId)
      .eq("success", false)
      .eq("purpose", "owner")
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
    // Jangan telan error baca: SELECT yang gagal (mis. GRANT belum ada)
    // harus terlihat sebagai 500, bukan disangka "PIN belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const hash = (row as { value?: string } | null)?.value;
    if (!hash) {
      return json({ ok: false, reason: "not_set" }, 403);
    }
    const match = await bcrypt.compare(pin, hash);
    await supabase.from("pin_attempts").insert({
      outlet_id: outletId,
      success: match,
      purpose: "owner",
    });
    if (!match) {
      return json({ ok: false, reason: "wrong" }, 403);
    }

    // --- Tulis (service_role melewati RLS) — SELALU baris global ---
    if (isDelete) {
      const { error } = await supabase
        .from("app_settings")
        .delete()
        .eq("outlet_id", GLOBAL_OUTLET_ID)
        .eq("key", "qris_static_payload");
      if (error) {
        return json({ ok: false, error: error.message }, 500);
      }
      return json({ ok: true });
    }
    const { error } = await supabase.from("app_settings").upsert(
      { outlet_id: GLOBAL_OUTLET_ID, key: "qris_static_payload", value },
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
