// SUKA TEA — Edge Function `get-qris-payload` (Batch C8.2 — QRIS GLOBAL)
// Baca payload QRIS statis merchant (PLAINTEXT) dari Supabase.
//
// Kenapa lewat Edge Function: `app_settings` (migrasi 002) RLS-nya
// nyala dengan SATU policy "owner kelola pengaturan"
// (is_outlet_owner via auth.uid()) — app TIDAK PERNAH login Supabase
// Auth, jadi SELECT langsung pakai anon key SELALU ditolak server
// (payload tidak pernah bisa dimuat ulang sesudah restart).
// Baca dilakukan service_role yang melewati RLS.
//
// Batch C8.2: payload kini SATU untuk SEMUA gerai + SEMUA device.
// SELALU baca baris global ...0001 (outlet_id pemanggil DIABAIKAN).
// Nilai dikembalikan PLAINTEXT apa adanya — kasir butuh payload ini
// tiap kali generate QR jualan, dan PIN Owner tidak ada di tangan
// kasir. Bila nilai tersimpan masih ciphertext lama `enc:v1:`
// (Batch C8), dikembalikan apa adanya; app yang menandainya sebagai
// "perlu simpan ulang" (tidak dibuka — kunci per-perangkat sudah
// tidak ada).
// JWT ON (default, sama seperti sync-sales): pemanggil harus membawa
// JWT proyek yang valid (anon key).
//
// POST { outlet_id } ->
//   { ok:true, set:true, value:"000201..." }  (200, sudah diatur)
//   { ok:true, set:false, value:null }         (200, belum diatur)
//   { ok:false, error:... }                     (400/500/501)
//
// Secret yang dibutuhkan (otomatis tersedia di Edge Functions):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
    // outlet_id pemanggil DIABAIKAN (Batch C8.2: satu payload global)
    // — baca body hanya supaya request tanpa body tidak error.
    await req.json().catch(() => ({}));

    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: row, error: readError } = await supabase
      .from("app_settings")
      .select("value")
      .eq("outlet_id", GLOBAL_OUTLET_ID)
      .eq("key", "qris_static_payload")
      .maybeSingle();
    // Jangan telan error baca: SELECT yang gagal (mis. GRANT belum ada)
    // harus terlihat sebagai 500, bukan disangka "belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const value = (row as { value?: string } | null)?.value;
    if (value == null) {
      return json({ ok: true, set: false, value: null });
    }
    return json({ ok: true, set: true, value });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
