-- SUKA TEA — Migrasi 010 (Batch C8.2: registri kasir + nama kasir per
-- penjualan + shift per gerai, penutup shift untuk audit)
-- Dijalankan via SQL Editor Supabase Dashboard (bukan CLI).
--
-- Tabel `cashiers` BARU: kasir yang didaftarkan Owner (nama + hash
-- PIN 6 digit). PIN berlaku di SEMUA gerai (tidak ada outlet_id di
-- tabel ini — identitas kasir global, PIN diverifikasi lewat Edge
-- Function verify-cashier-pin). `active` = false berarti kasir
-- dinonaktifkan Owner (PIN-nya tidak bisa dipakai login lagi).
-- Nama kasir AKTIF harus unik (dijaga Edge Function register-cashier,
-- bukan CHECK — perbandingan case-insensitive tidak bisa di CHECK
-- sederhana; nama unik dipakai sebagai kunci kasir di `expenses`
-- yang hanya menyimpan cashier_name).
--
-- `transactions.cashier_id` / `cashier_name`: kasir pencatat penjualan
-- (W4 — dulu hanya tampil di struk, tidak tersimpan). cashier_id
-- nullable (penjualan lama + penjualan Owner = null); cashier_name
-- default '' (Owner = 'Owner', tanpa sesi = 'Kasir').
-- `cash_shifts.cashier_id` / `cashier_name`: kasir PEMBUKA shift
-- (untuk kartu "Kas & Shift" + audit). cashier_name sudah ada sejak
-- 009 (IF NOT EXISTS = no-op); cashier_id baru.
-- `cash_shifts.closed_by_cashier_id` / `closed_by_cashier_name`:
-- kasir/Owner PENUTUP shift (audit — siapa pun boleh menutup shift,
-- expected dihitung dari SEMUA kasir, koreksi WS6 24 Nov 14:07).
--
-- RLS cashiers diaktifkan tanpa policy (anon/authenticated ditolak;
-- service_role bypass) — sama seperti tabel lain sebelum Auth M0;
-- semua akses lewat Edge Function service_role.
-- service_role GRANTs supaya Edge Function cashier + sync-sales
-- bisa baca/tulis — pola yang sama dengan 005/008/009.

-- ============ cashiers: tabel baru ============
create table if not exists public.cashiers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  pin_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.cashiers enable row level security;

grant select, insert, update, delete
  on table public.cashiers to service_role;

-- ============ transactions: kasir pencatat ============
alter table public.transactions
  add column if not exists cashier_id uuid;

alter table public.transactions
  add column if not exists cashier_name text not null default '';

-- ============ cash_shifts: pembuka + penutup ============
alter table public.cash_shifts
  add column if not exists cashier_id uuid;

alter table public.cash_shifts
  add column if not exists cashier_name text not null default '';

alter table public.cash_shifts
  add column if not exists closed_by_cashier_id uuid;

alter table public.cash_shifts
  add column if not exists closed_by_cashier_name text not null default '';

-- Sudah ada di 009, diulang supaya 010 mandiri bila dijalankan
-- tanpa 009 (grant itu idempotent).
grant select, insert, update, delete
  on table public.cash_shifts to service_role;
