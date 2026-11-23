-- SUKA TEA — 005_service_role_grants.sql
-- GRANT eksplisit untuk service_role (Edge Functions), 23 Nov 2026.
--
-- Akar masalah: tabel yang dibuat migrasi 001–004 tidak membawa GRANT
-- untuk service_role. Akibatnya Edge Function gagal dengan
-- "permission denied for table app_settings" saat upsert (set-owner-pin),
-- dan SELECT-nya gagal DIAM-DIAM karena error baca ditelan kode —
-- fungsi menyangka "PIN belum diatur" padahal bacanya pun ditolak.
-- SQL Editor jalan normal karena ia berjalan sebagai postgres (owner tabel).
--
-- RLS TIDAK berubah: service_role memang bypass RLS, tapi GRANT tabel
-- tetap wajib. anon/authenticated tidak disentuh di sini.

grant select, insert, update, delete on table public.app_settings to service_role;
grant select, insert, update, delete on table public.pin_attempts to service_role;

-- Cegah terulang: tabel baru yang dibuat postgres di schema public
-- otomatis memberi GRANT yang sama ke service_role ke depannya.
alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to service_role;
