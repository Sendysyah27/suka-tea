// SUKA TEA — Edge Function `sync-sales` (Batch C6 + C7 + C8.2 + C9 + C10)
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
//     stock: [{ name, unit, qty, low_threshold, cost_per_unit,
//     shelf_life_days, updated_at }] (Batch C10),
//     shifts: [shift terbuka gerai itu],
//     expenses: [pengeluaran gerai itu di jendela] (Batch C9),
//     closed_shifts: [shift yang ditutup di jendela] (Batch C9),
//     movements: [mutasi stok gerai itu di jendela] (Batch C9),
//     master_changes: [perubahan master-data] (Batch C10 WS0),
//     sends: [kiriman ke gerai itu di jendela] (Batch C10 WS3),
//     opnames: [baris opname gerai itu di jendela] (Batch C10 WS6),
//     stock_ins: [stok masuk gudang di jendela — hanya bila
//     outlet_id = GUDANG_ID] (Batch C10 WS1),
//     brews: [riwayat masak gerai itu di jendela] (Batch C10 WS4) }.
//   action 'shift_expected': { outlet_id, from, to } (ISO
//     timestamp) -> { ok, cash_in, cash_out } — expected kas
//     server (semua kasir + semua device gerai itu, void
//     dikecualikan). Pemanggil menambahkan opening_float sendiri.
//   400 input tidak valid / 500 error Supabase.
//
// Batch C10 (FILE SAJA, belum deploy — deploy sesudah migrasi 011):
// - Kind baru: 'master' (WS0 — perubahan master-data, LWW server
//   by updated_at), 'stock_in' (WS1 — gudang += qty), 'brew'
//   (WS4 — Teh Kering −, Teh Masak +), 'stock_send' (WS3 —
//   gudang −, gerai +, race guard 'gudang_kurang'), 'opname'
//   (WS6 — catat baris opname; delta lewat stock_movement).
// - Reason mutasi baru: 'brew' / 'kedaluwarsa' / 'opname' /
//   'kirim' (lihat pushStockMovement).
// - Pull gudang (outlet_id = GUDANG_ID) melewati cek tabel
//   outlets (gudang bukan gerai) + mengembalikan stock_ins.
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
// Batch C9 (sinkronisasi database — FILE SAJA, belum deploy):
// - PERBAIKAN BUG 23505 di pushStockMovement: client_uuid event
//   yang SAMA dipakai semua item (unique di stock_movements)
//   membuat item ke-2 dst SELALU kena 23505 lalu `continue` —
//   delta-nya TIDAK PERNAH diterapkan (hanya bahan PERTAMA tiap
//   penjualan yang terpotong di level server). Sekarang per-item:
//   item pertama tetap memakai client_uuid event (kompatibel retry
//   event lama), item berikutnya memakai UUID turunan deterministik
//   `${clientUuid}:${name}` (idempotent di retry, unik per item).
// - Reason mutasi 'koreksi' + 'tambah' (harga / koreksi jumlah /
//   bahan baru — Batch C9 WS4) diteruskan ke kolom reason.
// - Pull + expenses (WS5), closed_shifts + movements (WS6).
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

/// Batch C10 — gudang = pseudo-outlet (bukan gerai nyata; TIDAK ADA
/// baris di tabel outlets). HARUS sama dengan gudangOutletId di
/// lib/data/c10_models.dart.
const GUDANG_ID = "00000000-0000-0000-0000-000000000000";
/// Gerai kanonik resep (resep disimpan global di gerai ini — lihat
/// migrasi 011 + StockService.setRecipe). HARUS sama dengan
/// defaultOutletId di app.
const CANONICAL_OUTLET_ID = "00000000-0000-0000-0000-000000000001";

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
  // Batch C9: 'koreksi' (ubah harga / koreksi jumlah manual) +
  // 'tambah' (bahan baru) diteruskan — kolom reason tanpa CHECK.
  // Batch C10: 'opname' (penyesuaian stok sesudah "Sesuaikan
  // stok" — dari adjustLevels), 'kedaluwarsa' (sisa Teh Masak
  // kemarin hangus — dari expireTehMasak), 'brew' + 'kirim'
  // (tidak pernah datang sebagai stock_movement dari app, tapi
  // diizinkan supaya alasan tidak diam-diam jadi 'penjualan').
  const KNOWN_REASONS = new Set([
    "void",
    "koreksi",
    "tambah",
    "opname",
    "kedaluwarsa",
    "brew",
    "kirim",
  ]);
  const reason = KNOWN_REASONS.has(reasonRaw) ? reasonRaw : "penjualan";

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
  for (let idx = 0; idx < items.length; idx++) {
    const raw = items[idx];
    const item = raw as Record<string, unknown>;
    const name = String(item.name ?? "");
    if (name === "") throw new Error("item stok tanpa nama");
    // Batch C9 — BUG 23505: client_uuid event yang SAMA untuk semua
    // item (unique di stock_movements) membuat item ke-2 dst SELALU
    // kena 23505 lalu `continue` — delta-nya TIDAK PERNAH
    // diterapkan (hanya bahan PERTAMA tiap penjualan yang terpotong
    // di level server). Per-item: item pertama TETAP memakai
    // client_uuid event (kompatibel retry event lama — barisnya
    // sudah ada dengan UUID itu), item berikutnya memakai UUID
    // turunan deterministik `${clientUuid}:${name}` (idempotent di
    // retry, unik per item).
    const itemUuid = idx === 0
      ? clientUuid
      : await normalizeClientUuid(`${clientUuid}:${name}`);
    const unit =
      typeof item.unit === "string" && item.unit !== ""
        ? item.unit
        : "pcs";
    const qtyAfter = toNumber(item.qty_after, "item.qty_after");
    const lowThreshold = toNumber(item.low_threshold ?? 0, "item.low_threshold");
    // Batch C10.1 Bug 2b: cost_per_unit yang TIDAK DIKIRIM atau 0
    // = biaya belum diatur — JANGAN menimpa harga server dengan 0
    // (sentinel -1 app hancur; itu akar HPP Rp0). Harga hanya
    // diubah bila item membawa biaya > 0. Biaya 0 yang asli
    // (gratis, diatur Owner) sampai lewat event master
    // 'stock_item_config', bukan lewat mutasi.
    const rawCost = item.cost_per_unit;
    const hasCost = typeof rawCost === "number" && rawCost > 0;
    const cost = hasCost
      ? toNonNegInt(rawCost, "item.cost_per_unit")
      : 0;
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
      const stockPatch: Record<string, unknown> = {
        unit,
        low_threshold: lowThreshold,
      };
      // Hanya bila item membawa biaya: tanpa biaya, harga server
      // dibiarkan (jangan timpa dengan 0 — lihat hasCost di atas).
      if (hasCost) stockPatch["cost"] = cost;
      const { error: updErr } = await supabase
        .from("stock_items")
        .update(stockPatch)
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
    //    Batch C9: client_uuid di sini PER-ITEM (lihat atas) —
    //    item ke-2 dst tidak lagi tertukar dengan kirim ulang.
    const { data: moved, error: movErr } = await supabase
      .from("stock_movements")
      .insert({
        outlet_id: outletId,
        stock_item_id: stockId,
        qty_delta: delta,
        reason,
        transaction_id: transactionId,
        client_uuid: itemUuid,
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
// ===================== Batch C10 =====================
// Master-data + gudang + kirim + masak + opname (lihat
// ~/workspace/suka-tea-c10/C10-BRIEF.md §3). FILE SAJA — belum
// di-deploy (builder C10 tidak deploy; deploy sesudah migrasi
// 011 di-apply via SQL Editor).
//
// ATURAN DELTA (hindari dobel hitung — baca dulu sebelum ubah):
// - pushStockIn: SATU-SATUNYA penulis delta gudang untuk stok
//   masuk (app TIDAK mengirim stock_movement untuk stok masuk —
//   adjustLevels enqueueMovement=false).
// - pushBrew: SATU-SATUNYA penulis delta masak (Teh Kering −,
//   Teh Masak +). App TIDAK mengirim stock_movement untuk masak.
//   'kedaluwarsa' TIDAK ditulis di sini — delta hangus datang
//   lewat event stock_movement 'kedaluwarsa' (expireTehMasak)
//   yang sudah diantre SEBELUM event brew; menulisnya lagi di
//   sini = dobel potong.
// - pushStockSend: SATU-SATUNYA penulis delta kirim (gudang −,
//   gerai +). App TIDAK mengirim stock_movement untuk kirim
//   (transferStock tidak mengantre apa-apa).
// - pushOpname: TIDAK menulis mutasi sama sekali — delta
//   penyesuaian datang lewat event stock_movement 'opname'
//   (adjustOpname). Handler ini hanya mencatat baris opname.
// - pushMaster: last-write-wins by updated_at (server) — event
//   yang lebih tua dari baris tersimpan dilewati (tetap ok).

/// Ambil baris stock_items (outlet_id, name); bila belum ada, buat
/// qty 0. Dipakai pushMaster (resep), pushStockIn, pushBrew,
/// pushStockSend. 23505 (balapan device lain) = baca ulang.
async function getOrCreateStockRow(
  supabase: Supabase,
  outletId: string,
  name: string,
  unit: string,
): Promise<{ id: string; qty: number }> {
  const { data: existing } = await supabase
    .from("stock_items")
    .select("id, qty")
    .eq("outlet_id", outletId)
    .eq("name", name)
    .maybeSingle();
  if (existing != null) {
    const row = existing as { id: string; qty: number };
    return { id: row.id, qty: Number(row.qty ?? 0) };
  }
  const { data: created, error: insErr } = await supabase
    .from("stock_items")
    .insert({
      outlet_id: outletId,
      name,
      unit,
      qty: 0,
      low_threshold: 0,
      cost: 0,
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
      const row = raced as { id: string; qty: number };
      return { id: row.id, qty: Number(row.qty ?? 0) };
    }
    throw new Error(`buat stok gagal: ${insErr.message}`);
  }
  const row = created as { id: string; qty: number };
  return { id: row.id, qty: Number(row.qty ?? 0) };
}

/// Terapkan SATU delta ke level stok + catat mutasi (idempotent):
/// sisip mutasi dulu (23505 = sudah diterapkan — lewati, jangan
/// terapkan delta lagi), baru update level (clamp >= 0).
/// Mengembalikan true bila delta diterapkan, false bila sudah ada
/// (kirim ulang / retry).
async function applyStockDelta(
  supabase: Supabase,
  outletId: string,
  stockRow: { id: string; qty: number },
  delta: number,
  reason: string,
  clientUuid: string,
): Promise<boolean> {
  const { data: moved, error: movErr } = await supabase
    .from("stock_movements")
    .insert({
      outlet_id: outletId,
      stock_item_id: stockRow.id,
      qty_delta: delta,
      reason,
      transaction_id: null,
      client_uuid: clientUuid,
    })
    .select("id")
    .single();
  if (movErr) {
    if ((movErr as { code?: string }).code === "23505") return false;
    throw new Error(`sisip mutasi gagal: ${movErr.message}`);
  }
  if (moved == null) return false;
  const nextQty = Math.max(0, stockRow.qty + delta);
  const { error: lvlErr } = await supabase
    .from("stock_items")
    .update({ qty: nextQty })
    .eq("id", stockRow.id);
  if (lvlErr) throw new Error(`update level stok gagal: ${lvlErr.message}`);
  return true;
}

/// Upsert satu perubahan master-data (Batch C10 WS0).
/// LWW server: incoming updated_at < stored updated_at = lewati
/// (tetap ok — bukan error; HP pengirim sudah ketinggalan).
/// entity: package / package_item / package_default / recipe /
/// topping / product / target / stock_item_config.
async function pushMaster(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ applied: boolean }> {
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const entity = String(p.entity ?? "");
  const entityId = String(p.entity_id ?? "");
  const data = p.data as Record<string, unknown> | undefined;
  if (entity === "") throw new Error("master: entity kosong");
  if (entityId === "") throw new Error("master: entity_id kosong");
  if (data == null || typeof data !== "object") {
    throw new Error("master: data hilang");
  }
  const updatedAt = String(p.updated_at ?? new Date().toISOString());
  const isDeleted = p.is_deleted === true;
  const incoming = new Date(updatedAt);
  if (Number.isNaN(incoming.getTime())) {
    throw new Error("master: updated_at tidak valid");
  }

  // LWW: bandingkan dengan updated_at baris tersimpan (bila ada).
  async function storedUpdatedAt(
    table: string,
    keyCol: string,
    keyVal: string,
  ): Promise<Date | null> {
    const { data: row } = await supabase
      .from(table)
      .select("updated_at")
      .eq(keyCol, keyVal)
      .maybeSingle();
    const raw = (row as { updated_at?: string } | null)?.updated_at;
    if (raw == null) return null;
    const d = new Date(raw);
    return Number.isNaN(d.getTime()) ? null : d;
  }

  if (entity === "package") {
    const stored = await storedUpdatedAt("packages", "id", entityId);
    if (stored != null && incoming.getTime() < stored.getTime()) {
      return { applied: false };
    }
    const { error } = await supabase.from("packages").upsert(
      {
        id: entityId,
        name: String(data.name ?? ""),
        note: String(data.note ?? ""),
        is_active: isDeleted ? false : data.is_active !== false,
        updated_at: updatedAt,
        is_deleted: isDeleted,
      },
      { onConflict: "id" },
    );
    if (error) throw new Error(`upsert paket gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "package_item") {
    const stored = await storedUpdatedAt("package_items", "id", entityId);
    if (stored != null && incoming.getTime() < stored.getTime()) {
      return { applied: false };
    }
    const packageId = String(data.package_id ?? "");
    if (packageId === "") throw new Error("package_item: package_id kosong");
    const { error } = await supabase.from("package_items").upsert(
      {
        id: entityId,
        package_id: packageId,
        stock_name: String(data.stock_name ?? ""),
        qty: toNumber(data.qty ?? 0, "package_item.qty"),
        unit: String(data.unit ?? "pcs"),
        updated_at: updatedAt,
        is_deleted: isDeleted,
      },
      { onConflict: "id" },
    );
    if (error) throw new Error(`upsert item paket gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "package_default") {
    const stored = await storedUpdatedAt(
      "outlet_package_defaults",
      "outlet_id",
      entityId,
    );
    if (stored != null && incoming.getTime() < stored.getTime()) {
      return { applied: false };
    }
    const packageId =
      typeof data.package_id === "string" && data.package_id !== ""
        ? data.package_id
        : null;
    const { error } = await supabase
      .from("outlet_package_defaults")
      .upsert(
        {
          outlet_id: entityId,
          package_id: packageId,
          updated_at: updatedAt,
        },
        { onConflict: "outlet_id" },
      );
    if (error) throw new Error(`upsert default paket gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "target") {
    const stored = await storedUpdatedAt(
      "gerai_targets",
      "outlet_id",
      entityId,
    );
    if (stored != null && incoming.getTime() < stored.getTime()) {
      return { applied: false };
    }
    const { error } = await supabase.from("gerai_targets").upsert(
      {
        outlet_id: entityId,
        target_omzet: toNonNegInt(data.target_omzet ?? 0, "target_omzet"),
        updated_at: updatedAt,
      },
      { onConflict: "outlet_id" },
    );
    if (error) throw new Error(`upsert target gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "topping") {
    const stored = await storedUpdatedAt("app_toppings", "id", entityId);
    if (stored != null && incoming.getTime() < stored.getTime()) {
      return { applied: false };
    }
    const { error } = await supabase.from("app_toppings").upsert(
      {
        id: entityId,
        name: String(data.name ?? ""),
        price_delta: toNonNegInt(data.price_delta ?? 0, "price_delta"),
        active: isDeleted ? false : data.active !== false,
        updated_at: updatedAt,
        is_deleted: isDeleted,
      },
      { onConflict: "id" },
    );
    if (error) throw new Error(`upsert topping gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "product") {
    const stored = await storedUpdatedAt("app_products", "id", entityId);
    if (stored != null && incoming.getTime() < stored.getTime()) {
      return { applied: false };
    }
    const { error } = await supabase.from("app_products").upsert(
      {
        id: entityId,
        name: String(data.name ?? ""),
        category: String(data.category ?? "Mixtea"),
        price: toNonNegInt(data.price ?? 0, "price"),
        photo_url:
          typeof data.photo_url === "string" ? data.photo_url : null,
        is_active: isDeleted ? false : data.is_active !== false,
        updated_at: updatedAt,
        is_deleted: isDeleted,
      },
      { onConflict: "id" },
    );
    if (error) throw new Error(`upsert produk gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "recipe") {
    // Resep disimpan global di gerai kanonik (...0001) — kunci
    // (variant_id, stock_item_id). stock_item_id dicari dari nama
    // bahan di gerai kanonik (dibuat qty 0 bila belum ada).
    const variantId = String(data.variant_id ?? "");
    const stockName = String(data.stock_name ?? "");
    if (variantId === "" || stockName === "") {
      throw new Error("recipe: variant_id / stock_name kosong");
    }
    const stockRow = await getOrCreateStockRow(
      supabase,
      CANONICAL_OUTLET_ID,
      stockName,
      String(data.unit ?? "pcs"),
    );
    const { data: storedRow } = await supabase
      .from("product_recipes")
      .select("updated_at")
      .eq("variant_id", variantId)
      .eq("stock_item_id", stockRow.id)
      .maybeSingle();
    const storedRaw = (storedRow as { updated_at?: string } | null)
      ?.updated_at;
    if (storedRaw != null) {
      const stored = new Date(storedRaw);
      if (!Number.isNaN(stored.getTime()) &&
        incoming.getTime() < stored.getTime()) {
        return { applied: false };
      }
    }
    const { error } = await supabase.from("product_recipes").upsert(
      {
        outlet_id: CANONICAL_OUTLET_ID,
        product_id: String(data.product_id ?? ""),
        variant_id: variantId,
        stock_item_id: stockRow.id,
        qty: isDeleted ? 0.001 : toNumber(data.qty ?? 0, "recipe.qty"),
        updated_at: updatedAt,
        is_deleted: isDeleted,
      },
      { onConflict: "variant_id,stock_item_id" },
    );
    // qty punya CHECK > 0 — hapus disimpan qty 0.001 + is_deleted
    // (baris tidak dipakai karena is_deleted; angka 0.001 hanya
    // supaya CHECK lolos).
    if (error) throw new Error(`upsert resep gagal: ${error.message}`);
    return { applied: true };
  }

  if (entity === "stock_item_config") {
    // Konfigurasi bahan (unit/ambang/harga/masa simpan) — qty
    // TIDAK PERNAH disentuh di sini (qty digerakkan delta).
    // Ganti nama: data.old_name -> data.name (baris diganti nama +
    // resep ikut lewat stock_item_id — tidak perlu update resep).
    const outletId = String(data.outlet_id ?? "");
    const name = String(data.name ?? "");
    if (outletId === "" || name === "") {
      throw new Error("stock_item_config: outlet_id / name kosong");
    }
    const oldName =
      typeof data.old_name === "string" && data.old_name !== ""
        ? data.old_name
        : null;
    if (oldName != null && oldName !== name) {
      const { error: renErr } = await supabase
        .from("stock_items")
        .update({ name, updated_at: updatedAt })
        .eq("outlet_id", outletId)
        .eq("name", oldName);
      if (renErr) {
        throw new Error(`ganti nama bahan gagal: ${renErr.message}`);
      }
    }
    const row = await getOrCreateStockRow(
      supabase,
      outletId,
      name,
      String(data.unit ?? "pcs"),
    );
    const { data: storedRow } = await supabase
      .from("stock_items")
      .select("updated_at")
      .eq("id", row.id)
      .maybeSingle();
    const storedRaw = (storedRow as { updated_at?: string } | null)
      ?.updated_at;
    if (storedRaw != null) {
      const stored = new Date(storedRaw);
      if (!Number.isNaN(stored.getTime()) &&
        incoming.getTime() < stored.getTime()) {
        return { applied: false };
      }
    }
    const patch: Record<string, unknown> = { updated_at: updatedAt };
    if (typeof data.unit === "string" && data.unit !== "") {
      patch["unit"] = data.unit;
    }
    if (typeof data.low_threshold === "number") {
      patch["low_threshold"] = data.low_threshold;
    }
    if (typeof data.cost_per_unit === "number") {
      patch["cost"] = Math.max(0, Math.trunc(data.cost_per_unit));
    }
    if (typeof data.shelf_life_days === "number") {
      patch["shelf_life_days"] = Math.max(
        0,
        Math.trunc(data.shelf_life_days),
      );
    }
    const { error } = await supabase
      .from("stock_items")
      .update(patch)
      .eq("id", row.id);
    if (error) throw new Error(`upsert konfigurasi gagal: ${error.message}`);
    return { applied: true };
  }

  throw new Error(`master: entity tidak dikenal: ${entity}`);
}

/// Stok masuk gudang (Batch C10 WS1): gudang += qty (delta) +
/// catat baris stock_ins. Idempotent by client_uuid — urutan:
/// sisip baris dulu, baru terapkan delta (keduanya idempotent:
/// baris by client_uuid, delta by mutasi 23505) — retry sesudah
/// gagal di tengah tidak pernah dobel.
async function pushStockIn(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ applied: boolean }> {
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const name = String(p.stock_name ?? "");
  const qty = toNumber(p.qty ?? 0, "stock_in.qty");
  if (name === "") throw new Error("stock_in: stock_name kosong");
  if (qty <= 0) throw new Error("stock_in: qty harus > 0");
  const unit = typeof p.unit === "string" && p.unit !== "" ? p.unit : "pcs";
  const totalPrice = toNonNegInt(p.total_price ?? 0, "total_price");
  const { error: insErr } = await supabase.from("stock_ins").upsert(
    {
      id: clientUuid,
      client_uuid: clientUuid,
      stock_name: name,
      unit,
      qty,
      total_price: totalPrice,
      supplier: typeof p.supplier === "string" ? p.supplier : "",
      date: String(p.date ?? new Date().toISOString()).slice(0, 10),
      note: typeof p.note === "string" ? p.note : "",
      created_at: String(ev.created_at ?? new Date().toISOString()),
    },
    { onConflict: "client_uuid" },
  );
  if (insErr) throw new Error(`sisip stok masuk gagal: ${insErr.message}`);
  const row = await getOrCreateStockRow(supabase, GUDANG_ID, name, unit);
  const itemUuid = await normalizeClientUuid(`${clientUuid}:${name}`);
  await applyStockDelta(
    supabase,
    GUDANG_ID,
    row,
    qty,
    "tambah",
    itemUuid,
  );
  // Harga beli total -> costPerUnit baru (total / qty) menggantikan
  // harga lama — sama seperti app (recordStockIn -> setCostFor).
  if (totalPrice > 0) {
    const newCost = Math.max(0, Math.round(totalPrice / qty));
    const { error: costErr } = await supabase
      .from("stock_items")
      .update({ cost: newCost })
      .eq("id", row.id);
    if (costErr) throw new Error(`update harga gagal: ${costErr.message}`);
  }
  return { applied: true };
}

/// Masak teh (Batch C10 WS4): Teh Kering −kg, Teh Masak +liter di
/// gerai (delta + mutasi 'brew'). Idempotent by client_uuid —
/// sisip baris dulu, baru terapkan delta (retry aman, lihat
/// pushStockIn). 'kedaluwarsa' TIDAK ditulis di sini (lihat
/// catatan di atas).
async function pushBrew(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ applied: boolean }> {
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const kg = toNumber(p.kg_used ?? 0, "brew.kg_used");
  const liters = toNumber(p.liters_made ?? 0, "brew.liters_made");
  if (kg <= 0) throw new Error("brew: kg_used harus > 0");
  if (liters <= 0) throw new Error("brew: liters_made harus > 0");
  const { error: insErr } = await supabase.from("brews").upsert(
    {
      id: clientUuid,
      client_uuid: clientUuid,
      outlet_id: outletId,
      kg_used: kg,
      liters_made: liters,
      brewed_at: String(ev.created_at ?? new Date().toISOString()),
      brewed_by: typeof p.brewed_by === "string" ? p.brewed_by : "Kasir",
      expired_liters: toNumber(p.expired_liters ?? 0, "expired_liters"),
      created_at: String(ev.created_at ?? new Date().toISOString()),
    },
    { onConflict: "client_uuid" },
  );
  if (insErr) throw new Error(`sisip masak gagal: ${insErr.message}`);
  const keringRow = await getOrCreateStockRow(
    supabase,
    outletId,
    "Teh Kering",
    "kg",
  );
  const masakRow = await getOrCreateStockRow(
    supabase,
    outletId,
    "Teh Masak",
    "liter",
  );
  const keringUuid = await normalizeClientUuid(`${clientUuid}:Teh Kering`);
  const masakUuid = await normalizeClientUuid(`${clientUuid}:Teh Masak`);
  await applyStockDelta(
    supabase,
    outletId,
    keringRow,
    -kg,
    "brew",
    keringUuid,
  );
  await applyStockDelta(
    supabase,
    outletId,
    masakRow,
    liters,
    "brew",
    masakUuid,
  );
  return { applied: true };
}

/// Kirim ke gerai (Batch C10 WS3): cek gudang DULU (race guard —
/// dua HP kirim bersamaan), lalu gudang − + gerai + (delta +
/// mutasi 'kirim' di kedua sisi). Idempotent by client_uuid —
/// sisip baris kiriman dulu (upsert), baru terapkan delta (retry
/// aman, lihat pushStockIn). Gudang kurang -> throw
/// Error("gudang_kurang") — app membalik stok lokal + memberi tahu
/// Owner (bukan retry diam-diam).
async function pushStockSend(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ applied: boolean }> {
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const items = Array.isArray(p.items) ? p.items : [];
  if (items.length === 0) throw new Error("stock_send: items kosong");
  const parsed: { name: string; qty: number; unit: string }[] = [];
  for (const raw of items) {
    const it = raw as Record<string, unknown>;
    const name = String(it.stock_name ?? "");
    const qty = toNumber(it.qty ?? 0, "send.qty");
    if (name === "") throw new Error("stock_send: item tanpa nama");
    if (qty <= 0) throw new Error("stock_send: item qty harus > 0");
    parsed.push({
      name,
      qty,
      unit: typeof it.unit === "string" && it.unit !== "" ? it.unit : "pcs",
    });
  }
  // Race guard: baca gudang SEKARANG — bila kurang untuk SATU saja
  // item, tolak SELURUH kiriman (tidak ada yang dipindah). Cek ini
  // HARUS sebelum sisip baris kiriman (kiriman yang ditolak tidak
  // boleh tercatat 'ok').
  for (const it of parsed) {
    const { data: row } = await supabase
      .from("stock_items")
      .select("qty")
      .eq("outlet_id", GUDANG_ID)
      .eq("name", it.name)
      .maybeSingle();
    const have = row == null ? 0 : Number((row as { qty: number }).qty ?? 0);
    if (have < it.qty) throw new Error("gudang_kurang");
  }
  const { error: insErr } = await supabase.from("stock_sends").upsert(
    {
      id: clientUuid,
      client_uuid: clientUuid,
      outlet_id: outletId,
      package_id:
        typeof p.package_id === "string" && p.package_id !== ""
          ? p.package_id
          : null,
      package_name: typeof p.package_name === "string" ? p.package_name : "",
      sent_at: String(ev.created_at ?? new Date().toISOString()),
      sent_by: typeof p.sent_by === "string" ? p.sent_by : "Owner",
      note: typeof p.note === "string" ? p.note : "",
      status: "ok",
      created_at: String(ev.created_at ?? new Date().toISOString()),
    },
    { onConflict: "client_uuid" },
  );
  if (insErr) throw new Error(`sisip kiriman gagal: ${insErr.message}`);
  for (const it of parsed) {
    const gudangRow = await getOrCreateStockRow(
      supabase,
      GUDANG_ID,
      it.name,
      it.unit,
    );
    const geraiRow = await getOrCreateStockRow(
      supabase,
      outletId,
      it.name,
      it.unit,
    );
    const outUuid = await normalizeClientUuid(
      `${clientUuid}:gudang:${it.name}`,
    );
    const inUuid = await normalizeClientUuid(
      `${clientUuid}:gerai:${it.name}`,
    );
    await applyStockDelta(
      supabase,
      GUDANG_ID,
      gudangRow,
      -it.qty,
      "kirim",
      outUuid,
    );
    await applyStockDelta(
      supabase,
      outletId,
      geraiRow,
      it.qty,
      "kirim",
      inUuid,
    );
  }
  const sendItems = parsed.map((it) => ({
    id: `${clientUuid}:${it.name}`,
    send_id: clientUuid,
    stock_name: it.name,
    qty: it.qty,
    unit: it.unit,
  }));
  const { error: itemsErr } = await supabase
    .from("send_items")
    .upsert(sendItems, { onConflict: "id" });
  if (itemsErr) {
    throw new Error(`sisip item kiriman gagal: ${itemsErr.message}`);
  }
  return { applied: true };
}

async function pushOpname(
  supabase: Supabase,
  ev: Record<string, unknown>,
): Promise<{ applied: boolean }> {
  const p = ev.payload as Record<string, unknown> | undefined;
  if (p == null || typeof p !== "object") throw new Error("payload hilang");
  const outletId = String(ev.outlet_id ?? "");
  if (!UUID_RE.test(outletId)) throw new Error("outlet_id bukan UUID");
  const clientUuid = await normalizeClientUuid(String(ev.client_uuid ?? ""));
  const name = String(p.stock_name ?? "");
  const systemQty = toNumber(p.system_qty ?? 0, "opname.system_qty");
  const physicalQty = toNumber(p.physical_qty ?? 0, "opname.physical_qty");
  if (name === "") throw new Error("opname: stock_name kosong");
  if (systemQty < 0) throw new Error("opname: system_qty negatif");
  if (physicalQty < 0) throw new Error("opname: physical_qty negatif");
  const { error } = await supabase.from("stock_opnames").upsert(
    {
      id: clientUuid,
      client_uuid: clientUuid,
      outlet_id: outletId,
      stock_name: name,
      system_qty: systemQty,
      physical_qty: physicalQty,
      difference: physicalQty - systemQty,
      counted_at: String(ev.created_at ?? new Date().toISOString()),
      counted_by: typeof p.counted_by === "string" ? p.counted_by : "Owner",
      note: typeof p.note === "string" ? p.note : "",
      adjusted: p.adjusted === true,
      updated_at: String(ev.created_at ?? new Date().toISOString()),
    },
    { onConflict: "client_uuid" },
  );
  if (error) throw new Error(`upsert opname gagal: ${error.message}`);
  return { applied: true };
}

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
  // Batch C10: gudang = pseudo-outlet — TIDAK ADA baris di tabel
  // outlets (bukan gerai nyata) — lewati cek gerai untuk gudang.
  // Query transaksi/shift/pengeluaran untuk gudang tetap jalan
  // (hasilnya kosong — gudang tidak jualan).
  const isGudang = outletId === GUDANG_ID;
  if (!isGudang) {
    const { data: outlet, error: outletErr } = await supabase
      .from("outlets")
      .select("id")
      .eq("id", outletId)
      .maybeSingle();
    if (outletErr) throw new Error(`cek gerai gagal: ${outletErr.message}`);
    if (outlet == null) throw new Error("outlet_id tidak dikenal");
  }

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
  // Batch C10: + shelf_life_days (WS4 — Teh Masak 1 hari) +
  // updated_at (WS0 — LWW konfigurasi bahan).
  const { data: stockRows, error: stockErr } = await supabase
    .from("stock_items")
    .select("name, unit, qty, low_threshold, cost, shelf_life_days, updated_at")
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
      shelf_life_days: s["shelf_life_days"] ?? 0,
      updated_at: s["updated_at"],
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

  // Pengeluaran gerai itu di jendela yang sama (Batch C9 WS5 —
  // Keuangan/Laporan antar device: pengeluaran HP lain ikut
  // mengurangi laba bersih di HP ini).
  const { data: expenseRows, error: expErr } = await supabase
    .from("expenses")
    .select(
      "client_uuid, outlet_id, category, description, amount, is_cash, cashier_name, created_at",
    )
    .eq("outlet_id", outletId)
    .gte("created_at", start.toISOString())
    .lt("created_at", end.toISOString())
    .order("created_at", { ascending: false });
  if (expErr) throw new Error(`baca pengeluaran gagal: ${expErr.message}`);
  const expenses = (expenseRows ?? []) as Record<string, unknown>[];

  // Shift yang SUDAH DITUTUP di jendela yang sama (Batch C9 WS6 —
  // riwayat shift antar device; shift TERBUKA tetap di `shifts`).
  // closed_at di jendela (shift yang dibuka 40 hari lalu tapi
  // ditutup kemarin tetap ketarik).
  const { data: closedRows, error: closedErr } = await supabase
    .from("cash_shifts")
    .select(
      "client_uuid, outlet_id, cashier_id, cashier_name, opened_at, opening_float, status, closed_at, closed_by_cashier_id, closed_by_cashier_name, counted_cash, expected_cash, difference",
    )
    .eq("outlet_id", outletId)
    .eq("status", "closed")
    .gte("closed_at", start.toISOString())
    .lt("closed_at", end.toISOString())
    .order("closed_at", { ascending: false })
    .limit(20);
  if (closedErr) {
    throw new Error(`baca shift tutup gagal: ${closedErr.message}`);
  }
  const closedShifts = (closedRows ?? []) as Record<string, unknown>[];

  // Mutasi stok gerai itu di jendela yang sama (Batch C9 WS6 —
  // riwayat keluar-masuk barang di tab Stok). Nama bahan ikut via
  // join ke stock_items.
  const { data: movRows, error: movErr } = await supabase
    .from("stock_movements")
    .select(
      "client_uuid, qty_delta, reason, created_at, stock_items(name)",
    )
    .eq("outlet_id", outletId)
    .gte("created_at", start.toISOString())
    .lt("created_at", end.toISOString())
    .order("created_at", { ascending: false })
    .limit(200);
  if (movErr) throw new Error(`baca mutasi gagal: ${movErr.message}`);
  const movements = ((movRows ?? []) as Record<string, unknown>[]).map(
    (m) => {
      const joined = m["stock_items"] as Record<string, unknown> | null;
      return {
        client_uuid: m["client_uuid"],
        name: joined != null ? joined["name"] : null,
        qty_delta: m["qty_delta"],
        reason: m["reason"],
        created_at: m["created_at"],
      };
    },
  );

  return {
    ok: true,
    outlet_id: outletId,
    from,
    to,
    transactions: txnList,
    items,
    stock,
    shifts,
    expenses,
    closed_shifts: closedShifts,
    movements,
    master_changes: await pullMasterChanges(supabase, outletId),
    sends: await pullSends(supabase, outletId, start, end),
    opnames: await pullOpnames(supabase, outletId, start, end),
    stock_ins: isGudang
      ? await pullStockIns(supabase, start, end)
      : [],
    brews: await pullBrews(supabase, outletId, start, end),
  };
}

/// Master-data untuk pull (Batch C10 WS0): SEMUA baris (bukan
/// jendela 30 hari — HP baru harus mendapat paket/resep/target
/// yang dibuat > 30 hari lalu; tabelnya kecil — produk ~20,
/// resep ~120, konfigurasi ~60 baris).
/// Bentuk tiap baris = MasterChange (lihat master_sync.dart):
/// { entity, entity_id, updated_at, is_deleted, data }.
/// Konfigurasi bahan (stock_item_config) HANYA untuk gerai yang
/// diminta (per-gerai); sisanya global (produk/topping/paket/
//// resep/target berlaku di semua gerai).
async function pullMasterChanges(
  supabase: Supabase,
  outletId: string,
): Promise<Record<string, unknown>[]> {
  const out: Record<string, unknown>[] = [];
  const push = (
    rows: Record<string, unknown>[],
    entity: string,
    idOf: (r: Record<string, unknown>) => string,
    dataOf: (r: Record<string, unknown>) => Record<string, unknown>,
  ) => {
    for (const r of rows) {
      out.push({
        entity,
        entity_id: idOf(r),
        updated_at: r["updated_at"] ?? new Date(0).toISOString(),
        is_deleted: r["is_deleted"] === true,
        data: dataOf(r),
      });
    }
  };
  const { data: products } = await supabase
    .from("app_products")
    .select("id, name, category, price, photo_url, is_active, updated_at, is_deleted");
  push((products ?? []) as Record<string, unknown>[], "product",
    (r) => String(r["id"]),
    (r) => ({
      id: r["id"], name: r["name"], category: r["category"],
      price: r["price"], photo_url: r["photo_url"],
      is_active: r["is_active"],
    }));
  const { data: toppings } = await supabase
    .from("app_toppings")
    .select("id, name, price_delta, active, updated_at, is_deleted");
  push((toppings ?? []) as Record<string, unknown>[], "topping",
    (r) => String(r["id"]),
    (r) => ({
      id: r["id"], name: r["name"], price_delta: r["price_delta"],
      active: r["active"],
    }));
  const { data: packages } = await supabase
    .from("packages")
    .select("id, name, note, is_active, updated_at, is_deleted");
  push((packages ?? []) as Record<string, unknown>[], "package",
    (r) => String(r["id"]),
    (r) => ({
      id: r["id"], name: r["name"], note: r["note"],
      is_active: r["is_active"],
    }));
  const { data: pkgItems } = await supabase
    .from("package_items")
    .select("id, package_id, stock_name, qty, unit, updated_at, is_deleted");
  push((pkgItems ?? []) as Record<string, unknown>[], "package_item",
    (r) => String(r["id"]),
    (r) => ({
      id: r["id"], package_id: r["package_id"],
      stock_name: r["stock_name"], qty: r["qty"], unit: r["unit"],
    }));
  const { data: defaults } = await supabase
    .from("outlet_package_defaults")
    .select("outlet_id, package_id, updated_at");
  push((defaults ?? []) as Record<string, unknown>[], "package_default",
    (r) => String(r["outlet_id"]),
    (r) => ({ outlet_id: r["outlet_id"], package_id: r["package_id"] }));
  const { data: targets } = await supabase
    .from("gerai_targets")
    .select("outlet_id, target_omzet, updated_at");
  push((targets ?? []) as Record<string, unknown>[], "target",
    (r) => String(r["outlet_id"]),
    (r) => ({ outlet_id: r["outlet_id"], target_omzet: r["target_omzet"] }));
  const { data: recipes } = await supabase
    .from("product_recipes")
    .select("variant_id, product_id, qty, updated_at, is_deleted, stock_items(name, unit)")
    .eq("outlet_id", CANONICAL_OUTLET_ID);
  push((recipes ?? []) as Record<string, unknown>[], "recipe",
    (r) => {
      const joined = r["stock_items"] as Record<string, unknown> | null;
      return `${String(r["variant_id"])}|${joined != null ? String(joined["name"] ?? "") : ""}`;
    },
    (r) => {
      const joined = r["stock_items"] as Record<string, unknown> | null;
      return {
        variant_id: r["variant_id"], product_id: r["product_id"],
        stock_name: joined != null ? joined["name"] : "",
        qty: r["qty"], unit: joined != null ? joined["unit"] : "pcs",
      };
    });
  const { data: configs } = await supabase
    .from("stock_items")
    .select("outlet_id, name, unit, low_threshold, cost, shelf_life_days, updated_at")
    .eq("outlet_id", outletId);
  push((configs ?? []) as Record<string, unknown>[], "stock_item_config",
    (r) => `${String(r["outlet_id"])}|${String(r["name"])}`,
    (r) => ({
      outlet_id: r["outlet_id"], name: r["name"], unit: r["unit"],
      low_threshold: r["low_threshold"], cost_per_unit: r["cost"],
      shelf_life_days: r["shelf_life_days"] ?? 0,
    }));
  return out;
}

/// Kiriman ke gerai yang diminta di jendela (Batch C10 WS3) —
/// item disisipkan sebagai `items` per kiriman.
async function pullSends(
  supabase: Supabase,
  outletId: string,
  start: Date,
  end: Date,
): Promise<Record<string, unknown>[]> {
  const { data: sends } = await supabase
    .from("stock_sends")
    .select("id, client_uuid, outlet_id, package_id, package_name, sent_at, sent_by, note, status")
    .eq("outlet_id", outletId)
    .gte("sent_at", start.toISOString())
    .lt("sent_at", end.toISOString())
    .order("sent_at", { ascending: false });
  const list = (sends ?? []) as Record<string, unknown>[];
  if (list.length === 0) return [];
  const ids = list.map((s) => String(s["id"]));
  const { data: items } = await supabase
    .from("send_items")
    .select("send_id, stock_name, qty, unit")
    .in("send_id", ids);
  const bySend = new Map<string, Record<string, unknown>[]>();
  for (const it of (items ?? []) as Record<string, unknown>[]) {
    const key = String(it["send_id"]);
    const arr = bySend.get(key) ?? [];
    arr.push({
      stock_name: it["stock_name"], qty: it["qty"], unit: it["unit"],
    });
    bySend.set(key, arr);
  }
  return list.map((s) => ({
    ...s,
    items: bySend.get(String(s["id"])) ?? [],
  }));
}

/// Baris opname gerai yang diminta di jendela (Batch C10 WS6).
async function pullOpnames(
  supabase: Supabase,
  outletId: string,
  start: Date,
  end: Date,
): Promise<Record<string, unknown>[]> {
  const { data } = await supabase
    .from("stock_opnames")
    .select("id, client_uuid, outlet_id, stock_name, system_qty, physical_qty, difference, counted_at, counted_by, note, adjusted")
    .eq("outlet_id", outletId)
    .gte("counted_at", start.toISOString())
    .lt("counted_at", end.toISOString())
    .order("counted_at", { ascending: false });
  return (data ?? []) as Record<string, unknown>[];
}

/// Stok masuk gudang di jendela (Batch C10 WS1 — hanya untuk pull
/// gudang; gerai biasa tidak menerima daftar ini).
async function pullStockIns(
  supabase: Supabase,
  start: Date,
  end: Date,
): Promise<Record<string, unknown>[]> {
  const { data } = await supabase
    .from("stock_ins")
    .select("id, client_uuid, stock_name, unit, qty, total_price, supplier, date, note, created_at")
    .gte("created_at", start.toISOString())
    .lt("created_at", end.toISOString())
    .order("created_at", { ascending: false });
  return (data ?? []) as Record<string, unknown>[];
}

/// Riwayat masak gerai yang diminta di jendela (Batch C10 WS4).
async function pullBrews(
  supabase: Supabase,
  outletId: string,
  start: Date,
  end: Date,
): Promise<Record<string, unknown>[]> {
  const { data } = await supabase
    .from("brews")
    .select("id, client_uuid, outlet_id, kg_used, liters_made, brewed_at, brewed_by, expired_liters")
    .eq("outlet_id", outletId)
    .gte("brewed_at", start.toISOString())
    .lt("brewed_at", end.toISOString())
    .order("brewed_at", { ascending: false });
  return (data ?? []) as Record<string, unknown>[];
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
          } else if (ev.kind === "master") {
            // Batch C10 WS0 — master-data (last-write-wins server).
            await pushMaster(supabase, ev);
          } else if (ev.kind === "stock_in") {
            // Batch C10 WS1 — stok masuk gudang.
            await pushStockIn(supabase, ev);
          } else if (ev.kind === "brew") {
            // Batch C10 WS4 — masak teh.
            await pushBrew(supabase, ev);
          } else if (ev.kind === "stock_send") {
            // Batch C10 WS3 — kirim ke gerai ('gudang_kurang'
            // dilempar sebagai error event — lihat failedErrors).
            await pushStockSend(supabase, ev);
          } else if (ev.kind === "opname") {
            // Batch C10 WS6 — baris opname.
            await pushOpname(supabase, ev);
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
