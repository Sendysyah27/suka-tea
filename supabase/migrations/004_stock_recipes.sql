-- SUKA TEA — 004_stock_recipes.sql
-- Resep stok (22 Nov 2026): tiap varian produk memakai sejumlah bahan
-- baku per cup; penjualan memotong stok otomatis (lokal dulu, sinkron
-- Supabase di M1).
--
-- CATATAN: tabel stock_items SUDAH ADA dari 001_init.sql (dengan kolom
-- cost, tanpa unique) — JANGAN dibuat ulang di sini. Migrasi ini hanya
-- menambah unique index (outlet_id, name) + tabel product_recipes.
-- variant_id/product_id memakai id lokal app (string, mis.
-- 'manggo-milktea_r'); pemetaan ke uuid Supabase dilakukan saat
-- sinkronisasi M1.
-- BELUM di-apply live (seperti 003) — apply via dashboard/CLI sesudah
-- M0 Auth jalan.

-- Satu nama bahan per outlet (001 belum punya constraint ini).
create unique index if not exists stock_items_outlet_name_key
  on stock_items (outlet_id, name);

create table if not exists product_recipes (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  product_id text not null, -- id lokal app, mis. 'manggo-milktea'
  variant_id text not null, -- id lokal app, mis. 'manggo-milktea_r'
  stock_item_id uuid not null references stock_items(id) on delete cascade,
  qty numeric not null check (qty > 0), -- pemakaian per 1 cup
  unique (variant_id, stock_item_id)
);

alter table product_recipes enable row level security;

-- Resep: anggota baca; tulis hanya Owner (Kasir read-only) — pola 001.
create policy "member baca resep" on product_recipes
  for select using (is_outlet_member(outlet_id));
create policy "owner tulis resep" on product_recipes
  for all using (is_outlet_owner(outlet_id));
