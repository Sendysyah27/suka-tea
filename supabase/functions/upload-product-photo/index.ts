// SUKA TEA — Edge Function `upload-product-photo` (Batch C3)
// Upload foto produk custom Owner ke Supabase Storage.
//
// Kenapa lewat Edge Function, bukan upload langsung dari app:
// anon key bisa diekstrak dari APK — policy Storage "anon boleh tulis"
// sama saja dengan "siapa pun boleh tulis". Di sini bukti Owner adalah
// PIN Owner gerai itu (dibuktikan server-side dengan bcrypt, sama
// seperti verify-owner-pin) + upload dilakukan service_role yang
// melewati RLS. Batch C10.1: PIN Owner GLOBAL (satu PIN semua
// gerai) — verifikasi PIN + rate limit selalu baris global ...0001;
// outlet_id ASLI tetap dipakai untuk path storage (itu outlet
// produknya, bukan baris PIN). Bucket `product-photos` (migrasi 007)
// hanya punya policy SELECT publik; tidak ada policy tulis untuk anon.
//
// POST { outlet_id, product_id, owner_pin, image_base64 } ->
//   { ok:true, public_url, path }  (200)
//   { ok:false, reason:'wrong'|'not_set'|'locked' }  (403)
//   { ok:false, error:... }  (400/500/501)
// Foto disimpan sebagai JPEG di:
//   product-photos / products/<outlet_id>/<product_id>.jpg
// (upsert — ganti foto menimpa file lama; URL publik tetap sama,
// cache browser/HP bisa menahan foto lama sebentar.)
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

const BUCKET = "product-photos";
const MAX_FAILURES = 10;
const WINDOW_MINUTES = 10;
// Foto hasil image_picker (max 1024px, quality 85) umumnya < 300 KB.
// Batas 2 MB menahan upload raksasa yang tidak sengaja.
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

// PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026, Batch C10.1): SATU
// PIN untuk semua gerai — hash + rate limit selalu baris global
// (...0001). Path storage tetap memakai outlet_id ASLI.
const GLOBAL_OUTLET_ID = "00000000-0000-0000-0000-000000000001";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/// Path aman di bucket — id hanya boleh huruf/angka/'-'/'_' supaya
/// tidak ada traversal (`../`) lewat product_id/outlet_id.
function storagePath(outletId: string, productId: string): string | null {
  const safe = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
  if (!safe.test(outletId) || !safe.test(productId)) return null;
  return `products/${outletId}/${productId}.jpg`;
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
    const productId = String(body.product_id ?? "");
    const ownerPin = String(body.owner_pin ?? "");
    const imageBase64 = String(body.image_base64 ?? "");
    if (!outletId || !productId || !/^\d{6}$/.test(ownerPin) || !imageBase64) {
      return json(
        { ok: false, error: "outlet_id + product_id + owner_pin 6 digit + image_base64 wajib" },
        400,
      );
    }
    const path = storagePath(outletId, productId);
    if (path == null) {
      return json({ ok: false, error: "outlet_id / product_id tidak valid" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    // PIN Owner GLOBAL (Batch C10.1) — verifikasi PIN + rate limit
    // selalu baris ...0001. [outletId] ASLI tetap dipakai untuk
    // path storage (lihat [path] di atas).
    const pinOutletId = GLOBAL_OUTLET_ID;

    // --- Bukti Owner: verifikasi PIN (pola verify-owner-pin) ---
    const since = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000).toISOString();
    const { count } = await supabase
      .from("pin_attempts")
      .select("id", { count: "exact", head: true })
      .eq("outlet_id", pinOutletId)
      .eq("success", false)
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_FAILURES) {
      return json({ ok: false, reason: "locked" }, 403);
    }
    const { data: row, error: readError } = await supabase
      .from("app_settings")
      .select("value")
      .eq("outlet_id", pinOutletId)
      .eq("key", "owner_pin_hash")
      .maybeSingle();
    // Jangan telan error baca: SELECT yang gagal (mis. GRANT belum ada)
    // harus terlihat sebagai 500, bukan disangka "PIN belum diatur".
    if (readError) {
      return json({ ok: false, error: readError.message }, 500);
    }
    const hash = (row as { value?: string } | null)?.value;
    if (!hash) {
      return json({ ok: false, reason: "not_set" }, 403);
    }
    const match = await bcrypt.compare(ownerPin, hash);
    await supabase.from("pin_attempts").insert({
      outlet_id: pinOutletId,
      success: match,
    });
    if (!match) {
      return json({ ok: false, reason: "wrong" }, 403);
    }

    // --- Decode + upload ---
    let bytes: Uint8Array;
    try {
      const bin = atob(imageBase64);
      bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    } catch {
      return json({ ok: false, error: "image_base64 bukan base64 valid" }, 400);
    }
    if (bytes.length === 0 || bytes.length > MAX_IMAGE_BYTES) {
      return json({ ok: false, error: "ukuran foto harus 1 byte – 2 MB" }, 400);
    }
    // JPEG saja (app mengirim hasil image_picker maxWidth/maxHeight/
    // imageQuality — di Android hasilnya JPEG). Magic bytes JPEG:
    // FF D8 FF.
    if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) {
      return json({ ok: false, error: "foto harus JPEG" }, 400);
    }

    const { error: uploadError } = await supabase.storage
      .from(BUCKET)
      .upload(path, bytes, { contentType: "image/jpeg", upsert: true });
    if (uploadError) {
      return json({ ok: false, error: uploadError.message }, 500);
    }

    const publicUrl =
      `${supabaseUrl}/storage/v1/object/public/${BUCKET}/${path}`;
    return json({ ok: true, public_url: publicUrl, path });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
