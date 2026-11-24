-- SUKA TEA — Migrasi 012 (SEC-1 R-04: pisah counter lockout Owner vs Kasir)
-- Dijalankan via SQL Editor Supabase Dashboard (bukan CLI).
-- FILE SAJA — belum di-apply ke prod (Jhon yang deploy + apply).
--
-- MASALAH (audit RedMuse R-04, MEDIUM): satu tabel `pin_attempts`
-- dipakai SEMUA peran. 10x PIN kasir salah mengunci login Owner
-- (dan sebaliknya) — satu penyerang anonim bisa mengunci semua
-- login tanpa tahu PIN apa pun.
--
-- PERBAIKAN: kolom `purpose` ('owner' | 'cashier'). Tiap Edge
-- Function menghitung + menulis percobaan dengan purpose perannya
-- sendiri, jadi lockout Owner dan Kasir terpisah.
--
-- Baris LAMA mendapat DEFAULT 'owner': mayoritas percobaan PIN di
-- masa lalu adalah PIN Owner (verify-owner-pin + 7 EF bukti Owner),
-- dan semuanya kedaluwarsa dalam 10 menit — aman.
--
-- JANGAN menambah policy RLS: `pin_attempts` sengaja TANPA policy
-- (hanya service_role yang bisa akses; anon/authenticated ditolak).

alter table public.pin_attempts
  add column if not exists purpose text not null default 'owner';

-- Index bantu hitungan rate limit per peran + outlet (pola query
-- semua EF: outlet_id + success=false + purpose + created_at >= since).
create index if not exists pin_attempts_rate_idx
  on public.pin_attempts (outlet_id, purpose, success, created_at);
