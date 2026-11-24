// SUKA TEA — Edge Function `register-cashier` (Batch C8.2)
// Daftarkan kasir baru (nama + PIN 6 digit). PIN berlaku di SEMUA
// gerai — identitas kasir global, bukan per-gerai (perintah Sendy
// 24 Nov 13:58: kasir tidak boleh memberi nama sendiri; identitas
// diberikan Owner). Hanya Owner yang boleh mendaftar (bukti = PIN
// Owner gerai itu, diverifikasi server-side dengan bcrypt).
//
// PIN tidak boleh sama dengan PIN kasir aktif lain (verify-cashier-pin
// mencocokkan PIN ke semua kasir satu per satu — PIN ganda = identitas
// ambigu). Nama kasir aktif juga harus unik (case-insensitive) —
// nama dipakai sebagai kunci kasir di `expenses` yang hanya menyimpan
// cashier_name.
//
// POST { outlet_id, owner_pin, name, pin } -> { ok:true, cashier_id }
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:'pin_taken'|'name_taken'|... }  (400/500/501)
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

/// Verifikasi PIN Owner GLOBAL (pola set-qris-payload) — [outletId]
/// HARUS baris global ...0001 (pemanggil menormalisasi dulu,
/// Batch C10.1). Mengembalikan null bila cocok, Response error
/// bila tidak.
async function verifyOwnerPin(
  supabase: ReturnType<typeof createClient>,
  outletId: string,
  pin: string,
): Promise<Response | null> {
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
  const match = await bcrypt.compare(pin, hash);
  await supabase.from("pin_attempts").insert({
    outlet_id: outletId,
    success: match,
    purpose: "owner",
  });
  if (!match) {
    return json({ ok: false, reason: "wrong" }, 403);
  }
  return null;
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
    const name = String(body.name ?? "").trim();
    const pin = String(body.pin ?? "");
    if (!UUID_RE.test(outletIdRaw) || !/^\d{6}$/.test(ownerPin)) {
      return json(
        { ok: false, error: "outlet_id (UUID) + owner_pin 6 digit wajib" },
        400,
      );
    }
    if (name === "" || name.length > 50) {
      return json(
        { ok: false, error: "name wajib diisi (maks 50 karakter)" },
        400,
      );
    }
    if (!/^\d{6}$/.test(pin)) {
      return json({ ok: false, error: "pin kasir harus 6 digit" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);
    // PIN Owner GLOBAL (Batch C10.1) — outlet_id pemanggil
    // diabaikan untuk verifikasi PIN + rate limit.
    const outletId = GLOBAL_OUTLET_ID;
    const ownerErr = await verifyOwnerPin(supabase, outletId, ownerPin);
    if (ownerErr != null) return ownerErr;

    // PIN + nama harus unik di antara kasir AKTIF.
    const { data: actives, error: readError } = await supabase
      .from("cashiers")
      .select("id, name, pin_hash")
      .eq("active", true);
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    for (const c of (actives ?? []) as Record<string, unknown>[]) {
      if (String(c["name"] ?? "").trim().toLowerCase() === name.toLowerCase()) {
        return json({ ok: false, error: "name_taken" }, 400);
      }
      const hash = String(c["pin_hash"] ?? "");
      if (hash !== "" && (await bcrypt.compare(pin, hash))) {
        return json({ ok: false, error: "pin_taken" }, 400);
      }
    }

    const pinHash = await bcrypt.hash(pin, 10);
    const { data: created, error: insErr } = await supabase
      .from("cashiers")
      .insert({ name, pin_hash: pinHash })
      .select("id")
      .single();
    if (insErr) {
      return json({ ok: false, error: insErr.message }, 500);
    }
    return json({ ok: true, cashier_id: (created as { id: string }).id });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
