// SUKA TEA — Edge Function `sync-sales` (Batch C6 + C7 + C8.2)
// Sinkronisasi penjualan + mutasi stok per-gerai, dan baca live
// untuk Pantau Gerai Owner.
//
// POST { action, ... } -> { ok, ... }
//   action 'push': { events: [{ outbox_id, kind, client_uuid,
//     outlet_id, created_at, payload }] } -> { ok, results:
//     [{ outbox_id, client_uuid, ok, error? }],
//     shift_adoptions: [{ outbox_id, existing_client_uuid,
//     existing_opened_at, existing_cashier_name,
//     existing_cashier_id, existing_opening_float }] } (per-event,
//     urutan diproses sekuensial = urutan antrean app).
//   action 'pull': { outlet_id, from, to } (tanggal YYYY-MM-DD,
//     inklusif, zona lokal) -> { ok, outlet_id, from, to,
//     transactions: [...], items: [{ transaction_client_uuid,
//     name_snapshot, qty, unit_price, modifiers_json }],
//     stock: [{ name, unit, qty, low_threshold, cost_per_unit }],
//     shifts: [shift terbuka gerai itu] }.
//   action 'shift_expected': { outlet_id, from, to } (ISO
//     timestamp) -> { ok, cash_in, cash_out } — expected kas
//     server (semua kasir + semua device gerai itu, void
//     dikecualikan). Pemanggil menambahkan opening_float sendiri.
//   400 input tidak valid / 500 error Supabase.
//
// Batch C7: kind 'expense' (upsert pengeluaran by client_uuid;
// is_deleted true = hapus baris) + kind 'shift' (upsert shift kas
// by client_uuid, last-write-wins: event tutup menimpa event buka).
//
// Batch C8.2:
// - WS4: transaksi menyimpan cashier_id + cashier_name (kasir
//   pencatat dari server); pull mengembalikannya.
// - WS5: stok PER GERAI — mutasi diterapkan ke outlet PENGIRIM
//   (bukan lagi gerai utama); server menerapkan DELTA (qty_delta),
//   bukan level absolut qty_after — idempotent via client_uuid
//   (hanya terapkan bila movement benar-benar baru), clamp >= 0.
//   Baris stok baru memakai qty_after sebagai level awal.
//   Pull mengembalikan stok gerai yang diminta.
// - WS6: SATU shift per gerai (laci satu). Push 'open' di-dedupe
//   server: shift dengan opened_at PALING AWAL dipertahankan —
//   yang lebih awal menutup yang lebih lambat; yang lebih lambat
//   dikembalikan sebagai dedupe (shift_adoptions) supaya app
//   mengadopsi shift yang sudah ada. Push 'close' untuk shift
//   yang tidak ada diabaikan (tidak membuat baris hantu).
//   Pull mengembalikan shift TERBUKA gerai itu (visibilitas antar
//   device). Expected dihitung server (aksi 'shift_expected').
//
// JALUR TULIS: Edge Function ini (bukan tulis langsung dari app).
// RLS 001 menuntut auth.uid() membership — anon key tidak punya
// identitas, jadi SEMUA policy SELECT/INSERT menolak anon. Membuka
// RLS untuk anon = siapa pun bisa baca/tulis semua gerai. EF ini
// jalan dengan service_role (bypass RLS, seperti export-sheets)
// dan JWT default ON (app memanggil pakai anon key = JWT valid).
//
// IDEMPOTENCY: kunci = client_uuid (unique di `transactions` dan
// `stock_movements`). Kirim ulang event yang sama = upsert yang
// sama (transaksi) / lewati (mutasi). client_uuid LAMA dari app
// (string angka mikROdetik, bukan UUID) dinormalkan secara
// deterministik (SHA-256 -> UUID v5-style) supaya tetap idempotent.
// Void = event 'transaction' dengan client_uuid YANG SAMA +
// is_void true; status 'void' bersifat STICKY — event penjualan
// lama yang terkirim ulang tidak bisa membaliknya ke 'completed'.
//
// KEJUJURAN / BATASAN (tanpa Auth M0, EF ini tidak bisa membedakan
// kasir asli vs pemalsu yang mengekstrak anon key dari app —
// keterbatasan yang sama dengan seluruh model keamanan app saat
// ini; Auth M0 adalah perbaikan sebenarnya, bukan EF ini).
// Validasi yang dilakukan: outlet_id UUID + ada di tabel outlets
// (pull), payment_method allowlist, angka non-negatif, items
// tidak kosong, maksimal 200 event per request.

import { createClient } from "jsr:@supabase/supabase-js@2";

type Supabase = ReturnType<typeof createClient>;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAYMENT_METHODS = new Set([
  "tunai",
  "transfer",
  "qris",
  "qris_manual",
  "ewallet",
  "split",
]);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isDateString(s: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(`${s}T00:00:00+07:00`));
}

function toNonNegInt(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${field} bukan angka: ${String(value)}`);
  }
  const v = Math.trunc(value);
  if (v < 0) throw new Error(`${field} negatif: ${v}`);
  return v;
}

function toPosInt(value: unknown, field: string): number {
  const v = toNonNegInt(value, field);
  if (v === 0) throw new Error(`${field} harus > 0`);
  return v;
}

function toNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${field} bukan angka: ${String(value)}`);
  }
  return value;
}

/// Normalisasi client_uuid: UUID valid dipakai apa adanya; string
/// lain (mis. angka mikROdetik dari outbox lama) dipetakan secara
/// deterministik ke UUID v5-style dari SHA-256 — string yang sama
/// selalu menghasilkan UUID yang sama (idempotent).
async function normalizeClientUuid(raw: string): Promise<string> {
  const s = String(raw ?? "").trim().toLowerCase();
  if (UUID_RE.test(s)) return s;
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(s),
  );
  const bytes = new Uint8Array(hash).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/// Upsert satu transaksi + ganti item-nya utuh (idempotent).
/// Batch C8.2 WS4: simpan cashier_id + cashier_name (kasir pencatat).
async function pushTransaction(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ transaction_id: string; status: string }> {
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const method = String(p.payment_method ?? "");
  if (!PAYMENT_METHODS.has(method)) {
    throw new Error(`payment_method tidak dikenal: ${method}`);
  }
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const total = toNonNegInt(p.total, "total");
  const discount = toNonNegInt(p.discount ?? 0, "discount");
  const paid = toNonNegInt(p.paid ?? total, "paid");
  const change = toNonNegInt(p.change ?? 0, "change");
  const qrisAmount = toNonNegInt(p.qris_amount ?? 0, "qris_amount");
  const cashAmount = toNonNegInt(p.cash_amount ?? 0, "cash_amount");
  const isVoid = p.is_void === true;
  const items = Array.isArray(p.items) ? p.items : [];
  if (items.length === 0) throw new Error("items kosong");
  for (const it of items) {
    const item = it as Record<string, unknown>;
    if (typeof item.name !== "string" || item.name === "") {
      throw new Error("item tanpa nama");
    }
    toPosInt(item.qty, "item.qty");
    toNonNegInt(item.price, "item.price");
  }
  const createdAt = String(ev.created_at ?? new Date().toISOString());
  // cashier_id = UUID kasir dari server (migrasi 010); string bukan
  // UUID / kosong = null (kolom uuid tidak menerima string kosong).
  const cashierIdRaw =
    typeof p.cashier_id === "string" ? p.cashier_id : "";
  const cashierId = UUID_RE.test(cashierIdRaw) ? cashierIdRaw : null;
  const cashierName =
    typeof p.cashier_name === "string" ? p.cashier_name : "";

  // Sticky-void: status 'void' yang sudah tersimpan tidak boleh
  // balik ke 'completed' bila event penjualan lama terkirim ulang.
  const { data: existing, error: readErr } = await supabase
    .from("transactions")
    .select("id, status")
    .eq("client_uuid", clientUuid)
    .maybeSingle();
  if (readErr) throw new Error(`baca transaksi gagal: ${readErr.message}`);
  const status = existing?.status === "void" && !isVoid
    ? "void"
    : (isVoid ? "void" : "completed");

  const { data: txn, error: upErr } = await supabase
    .from("transactions")
    .upsert(
      {
        outlet_id: outletId,
        payment_method: method,
        subtotal: total + discount,
        total,
        paid,
        change_amount: change,
        status,
        client_uuid: clientUuid,
        created_at: createdAt,
        discount,
        qris_amount: qrisAmount,
        cash_amount: cashAmount,
        cashier_id: cashierId,
        cashier_name: cashierName,
      },
      { onConflict: "client_uuid" },
    )
    .select("id")
    .single();
  if (upErr) throw new Error(`upsert transaksi gagal: ${upErr.message}`);
  const txnId = (txn as { id: string }).id;

  // Item diganti utuh tiap kirim ulang: hapus dulu, baru sisipkan.
  const { error: delErr } = await supabase
    .from("transaction_items")
    .delete()
    .eq("transaction_id", txnId);
  if (delErr) throw new Error(`hapus item lama gagal: ${delErr.message}`);
  const rows = items.map((it) => {
    const item = it as Record<string, unknown>;
    return {
      transaction_id: txnId,
      product_id: null,
      variant_id: null,
      name_snapshot: String(item.name),
      qty: toPosInt(item.qty, "item.qty"),
      unit_price: toNonNegInt(item.price, "item.price"),
      modifiers_json: Array.isArray(item.modifiers) ? item.modifiers : [],
    };
  });
  const { error: insErr } = await supabase
    .from("transaction_items")
    .insert(rows);
  if (insErr) throw new Error(`sisip item gagal: ${insErr.message}`);
  return { transaction_id: txnId, status };
}

/// Satu mutasi stok (Batch C8.2 WS5 — DELTA, per gerai pengirim):
/// pastikan baris stock_items gerai itu ada, sisipkan mutasi
/// (idempotent via client_uuid), lalu terapkan DELTA ke level —
/// HANYA bila mutasi benar-benar baru, clamp >= 0. Baris stok baru
/// memakai qty_after sebagai level awal (mutasi pertama per bahan).
async function pushStockMovement(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ applied_items: number }> {
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const items = Array.isArray(p.items) ? p.items : [];
  if (items.length === 0) throw new Error("items kosong");
  const reasonRaw = String(p.reason ?? "penjualan");
  const reason = reasonRaw === "void" ? "void" : "penjualan";

  // Tautkan ke transaksi asal bila sudah tersinkron (boleh null).
  let transactionId: string | null = null;
  const txnRaw = p.transaction_client_uuid;
  if (typeof txnRaw === "string" && txnRaw !== "") {
    const txnUuid = await normalizeClientUuid(txnRaw);
    const { data } = await supabase
      .from("transactions")
      .select("id")
      .eq("client_uuid", txnUuid)
      .maybeSingle();
    transactionId = (data as { id: string } | null)?.id ?? null;
  }

  let applied = 0;
  for (const raw of items) {
    const item = raw as Record<string, unknown>;
    const name = String(item.name ?? "");
    if (name === "") throw new Error("item stok tanpa nama");
    const unit =
      typeof item.unit === "string" && item.unit !== ""
        ? item.unit
        : "pcs";
    const qtyAfter = toNumber(item.qty_after, "item.qty_after");
    const lowThreshold = toNumber(item.low_threshold ?? 0, "item.low_threshold");
    const cost = toNonNegInt(item.cost_per_unit ?? 0, "item.cost_per_unit");
    const delta = toNumber(item.delta, "item.delta");

    // 1) Pastikan baris stok gerai ini ada. Baris baru memakai
    //    qty_after sebagai level awal (mutasi pertama per bahan).
    //    23505 = balapan dengan device lain yang membuat baris yang
    //    sama duluan — baca ulang, lalu lanjut sebagai baris lama.
    const { data: existingStock } = await supabase
      .from("stock_items")
      .select("id, qty")
      .eq("outlet_id", outletId)
      .eq("name", name)
      .maybeSingle();
    let stockId: string;
    let currentQty: number | null = null;
    // true = baris SUDAH ada sebelum event ini (delta diterapkan di
    // langkah 3); false = baris baru dibuat langkah 1 dengan
    // qty_after sebagai level awal (mutasi ini SUDAH termasuk di
    // level itu — jangan terapkan delta lagi).
    let rowPreExisted = false;
    if (existingStock != null) {
      stockId = (existingStock as { id: string }).id;
      currentQty = Number(
        (existingStock as { qty: number }).qty ?? 0,
      );
      rowPreExisted = true;
      const { error: updErr } = await supabase
        .from("stock_items")
        .update({ unit, low_threshold: lowThreshold, cost })
        .eq("id", stockId);
      if (updErr) {
        throw new Error(`update stok gagal: ${updErr.message}`);
      }
    } else {
      const { data: created, error: insErr } = await supabase
        .from("stock_items")
        .insert({
          outlet_id: outletId,
          name,
          unit,
          qty: qtyAfter,
          low_threshold: lowThreshold,
          cost,
        })
        .select("id, qty")
        .single();
      if (insErr) {
        if ((insErr as { code?: string }).code === "23505") {
          const { data: raced } = await supabase
            .from("stock_items")
            .select("id, qty")
            .eq("outlet_id", outletId)
            .eq("name", name)
            .maybeSingle();
          if (raced == null) {
            throw new Error(`buat stok gagal: ${insErr.message}`);
          }
          stockId = (raced as { id: string }).id;
          currentQty = Number((raced as { qty: number }).qty ?? 0);
          // Baris ternyata sudah ada (dibuat device lain duluan) —
          // delta TETAP diterapkan di langkah 3.
          rowPreExisted = true;
        } else {
          throw new Error(`buat stok gagal: ${insErr.message}`);
        }
      } else {
        stockId = (created as { id: string }).id;
        currentQty = Number((created as { qty: number }).qty ?? 0);
      }
    }

    // 2) Sisip mutasi — duplikat client_uuid (23505) = kirim ulang:
    //    bukan error, lewati penerapan delta (sudah diterapkan dulu).
    const { data: moved, error: movErr } = await supabase
      .from("stock_movements")
      .insert({
        outlet_id: outletId,
        stock_item_id: stockId,
        qty_delta: delta,
        reason,
        transaction_id: transactionId,
        client_uuid: clientUuid,
      })
      .select("id")
      .single();
    if (movErr) {
      if ((movErr as { code?: string }).code === "23505") continue;
      throw new Error(`sisip mutasi gagal: ${movErr.message}`);
    }
    if (moved == null) continue;

    // 3) Mutasi baru -> terapkan DELTA ke level gerai ini, clamp >= 0.
    //    Baris baru: currentQty SUDAH = qty_after (level awal di
    //    langkah 1 sudah termasuk mutasi ini) — jangan terapkan
    //    delta lagi, atau level jadi dobel.
    if (rowPreExisted) {
      const nextQty = Math.max(0, (currentQty ?? 0) + delta);
      const { error: lvlErr } = await supabase
        .from("stock_items")
        .update({ qty: nextQty })
        .eq("id", stockId);
      if (lvlErr) {
        throw new Error(`update level stok gagal: ${lvlErr.message}`);
      }
    }
    applied++;
  }
  return { applied_items: applied };
}

/// Upsert satu pengeluaran; is_deleted true = hapus baris by
/// client_uuid (keputusan C7: hapus = event, bukan hapus langsung —
/// antrean yang sama dipakai semua jenis sync, hapus offline tetap
/// jalan lalu tersinkron saat online).
async function pushExpense(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ deleted: boolean }> {
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  if (p.is_deleted === true) {
    const { error: delErr } = await supabase
      .from("expenses")
      .delete()
      .eq("client_uuid", clientUuid);
    if (delErr) throw new Error(`hapus pengeluaran gagal: ${delErr.message}`);
    return { deleted: true };
  }
  const category = String(p.category ?? "");
  if (category === "") throw new Error("category kosong");
  const amount = toPosInt(p.amount, "amount");
  const isCash = p.is_cash !== false;
  const cashierName =
    typeof p.cashier_name === "string" ? p.cashier_name : "";
  const description =
    typeof p.description === "string" ? p.description : "";
  const createdAt = String(ev.created_at ?? new Date().toISOString());
  const { error: upErr } = await supabase
    .from("expenses")
    .upsert(
      {
        outlet_id: outletId,
        category,
        description,
        amount,
        is_cash: isCash,
        cashier_name: cashierName,
        client_uuid: clientUuid,
        created_at: createdAt,
      },
      { onConflict: "client_uuid" },
    );
  if (upErr) throw new Error(`upsert pengeluaran gagal: ${upErr.message}`);
  return { deleted: false };
}

/// Upsert satu shift kas (Batch C8.2 WS6 — SATU shift per gerai).
/// - Event 'open': dedupe — bila sudah ada shift OPEN lain di gerai
///   ini (client_uuid berbeda), yang opened_at PALING AWAL menang.
///   Masuk lebih awal -> shift lain ditutup (closed_at = opened_at
///   masuk) lalu masuk di-upsert. Masuk lebih lambat/sama ->
///   kembalikan dedupe (existing_*) supaya app mengadopsi shift
///   yang sudah ada, JANGAN upsert.
/// - Event 'close': bila baris client_uuid tidak ada, abaikan
///   (jangan buat baris hantu — tutup tanpa buka tidak ada artinya).
/// - Selain itu last-write-wins by client_uuid seperti C7.
async function pushShift(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const cashierIdRaw =
    typeof p.cashier_id === "string" ? p.cashier_id : "";
  const cashierId = UUID_RE.test(cashierIdRaw) ? cashierIdRaw : null;
  const cashierName =
    typeof p.cashier_name === "string" ? p.cashier_name : "";
  const closedByIdRaw =
    typeof p.closed_by_cashier_id === "string"
      ? p.closed_by_cashier_id
      : "";
  const closedById = UUID_RE.test(closedByIdRaw) ? closedByIdRaw : null;
  const closedByName =
    typeof p.closed_by_cashier_name === "string"
      ? p.closed_by_cashier_name
      : "";
  const openedAt = String(p.opened_at ?? "");
  if (Number.isNaN(Date.parse(openedAt))) {
    throw new Error("opened_at bukan tanggal");
  }
  const openingFloat = toNonNegInt(p.opening_float ?? 0, "opening_float");
  const statusRaw = String(p.status ?? "open");
  const status = statusRaw === "closed" ? "closed" : "open";
  const closedRaw = p.closed_at;
  const closedAt =
    typeof closedRaw === "string" && closedRaw !== "" ? closedRaw : null;
  if (status === "closed" && closedAt == null) {
    throw new Error("shift closed tanpa closed_at");
  }
  if (closedAt != null && Number.isNaN(Date.parse(closedAt))) {
    throw new Error("closed_at bukan tanggal");
  }
  const optInt = (v: unknown, field: string): number | null => {
    if (v == null) return null;
    return Math.trunc(toNumber(v, field));
  };

  if (status === "open") {
    const { data: otherOpen } = await supabase
      .from("cash_shifts")
      .select("client_uuid, opened_at, cashier_name, cashier_id, opening_float")
      .eq("outlet_id", outletId)
      .eq("status", "open")
      .neq("client_uuid", clientUuid)
      .order("opened_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (otherOpen != null) {
      const other = otherOpen as Record<string, unknown>;
      const otherOpened = new Date(String(other["opened_at"]));
      const incomingOpened = new Date(openedAt);
      if (incomingOpened.getTime() < otherOpened.getTime()) {
        // Masuk lebih awal -> menang: tutup shift lain (yang lebih
        // lambat) di titik waktu masuk dibuka, lalu upsert masuk.
        await supabase
          .from("cash_shifts")
          .update({ status: "closed", closed_at: openedAt })
          .eq("client_uuid", String(other["client_uuid"]));
      } else {
        // Masuk lebih lambat/sama -> dedupe: kembalikan shift yang
        // sudah ada, app mengadopsinya (buang duplikat lokalnya).
        return {
          status: "open",
          deduped: true,
          existing_client_uuid: String(other["client_uuid"]),
          existing_opened_at: String(other["opened_at"]),
          existing_cashier_name: String(other["cashier_name"] ?? ""),
          existing_cashier_id: String(other["cashier_id"] ?? ""),
          existing_opening_float:
            typeof other["opening_float"] === "number"
              ? other["opening_float"]
              : 0,
        };
      }
    }
  } else {
    const { data: existing } = await supabase
      .from("cash_shifts")
      .select("id")
      .eq("client_uuid", clientUuid)
      .maybeSingle();
    if (existing == null) {
      return { status: "closed", ignored: true };
    }
  }

  const { error: upErr } = await supabase
    .from("cash_shifts")
    .upsert(
      {
        outlet_id: outletId,
        cashier_id: cashierId,
        cashier_name: cashierName,
        closed_by_cashier_id: closedById,
        closed_by_cashier_name: closedByName,
        opened_at: openedAt,
        opening_float: openingFloat,
        closed_at: closedAt,
        counted_cash: optInt(p.counted_cash, "counted_cash"),
        expected_cash: optInt(p.expected_cash, "expected_cash"),
        difference: optInt(p.difference, "difference"),
        status,
        note: typeof p.note === "string" ? p.note : "",
        client_uuid: clientUuid,
      },
      { onConflict: "client_uuid" },
    );
  if (upErr) throw new Error(`upsert shift gagal: ${upErr.message}`);
  return { status };
}

/// Baca transaksi + stok + shift terbuka gerai untuk Pantau Gerai live.
/// Hari dalam WIB (toko di UTC+7): from 00:00 WIB s.d. to+1 00:00 WIB.
async function pull(
  supabase: Supabase,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const outletId = String(body.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const from = String(body.from ?? "");
  const to = String(body.to ?? "");
  if (!isDateString(from) || !isDateString(to)) {
    throw new Error("from/to harus tanggal YYYY-MM-DD");
  }
  const { data: outlet, error: outletErr } = await supabase
    .from("outlets")
    .select("id")
    .eq("id", outletId)
    .maybeSingle();
  if (outletErr) throw new Error(`cek gerai gagal: ${outletErr.message}`);
  if (outlet == null) throw new Error("outlet_id tidak dikenal");

  const start = new Date(`${from}T00:00:00+07:00`);
  const end = new Date(`${to}T00:00:00+07:00`);
  end.setDate(end.getDate() + 1);

  const { data: txns, error: txnErr } = await supabase
    .from("transactions")
    .select(
      "id, client_uuid, outlet_id, created_at, payment_method, subtotal, total, paid, change_amount, status, discount, qris_amount, cash_amount, cashier_id, cashier_name",
    )
    .eq("outlet_id", outletId)
    .gte("created_at", start.toISOString())
    .lt("created_at", end.toISOString())
    .order("created_at", { ascending: false });
  if (txnErr) throw new Error(`baca transaksi gagal: ${txnErr.message}`);
  const txnList = (txns ?? []) as Record<string, unknown>[];

  const items: Record<string, unknown>[] = [];
  if (txnList.length > 0) {
    const ids = txnList.map((t) => String(t["id"]));
    const idToUuid = new Map(
      txnList.map((t) => [String(t["id"]), String(t["client_uuid"])]),
    );
    const { data: rawItems, error: itemsErr } = await supabase
      .from("transaction_items")
      .select("transaction_id, name_snapshot, qty, unit_price, modifiers_json")
      .in("transaction_id", ids);
    if (itemsErr) throw new Error(`baca item gagal: ${itemsErr.message}`);
    for (const it of (rawItems ?? []) as Record<string, unknown>[]) {
      items.push({
        transaction_client_uuid:
          idToUuid.get(String(it["transaction_id"])) ?? "",
        name_snapshot: it["name_snapshot"],
        qty: it["qty"],
        unit_price: it["unit_price"],
        modifiers_json: it["modifiers_json"] ?? [],
      });
    }
  }

  // Stok gerai yang diminta (Batch C8.2 WS5).
  const { data: stockRows, error: stockErr } = await supabase
    .from("stock_items")
    .select("name, unit, qty, low_threshold, cost")
    .eq("outlet_id", outletId)
    .order("name", { ascending: true });
  if (stockErr) throw new Error(`baca stok gagal: ${stockErr.message}`);
  const stock = ((stockRows ?? []) as Record<string, unknown>[]).map(
    (s) => ({
      name: s["name"],
      unit: s["unit"],
      qty: s["qty"],
      low_threshold: s["low_threshold"],
      cost_per_unit: s["cost"],
    }),
  );

  // Shift TERBUKA gerai itu (Batch C8.2 WS6 — visibilitas antar device).
  const { data: shiftRows, error: shiftErr } = await supabase
    .from("cash_shifts")
    .select(
      "client_uuid, outlet_id, cashier_id, cashier_name, opened_at, opening_float, status, closed_at, closed_by_cashier_id, closed_by_cashier_name",
    )
    .eq("outlet_id", outletId)
    .eq("status", "open")
    .order("opened_at", { ascending: true });
  if (shiftErr) throw new Error(`baca shift gagal: ${shiftErr.message}`);
  const shifts = (shiftRows ?? []) as Record<string, unknown>[];

  return {
    ok: true,
    outlet_id: outletId,
    from,
    to,
    transactions: txnList,
    items,
    stock,
    shifts,
  };
}

/// Expected kas server (Batch C8.2 WS6): cash_in = tunai masuk dari
/// SEMUA transaksi gerai itu di [from, to) (tunai -> total; split ->
/// total − qris_amount; void dikecualikan); cash_out = pengeluaran
/// TUNAI gerai itu di jendela yang sama. Pemanggil menambahkan
/// opening_float shift itu sendiri. [from]/[to] = ISO timestamp.
async function shiftExpected(
  supabase: Supabase,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const outletId = String(body.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const fromRaw = String(body.from ?? "");
  const toRaw = String(body.to ?? "");
  const from = new Date(fromRaw);
  const to = new Date(toRaw);
  if (Number.isNaN(from.getTime()) || Number.isNaN(to.getTime())) {
    throw new Error("from/to harus timestamp ISO");
  }
  if (from.getTime() >= to.getTime()) {
    throw new Error("from harus sebelum to");
  }
  const { data: txns, error: txnErr } = await supabase
    .from("transactions")
    .select("payment_method, total, qris_amount, status")
    .eq("outlet_id", outletId)
    .gte("created_at", from.toISOString())
    .lt("created_at", to.toISOString());
  if (txnErr) throw new Error(`baca transaksi gagal: ${txnErr.message}`);
  let cashIn = 0;
  for (const t of (txns ?? []) as Record<string, unknown>[]) {
    if (t["status"] === "void") continue;
    const total = Number(t["total"] ?? 0);
    const method = String(t["payment_method"] ?? "");
    if (method === "tunai") {
      cashIn += total;
    } else if (method === "split") {
      cashIn += Math.max(0, total - Number(t["qris_amount"] ?? 0));
    }
  }
  const { data: expenses, error: expErr } = await supabase
    .from("expenses")
    .select("amount")
    .eq("outlet_id", outletId)
    .eq("is_cash", true)
    .gte("created_at", from.toISOString())
    .lt("created_at", to.toISOString());
  if (expErr) throw new Error(`baca pengeluaran gagal: ${expErr.message}`);
  let cashOut = 0;
  for (const e of (expenses ?? []) as Record<string, unknown>[]) {
    cashOut += Number(e["amount"] ?? 0);
  }
  return { ok: true, cash_in: cashIn, cash_out: cashOut };
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
    const body = (await req.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    const action = String(body.action ?? "");
    const supabase = createClient(supabaseUrl, serviceKey);

    if (action === "push") {
      const events = Array.isArray(body.events) ? body.events : [];
      if (events.length === 0) {
        return json({ ok: false, error: "events kosong" }, 400);
      }
      if (events.length > 200) {
        return json(
          { ok: false, error: "events maksimal 200 per request" },
          400,
        );
      }
      const results: Record<string, unknown>[] = [];
      // Dedupe shift (Batch C8.2 WS6): event buka yang ditolak server
      // karena shift lain lebih awal — app mengadopsi shift itu.
      const shiftAdoptions: Record<string, unknown>[] = [];
      for (const raw of events) {
        const ev = raw as Record<string, unknown>;
        const outboxId = String(ev.outbox_id ?? "");
        try {
          if (ev.kind === "transaction") {
            await pushTransaction(supabase, ev);
          } else if (ev.kind === "stock_movement") {
            await pushStockMovement(supabase, ev);
          } else if (ev.kind === "expense") {
            await pushExpense(supabase, ev);
          } else if (ev.kind === "shift") {
            const shiftResult = await pushShift(supabase, ev);
            if (shiftResult["deduped"] === true) {
              shiftAdoptions.push({
                outbox_id: outboxId,
                existing_client_uuid: shiftResult["existing_client_uuid"],
                existing_opened_at: shiftResult["existing_opened_at"],
                existing_cashier_name:
                  shiftResult["existing_cashier_name"],
                existing_cashier_id: shiftResult["existing_cashier_id"],
                existing_opening_float:
                  shiftResult["existing_opening_float"],
              });
            }
          } else {
            throw new Error(`kind tidak dikenal: ${String(ev.kind ?? "")}`);
          }
          results.push({
            outbox_id: outboxId,
            client_uuid: String(ev.client_uuid ?? ""),
            ok: true,
          });
        } catch (e) {
          results.push({
            outbox_id: outboxId,
            client_uuid: String(ev.client_uuid ?? ""),
            ok: false,
            error: String(e instanceof Error ? e.message : e),
          });
        }
      }
      return json({ ok: true, results, shift_adoptions: shiftAdoptions });
    }

    if (action === "pull") {
      try {
        return json(await pull(supabase, body));
      } catch (e) {
        return json(
          { ok: false, error: String(e instanceof Error ? e.message : e) },
          400,
        );
      }
    }

    if (action === "shift_expected") {
      try {
        return json(await shiftExpected(supabase, body));
      } catch (e) {
        return json(
          { ok: false, error: String(e instanceof Error ? e.message : e) },
          400,
        );
      }
    }

    return json({ ok: false, error: `action tidak dikenal: ${action}` }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
