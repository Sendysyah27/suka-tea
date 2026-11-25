// SUKA TEA — Edge Function `set-cashier-settings` (BARU, Batch v40)
// Ubah pengaturan kontrol kasir secara parsial (Detail Kasir,
// frame 28): izin void/diskon/tutup-shift, paksa ganti PIN, gerai
// yang diizinkan, dan paksa keluar (kick). Hanya Owner yang boleh
// (bukti = PIN Owner gerai itu, diverifikasi server-side).
// Setiap field opsional; hanya field yang ADA yang diubah.
//   can_void / can_discount / can_close_shift / force_pin_change:
//     boolean -> kolom cashiers yang sama.
//   outlet_ids: array UUID -> ganti SELURUH isi `cashier_outlets`
//     kasir ini (hapus semua + insert baru). HARUS non-empty
//     (-> 400 'outlets_empty') dan semua UUID HARUS salah satu
//     dari 4 gerai yang ada (-> 400 'outlet_unknown').
//   kicked: true -> kicked_at = now (kick — kunci sesi kasir yang
//     sedang login di HP-nya); false -> kicked_at = NULL (batal kick).
//
// POST { outlet_id, owner_pin, cashier_id, can_void?, can_discount?,
//   can_close_shift?, force_pin_change?, outlet_ids?, kicked? }
//   -> { ok:true }
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:'cashier_not_found'|'outlets_empty'|
//     'outlet_unknown'|'nothing_to_update'|... }  (400/500/501)
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

// PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026, Batch C10.1): SATU
// PIN untuk semua gerai — hash + rate limit selalu baris global
// (...0001); outlet_id dari client hanya divalidasi formatnya,
// tidak dipakai untuk lookup PIN.
const GLOBAL_OUTLET_ID = "00000000-0000-0000-0000-000000000001";

// 4 gerai SUKA TEA (migrasi 006) — satu-satunya outlet_id yang
// boleh masuk `cashier_outlets`.
const KNOWN_OUTLETS = [
  "00000000-0000-0000-0000-000000000001",
  "00000000-0000-0000-0000-000000000002",
  "00000000-0000-0000-0000-000000000003",
  "00000000-0000-0000-0000-000000000004",
];

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
    const ownerPin = String(body.owner_pin ?? "");
    const cashierId = String(body.cashier_id ?? "");
    if (
      !UUID_RE.test(outletIdRaw) ||
      !/^\d{6}$/.test(ownerPin) ||
      !UUID_RE.test(cashierId)
    ) {
      return json(
        {
          ok: false,
          error: "outlet_id + cashier_id (UUID) + owner_pin 6 digit wajib",
        },
        400,
      );
    }

    // --- Validasi field opsional (sebelum bukti Owner, supaya
    // request cacat tidak menghabiskan percobaan PIN) ---
    const patch: Record<string, unknown> = {};
    let hasUpdate = false;
    const boolField = (key: string, col: string) => {
      if (body[key] !== undefined) {
        if (typeof body[key] !== "boolean") {
          throw new Error(key + " harus boolean");
        }
        patch[col] = body[key];
        hasUpdate = true;
      }
    };
    boolField("can_void", "can_void");
    boolField("can_discount", "can_discount");
    boolField("can_close_shift", "can_close_shift");
    boolField("force_pin_change", "force_pin_change");
    if (body.kicked !== undefined) {
      if (typeof body.kicked !== "boolean") {
        throw new Error("kicked harus boolean");
      }
      patch["kicked_at"] = body.kicked ? new Date().toISOString() : null;
      hasUpdate = true;
    }
    let outletIds: string[] | null = null;
    if (body.outlet_ids !== undefined) {
      if (!Array.isArray(body.outlet_ids)) {
        throw new Error("outlet_ids harus array");
      }
      outletIds = (body.outlet_ids as unknown[]).map((o) => String(o ?? ""));
      if (outletIds.length === 0) {
        return json({ ok: false, error: "outlets_empty" }, 400);
      }
      for (const oid of outletIds) {
        if (!KNOWN_OUTLETS.includes(oid)) {
          return json({ ok: false, error: "outlet_unknown" }, 400);
        }
      }
      hasUpdate = true;
    }
    if (!hasUpdate) {
      return json({ ok: false, error: "nothing_to_update" }, 400);
    }

    // PIN Owner GLOBAL (Batch C10.1) — outlet_id pemanggil
    // diabaikan untuk verifikasi PIN + rate limit.
    const outletId = GLOBAL_OUTLET_ID;
    const supabase = createClient(supabaseUrl, serviceKey);

    // --- Bukti Owner: verifikasi PIN (pola set-qris-payload) ---
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
    // Jangan telan error baca: SELECT yang gagal harus terlihat
    // sebagai 500, bukan disangka "PIN belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const hash = (row as { value?: string } | null)?.value;
    if (!hash) {
      return json({ ok: false, reason: "not_set" }, 403);
    }
    const match = await bcrypt.compare(ownerPin, hash);
    await supabase.from("pin_attempts").insert({
      outlet_id: outletId,
      success: match,
      purpose: "owner",
    });
    if (!match) {
      return json({ ok: false, reason: "wrong" }, 403);
    }

    // Kasir harus ada.
    const { data: target, error: targetErr } = await supabase
      .from("cashiers")
      .select("id")
      .eq("id", cashierId)
      .maybeSingle();
    if (targetErr) {
      return json({ ok: false, error: targetErr.message }, 500);
    }
    if (target == null) {
      return json({ ok: false, error: "cashier_not_found" }, 400);
    }

    if (Object.keys(patch).length > 0) {
      const { error: updErr } = await supabase
        .from("cashiers")
        .update(patch)
        .eq("id", cashierId);
      if (updErr) {
        return json({ ok: false, error: updErr.message }, 500);
      }
    }
    if (outletIds !== null) {
      const { error: delErr } = await supabase
        .from("cashier_outlets")
        .delete()
        .eq("cashier_id", cashierId);
      if (delErr) {
        return json({ ok: false, error: delErr.message }, 500);
      }
      const { error: insErr } = await supabase
        .from("cashier_outlets")
        .insert(outletIds.map((outlet_id) => ({ cashier_id: cashierId, outlet_id })));
      if (insErr) {
        return json({ ok: false, error: insErr.message }, 500);
      }
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
