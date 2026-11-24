// SUKA TEA — Edge Function `pin-status`
// Cek apakah PIN Owner GLOBAL sudah diatur — tanpa membocorkan
// hash atau nilai PIN. Dipakai halaman Pengaturan untuk menampilkan status.
// GLOBAL (koreksi Sendy 24 Nov 2026): satu PIN untuk semua gerai —
// selalu cek baris outlet global (...0001); outlet_id dari client
// DIABAIKAN.
//
// POST {} (outlet_id diterima tapi diabaikan) -> { ok:true, set:boolean }

import { createClient } from "jsr:@supabase/supabase-js@2";

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
    // PIN Owner GLOBAL — outlet_id dari client diabaikan.
    const outletId = GLOBAL_OUTLET_ID;
    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: row } = await supabase
      .from("app_settings")
      .select("id")
      .eq("outlet_id", outletId)
      .eq("key", "owner_pin_hash")
      .maybeSingle();
    return json({ ok: true, set: row != null });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
