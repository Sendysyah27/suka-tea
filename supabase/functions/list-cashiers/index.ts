// SUKA TEA — Edge Function `list-cashiers` (Batch C8.2,
// v40: + izin + presence + resign + gerai)
// Daftar semua kasir terdaftar (id + nama + status aktif + izin +
// terakhir sync + gerai terakhir + arsip resign + gerai yang
// diizinkan) — untuk halaman Kelola Kasir Owner. Hanya Owner yang
// boleh membaca (bukti = PIN Owner gerai itu, diverifikasi
// server-side).
//
// POST { outlet_id, owner_pin } -> { ok:true, cashiers:[{id,name,
//   active, can_void, can_discount, can_close_shift,
//   force_pin_change, resigned_at, last_seen_at, last_outlet_id,
//   allowed_outlets:[...]}] }
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:... }  (400/500/501)
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
    if (!UUID_RE.test(outletIdRaw) || !/^\d{6}$/.test(ownerPin)) {
      return json(
        { ok: false, error: "outlet_id (UUID) + owner_pin 6 digit wajib" },
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

    const { data: cashiers, error: listError } = await supabase
      .from("cashiers")
      .select(
        "id, name, active, can_void, can_discount, can_close_shift, " +
          "force_pin_change, resigned_at, last_seen_at, last_outlet_id, " +
          "created_at",
      )
      .order("created_at", { ascending: true });
    if (listError) {
      return json({ ok: false, error: listError.message }, 500);
    }
    // v40 — gerai yang diizinkan per kasir (satu query tambahan;
    // N kasir kecil — jangan N+1 query per kasir).
    const { data: outletRows, error: outletsErr } = await supabase
      .from("cashier_outlets")
      .select("cashier_id, outlet_id");
    if (outletsErr) {
      return json({ ok: false, error: outletsErr.message }, 500);
    }
    const byCashier = new Map<string, string[]>();
    for (const r of (outletRows ?? []) as Record<string, unknown>[]) {
      const cid = String(r["cashier_id"] ?? "");
      const oid = String(r["outlet_id"] ?? "");
      if (cid === "" || oid === "") continue;
      const list = byCashier.get(cid) ?? [];
      list.push(oid);
      byCashier.set(cid, list);
    }
    const out = ((cashiers ?? []) as Record<string, unknown>[]).map(
      (c) => ({
        id: c["id"],
        name: c["name"],
        active: c["active"],
        can_void: c["can_void"] !== false,
        can_discount: c["can_discount"] !== false,
        can_close_shift: c["can_close_shift"] !== false,
        force_pin_change: c["force_pin_change"] === true,
        resigned_at: c["resigned_at"] ?? null,
        last_seen_at: c["last_seen_at"] ?? null,
        last_outlet_id: c["last_outlet_id"] ?? null,
        allowed_outlets: byCashier.get(String(c["id"] ?? "")) ?? [],
      }),
    );
    return json({ ok: true, cashiers: out });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
