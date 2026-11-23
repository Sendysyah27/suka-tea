// SUKA TEA — Edge Function `export-sheets` (Batch C3, implementasi penuh)
// Setelah tutup kasir, kirim ringkasan + baris transaksi ke Google
// Sheets (tab: Ringkasan Harian, Transaksi, Stok/Bahan, Pengeluaran).
// Sheets HANYA untuk laporan/export — Supabase tetap sumber kebenaran.
//
// POST { outlet_id, shift_id } -> { ok, ... }
//   outlet_id = UUID gerai (wajib), shift_id = TANGGAL 'YYYY-MM-DD'
//   (wajib — app tidak punya konsep shift; tutup kasir = harian).
//   200 { ok:true, spreadsheet_id, date, counts:{...}, note? }
//   400 input tidak valid / 501 secret Google belum diisi /
//   500 error Supabase / Sheets API.
//
// KEJUJURAN DATA (penting): penjualan selama ini LOKAL SAJA di HP
// (tidak ada sinkronisasi outbox ke Supabase), jadi tabel
// `transactions` di Supabase kemungkinan besar KOSONG. Fungsi ini
// TIDAK mengarang angka: bila tidak ada data, tab ditulis dengan
// header + baris catatan 'data lokal belum tersinkron' dan response
// membawa counts 0 + note yang sama. Begitu sinkronisasi penjualan
// ada, fungsi ini langsung menulis angka nyata tanpa perubahan.
//
// Auth Google: service account (JWT RS256, dibuat sendiri dengan
// crypto.subtle — tanpa dep googleapis). Secret (JANGAN di repo):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (otomatis tersedia),
//   GOOGLE_SERVICE_ACCOUNT_JSON (fallback: GOOGLE_SERVICE_ACCOUNT_KEY)
//     = isi file JSON service account, satu string JSON utuh.
//   SHEETS_SPREADSHEET_ID (fallback: GOOGLE_SHEET_ID)
//     = ID spreadsheet tujuan (bagian tengah URL docs.google.com/.../d/<ID>/...).
// Spreadsheet HARUS di-share ke email service account (client_email
// di JSON) sebagai Editor, kalau tidak Sheets API mengembalikan 403.
//
// Secret diisi di: Supabase Dashboard -> Edge Functions -> Secrets
// (atau `supabase secrets set`). Bila secret belum diisi, fungsi
// mengembalikan 501 dengan pesan yang menyebut nama secret-nya.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TABS = ["Ringkasan Harian", "Transaksi", "Stok/Bahan", "Pengeluaran"];
const SHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/// A1-notation: nama tab dikutip satu — wajib karena ada spasi dan '/'.
function tabRange(tab: string, a1 = "A1"): string {
  return `'${tab.replaceAll("'", "''")}'!${a1}`;
}

function base64url(data: Uint8Array): string {
  let bin = "";
  data.forEach((b) => {
    bin += String.fromCharCode(b);
  });
  return btoa(bin).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/// Access token Google dari service account (JWT RS256 -> OAuth2 token).
async function googleAccessToken(sa: {
  client_email: string;
  private_key: string;
  token_uri?: string;
}): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: sa.client_email,
    scope: SHEETS_SCOPE,
    aud: sa.token_uri ?? TOKEN_URL,
    exp: now + 3600,
    iat: now,
  };
  const enc = (o: unknown) =>
    base64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc(header)}.${enc(payload)}`;
  const pem = sa.private_key
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64url(new Uint8Array(sig))}`;
  const res = await fetch(sa.token_uri ?? TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || typeof body.access_token !== "string") {
    throw new Error(
      `token Google gagal (${res.status}): ${body.error_description ?? body.error ?? "unknown"}`,
    );
  }
  return body.access_token;
}

/// Satu panggilan Sheets API v4 (throw bila status bukan 2xx).
async function sheetsFetch(
  token: string,
  path: string,
  init?: RequestInit,
): Promise<Record<string, unknown>> {
  const res = await fetch(`https://sheets.googleapis.com/v4/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  const body = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  if (!res.ok) {
    const err = body.error as { message?: string } | undefined;
    throw new Error(
      `Sheets API ${path} gagal (${res.status}): ${err?.message ?? JSON.stringify(body)}`,
    );
  }
  return body;
}

function isDateString(s: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(`${s}T00:00:00+07:00`));
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const saJson = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON") ??
      Deno.env.get("GOOGLE_SERVICE_ACCOUNT_KEY") ?? "";
    const spreadsheetId = Deno.env.get("SHEETS_SPREADSHEET_ID") ??
      Deno.env.get("GOOGLE_SHEET_ID") ?? "";
    if (!supabaseUrl || !serviceKey) {
      return json({ ok: false, error: "Edge Function belum dikonfigurasi" }, 501);
    }
    if (!saJson || !spreadsheetId) {
      const missing = [
        !saJson ? "GOOGLE_SERVICE_ACCOUNT_JSON" : null,
        !spreadsheetId ? "SHEETS_SPREADSHEET_ID" : null,
      ].filter(Boolean).join(" + ");
      return json(
        {
          ok: false,
          error: `Google Sheets belum dikonfigurasi — isi secret ${missing} di Supabase (Edge Functions -> Secrets), lalu share spreadsheet ke email service account sebagai Editor.`,
        },
        501,
      );
    }
    let sa: { client_email: string; private_key: string; token_uri?: string };
    try {
      sa = JSON.parse(saJson);
    } catch {
      return json(
        { ok: false, error: "GOOGLE_SERVICE_ACCOUNT_JSON bukan JSON valid" },
        501,
      );
    }
    if (!sa.client_email || !sa.private_key) {
      return json(
        { ok: false, error: "Service account JSON harus berisi client_email + private_key" },
        501,
      );
    }

    const body = await req.json().catch(() => ({}));
    const outletId = String(body.outlet_id ?? "");
    const shiftId = String(body.shift_id ?? "");
    if (!outletId || !shiftId) {
      return json({ ok: false, error: "outlet_id + shift_id wajib" }, 400);
    }
    if (!isDateString(shiftId)) {
      return json(
        { ok: false, error: "shift_id harus tanggal YYYY-MM-DD (tutup kasir = harian)" },
        400,
      );
    }
    const date = shiftId;
    // Hari dalam WIB (toko di UTC+7): 00:00 WIB = 17:00 UTC hari sebelumnya.
    const dayStart = new Date(`${date}T00:00:00+07:00`);
    const dayEnd = new Date(dayStart.getTime() + 24 * 3600 * 1000);
    const startIso = dayStart.toISOString();
    const endIso = dayEnd.toISOString();

    const supabase = createClient(supabaseUrl, serviceKey);

    // --- Baca data Supabase (service_role, RLS dilewati) ---
    const { data: summaryRows, error: summaryError } = await supabase
      .from("v_daily_summary")
      .select("jumlah_transaksi, omzet, tunai, transfer, qris_manual, ewallet")
      .eq("outlet_id", outletId)
      .eq("hari", date);
    if (summaryError) {
      return json({ ok: false, error: summaryError.message }, 500);
    }
    const { data: txns, error: txnError } = await supabase
      .from("transactions")
      .select("id, created_at, payment_method, subtotal, total, paid, change_amount, status")
      .eq("outlet_id", outletId)
      .gte("created_at", startIso)
      .lt("created_at", endIso)
      .order("created_at", { ascending: true });
    if (txnError) {
      return json({ ok: false, error: txnError.message }, 500);
    }
    const txnList = (txns ?? []) as Record<string, unknown>[];
    // Item per transaksi (untuk kolom Item di tab Transaksi).
    const itemsByTxn = new Map<string, string>();
    const txnIds = txnList.map((t) => String(t['id']));
    if (txnIds.length > 0) {
      const { data: items, error: itemsError } = await supabase
        .from("transaction_items")
        .select("transaction_id, name_snapshot, qty")
        .in("transaction_id", txnIds);
      if (itemsError) {
        return json({ ok: false, error: itemsError.message }, 500);
      }
      for (const it of (items ?? []) as Record<string, unknown>[]) {
        const key = String(it['transaction_id']);
        const label = `${it['name_snapshot']} x${it['qty']}`;
        itemsByTxn.set(key, itemsByTxn.has(key) ? `${itemsByTxn.get(key)}, ${label}` : label);
      }
    }
    const { data: stock, error: stockError } = await supabase
      .from("stock_items")
      .select("name, unit, qty, low_threshold, cost")
      .eq("outlet_id", outletId)
      .order("name", { ascending: true });
    if (stockError) {
      return json({ ok: false, error: stockError.message }, 500);
    }
    const { data: expenses, error: expError } = await supabase
      .from("expenses")
      .select("created_at, category, description, amount")
      .eq("outlet_id", outletId)
      .gte("created_at", startIso)
      .lt("created_at", endIso)
      .order("created_at", { ascending: true });
    if (expError) {
      return json({ ok: false, error: expError.message }, 500);
    }
    const stockList = (stock ?? []) as Record<string, unknown>[];
    const expList = (expenses ?? []) as Record<string, unknown>[];

    // --- Susun isi 4 tab ---
    const emptyNote =
      "Belum ada data di Supabase untuk gerai + tanggal ini — penjualan masih tersimpan lokal di HP (sinkronisasi penjualan belum ada).";
    const summary = (summaryRows ?? [])[0] as Record<string, unknown> | undefined;
    const summaryValues: unknown[][] = [
      ["Tanggal", "Gerai (outlet_id)", "Jumlah Transaksi", "Omzet (Rp)", "Tunai (Rp)", "Transfer (Rp)", "QRIS Manual (Rp)", "E-Wallet (Rp)"],
      [
        date,
        outletId,
        summary?.['jumlah_transaksi'] ?? 0,
        summary?.['omzet'] ?? 0,
        summary?.['tunai'] ?? 0,
        summary?.['transfer'] ?? 0,
        summary?.['qris_manual'] ?? 0,
        summary?.['ewallet'] ?? 0,
      ],
    ];
    if (summary == null) summaryValues.push(["Catatan", emptyNote]);

    const txnValues: unknown[][] = [
      ["Waktu", "ID Transaksi", "Item", "Cara Bayar", "Subtotal (Rp)", "Total (Rp)", "Dibayar (Rp)", "Kembalian (Rp)", "Status"],
    ];
    for (const t of txnList) {
      txnValues.push([
        String(t['created_at'] ?? "").replace("T", " ").slice(0, 19),
        String(t['id'] ?? ""),
        itemsByTxn.get(String(t['id'])) ?? "-",
        String(t['payment_method'] ?? ""),
        t['subtotal'] ?? 0,
        t['total'] ?? 0,
        t['paid'] ?? 0,
        t['change_amount'] ?? 0,
        String(t['status'] ?? ""),
      ]);
    }
    if (txnList.length === 0) txnValues.push(["Catatan", emptyNote]);

    const stockValues: unknown[][] = [
      ["Nama Bahan", "Satuan", "Stok", "Ambang Rendah", "Harga/Satuan (Rp)"],
    ];
    for (const s of stockList) {
      stockValues.push([s['name'] ?? "", s['unit'] ?? "", s['qty'] ?? 0, s['low_threshold'] ?? 0, s['cost'] ?? 0]);
    }
    if (stockList.length === 0) {
      stockValues.push(["Catatan", "Belum ada data stok di Supabase untuk gerai ini."]);
    }

    const expValues: unknown[][] = [
      ["Waktu", "Kategori", "Deskripsi", "Jumlah (Rp)"],
    ];
    for (const e of expList) {
      expValues.push([
        String(e['created_at'] ?? "").replace("T", " ").slice(0, 19),
        e['category'] ?? "",
        e['description'] ?? "",
        e['amount'] ?? 0,
      ]);
    }
    if (expList.length === 0) {
      expValues.push(["Catatan", "Belum ada pengeluaran di Supabase untuk gerai + tanggal ini."]);
    }

    // --- Tulis ke Google Sheets ---
    const token = await googleAccessToken(sa);
    const meta = await sheetsFetch(token, `spreadsheets/${spreadsheetId}`);
    const existing = new Set(
      ((meta.sheets as { properties?: { title?: string } }[] | undefined) ?? [])
        .map((s) => s.properties?.title)
        .filter((t): t is string => typeof t === "string"),
    );
    const missing = TABS.filter((t) => !existing.has(t));
    if (missing.length > 0) {
      await sheetsFetch(token, `spreadsheets/${spreadsheetId}:batchUpdate`, {
        method: "POST",
        body: JSON.stringify({
          requests: missing.map((title) => ({ addSheet: { properties: { title } } })),
        }),
      });
    }
    // Bersihkan isi lama tiap tab dulu (tulis ulang dari A1 — tanpa
    // clear, baris lama yang lebih panjang akan tertinggal di bawah).
    // Range di sini = NAMA TAB saja (seluruh sheet), BUKAN 'Tab'!A1
    // (itu hanya membersihkan sel A1).
    await sheetsFetch(token, `spreadsheets/${spreadsheetId}/values:batchClear`, {
      method: "POST",
      body: JSON.stringify({
        ranges: TABS.map((t) => `'${t.replaceAll("'", "''")}'`),
      }),
    });
    await sheetsFetch(token, `spreadsheets/${spreadsheetId}/values:batchUpdate`, {
      method: "POST",
      body: JSON.stringify({
        valueInputOption: "USER_ENTERED",
        data: [
          { range: tabRange("Ringkasan Harian"), values: summaryValues },
          { range: tabRange("Transaksi"), values: txnValues },
          { range: tabRange("Stok/Bahan"), values: stockValues },
          { range: tabRange("Pengeluaran"), values: expValues },
        ],
      }),
    });

    const counts = {
      transactions: txnList.length,
      stock_items: stockList.length,
      expenses: expList.length,
      summary_rows: summary == null ? 0 : 1,
    };
    return json({
      ok: true,
      spreadsheet_id: spreadsheetId,
      date,
      outlet_id: outletId,
      counts,
      ...(txnList.length === 0 ? { note: emptyNote } : {}),
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
