// SUKA TEA — Edge Function `pin-status`
// Cek apakah PIN Owner sudah diatur untuk satu outlet — tanpa membocorkan
// hash atau nilai PIN. Dipakai halaman Pengaturan untuk menampilkan status.
//
// POST { outlet_id } -> { ok:true, set:boolean }

import { createClient } from "jsr:@supabase/supabase-js@2";

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
    if (!outletId) {
      return json({ ok: false, error: "outlet_id wajib" }, 400);
    }
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
