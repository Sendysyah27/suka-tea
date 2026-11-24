// SUKA TEA — Edge Function `get-qris-payload` (Batch C8)
// Baca payload QRIS statis merchant (TERENKRIPSI) dari Supabase.
//
// Kenapa lewat Edge Function: `app_settings` (migrasi 002) RLS-nya
// nyala dengan SATU policy "owner kelola pengaturan"
// (is_outlet_owner via auth.uid()) — app TIDAK PERNAH login Supabase
// Auth, jadi SELECT langsung pakai anon key SELALU ditolak server
// (payload tidak pernah bisa dimuat ulang sesudah restart).
// Baca dilakukan service_role yang melewati RLS.
//
// TANPA cek PIN: kasir butuh payload ini tiap kali generate QR
// jualan, dan PIN Owner tidak ada di tangan kasir. Yang dikembalikan
// HANYA ciphertext (`enc:v1:`) — tidak berguna tanpa kunci enkripsi
// perangkat (Android Keystore, TIDAK PERNAH ikut ke Supabase).
// JWT ON (default, sama seperti sync-sales): pemanggil harus membawa
// JWT proyek yang valid (anon key).
//
// POST { outlet_id } ->
//   { ok:true, set:true, value:"enc:v1:..." }  (200, sudah diatur)
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
    if (!UUID_RE.test(outletId)) {
      return json({ ok: false, error: "outlet_id (UUID) wajib" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: row, error: readError } = await supabase
      .from("app_settings")
      .select("value")
      .eq("outlet_id", outletId)
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
