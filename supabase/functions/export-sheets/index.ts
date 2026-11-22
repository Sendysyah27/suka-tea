// SUKA TEA — Edge Function `export-sheets` (SKELETON)
// Tugas: setelah tutup kasir, kirim ringkasan + baris transaksi ke Google
// Sheets (tab: Ringkasan Harian, Transaksi, Stok/Bahan, Pengeluaran).
// Sheets HANYA untuk laporan/export — Supabase tetap sumber kebenaran.
//
// Secret yang dibutuhkan (via `supabase secrets set`, JANGAN di repo):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GOOGLE_SERVICE_ACCOUNT_JSON,
//   SHEETS_SPREADSHEET_ID
// Status: skeleton — mengembalikan 501 sampai kredensial Sheets diisi.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const sheetsCreds = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON") ?? "";
    const spreadsheetId = Deno.env.get("SHEETS_SPREADSHEET_ID") ?? "";

    if (!supabaseUrl || !serviceKey || !sheetsCreds || !spreadsheetId) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: "export-sheets belum dikonfigurasi (secret Sheets belum diisi)",
        }),
        { status: 501, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const body = await req.json().catch(() => ({}));
    const shiftId = String(body.shift_id ?? "");
    const outletId = String(body.outlet_id ?? "");
    if (!shiftId || !outletId) {
      return new Response(JSON.stringify({ ok: false, error: "shift_id + outlet_id wajib" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const supabase = createClient(supabaseUrl, serviceKey);
    // TODO (M4): baca v_daily_summary + transaksi shift ini, lalu append ke
    // Sheets API v4 dengan service-account JWT. Sengaja belum diimplementasi
    // penuh sebelum proyek Supabase + sheet Owner benar-benar dibuat.
    const { data } = await supabase
      .from("transactions")
      .select("id,total,payment_method,created_at")
      .eq("shift_id", shiftId)
      .limit(1);
    void data;

    return new Response(JSON.stringify({ ok: false, error: "TODO: append ke Sheets" }),
      { status: 501, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: String(e) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
