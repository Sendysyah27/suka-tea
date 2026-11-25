-- SUKA TEA — Migrasi 014 (Batch v40: kontrol kasir Owner)
-- Dijalankan via SQL Editor Supabase Dashboard (bukan CLI),
-- SETELAH app v40 terinstall (aturan deploy: app dulu, server
-- kemudian). Idempotent (IF NOT EXISTS) supaya aman diulang.
--
-- cashiers: kolom kontrol (izin void/diskon/tutup-shift, paksa
-- ganti PIN) + presence (terakhir sync + gerai terakhir) + kick
-- (kicked_at) + arsip resign (resigned_at).
-- cashier_outlets BARU: gerai yang boleh dimasuki kasir (backfill:
-- semua kasir lama boleh ke-4 gerai = perilaku lama).
-- cashier_login_events BARU: audit login (satu baris per login
-- sukses, ditulis verify-cashier-pin).
--
-- RLS diaktifkan tanpa policy (anon/authenticated ditolak;
-- service_role bypass) — sama seperti tabel lain sebelum Auth M0;
-- semua akses lewat Edge Function service_role.

-- ============ cashiers: kolom kontrol + presence ============
alter table public.cashiers
  add column if not exists can_void boolean not null default true,
  add column if not exists can_discount boolean not null default false,
  add column if not exists can_close_shift boolean not null default true,
  add column if not exists force_pin_change boolean not null default false,
  add column if not exists kicked_at timestamptz,
  add column if not exists resigned_at timestamptz,
  add column if not exists last_seen_at timestamptz,
  add column if not exists last_outlet_id uuid,
  add column if not exists updated_at timestamptz not null default now();

-- Backfill perilaku LAMA untuk kasir yang sudah ada (jangan cabut
-- diam-diam izin yang sudah mereka punya): void + diskon + tutup
-- shift tetap boleh (seperti sebelum v40 — tidak ada gate).
-- Kasir BARU sesudah v40 default kolom di atas: can_void true,
-- can_discount FALSE (frame 28: Budi diskon OFF),
-- can_close_shift true.
update public.cashiers
set can_void = true,
    can_discount = true,
    can_close_shift = true
where can_void is null or can_discount is null or can_close_shift is null;

-- ============ cashier_outlets: gerai yang boleh dimasuki kasir ============
create table if not exists public.cashier_outlets (
  cashier_id uuid not null references public.cashiers(id),
  outlet_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (cashier_id, outlet_id)
);

alter table public.cashier_outlets enable row level security;

grant select, insert, update, delete
  on table public.cashier_outlets to service_role;

-- Backfill: SEMUA kasir yang ada boleh masuk ke-4 gerai (perilaku
-- lama: PIN berlaku di semua gerai).
insert into public.cashier_outlets (cashier_id, outlet_id)
select c.id, o.id
from public.cashiers c
cross join (values
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003'),
  ('00000000-0000-0000-0000-000000000004')
) as o(id)
on conflict (cashier_id, outlet_id) do nothing;

-- ============ cashier_login_events: audit login ============
create table if not exists public.cashier_login_events (
  id uuid primary key default gen_random_uuid(),
  cashier_id uuid not null references public.cashiers(id),
  cashier_name text not null default '',
  outlet_id uuid not null,
  login_at timestamptz not null default now()
);

alter table public.cashier_login_events enable row level security;

grant select, insert
  on table public.cashier_login_events to service_role;

-- Index: riwayat login dibaca per kasir + terbaru dulu (frame 30).
create index if not exists cashier_login_events_cashier_idx
  on public.cashier_login_events (cashier_id, login_at desc);
create index if not exists cashier_login_events_login_idx
  on public.cashier_login_events (login_at desc);
