// SUKA TEA — Edge Function `verify-cashier-pin` (Batch C8.2,
// v40: + izin + gerai + force PIN + audit login + reset kick)
// Verifikasi PIN akses kasir: cocokkan PIN ke SEMUA kasir AKTIF satu
// per satu via bcrypt.compare (PIN berlaku di semua gerai — tidak ada
// outlet_id di tabel cashiers). Sukses = identitas kasir (id + nama)
// dari server, BUKAN ketikan kasir (perintah Sendy 24 Nov 13:58).
//
// v40 — sesudah cocok:
//   1. Gerai: outlet_id request HARUS ada di `cashier_outlets`
//      kasir itu, bila tidak -> reason 'outlet_not_allowed' (200).
//      PIN-nya benar jadi TIDAK dicatat ke pin_attempts (bukan
//      percobaan gagal); audit gerai hanya untuk login sukses.
//   2. Audit: insert SATU baris `cashier_login_events` per login
//      sukses (dipakai halaman Riwayat Login Owner).
//   3. Kick: `kicked_at` di-reset NULL (sesi baru bersih — Owner
//      yang kick kasir yang sedang login, bukan yang mau login).
//      Reset best-effort: gagal reset TIDAK menggagalkan login.
//   4. Jawaban ok membawa izin + gerai + flag:
//      { ok:true, cashier_id, name, can_void, can_discount,
//        can_close_shift, force_pin_change, allowed_outlets:[...] }
//      (app memakai ini untuk gate void/diskon/tutup-shift +
//      alur paksa ganti PIN).
//
// Rate limit GLOBAL: >=10 gagal dalam 10 menit TANPA filter outlet
// -> locked (PIN yang sama bisa dicoba di gerai mana pun, jadi batas
// per-gerai tidak ada gunanya). Percobaan dicatat ke pin_attempts
// dengan outlet_id yang diminta (audit) — outlet_id tidak dipakai
// untuk mencocokkan kasir, hanya untuk audit. Bila outlet_id tidak
// valid, audit memakai gerai global ...0001.
//
// POST { pin, outlet_id } ->
//   { ok:true, cashier_id, name, can_void, can_discount,
//     can_close_shift, force_pin_change, allowed_outlets } (200, cocok)
//   { ok:false, reason:'wrong'|'locked'|'not_found'|
//     'outlet_not_allowed' }  (200, tidak cocok)
//   { ok:false, error:... }                            (400/500/501)
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
const DEFAULT_OUTLET_ID = "00000000-0000-0000-0000-000000000001";

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
    const pin = String(body.pin ?? "");
    const outletRaw = String(body.outlet_id ?? "");
    const auditOutletId = UUID_RE.test(outletRaw)
      ? outletRaw
      : DEFAULT_OUTLET_ID;
    if (!/^\d{6}$/.test(pin)) {
      return json({ ok: false, error: "pin kasir harus 6 digit" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    // Rate limit GLOBAL — TANPA filter outlet (pola verify-owner-pin
    // tapi tanpa .eq('outlet_id', ...)).
    const since = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000)
      .toISOString();
    const { count } = await supabase
      .from("pin_attempts")
      .select("id", { count: "exact", head: true })
      .eq("success", false)
      .eq("purpose", "cashier")
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_FAILURES) {
      return json({ ok: false, reason: "locked" });
    }

    const { data: actives, error: readError } = await supabase
      .from("cashiers")
      .select(
        "id, name, pin_hash, can_void, can_discount, can_close_shift, " +
          "force_pin_change, kicked_at",
      )
      .eq("active", true);
    // Jangan telan error baca: SELECT yang gagal harus terlihat
    // sebagai 500, bukan disangka "belum ada kasir".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const list = (actives ?? []) as Record<string, unknown>[];
    if (list.length === 0) {
      // Belum ada kasir terdaftar — catat sebagai percobaan gagal
      // (audit + rate limit global ikut menghitungnya).
      await supabase.from("pin_attempts").insert({
        outlet_id: auditOutletId,
        success: false,
        purpose: "cashier",
      });
      return json({ ok: false, reason: "not_found" });
    }
    for (const c of list) {
      const hash = String(c["pin_hash"] ?? "");
      if (hash === "") continue;
      const match = await bcrypt.compare(pin, hash);
      if (match) {
        await supabase.from("pin_attempts").insert({
          outlet_id: auditOutletId,
          success: true,
          purpose: "cashier",
        });
        const cashierId = String(c["id"] ?? "");
        const cashierName = String(c["name"] ?? "");
        // v40 — gerai: PIN benar tapi gerai tidak dicentang untuk
        // kasir ini = tolak login (bukan percobaan gagal).
        const { data: outlets, error: outletsErr } = await supabase
          .from("cashier_outlets")
          .select("outlet_id")
          .eq("cashier_id", cashierId);
        if (outletsErr) {
          return json({ ok: false, error: outletsErr.message }, 500);
        }
        const allowedOutlets = ((outlets ?? []) as Record<string, unknown>[])
          .map((o) => String(o["outlet_id"] ?? ""))
          .filter((id) => id !== "");
        if (!allowedOutlets.includes(auditOutletId)) {
          return json({ ok: false, reason: "outlet_not_allowed" });
        }
        // v40 — audit login + reset kick (best-effort: gagal
        // tulis TIDAK menggagalkan login yang sudah terbukti).
        try {
          await supabase.from("cashier_login_events").insert({
            cashier_id: cashierId,
            cashier_name: cashierName,
            outlet_id: auditOutletId,
          });
        } catch (_) {
          // Audit gagal = login tetap jalan (lihat komentar di atas).
        }
        try {
          await supabase
            .from("cashiers")
            .update({ kicked_at: null })
            .eq("id", cashierId);
        } catch (_) {
          // Reset kick gagal = login tetap jalan.
        }
        return json({
          ok: true,
          cashier_id: cashierId,
          name: cashierName,
          can_void: c["can_void"] !== false,
          can_discount: c["can_discount"] !== false,
          can_close_shift: c["can_close_shift"] !== false,
          force_pin_change: c["force_pin_change"] === true,
          allowed_outlets: allowedOutlets,
        });
      }
    }
    await supabase.from("pin_attempts").insert({
      outlet_id: auditOutletId,
      success: false,
      purpose: "cashier",
    });
    return json({ ok: false, reason: "wrong" });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
