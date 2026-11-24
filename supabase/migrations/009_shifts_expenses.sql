-- SUKA TEA — Migrasi 009 (Batch C7: tutup kas + pengeluaran)
-- Dijalankan via SQL Editor Supabase Dashboard (bukan CLI).
--
-- KOREKSI vs catatan awal C7: tabel `expenses` di 001 ternyata
-- SUDAH punya outlet_id (uuid not null, references outlets) — yang
-- belum ada hanya client_uuid / is_cash / cashier_name. Migrasi ini
-- hanya menambah 3 kolom itu (idempotent: IF NOT EXISTS).
-- Tabel `cash_shifts` BARU (satu baris per shift buka s.d. tutup).
-- service_role GRANTs supaya Edge Function sync-sales (JWT ON,
-- service_role) bisa upsert/hapus — pola yang sama dengan 005/008.
-- RLS cash_shifts diaktifkan tanpa policy (anon/authenticated
-- ditolak; service_role bypass) — sama seperti tabel lain sebelum
-- Auth M0; baca Owner lewat app saat ini hanya via EF pull
-- (transaksi) — pull shift/expense belum dibangun (di luar C7).

-- ============ expenses: kolom sinkronisasi ============
alter table public.expenses
  add column if not exists client_uuid uuid unique;

alter table public.expenses
  add column if not exists is_cash boolean not null default true;

alter table public.expenses
  add column if not exists cashier_name text not null default '';

-- ============ cash_shifts: tabel baru ============
create table if not exists public.cash_shifts (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid references public.outlets(id) on delete cascade,
  cashier_name text,
  opened_at timestamptz not null,
  opening_float integer not null default 0 check (opening_float >= 0),
  closed_at timestamptz,
  counted_cash integer check (counted_cash >= 0),
  expected_cash integer check (expected_cash >= 0),
  difference integer,
  status text not null default 'open'
    check (status in ('open', 'closed')),
  note text not null default '',
  client_uuid uuid unique,
  created_at timestamptz not null default now()
);

alter table public.cash_shifts enable row level security;

-- ============ GRANTs service_role (EF sync-sales) ============
grant select, insert, update, delete
  on table public.cash_shifts to service_role;

-- Sudah ada di 008, diulang supaya 009 mandiri bila dijalankan
-- tanpa 008 (grant itu idempotent).
grant select, insert, update, delete
  on table public.expenses to service_role;
