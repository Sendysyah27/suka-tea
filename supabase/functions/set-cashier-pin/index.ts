// SUKA TEA — Edge Function `set-cashier-pin` (Batch C8.2,
// v40: + ubah nama dalam satu panggilan)
// Ubah PIN akses satu kasir (6 digit baru). Hanya Owner yang boleh
// (bukti = PIN Owner gerai itu, diverifikasi server-side).
// PIN baru tidak boleh sama dengan PIN kasir aktif LAIN (kasir ini
// sendiri dikecualikan — PIN lama boleh dipakai lagi).
// v40 — parameter opsional `name`: dialog Ubah (frame 33) mengubah
// nama + PIN dalam SATU panggilan. Nama dicek unik antar kasir AKTIF
// kecuali kasir ini sendiri (case-insensitive) -> 'name_taken'.
// Bila `name` tidak ada/kosong = perilaku lama (hanya PIN).
// Bila `pin` tidak ada = hanya nama. Keduanya kosong -> 400.
//
// POST { outlet_id, owner_pin, cashier_id, pin?, name? } -> { ok:true }
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:'pin_taken'|'name_taken'|'cashier_not_found'|... }
//     (400/500/501)
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
    const pinRaw = body.pin;
    const pin = typeof pinRaw === "string" ? pinRaw : "";
    const nameRaw = body.name;
    const name = typeof nameRaw === "string" ? nameRaw.trim() : "";
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
    if (pin !== "" && !/^\d{6}$/.test(pin)) {
      return json({ ok: false, error: "pin kasir harus 6 digit" }, 400);
    }
    if (name !== "" && name.length > 50) {
      return json(
        { ok: false, error: "name wajib diisi (maks 50 karakter)" },
        400,
      );
    }
    if (pin === "" && name === "") {
      return json(
        { ok: false, error: "pin atau name wajib diisi" },
        400,
      );
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
    // v40 — nama baru tidak boleh dipakai kasir aktif LAIN
    // (kasir ini dikecualikan — nama lama boleh dipakai lagi).
    if (name !== "") {
      const { data: actives, error: nameErr } = await supabase
        .from("cashiers")
        .select("id, name")
        .eq("active", true)
        .neq("id", cashierId);
      if (nameErr) {
        return json({ ok: false, error: nameErr.message }, 500);
      }
      for (const c of (actives ?? []) as Record<string, unknown>[]) {
        if (
          String(c["name"] ?? "").trim().toLowerCase() ===
          name.toLowerCase()
        ) {
          return json({ ok: false, error: "name_taken" }, 400);
        }
      }
    }
    // PIN baru tidak boleh dipakai kasir aktif LAIN.
    if (pin !== "") {
      const { data: actives, error: activesErr } = await supabase
        .from("cashiers")
        .select("id, pin_hash")
        .eq("active", true)
        .neq("id", cashierId);
      if (activesErr) {
        return json({ ok: false, error: activesErr.message }, 500);
      }
      for (const c of (actives ?? []) as Record<string, unknown>[]) {
        const otherHash = String(c["pin_hash"] ?? "");
        if (otherHash !== "" && (await bcrypt.compare(pin, otherHash))) {
          return json({ ok: false, error: "pin_taken" }, 400);
        }
      }
    }

    const patch: Record<string, unknown> = {};
    if (name !== "") patch["name"] = name;
    if (pin !== "") patch["pin_hash"] = await bcrypt.hash(pin, 10);
    const { error: updErr } = await supabase
      .from("cashiers")
      .update(patch)
      .eq("id", cashierId);
    if (updErr) {
      return json({ ok: false, error: updErr.message }, 500);
    }
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
