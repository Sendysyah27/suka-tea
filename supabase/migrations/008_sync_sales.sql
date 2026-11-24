-- SUKA TEA — 008_sync_sales.sql
-- Sinkronisasi penjualan per-gerai (Batch C6).
-- Terapkan via dashboard Supabase > SQL Editor (seperti 003-007):
-- copy-paste seluruh file ini, Run.
--
-- 1) Cara bayar 'split' (QRIS + Tunai, Batch C2) masuk ke
--    transactions — selama ini CHECK hanya mengizinkan
--    tunai/transfer/qris/qris_manual/ewallet, jadi transaksi split
--    DITOLAK server. Pola drop + recreate sama seperti migrasi 002.
-- 2) Kolom baru di transactions: discount + qris_amount +
--    cash_amount — supaya baris yang disinkronkan menyimpan
--    rincian yang sama dengan riwayat lokal (dan bisa dibaca
--    kembali utuh oleh pull). Baris lama = 0 (bukan split).
-- 3) View v_daily_summary: tambah kolom 'split' (drop + recreate,
--    pola 002 — CREATE OR REPLACE tidak bisa menyisipkan kolom).
-- 4) stock_movements.client_uuid (unique) — kunci idempotency
--    mutasi stok, supaya kirim ulang tidak menggandakan mutasi
--    maupun level stok.
-- 5) Unique index stock_items(outlet_id, name) — syarat upsert
--    stok per (gerai, nama bahan) dari Edge Function sync-sales.
--    Asumsi: tabel stock_items masih kosong (tidak pernah ada
--    sinkronisasi sebelumnya); bila index gagal karena duplikat,
--    bersihkan duplikat manual dulu, lalu jalankan ulang file ini.
-- 6) GRANT eksplisit untuk service_role atas tabel 001
--    (transactions, transaction_items, stock_items,
--    stock_movements, expenses) + SELECT atas v_daily_summary +
--    outlets. Tabel-tabel itu dibuat migrasi 001 — SEBELUM
--    migrasi 005 — jadi TIDAK membawa GRANT service_role
--    (jebakan yang sama dengan bug #2 PIN: service_role bypass
--    RLS tapi tetap butuh GRANT tabel; tanpa ini Edge Function
--    gagal "permission denied").
-- RLS TIDAK berubah di sini. anon/authenticated tidak disentuh.

-- 1) Cara bayar 'split'.
alter table public.transactions drop constraint if exists transactions_payment_method_check;
alter table public.transactions add constraint transactions_payment_method_check
  check (payment_method in ('tunai', 'transfer', 'qris', 'qris_manual', 'ewallet', 'split'));

-- 2) Kolom rincian transaksi.
alter table public.transactions
  add column if not exists discount integer not null default 0 check (discount >= 0);
alter table public.transactions
  add column if not exists qris_amount integer not null default 0 check (qris_amount >= 0);
alter table public.transactions
  add column if not exists cash_amount integer not null default 0 check (cash_amount >= 0);

-- 3) View ringkasan harian + kolom split.
drop view if exists public.v_daily_summary;
create view public.v_daily_summary as
select
  t.outlet_id,
  date_trunc('day', t.created_at)::date as hari,
  count(*) as jumlah_transaksi,
  sum(case when t.payment_method = 'tunai' then t.total else 0 end) as tunai,
  sum(case when t.payment_method = 'transfer' then t.total else 0 end) as transfer,
  sum(case when t.payment_method = 'qris' then t.total else 0 end) as qris,
  sum(case when t.payment_method = 'qris_manual' then t.total else 0 end) as qris_manual,
  sum(case when t.payment_method = 'ewallet' then t.total else 0 end) as ewallet,
  sum(case when t.payment_method = 'split' then t.total else 0 end) as split,
  sum(t.total) as omzet
from transactions t
where t.status = 'completed'
group by t.outlet_id, date_trunc('day', t.created_at)::date;

-- 4) Idempotency mutasi stok.
alter table public.stock_movements
  add column if not exists client_uuid uuid unique;

-- 5) Upsert stok per (gerai, nama bahan).
create unique index if not exists stock_items_outlet_name_key
  on public.stock_items (outlet_id, name);

-- 6) GRANT service_role (Edge Functions) atas tabel 001.
grant select, insert, update, delete on table public.transactions to service_role;
grant select, insert, update, delete on table public.transaction_items to service_role;
grant select, insert, update, delete on table public.stock_items to service_role;
grant select, insert, update, delete on table public.stock_movements to service_role;
grant select, insert, update, delete on table public.expenses to service_role;
grant select on table public.v_daily_summary to service_role;
grant select on table public.outlets to service_role;
